(() => {
  "use strict";

  const DAYS = ["Fri", "Sat", "Sun", "All"];
  const DAY_NAMES = { Mon: "Monday", Tue: "Tuesday", Wed: "Wednesday", Thu: "Thursday", Fri: "Friday", Sat: "Saturday", Sun: "Sunday", All: "All Days" };
  // Items saved as "Multiple Days" before the change count as "All Days".
  const dayOf = (i) => (i.day === "Multiple" ? "All" : i.day);
  const MEALS = ["Breakfast", "Lunch", "Dinner", "Snacks"];
  const TITLES = { all: "All Items", day: "By Day", meal: "By Meal", aisle: "By Aisle" };
  // Sainsbury's sections in typical walk order. Keep in sync with netlify/functions/aisles.mjs.
  const AISLES = ["Fruit & Veg", "Bakery", "Meat & Poultry", "Fish & Seafood", "Deli & Cheese", "Dairy & Eggs",
    "Chilled & Ready Meals", "Frozen", "Food Cupboard", "Baking & Home Cooking", "World Foods", "Cereals & Spreads",
    "Tea & Coffee", "Crisps & Snacks", "Chocolate & Sweets", "Soft Drinks & Juice", "Beer, Wine & Spirits",
    "Christmas & Seasonal", "Household", "Health & Beauty", "Baby", "Pet", "Home & Clothing"];
  const API = "/api/items";
  const POLL_MS = 8000;

  // ---------- Local state (localStorage = offline source of truth) ----------
  const load = (k, d) => { try { return JSON.parse(localStorage.getItem(k)) ?? d; } catch { return d; } };
  const persist = () => {
    try {
      localStorage.setItem("cs-items", JSON.stringify(items));
      localStorage.setItem("cs-outbox", JSON.stringify(outbox));
      localStorage.setItem("cs-tab", tab);
      if (me) localStorage.setItem("cs-me", JSON.stringify(me));
      localStorage.setItem("cs-aisles", JSON.stringify(aisleMap));
    } catch {}
  };
  let items = load("cs-items", {});   // id -> item (incl. tombstones)
  let outbox = load("cs-outbox", {}); // id -> item waiting to upload
  let tab = load("cs-tab", "all");
  let aisleMap = load("cs-aisles", {}); // normalised item name -> aisle
  if (typeof tab !== "string" || !TITLES[tab]) tab = "all";

  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const uid = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
  const haptic = (ms = 8) => { try { navigator.vibrate && navigator.vibrate(ms); } catch {} };
  const live = () => Object.values(items).filter((i) => !i.deleted);

  // ---------- Who am I (stored on this device only) ----------
  const COLORS = ["#007AFF", "#FF9500", "#AF52DE", "#FF2D55", "#30B0C7", "#5856D6", "#D4A900", "#A2845E", "#00A89F", "#8E8E93"];
  let me = load("cs-me", null); // { name, color }
  if (!me || typeof me.name !== "string" || !me.name.trim()) me = null;
  const firstName = (n) => String(n).trim().split(/\s+/)[0];
  const sameName = (a, b) => String(a || "").trim().toLowerCase() === String(b || "").trim().toLowerCase();
  // Reuse the colour this name already has on the list; otherwise take the first colour nobody uses.
  function colorFor(name) {
    const mine = live().find((i) => sameName(i.by, name) && i.color);
    if (mine) return mine.color;
    const used = new Set(live().filter((i) => i.by && !sameName(i.by, name)).map((i) => i.color));
    return COLORS.find((c) => !used.has(c)) || COLORS[0];
  }

  function save(item) {
    item.updatedAt = Math.max(Date.now(), (items[item.id]?.updatedAt || 0) + 1);
    items[item.id] = item;
    outbox[item.id] = item;
    persist();
    render();
    sync();
  }
  function remove(id) {
    const old = items[id];
    if (!old) return;
    save({ id, deleted: true });
    toast(`Deleted “${old.name}”`, "Undo", () => save({ ...old }));
  }

  // ---------- Sync ----------
  let syncing = false, again = false, online = navigator.onLine;
  function setStatus(s) {
    const el = $("sync");
    el.className = "sync " + s;
    el.textContent = s === "offline" ? "Offline" : s === "syncing" ? "Syncing" : "Synced";
  }
  function merge(remote) {
    let changed = false;
    for (const r of remote) {
      const local = items[r.id];
      const pending = outbox[r.id];
      if (pending && pending.updatedAt > r.updatedAt) continue;
      if (!local || r.updatedAt > local.updatedAt || (r.updatedAt === local.updatedAt && JSON.stringify(r) !== JSON.stringify(local))) {
        items[r.id] = r; changed = true;
      }
      if (pending && pending.updatedAt <= r.updatedAt) delete outbox[r.id];
    }
    return changed;
  }
  async function sync() {
    if (syncing) { again = true; return; }
    syncing = true;
    setStatus("syncing");
    try {
      const pending = Object.values(outbox);
      if (pending.length) {
        const res = await fetch(API, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ changes: pending }) });
        if (!res.ok) throw new Error("push " + res.status);
        const { items: saved } = await res.json();
        for (const p of pending) if (outbox[p.id] && outbox[p.id].updatedAt === p.updatedAt) delete outbox[p.id];
        merge(saved);
      }
      const res = await fetch(API, { cache: "no-store" });
      if (!res.ok) throw new Error("pull " + res.status);
      const { items: remote } = await res.json();
      const changed = merge(remote);
      persist();
      if (changed) render();
      online = true;
      setStatus(Object.keys(outbox).length ? "syncing" : "");
      fetchAisles();
    } catch (e) {
      online = false;
      setStatus("offline");
    } finally {
      syncing = false;
      if (again) { again = false; sync(); }
    }
  }
  setInterval(() => { if (document.visibilityState === "visible") sync(); }, POLL_MS);
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") sync(); });
  window.addEventListener("online", sync);
  window.addEventListener("offline", () => setStatus("offline"));

  // ---------- Aisle sorting (Claude, via /api/aisles; cached per item name) ----------
  const normName = (s) => String(s).trim().toLowerCase().replace(/\s+/g, " ").slice(0, 200);
  let aisleBusy = false, aisleFailAt = 0;
  async function fetchAisles() {
    const names = [...new Set(live().map((i) => normName(i.name)))].filter((n) => !aisleMap[n]);
    if (!names.length || aisleBusy || !navigator.onLine || Date.now() - aisleFailAt < 30000) return;
    aisleBusy = true;
    if (tab === "aisle") render();
    try {
      const res = await fetch("/api/aisles", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ names }) });
      const data = await res.json().catch(() => ({}));
      Object.assign(aisleMap, data.aisles || {});
      if (!res.ok) aisleFailAt = Date.now();
      persist();
    } catch { aisleFailAt = Date.now(); }
    aisleBusy = false;
    if (tab === "aisle") render();
  }

  // ---------- Rendering ----------
  const byName = (a, b) => (a.done - b.done) || a.name.localeCompare(b.name, undefined, { sensitivity: "base" });
  const CHECK = '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const CHEV = '<svg class="chev" width="8" height="14" viewBox="0 0 8 14"><path d="M1 1l6 6-6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  function rowHTML(it, hide) {
    const tags = [];
    if (it.day && hide !== "day") tags.push(`<span class="tag day">${esc(DAY_NAMES[dayOf(it)] || it.day)}</span>`);
    if (it.meal && hide !== "meal") tags.push(`<span class="tag meal">${esc(it.meal)}</span>`);
    return `<div class="row-wrap" data-id="${esc(it.id)}">
      <button class="row-delete" data-act="delete">Delete</button>
      <div class="row ${it.done ? "done" : ""}" data-act="edit">
        <button class="check" data-act="toggle" aria-label="${it.done ? "Mark as not bought" : "Mark as bought"}">${CHECK}</button>
        <div class="row-main">
          <div class="row-title">${it.by ? `<span class="who" style="background:${esc(it.color || "#8E8E93")}" title="Added by ${esc(it.by)}"></span>` : ""}${esc(it.name)}${it.qty ? ` <span class="row-qty">· ${esc(it.qty)}</span>` : ""}</div>
          ${tags.length ? `<div class="tags">${tags.join("")}</div>` : ""}
        </div>
        ${CHEV}
      </div>
    </div>`;
  }
  function section(title, list, hide) {
    if (!list.length) return "";
    const left = list.filter((i) => !i.done).length;
    return `<div class="section-header"><span>${esc(title)}</span><span>${left ? left + " to buy" : "All bought ✓"}</span></div>
      <div class="list">${list.sort(byName).map((i) => rowHTML(i, hide)).join("")}</div>`;
  }

  function render() {
    const all = live();
    const left = all.filter((i) => !i.done).length;
    const done = all.length - left;
    $("title").textContent = TITLES[tab];
    $("counts").textContent = all.length ? `${left} to buy` : "";
    $("clearDone").textContent = done ? `Clear ${done} Bought Item${done > 1 ? "s" : ""}` : "No Bought Items";
    $("clearDone").disabled = done === 0;
    $("me").innerHTML = me ? `<span class="dot" style="background:${esc(me.color)}"></span>${esc(firstName(me.name))}` : "";
    document.querySelectorAll(".tab").forEach((t) => {
      const on = t.dataset.tab === tab;
      t.classList.toggle("active", on);
      t.setAttribute("aria-selected", on);
    });

    let html = "";
    if (!all.length) {
      html = `<div class="empty"><div class="big">🎄</div><h3>Nothing on the list yet</h3>Tap <b>Add</b> to put the first item on the shared list.</div>`;
    } else if (tab === "all") {
      html = `<div class="list">${all.sort(byName).map((i) => rowHTML(i)).join("")}</div>`;
    } else if (tab === "day") {
      for (const d of DAYS) html += section(DAY_NAMES[d], all.filter((i) => dayOf(i) === d), "day");
      html += section("Other Days", all.filter((i) => !DAYS.includes(dayOf(i))), "");
    } else if (tab === "aisle") {
      for (const a of AISLES) html += section(a, all.filter((i) => aisleMap[normName(i.name)] === a), "");
      const unsorted = all.filter((i) => !AISLES.includes(aisleMap[normName(i.name)]));
      html += section(aisleBusy ? "Sorting…" : "Not Sorted Yet", unsorted, "");
      if (unsorted.length && !aisleBusy && !online) html += `<p class="note">Items are sorted into aisles when the phone is online.</p>`;
    } else {
      for (const m of MEALS) html += section(m, all.filter((i) => i.meal === m), "meal");
      html += section("No Meal", all.filter((i) => !MEALS.includes(i.meal)), "meal");
    }
    $("content").innerHTML = html;
  }

  // ---------- Tabs, scroll ----------
  document.querySelector(".tabbar").addEventListener("click", (e) => {
    const t = e.target.closest(".tab");
    if (!t || t.dataset.tab === tab) return;
    haptic(5);
    tab = t.dataset.tab;
    persist();
    render();
    if (tab === "aisle") fetchAisles();
    window.scrollTo(0, 0);
  });
  const onScroll = () => $("nav").classList.toggle("scrolled", window.scrollY > 4);
  window.addEventListener("scroll", onScroll, { passive: true });

  // ---------- Pull to refresh ----------
  const PTR_TRIGGER = 64;
  let ptr = null, refreshing = false;
  const ptrEl = $("ptr");
  const setPull = (d) => {
    ptrEl.style.transform = `translateY(${Math.min(d, 90) - 44}px)`;
    ptrEl.style.opacity = Math.min(1, d / PTR_TRIGGER);
    ptrEl.firstElementChild.style.transform = `rotate(${d * 4}deg)`;
  };
  window.addEventListener("touchstart", (e) => {
    if (refreshing || window.scrollY > 0 || $("sheet").classList.contains("open") || e.touches.length > 1) return;
    ptr = { y: e.touches[0].clientY, x: e.touches[0].clientX, d: 0, armed: false };
  }, { passive: true });
  window.addEventListener("touchmove", (e) => {
    if (!ptr) return;
    const dy = e.touches[0].clientY - ptr.y, dx = e.touches[0].clientX - ptr.x;
    if (dy <= 0 || Math.abs(dx) > Math.abs(dy) || window.scrollY > 0) { if (dy < 0) { ptr = null; setPull(0); } return; }
    ptr.d = dy * 0.5; // resistance
    if (!ptr.armed && ptr.d >= PTR_TRIGGER) { ptr.armed = true; haptic(10); }
    if (ptr.armed && ptr.d < PTR_TRIGGER) ptr.armed = false;
    ptrEl.classList.remove("settle");
    setPull(ptr.d);
  }, { passive: true });
  window.addEventListener("touchend", async () => {
    if (!ptr) return;
    const armed = ptr.armed;
    ptr = null;
    ptrEl.classList.add("settle");
    if (!armed) { setPull(0); return; }
    refreshing = true;
    setPull(PTR_TRIGGER);
    ptrEl.classList.add("spinning");
    aisleFailAt = 0;
    await Promise.all([sync(), new Promise((r) => setTimeout(r, 600))]);
    await fetchAisles();
    ptrEl.classList.remove("spinning");
    setPull(0);
    refreshing = false;
  });

  $("clearDone").addEventListener("click", () => {
    const done = live().filter((i) => i.done);
    if (!done.length || !confirm(`Remove ${done.length} bought item${done.length > 1 ? "s" : ""} from the list for everyone?`)) return;
    for (const i of done) save({ id: i.id, deleted: true });
  });

  // ---------- Row interactions: tap, check, swipe-to-delete ----------
  let openRow = null;
  const closeOpenRow = () => { if (openRow) { openRow.style.transform = ""; openRow = null; } };

  $("content").addEventListener("click", (e) => {
    const wrap = e.target.closest(".row-wrap");
    if (!wrap) return;
    const id = wrap.dataset.id;
    const act = e.target.closest("[data-act]")?.dataset.act;
    if (swiped) { swiped = false; return; }
    if (act === "delete") { haptic(15); closeOpenRow(); remove(id); return; }
    if (openRow) { closeOpenRow(); return; }
    if (act === "toggle") { haptic(10); save({ ...items[id], done: !items[id].done }); return; }
    if (act === "edit") openSheet(items[id]);
  });

  let drag = null, swiped = false;
  $("content").addEventListener("pointerdown", (e) => {
    const row = e.target.closest(".row");
    if (!row || e.button > 0) return;
    if (openRow && openRow !== row) closeOpenRow();
    drag = { row, x: e.clientX, y: e.clientY, base: row === openRow ? -80 : 0, dx: 0, active: false };
  });
  window.addEventListener("pointermove", (e) => {
    if (!drag) return;
    const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
    if (!drag.active) {
      if (Math.abs(dy) > 10) { drag = null; return; }
      if (Math.abs(dx) < 10) return;
      drag.active = true;
      drag.row.classList.add("dragging");
    }
    drag.dx = Math.min(0, Math.max(-220, drag.base + dx));
    drag.row.style.transform = `translateX(${drag.dx}px)`;
  });
  const endDrag = () => {
    if (!drag) return;
    const { row, active, dx } = drag;
    drag = null;
    if (!active) return;
    swiped = true;
    setTimeout(() => (swiped = false), 50);
    row.classList.remove("dragging");
    if (dx < -180) { haptic(15); remove(row.parentElement.dataset.id); openRow = null; return; }
    if (dx < -44) { row.style.transform = "translateX(-80px)"; openRow = row; }
    else { row.style.transform = ""; if (openRow === row) openRow = null; }
  };
  window.addEventListener("pointerup", endDrag);
  window.addEventListener("pointercancel", endDrag);

  // ---------- Add / edit sheet ----------
  let editing = null, selDay = "", selMeal = "";
  $("dayChips").innerHTML = DAYS.map((d) => `<button type="button" class="chip" data-day="${d}">${d}</button>`).join("");
  $("mealSeg").innerHTML = MEALS.map((m) => `<button type="button" class="seg" data-meal="${m}">${m}</button>`).join("");

  function refreshForm() {
    document.querySelectorAll(".chip").forEach((c) => c.classList.toggle("on", c.dataset.day === selDay));
    document.querySelectorAll(".seg").forEach((s) => s.classList.toggle("on", s.dataset.meal === selMeal));
    $("saveBtn").disabled = !($("itemText").value.trim() && selDay);
  }
  $("dayChips").addEventListener("click", (e) => {
    const c = e.target.closest(".chip"); if (!c) return;
    haptic(5); selDay = c.dataset.day; refreshForm();
  });
  $("mealSeg").addEventListener("click", (e) => {
    const s = e.target.closest(".seg"); if (!s) return;
    haptic(5); selMeal = selMeal === s.dataset.meal ? "" : s.dataset.meal; refreshForm();
  });
  $("itemText").addEventListener("input", refreshForm);

  function openSheet(item) {
    closeOpenRow();
    editing = item || null;
    $("sheetTitle").textContent = item ? "Edit Item" : "New Item";
    $("saveLabel").textContent = item ? "Save Changes" : "Add Item";
    $("deleteBtn").hidden = !item;
    $("itemText").value = item?.name || "";
    $("itemQty").value = item?.qty || "";
    selDay = item ? (DAYS.includes(dayOf(item)) ? dayOf(item) : "") : "All";
    selMeal = item ? item.meal || "" : "";
    refreshForm();
    $("sheet").style.transform = "";
    $("sheet").classList.add("open");
    $("backdrop").classList.add("open");
    if (!item) setTimeout(() => $("itemText").focus(), 60);
  }
  function closeSheet() {
    document.activeElement?.blur();
    $("sheet").style.transform = "";
    $("sheet").classList.remove("open");
    $("backdrop").classList.remove("open");
  }
  function submit() {
    const name = $("itemText").value.trim();
    if (!name || !selDay) { haptic(30); return; }
    const base = editing ? { ...items[editing.id] } : { id: uid(), done: false, createdAt: Date.now(), by: me?.name || "", color: me?.color || "" };
    save({ ...base, name, qty: $("itemQty").value.trim(), day: selDay, meal: selMeal });
    haptic(12);
    if (editing) { closeSheet(); return; }
    // Stay open for rapid entry of the next item.
    toast(`Added “${name}”`);
    $("itemText").value = ""; $("itemQty").value = "";
    refreshForm();
    $("itemText").focus();
  }

  $("addBtn").addEventListener("click", () => { haptic(10); openSheet(); });
  $("cancelBtn").addEventListener("click", closeSheet);
  $("backdrop").addEventListener("click", () => { if ($("settings").classList.contains("open")) closeSettings(); else closeSheet(); });
  $("saveBtn").addEventListener("click", submit);
  $("form").addEventListener("submit", (e) => { e.preventDefault(); submit(); });
  $("form").addEventListener("keydown", (e) => { if (e.key === "Enter" && e.target.tagName === "INPUT") { e.preventDefault(); submit(); } });
  $("deleteBtn").addEventListener("click", () => { if (editing) { const id = editing.id; closeSheet(); remove(id); } });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") { closeSheet(); closeSettings(); } });

  // Drag the sheet down by its grabber/header to dismiss.
  let sd = null;
  const sheetHead = (e) => e.target.closest(".grabber, .sheet-bar") && !e.target.closest("button");
  $("sheet").addEventListener("pointerdown", (e) => { if (sheetHead(e)) { sd = { y: e.clientY, dy: 0 }; $("sheet").classList.add("dragging"); } });
  window.addEventListener("pointermove", (e) => {
    if (!sd) return;
    sd.dy = Math.max(0, e.clientY - sd.y);
    $("sheet").style.transform = `translateY(${sd.dy}px)`;
  });
  window.addEventListener("pointerup", () => {
    if (!sd) return;
    $("sheet").classList.remove("dragging");
    if (sd.dy > 120) closeSheet(); else $("sheet").style.transform = "";
    sd = null;
  });

  // ---------- Toast ----------
  let toastTimer;
  function toast(msg, actionLabel, action) {
    const el = $("toast");
    el.innerHTML = `<span>${esc(msg)}</span>${actionLabel ? `<button>${esc(actionLabel)}</button>` : ""}`;
    if (actionLabel) el.querySelector("button").onclick = () => { action(); el.classList.remove("show"); };
    el.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove("show"), actionLabel ? 4500 : 1600);
  }

  // ---------- Settings / welcome sheet ----------
  let welcome = false, pickedColor = null;
  function renderSwatches() {
    $("swatches").innerHTML = COLORS.map((c) =>
      `<button type="button" class="swatch ${c === pickedColor ? "on" : ""}" data-color="${c}" style="background:${c}" aria-label="Colour ${c}"></button>`).join("");
  }
  function refreshSettings() { $("settingsDone").disabled = !$("sName").value.trim(); }
  function openSettings(isWelcome) {
    closeOpenRow();
    welcome = !!isWelcome;
    $("settingsTitle").textContent = welcome ? "Welcome" : "Settings";
    $("welcomeText").hidden = !welcome;
    $("listSettings").hidden = welcome;
    $("aboutText").textContent = `Version ${window.APP_VERSION || "dev"}`;
    $("sName").value = me?.name || "";
    pickedColor = me?.color || colorFor($("sName").value);
    renderSwatches();
    refreshSettings();
    $("settings").classList.add("open");
    $("backdrop").classList.add("open");
    if (welcome) setTimeout(() => $("sName").focus(), 300);
  }
  function closeSettings(force) {
    if (welcome && !force) return; // a name is required
    document.activeElement?.blur();
    $("settings").classList.remove("open");
    if (!$("sheet").classList.contains("open")) $("backdrop").classList.remove("open");
  }
  function saveSettings() {
    const name = $("sName").value.trim().replace(/\s+/g, " ");
    if (!name) { haptic(30); return; }
    me = { name, color: pickedColor || colorFor(name) };
    // Keep every dot for this name the same colour.
    for (const i of live()) if (sameName(i.by, name) && i.color !== me.color) save({ ...i, color: me.color });
    persist();
    haptic(10);
    closeSettings(true);
    render();
  }
  $("settingsBtn").addEventListener("click", () => openSettings(false));
  $("settingsDone").addEventListener("click", saveSettings);
  $("sName").addEventListener("input", () => {
    // Suggest the colour this name already uses on the list, until the user picks one.
    if (!me) { pickedColor = colorFor($("sName").value); renderSwatches(); }
    refreshSettings();
  });
  $("sName").addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); saveSettings(); } });
  $("swatches").addEventListener("click", (e) => {
    const b = e.target.closest(".swatch"); if (!b) return;
    haptic(5); pickedColor = b.dataset.color; renderSwatches();
  });

  // ---------- Boot ----------
  $("ver").textContent = window.APP_VERSION || "";
  if (!me) setTimeout(() => openSettings(true), 400);
  render();
  setStatus(online ? "syncing" : "offline");
  sync();
  if ("serviceWorker" in navigator) {
    const hadController = !!navigator.serviceWorker.controller;
    navigator.serviceWorker.addEventListener("controllerchange", () => { if (hadController) location.reload(); });
    navigator.serviceWorker.register("/sw.js", { updateViaCache: "none" }).then((r) => r.update()).catch(() => {});
  }
})();
