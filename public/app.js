(() => {
  "use strict";

  // ---------- Constants ----------
  const DAYS = ["Fri", "Sat", "Sun", "All"];
  const DAY_NAMES = { Mon: "Monday", Tue: "Tuesday", Wed: "Wednesday", Thu: "Thursday", Fri: "Friday", Sat: "Saturday", Sun: "Sunday", All: "All Days" };
  const dayOf = (i) => (i.day === "Multiple" ? "All" : i.day); // old "Multiple Days" items count as All
  const MEALS = ["Breakfast", "Lunch", "Dinner", "Snacks"];
  // Sainsbury's sections in typical walk order. Keep in sync with netlify/functions/aisles.mjs.
  const AISLES = ["Fruit & Veg", "Bakery", "Meat & Poultry", "Fish & Seafood", "Deli & Cheese", "Dairy & Eggs",
    "Chilled & Ready Meals", "Frozen", "Food Cupboard", "Baking & Home Cooking", "World Foods", "Cereals & Spreads",
    "Tea & Coffee", "Crisps & Snacks", "Chocolate & Sweets", "Soft Drinks & Juice", "Beer, Wine & Spirits",
    "Christmas & Seasonal", "Household", "Health & Beauty", "Baby", "Pet", "Home & Clothing"];
  const COLORS = ["#007AFF", "#FF9500", "#AF52DE", "#FF2D55", "#30B0C7", "#5856D6", "#D4A900", "#A2845E", "#00A89F", "#8E8E93"];
  const VIEWS = ["shop", "todo", "settings"];
  const SHOP_TABS = ["all", "day", "meal", "aisle"];
  const API = "/api/items";
  const POLL_MS = 8000;

  // ---------- Helpers ----------
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const uid = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
  const haptic = (ms = 8) => { try { navigator.vibrate && navigator.vibrate(ms); } catch {} };
  const load = (k, d) => { try { return JSON.parse(localStorage.getItem(k)) ?? d; } catch { return d; } };
  const firstName = (n) => String(n || "").trim().split(/\s+/)[0];
  const sameName = (a, b) => String(a || "").trim().toLowerCase() === String(b || "").trim().toLowerCase();
  const normName = (s) => String(s).trim().toLowerCase().replace(/\s+/g, " ").slice(0, 200);
  const standalone = window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
  const isIOS = /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  const isPhone = isIOS || /android/i.test(navigator.userAgent);

  // Dates are "YYYY-MM-DD" in local time.
  const ymd = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  const today = () => ymd(new Date());
  const addDays = (n) => { const d = new Date(); d.setDate(d.getDate() + n); return ymd(d); };
  const fmtDate = (s) => new Date(s + "T12:00:00").toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" });
  function dueInfo(due) {
    if (!due) return null;
    const t = today();
    if (due < t) return { label: `Overdue · ${fmtDate(due)}`, cls: "overdue" };
    if (due === t) return { label: "Today", cls: "today" };
    if (due === addDays(1)) return { label: "Tomorrow", cls: "soon" };
    return { label: fmtDate(due), cls: "" };
  }

  // ---------- State (localStorage = offline source of truth) ----------
  let items = load("cs-items", {});    // id -> item (incl. tombstones)
  let outbox = load("cs-outbox", {});  // id -> item waiting to upload
  let aisleMap = load("cs-aisles", {}); // normalised item name -> aisle
  let view = load("cs-view", "shop");
  let shopTab = load("cs-tab", "all");
  let todoFilter = load("cs-todo-filter", "all");
  let me = load("cs-me", null);        // { name, color }
  if (!VIEWS.includes(view)) view = "shop";
  if (!SHOP_TABS.includes(shopTab)) shopTab = "all";
  if (!["all", "mine"].includes(todoFilter)) todoFilter = "all";
  if (!me || typeof me.name !== "string" || !me.name.trim()) me = null;
  const urlView = new URLSearchParams(location.search).get("view");
  if (VIEWS.includes(urlView)) { view = urlView; history.replaceState(null, "", "/"); }

  const persist = () => {
    try {
      localStorage.setItem("cs-items", JSON.stringify(items));
      localStorage.setItem("cs-outbox", JSON.stringify(outbox));
      localStorage.setItem("cs-aisles", JSON.stringify(aisleMap));
      localStorage.setItem("cs-view", JSON.stringify(view));
      localStorage.setItem("cs-tab", JSON.stringify(shopTab));
      localStorage.setItem("cs-todo-filter", JSON.stringify(todoFilter));
      if (me) localStorage.setItem("cs-me", JSON.stringify(me));
    } catch {}
  };

  const live = () => Object.values(items).filter((i) => !i.deleted);
  const shopItems = () => live().filter((i) => i.type !== "todo");
  const todoItems = () => live().filter((i) => i.type === "todo");

  // ---------- People and colours ----------
  // Everyone the list knows about: item authors, to-do assignees, and me.
  function people() {
    const map = new Map();
    const add = (name, color) => {
      if (!name || !name.trim()) return;
      const k = name.trim().toLowerCase();
      if (!map.has(k)) map.set(k, { name: name.trim(), color: color || "" });
      else if (color && !map.get(k).color) map.get(k).color = color;
    };
    if (me) add(me.name, me.color);
    for (const i of live()) { add(i.by, i.color); add(i.assignee, i.assigneeColor); }
    return [...map.values()];
  }
  // A name keeps the colour it already has; a new name takes the first colour nobody uses.
  function colorFor(name) {
    if (me && sameName(name, me.name)) return me.color;
    const known = people().find((p) => sameName(p.name, name) && p.color);
    if (known) return known.color;
    const used = new Set(people().filter((p) => !sameName(p.name, name)).map((p) => p.color));
    return COLORS.find((c) => !used.has(c)) || COLORS[0];
  }

  // ---------- Saving ----------
  function save(item) {
    // History shown on the item: who ticked it off and when, and who changed it last.
    if (!item.deleted) {
      const prev = items[item.id];
      if (!item.done) { item.doneAt = 0; item.doneBy = ""; }
      else if (!prev || prev.deleted || !prev.done) { item.doneAt = Date.now(); item.doneBy = me?.name || ""; }
      item.editedBy = me?.name || "";
    }
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
        const res = await fetch(API, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ changes: pending, actor: me?.name || "" }) });
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
    } catch {
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
  let aisleBusy = false, aisleFailAt = 0;
  async function fetchAisles() {
    const names = [...new Set(shopItems().map((i) => normName(i.name)))].filter((n) => !aisleMap[n]);
    if (!names.length || aisleBusy || !navigator.onLine || Date.now() - aisleFailAt < 30000) return;
    aisleBusy = true;
    if (view === "shop" && shopTab === "aisle") render();
    try {
      const res = await fetch("/api/aisles", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ names }) });
      const data = await res.json().catch(() => ({}));
      Object.assign(aisleMap, data.aisles || {});
      if (!res.ok) aisleFailAt = Date.now();
      persist();
    } catch { aisleFailAt = Date.now(); }
    aisleBusy = false;
    if (view === "shop" && shopTab === "aisle") render();
  }

  // ---------- Rendering ----------
  const CHECK = '<svg viewBox="0 0 24 24"><path d="M5 12.5l4.5 4.5L19 7.5" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const CHEV = '<svg class="chev" width="8" height="14" viewBox="0 0 8 14"><path d="M1 1l6 6-6 6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const byName = (a, b) => (a.done - b.done) || a.name.localeCompare(b.name, undefined, { sensitivity: "base" });
  const dot = (color, title) => `<span class="who" style="background:${esc(color || "#8E8E93")}" title="${esc(title)}"></span>`;

  function rowShell(it, title, tags, label) {
    return `<div class="row-wrap" data-id="${esc(it.id)}">
      <button class="row-delete" data-act="delete">Delete</button>
      <div class="row ${it.done ? "done" : ""}" data-act="edit">
        <button class="check" data-act="toggle" aria-label="${esc(label)}">${CHECK}</button>
        <div class="row-main"><div class="row-title">${title}</div>${tags.length ? `<div class="tags">${tags.join("")}</div>` : ""}</div>
        ${CHEV}
      </div>
    </div>`;
  }
  function shopRow(it, hide) {
    const tags = [];
    if (it.day && hide !== "day") tags.push(`<span class="tag day">${esc(DAY_NAMES[dayOf(it)] || it.day)}</span>`);
    if (it.meal && hide !== "meal") tags.push(`<span class="tag meal">${esc(it.meal)}</span>`);
    const title = `${it.by ? dot(it.color, `Added by ${it.by}`) : ""}${esc(it.name)}${it.qty ? ` <span class="row-qty">· ${esc(it.qty)}</span>` : ""}`;
    return rowShell(it, title, tags, it.done ? "Mark as not bought" : "Mark as bought");
  }
  function todoRow(t) {
    const tags = [];
    const c = t.assignee ? (t.assigneeColor || colorFor(t.assignee)) : "#8E8E93";
    tags.push(`<span class="tag assignee" style="--c:${esc(c)}">${esc(t.assignee ? firstName(t.assignee) : "Anyone")}</span>`);
    const d = dueInfo(t.due);
    if (d) tags.push(`<span class="tag due ${t.done ? "" : d.cls}">${esc(d.label)}</span>`);
    return rowShell(t, `${dot(c, t.assignee || "Anyone")}${esc(t.name)}`, tags, t.done ? "Mark as not done" : "Mark as done");
  }
  function section(title, list, rowFn, countWord, sort = byName) {
    if (!list.length) return "";
    const left = list.filter((i) => !i.done).length;
    return `<div class="section-header"><span>${esc(title)}</span><span>${left ? `${left} ${countWord}` : "All done ✓"}</span></div>
      <div class="list">${list.sort(sort).map(rowFn).join("")}</div>`;
  }

  function renderShop() {
    const all = shopItems();
    if (!all.length) return `<div class="empty"><div class="big">🎄</div><h3>Nothing on the list yet</h3>Tap <b>Add</b> to put the first item on the shared list.</div>`;
    const row = (hide) => (i) => shopRow(i, hide);
    let html = "";
    if (shopTab === "all") {
      html = `<div class="list">${all.sort(byName).map(row()).join("")}</div>`;
    } else if (shopTab === "day") {
      for (const d of DAYS) html += section(DAY_NAMES[d], all.filter((i) => dayOf(i) === d), row("day"), "to buy");
      html += section("Other Days", all.filter((i) => !DAYS.includes(dayOf(i))), row(), "to buy");
    } else if (shopTab === "meal") {
      for (const m of MEALS) html += section(m, all.filter((i) => i.meal === m), row("meal"), "to buy");
      html += section("No Meal", all.filter((i) => !MEALS.includes(i.meal)), row("meal"), "to buy");
    } else {
      for (const a of AISLES) html += section(a, all.filter((i) => aisleMap[normName(i.name)] === a), row(), "to buy");
      const unsorted = all.filter((i) => !AISLES.includes(aisleMap[normName(i.name)]));
      html += section(aisleBusy ? "Sorting…" : "Not Sorted Yet", unsorted, row(), "to buy");
      if (unsorted.length && !aisleBusy && !online) html += `<p class="note">Items are sorted into aisles when the phone is online.</p>`;
    }
    return html;
  }

  function renderTodos() {
    let all = todoItems();
    if (todoFilter === "mine") all = all.filter((t) => !t.assignee || (me && sameName(t.assignee, me.name)));
    if (!all.length) {
      return `<div class="empty"><div class="big">✅</div><h3>${todoFilter === "mine" ? "Nothing for you to do" : "No to-dos yet"}</h3>Tap <b>Add</b> to give someone a job.</div>`;
    }
    const t = today(), tm = addDays(1);
    const open = all.filter((x) => !x.done);
    const byDue = (a, b) => (a.due || "9999").localeCompare(b.due || "9999") || a.name.localeCompare(b.name);
    let html = "";
    html += section("Overdue", open.filter((x) => x.due && x.due < t), todoRow, "to do", byDue);
    html += section("Today", open.filter((x) => x.due === t), todoRow, "to do", byDue);
    html += section("Tomorrow", open.filter((x) => x.due === tm), todoRow, "to do", byDue);
    html += section("Later", open.filter((x) => x.due && x.due > tm), todoRow, "to do", byDue);
    html += section("No Date", open.filter((x) => !x.due), todoRow, "to do", byDue);
    html += section("Done", all.filter((x) => x.done), todoRow, "to do", (a, b) => b.updatedAt - a.updatedAt);
    return html;
  }

  function render() {
    const shop = shopItems(), todos = todoItems();
    const shopLeft = shop.filter((i) => !i.done).length;
    const todoLeft = todos.filter((i) => !i.done).length;
    $("title").textContent = view === "shop" ? "Shopping" : view === "todo" ? "To-do" : "Settings";
    $("counts").textContent = view === "shop" && shop.length ? `${shopLeft} to buy` : view === "todo" && todos.length ? `${todoLeft} to do` : "";
    $("me").innerHTML = me ? `<span class="dot" style="background:${esc(me.color)}"></span>${esc(firstName(me.name))}` : "";

    document.querySelectorAll(".tab").forEach((b) => {
      const on = b.dataset.view === view;
      b.classList.toggle("active", on);
      b.setAttribute("aria-selected", on);
    });
    $("shopTabs").hidden = view !== "shop";
    $("todoTabs").hidden = view !== "todo";
    document.querySelectorAll("#shopTabs .subtab").forEach((b) => b.classList.toggle("on", b.dataset.sub === shopTab));
    document.querySelectorAll("#todoTabs .subtab").forEach((b) => b.classList.toggle("on", b.dataset.filter === todoFilter));
    $("addBtn").hidden = view === "settings";
    $("addLabel").textContent = view === "todo" ? "Add To-do" : "Add";

    const doneShop = shop.filter((i) => i.done).length, doneTodo = todos.filter((i) => i.done).length;
    $("clearDone").textContent = doneShop ? `Clear ${doneShop} Bought Item${doneShop > 1 ? "s" : ""}` : "No Bought Items";
    $("clearDone").disabled = !doneShop;
    $("clearTodos").textContent = doneTodo ? `Clear ${doneTodo} Done To-do${doneTodo > 1 ? "s" : ""}` : "No Done To-dos";
    $("clearTodos").disabled = !doneTodo;

    $("content").hidden = view === "settings";
    $("settingsPage").hidden = view !== "settings";
    if (view === "settings") {
      if (!$("welcome").classList.contains("open")) placeSettings("page");
    } else {
      $("content").innerHTML = view === "shop" ? renderShop() : renderTodos();
    }
  }

  // ---------- Tabs, sub-tabs, scroll ----------
  document.querySelector(".tabbar").addEventListener("click", (e) => {
    const b = e.target.closest(".tab");
    if (!b || b.dataset.view === view) return;
    haptic(5);
    view = b.dataset.view;
    persist();
    render();
    if (view === "settings") refreshNotifyUI();
    window.scrollTo(0, 0);
  });
  $("shopTabs").addEventListener("click", (e) => {
    const b = e.target.closest(".subtab");
    if (!b || b.dataset.sub === shopTab) return;
    haptic(5);
    shopTab = b.dataset.sub;
    persist();
    render();
    if (shopTab === "aisle") fetchAisles();
    window.scrollTo(0, 0);
  });
  $("todoTabs").addEventListener("click", (e) => {
    const b = e.target.closest(".subtab");
    if (!b || b.dataset.filter === todoFilter) return;
    haptic(5);
    todoFilter = b.dataset.filter;
    persist();
    render();
  });
  window.addEventListener("scroll", () => $("nav").classList.toggle("scrolled", window.scrollY > 4), { passive: true });

  // ---------- Pull to refresh ----------
  const PTR_TRIGGER = 64;
  let ptr = null, refreshing = false;
  const ptrEl = $("ptr");
  const anySheetOpen = () => !!document.querySelector(".sheet.open");
  const setPull = (d) => {
    ptrEl.style.transform = `translateY(${Math.min(d, 90) - 44}px)`;
    ptrEl.style.opacity = Math.min(1, d / PTR_TRIGGER);
    ptrEl.firstElementChild.style.transform = `rotate(${d * 4}deg)`;
  };
  window.addEventListener("touchstart", (e) => {
    if (refreshing || window.scrollY > 0 || anySheetOpen() || view === "settings" || !$("guide").hidden || e.touches.length > 1) return;
    ptr = { y: e.touches[0].clientY, x: e.touches[0].clientX, d: 0, armed: false };
  }, { passive: true });
  window.addEventListener("touchmove", (e) => {
    if (!ptr) return;
    const dy = e.touches[0].clientY - ptr.y, dx = e.touches[0].clientX - ptr.x;
    if (dy <= 0 || Math.abs(dx) > Math.abs(dy) || window.scrollY > 0) { if (dy < 0) { ptr = null; setPull(0); } return; }
    ptr.d = dy * 0.5;
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

  // ---------- Row interactions: tap, check, swipe-to-delete ----------
  let openRow = null, drag = null, swiped = false;
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
    if (act === "edit") items[id].type === "todo" ? openTodo(items[id]) : openItem(items[id]);
  });
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

  // ---------- Sheets (shared open / close / drag-to-dismiss) ----------
  function openSheetEl(id) {
    closeOpenRow();
    const el = $(id);
    el.style.transform = "";
    el.classList.add("open");
    $("backdrop").classList.add("open");
  }
  function closeSheetEl(id) {
    const el = $(id);
    if (!el.classList.contains("open")) return;
    if (id === "welcome" && !me) return; // a name is required
    document.activeElement?.blur();
    el.style.transform = "";
    el.classList.remove("open");
    if (!anySheetOpen()) $("backdrop").classList.remove("open");
  }
  const topSheet = () => [...document.querySelectorAll(".sheet.open")].pop();
  $("backdrop").addEventListener("click", () => { const s = topSheet(); if (s) closeSheetEl(s.id); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") { const s = topSheet(); if (s) closeSheetEl(s.id); } });
  document.querySelectorAll("[data-close]").forEach((b) => b.addEventListener("click", () => closeSheetEl(b.closest(".sheet").id)));

  let sd = null;
  document.querySelectorAll(".sheet").forEach((sheet) => {
    sheet.addEventListener("pointerdown", (e) => {
      if (sheet.id === "welcome" || !e.target.closest(".grabber, .sheet-bar") || e.target.closest("button")) return;
      sd = { sheet, y: e.clientY, dy: 0 };
      sheet.classList.add("dragging");
    });
  });
  window.addEventListener("pointermove", (e) => {
    if (!sd) return;
    sd.dy = Math.max(0, e.clientY - sd.y);
    sd.sheet.style.transform = `translateY(${sd.dy}px)`;
  });
  window.addEventListener("pointerup", () => {
    if (!sd) return;
    sd.sheet.classList.remove("dragging");
    if (sd.dy > 120) closeSheetEl(sd.sheet.id); else sd.sheet.style.transform = "";
    sd = null;
  });

  // ---------- Shopping item sheet ----------
  let editingItem = null, selDay = "", selMeal = "";
  $("dayChips").innerHTML = DAYS.map((d) => `<button type="button" class="chip" data-day="${d}">${d}</button>`).join("");
  $("mealSeg").innerHTML = MEALS.map((m) => `<button type="button" class="seg" data-meal="${m}">${m}</button>`).join("");
  function refreshItemForm() {
    document.querySelectorAll("#dayChips .chip").forEach((c) => c.classList.toggle("on", c.dataset.day === selDay));
    document.querySelectorAll("#mealSeg .seg").forEach((s) => s.classList.toggle("on", s.dataset.meal === selMeal));
    $("saveBtn").disabled = !($("itemText").value.trim() && selDay);
  }
  $("dayChips").addEventListener("click", (e) => { const c = e.target.closest(".chip"); if (!c) return; haptic(5); selDay = c.dataset.day; refreshItemForm(); });
  $("mealSeg").addEventListener("click", (e) => { const s = e.target.closest(".seg"); if (!s) return; haptic(5); selMeal = selMeal === s.dataset.meal ? "" : s.dataset.meal; refreshItemForm(); });
  $("itemText").addEventListener("input", refreshItemForm);
  function openItem(item) {
    editingItem = item || null;
    $("sheetTitle").textContent = item ? "Edit Item" : "New Item";
    $("saveLabel").textContent = item ? "Save Changes" : "Add Item";
    $("deleteBtn").hidden = !item;
    $("itemText").value = item?.name || "";
    $("itemQty").value = item?.qty || "";
    selDay = item ? (DAYS.includes(dayOf(item)) ? dayOf(item) : "") : "All";
    selMeal = item ? item.meal || "" : "";
    refreshItemForm();
    openSheetEl("sheet");
    if (!item) setTimeout(() => $("itemText").focus(), 60);
  }
  function submitItem() {
    const name = $("itemText").value.trim();
    if (!name || !selDay) { haptic(30); return; }
    const base = editingItem ? { ...items[editingItem.id] } : { id: uid(), type: "", done: false, createdAt: Date.now(), by: me?.name || "", color: me?.color || "" };
    save({ ...base, name, qty: $("itemQty").value.trim(), day: selDay, meal: selMeal });
    haptic(12);
    if (editingItem) { closeSheetEl("sheet"); return; }
    toast(`Added “${name}”`); // stay open for the next item
    $("itemText").value = ""; $("itemQty").value = "";
    refreshItemForm();
    $("itemText").focus();
  }
  $("saveBtn").addEventListener("click", submitItem);
  $("form").addEventListener("keydown", (e) => { if (e.key === "Enter" && e.target.tagName === "INPUT") { e.preventDefault(); submitItem(); } });
  $("deleteBtn").addEventListener("click", () => { if (editingItem) { const id = editingItem.id; closeSheetEl("sheet"); remove(id); } });

  // ---------- To-do sheet ----------
  let editingTodo = null, selWho = null, otherMode = false, selDue = "";
  function renderWho() {
    const list = people();
    let html = list.map((p) => {
      const on = !otherMode && selWho !== null && selWho !== "" && sameName(selWho, p.name);
      return `<button type="button" class="person ${on ? "on" : ""}" data-who="${esc(p.name)}"><span class="pdot" style="background:${esc(p.color || colorFor(p.name))}"></span>${esc(firstName(p.name))}${me && sameName(p.name, me.name) ? " (me)" : ""}</button>`;
    }).join("");
    html += `<button type="button" class="person ${!otherMode && selWho === "" ? "on" : ""}" data-who="">Anyone</button>`;
    html += `<button type="button" class="person ${otherMode ? "on" : ""}" data-other="1">Someone else…</button>`;
    $("whoChips").innerHTML = html;
    $("otherWrap").hidden = !otherMode;
  }
  function refreshTodoForm() {
    const who = otherMode ? $("otherName").value.trim() : selWho;
    $("todoSave").disabled = !($("todoText").value.trim() && who !== null && (who !== "" || !otherMode));
    document.querySelectorAll(".due-row [data-due]").forEach((b) =>
      b.classList.toggle("on", (b.dataset.due === "today" && selDue === today()) || (b.dataset.due === "tomorrow" && selDue === addDays(1))));
    const custom = selDue && selDue !== today() && selDue !== addDays(1);
    $("dueText").textContent = custom ? fmtDate(selDue) : "Pick date";
    document.querySelector(".date-pill").classList.toggle("on", !!custom);
    $("dueClear").hidden = !selDue;
    $("dueDate").value = selDue;
  }
  function openTodo(t) {
    editingTodo = t || null;
    $("todoTitle").textContent = t ? "Edit To-do" : "New To-do";
    $("todoSaveLabel").textContent = t ? "Save Changes" : "Add To-do";
    $("todoDelete").hidden = !t;
    $("todoText").value = t?.name || "";
    selWho = t ? (t.assignee || "") : (me?.name ?? null);
    otherMode = !!(t && t.assignee && !people().some((p) => sameName(p.name, t.assignee)));
    $("otherName").value = otherMode ? t.assignee : "";
    selDue = t?.due || "";
    renderWho();
    refreshTodoForm();
    openSheetEl("todoSheet");
    if (!t) setTimeout(() => $("todoText").focus(), 60);
  }
  $("whoChips").addEventListener("click", (e) => {
    const b = e.target.closest(".person"); if (!b) return;
    haptic(5);
    if (b.dataset.other) { otherMode = true; renderWho(); refreshTodoForm(); setTimeout(() => $("otherName").focus(), 50); return; }
    otherMode = false; selWho = b.dataset.who; renderWho(); refreshTodoForm();
  });
  $("todoText").addEventListener("input", refreshTodoForm);
  $("otherName").addEventListener("input", refreshTodoForm);
  document.querySelector(".due-row").addEventListener("click", (e) => {
    const b = e.target.closest("[data-due]"); if (!b) return;
    haptic(5);
    const v = b.dataset.due === "today" ? today() : addDays(1);
    selDue = selDue === v ? "" : v;
    refreshTodoForm();
  });
  $("dueDate").addEventListener("change", () => { selDue = $("dueDate").value || ""; refreshTodoForm(); });
  $("dueClear").addEventListener("click", () => { haptic(5); selDue = ""; refreshTodoForm(); });
  function submitTodo() {
    const name = $("todoText").value.trim();
    const assignee = (otherMode ? $("otherName").value.trim() : selWho ?? "").replace(/\s+/g, " ");
    if (!name || (otherMode && !assignee) || (!otherMode && selWho === null)) { haptic(30); return; }
    const base = editingTodo ? { ...items[editingTodo.id] } : { id: uid(), type: "todo", done: false, createdAt: Date.now(), by: me?.name || "", color: me?.color || "" };
    const keepColor = editingTodo && sameName(base.assignee, assignee) && base.assigneeColor;
    save({ ...base, name, assignee, assigneeColor: assignee ? (keepColor || colorFor(assignee)) : "", due: selDue });
    haptic(12);
    if (editingTodo) { closeSheetEl("todoSheet"); return; }
    toast(`Added “${name}”`); // stay open for the next to-do
    $("todoText").value = "";
    if (otherMode) { selWho = assignee; otherMode = false; renderWho(); }
    refreshTodoForm();
    $("todoText").focus();
  }
  $("todoSave").addEventListener("click", submitTodo);
  $("todoForm").addEventListener("keydown", (e) => { if (e.key === "Enter" && e.target.tagName === "INPUT" && e.target.type !== "date") { e.preventDefault(); submitTodo(); } });
  $("todoDelete").addEventListener("click", () => { if (editingTodo) { const id = editingTodo.id; closeSheetEl("todoSheet"); remove(id); } });

  $("addBtn").addEventListener("click", () => { haptic(10); view === "todo" ? openTodo() : openItem(); });

  // ---------- Settings (a tab page; also the first-run welcome sheet) ----------
  let pickedColor = null;
  function placeSettings(where) {
    const body = $("settingsBody");
    const welcome = where === "welcome";
    $("welcomeText").hidden = !welcome;
    $("moreSettings").hidden = welcome;
    $(welcome ? "welcomeBody" : "settingsPage").appendChild(body);
    if (document.activeElement !== $("sName")) $("sName").value = me?.name || "";
    pickedColor = me?.color || pickedColor || colorFor($("sName").value);
    $("aboutText").textContent = `Version ${window.APP_VERSION || "dev"}`;
    renderSwatches();
    refreshInstallBtn();
  }
  function renderSwatches() {
    $("swatches").innerHTML = COLORS.map((c) =>
      `<button type="button" class="swatch ${c === pickedColor ? "on" : ""}" data-color="${c}" style="background:${c}" aria-label="Colour ${c}"></button>`).join("");
  }
  function saveMe() {
    const name = $("sName").value.trim().replace(/\s+/g, " ");
    if (!name) { haptic(30); return false; }
    const changedName = !me || !sameName(me.name, name);
    me = { name, color: pickedColor || colorFor(name) };
    // Keep every dot for this person the same colour.
    for (const i of live()) {
      if (sameName(i.by, name) && i.color !== me.color) save({ ...i, color: me.color });
      if (i.type === "todo" && sameName(i.assignee, name) && i.assigneeColor !== me.color) save({ ...items[i.id], assigneeColor: me.color });
    }
    persist();
    render();
    if (changedName) registerPush(false);
    return true;
  }
  function openWelcome() {
    placeSettings("welcome");
    $("welcomeDone").disabled = !$("sName").value.trim();
    openSheetEl("welcome");
    setTimeout(() => $("sName").focus(), 300);
  }
  $("welcomeDone").addEventListener("click", () => {
    if (!saveMe()) return;
    haptic(10);
    closeSheetEl("welcome");
    render();
  });
  $("sName").addEventListener("input", () => {
    if (!me) { pickedColor = colorFor($("sName").value); renderSwatches(); }
    $("welcomeDone").disabled = !$("sName").value.trim();
  });
  $("sName").addEventListener("change", () => { if (view === "settings" && me && $("sName").value.trim()) { saveMe(); toast("Name saved"); } });
  $("sName").addEventListener("keydown", (e) => {
    if (e.key !== "Enter") return;
    e.preventDefault();
    if ($("welcome").classList.contains("open")) $("welcomeDone").click(); else $("sName").blur();
  });
  $("swatches").addEventListener("click", (e) => {
    const b = e.target.closest(".swatch"); if (!b) return;
    haptic(5); pickedColor = b.dataset.color; renderSwatches();
    if (me && !$("welcome").classList.contains("open")) saveMe();
  });
  $("clearDone").addEventListener("click", () => {
    const done = shopItems().filter((i) => i.done);
    if (!done.length || !confirm(`Remove ${done.length} bought item${done.length > 1 ? "s" : ""} from the list for everyone?`)) return;
    for (const i of done) save({ id: i.id, deleted: true });
  });
  $("clearTodos").addEventListener("click", () => {
    const done = todoItems().filter((i) => i.done);
    if (!done.length || !confirm(`Remove ${done.length} done to-do${done.length > 1 ? "s" : ""} for everyone?`)) return;
    for (const i of done) save({ id: i.id, deleted: true });
  });

  // ---------- Notifications (Web Push) ----------
  const pushSupported = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
  const b64ToBytes = (b64) => {
    const s = atob((b64 + "=".repeat((4 - (b64.length % 4)) % 4)).replace(/-/g, "+").replace(/_/g, "/"));
    return Uint8Array.from(s, (c) => c.charCodeAt(0));
  };
  async function currentSub() {
    if (!pushSupported) return null;
    const reg = await navigator.serviceWorker.ready;
    return reg.pushManager.getSubscription();
  }
  async function registerPush(ask) {
    if (!pushSupported || !me) return false;
    try {
      let sub = await currentSub();
      if (!sub) {
        if (!ask) return false;
        if ((await Notification.requestPermission()) !== "granted") return false;
        const { publicKey } = await (await fetch("/api/push")).json();
        if (!publicKey) throw new Error("Notifications are not set up on the server");
        const reg = await navigator.serviceWorker.ready;
        sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToBytes(publicKey) });
      }
      const res = await fetch("/api/push", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ action: "subscribe", subscription: sub.toJSON(), name: me.name }) });
      return res.ok;
    } catch (e) {
      if (ask) toast(e.message || "Could not turn on notifications");
      return false;
    }
  }
  async function refreshNotifyUI() {
    const btn = $("notifyBtn"), note = $("notifyNote"), test = $("notifyTest");
    test.hidden = true;
    btn.classList.remove("off");
    if (!pushSupported) {
      btn.disabled = true;
      btn.textContent = "Notifications Unavailable";
      note.innerHTML = isIOS && !standalone
        ? "On iPhone, notifications work only in the Home Screen app. Add the app to your Home Screen, open it from there, then turn notifications on."
        : "This browser does not support notifications.";
      return;
    }
    if (Notification.permission === "denied") {
      btn.disabled = true;
      btn.textContent = "Notifications Blocked";
      note.textContent = "Allow notifications for Xmas List in your phone’s Settings app, then come back here.";
      return;
    }
    const sub = await currentSub().catch(() => null);
    btn.disabled = false;
    if (sub && Notification.permission === "granted") {
      btn.textContent = "Turn Off Notifications";
      btn.classList.add("off");
      test.hidden = false;
      note.textContent = "You are told when someone adds shopping, when someone gives you a to-do, and at 8am when your to-dos are due.";
    } else {
      btn.textContent = "Turn On Notifications";
      note.textContent = "Get told when someone adds shopping, when someone gives you a to-do, and at 8am when your to-dos are due.";
    }
  }
  $("notifyBtn").addEventListener("click", async () => {
    haptic(5);
    const sub = await currentSub().catch(() => null);
    if (sub && Notification.permission === "granted") {
      await fetch("/api/push", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ action: "unsubscribe", endpoint: sub.endpoint }) }).catch(() => {});
      await sub.unsubscribe().catch(() => {});
      toast("Notifications off");
    } else if (await registerPush(true)) {
      toast("Notifications on");
    }
    refreshNotifyUI();
  });
  $("notifyTest").addEventListener("click", async () => {
    haptic(5);
    const sub = await currentSub().catch(() => null);
    if (!sub) return refreshNotifyUI();
    const res = await fetch("/api/push", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ action: "test", endpoint: sub.endpoint }) }).catch(() => null);
    toast(res && res.ok ? "Test sent" : "Test failed. Try turning notifications off and on.");
  });

  // ---------- Install guide (shown when opened in a phone browser, not from the Home Screen) ----------
  let installEvent = null;
  const SHARE_ICON = '<svg class="share-ico" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 15V3m0 0L8 7m4-4 4 4M6 11H5a1 1 0 0 0-1 1v8a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-8a1 1 0 0 0-1-1h-1" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const ILL = window.InstallIllustrations;
  function guideSteps() {
    if (isIOS) {
      return [
        [`In Safari, tap ${SHARE_ICON} <b>Share</b> in the toolbar. If you do not see it, tap <b>•••</b> first, then <b>Share</b>.`, ILL.share],
        ["Scroll down the list and tap <b>Add to Home Screen</b>. If it is not there, tap <b>Edit Actions</b> or <b>More</b> to find it.", ILL.addToHome],
        ["Keep the name <b>Xmas List</b>. If you see <b>Open as Web App</b>, leave it on. Tap <b>Add</b>.", ILL.confirm],
        ["Find the new icon. If it went into the <b>App Library</b> (swipe left past your last Home Screen page), touch and hold <b>Xmas List</b> and tap <b>Add to Home Screen</b>. You can also drag it onto a Home Screen page.", ILL.appLibrary],
        ["Open <b>Xmas List</b> from your Home Screen. Always open it from there, not from Safari.", ILL.homeScreen],
      ];
    }
    return [
      ["Tap the <b>⋮</b> menu at the top right of your browser.", ILL.androidMenu],
      ["Tap <b>Install app</b> or <b>Add to Home screen</b>, then tap <b>Install</b>.", ILL.androidInstall],
      ["Open <b>Xmas List</b> from your Home Screen. If it is only in your app drawer, touch and hold it and drag it onto the Home Screen.", ILL.homeScreen],
    ];
  }
  function showGuide() {
    $("guideSteps").innerHTML = guideSteps().map(([text, ill]) => `<li><div class="step-text">${text}</div><div class="step-ill">${ill}</div></li>`).join("");
    $("guideInstall").hidden = !installEvent;
    $("guide").hidden = false;
    document.body.classList.add("guide-open");
    $("guide").scrollTop = 0;
  }
  function hideGuide() { $("guide").hidden = true; document.body.classList.remove("guide-open"); }
  $("guideSkip").addEventListener("click", () => {
    hideGuide();
    if (!me) setTimeout(openWelcome, 300);
  });
  async function promptInstall() {
    if (!installEvent) return false;
    installEvent.prompt();
    await installEvent.userChoice.catch(() => {});
    installEvent = null;
    return true;
  }
  $("guideInstall").addEventListener("click", async () => { if (await promptInstall()) hideGuide(); });
  window.addEventListener("beforeinstallprompt", (e) => { e.preventDefault(); installEvent = e; if (!$("guide").hidden) $("guideInstall").hidden = false; });
  function refreshInstallBtn() {
    $("installBtn").textContent = standalone ? "Installed on Home Screen ✓" : "How to Add to Home Screen";
    $("installBtn").disabled = standalone;
    $("installSteps").hidden = true;
  }
  $("installBtn").addEventListener("click", async () => { haptic(5); if (!(await promptInstall())) showGuide(); });

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
  $("ver").textContent = window.APP_VERSION || "";
  placeSettings("page");
  render();
  setStatus(online ? "syncing" : "offline");
  sync();
  const showInstallGuide = isPhone && !standalone && navigator.onLine;
  if (showInstallGuide) showGuide();
  else if (!me) setTimeout(openWelcome, 400);
  if ("serviceWorker" in navigator) {
    const hadController = !!navigator.serviceWorker.controller;
    navigator.serviceWorker.addEventListener("controllerchange", () => { if (hadController) location.reload(); });
    navigator.serviceWorker.register("/sw.js", { updateViaCache: "none" }).then((r) => r.update()).catch(() => {});
    // Keep this device's notification name current.
    registerPush(false).then(() => { if (view === "settings") refreshNotifyUI(); });
  }
  if (view === "settings") refreshNotifyUI();
})();
