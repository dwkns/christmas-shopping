(() => {
  "use strict";

  const DAYS = ["Fri", "Sat", "Sun", "All"];
  const DAY_NAMES = { Mon: "Monday", Tue: "Tuesday", Wed: "Wednesday", Thu: "Thursday", Fri: "Friday", Sat: "Saturday", Sun: "Sunday", All: "All Days" };
  // Items saved as "Multiple Days" before the change count as "All Days".
  const dayOf = (i) => (i.day === "Multiple" ? "All" : i.day);
  const MEALS = ["Breakfast", "Lunch", "Dinner", "Snacks"];
  const TITLES = { all: "All Items", day: "By Day", meal: "By Meal" };
  const API = "/api/items";
  const POLL_MS = 8000;

  // ---------- Local state (localStorage = offline source of truth) ----------
  const load = (k, d) => { try { return JSON.parse(localStorage.getItem(k)) ?? d; } catch { return d; } };
  const persist = () => {
    try {
      localStorage.setItem("cs-items", JSON.stringify(items));
      localStorage.setItem("cs-outbox", JSON.stringify(outbox));
      localStorage.setItem("cs-tab", tab);
    } catch {}
  };
  let items = load("cs-items", {});   // id -> item (incl. tombstones)
  let outbox = load("cs-outbox", {}); // id -> item waiting to upload
  let tab = load("cs-tab", "all");
  if (typeof tab !== "string" || !TITLES[tab]) tab = "all";

  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const uid = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
  const haptic = (ms = 8) => { try { navigator.vibrate && navigator.vibrate(ms); } catch {} };
  const live = () => Object.values(items).filter((i) => !i.deleted);

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
          <div class="row-title">${esc(it.name)}${it.qty ? ` <span class="row-qty">· ${esc(it.qty)}</span>` : ""}</div>
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
    $("largeTitle").textContent = $("smallTitle").textContent = TITLES[tab];
    $("subtitle").textContent = all.length ? `${left} to buy · ${done} bought` : "";
    $("clearDone").hidden = done === 0;
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
    window.scrollTo(0, 0);
  });
  const onScroll = () => $("nav").classList.toggle("scrolled", window.scrollY > 40);
  window.addEventListener("scroll", onScroll, { passive: true });

  $("clearDone").addEventListener("click", () => {
    const done = live().filter((i) => i.done);
    if (!done.length || !confirm(`Remove ${done.length} bought item${done.length > 1 ? "s" : ""} from the list?`)) return;
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
    drag = { row, x: e.clientX, y: e.clientY, base: row === openRow ? -88 : 0, dx: 0, active: false };
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
    if (dx < -44) { row.style.transform = "translateX(-88px)"; openRow = row; }
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
    $("saveBtn").disabled = !($("fName").value.trim() && selDay);
  }
  $("dayChips").addEventListener("click", (e) => {
    const c = e.target.closest(".chip"); if (!c) return;
    haptic(5); selDay = c.dataset.day; refreshForm();
  });
  $("mealSeg").addEventListener("click", (e) => {
    const s = e.target.closest(".seg"); if (!s) return;
    haptic(5); selMeal = selMeal === s.dataset.meal ? "" : s.dataset.meal; refreshForm();
  });
  $("fName").addEventListener("input", refreshForm);

  function openSheet(item) {
    closeOpenRow();
    editing = item || null;
    $("sheetTitle").textContent = item ? "Edit Item" : "New Item";
    $("saveBtn").textContent = item ? "Save" : "Add";
    $("deleteBtn").hidden = !item;
    $("fName").value = item?.name || "";
    $("fQty").value = item?.qty || "";
    selDay = item ? (DAYS.includes(dayOf(item)) ? dayOf(item) : "") : "All";
    selMeal = item ? item.meal || "" : "";
    refreshForm();
    $("sheet").style.transform = "";
    $("sheet").classList.add("open");
    $("backdrop").classList.add("open");
    if (!item) setTimeout(() => $("fName").focus(), 60);
  }
  function closeSheet() {
    document.activeElement?.blur();
    $("sheet").style.transform = "";
    $("sheet").classList.remove("open");
    $("backdrop").classList.remove("open");
  }
  function submit() {
    const name = $("fName").value.trim();
    if (!name || !selDay) { haptic(30); return; }
    const base = editing ? { ...items[editing.id] } : { id: uid(), done: false, createdAt: Date.now() };
    save({ ...base, name, qty: $("fQty").value.trim(), day: selDay, meal: selMeal });
    haptic(12);
    if (editing) { closeSheet(); return; }
    // Stay open for rapid entry of the next item.
    toast(`Added “${name}”`);
    $("fName").value = ""; $("fQty").value = "";
    refreshForm();
    $("fName").focus();
  }

  $("addBtn").addEventListener("click", () => { haptic(10); openSheet(); });
  $("cancelBtn").addEventListener("click", closeSheet);
  $("backdrop").addEventListener("click", closeSheet);
  $("saveBtn").addEventListener("click", submit);
  $("form").addEventListener("submit", (e) => { e.preventDefault(); submit(); });
  $("form").addEventListener("keydown", (e) => { if (e.key === "Enter" && e.target.tagName === "INPUT") { e.preventDefault(); submit(); } });
  $("deleteBtn").addEventListener("click", () => { if (editing) { const id = editing.id; closeSheet(); remove(id); } });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") closeSheet(); });

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

  // ---------- Boot ----------
  render();
  setStatus(online ? "syncing" : "offline");
  sync();
  if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});
})();
