// app.js — logic dashboard PokémonTool (renderer). Gọi main qua window.poke (preload).
"use strict";
const $ = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];
const esc = (s) => String(s == null ? "" : s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const cssEsc = (s) => String(s).replace(/["\\]/g, "\\$&");

let currentMode = "wifi";
let devices = [];
let scanning = false;
const licCache = {};   // id -> { valid, reasonVi, plan, expiresAt } (pokemontool)
const appLicCache = {}; // id -> { activated, reason, tierName, plan, expiresAt } (iOSAuto)
const selected = new Set();   // id thiết bị đang tick chọn (cho chạy/dừng hàng loạt)
let runningState = {};        // id -> đang chạy script? (poll nhẹ để đổi nút Chạy↔Dừng)

// ----- Toast thông báo (góc phải dưới) -----
const ICONS = { warn: "⚠️", bad: "⛔", ok: "✅", info: "ℹ️" };
function toast(msg, { type = "info", timeout = 4000 } = {}) {
  const el = document.createElement("div");
  el.className = "toast " + type;
  el.innerHTML = `<span class="t-ic">${ICONS[type] || "ℹ️"}</span><span>${esc(msg)}</span>`;
  $("#toasts").appendChild(el);
  setTimeout(() => { el.classList.add("hide"); setTimeout(() => el.remove(), 260); }, timeout);
}

// ===================== Điều khiển cửa sổ =====================
$("#winMin").onclick = () => poke.win.minimize();
$("#winMax").onclick = () => poke.win.maximize();
$("#winClose").onclick = () => poke.win.close();

// ===================== Điều hướng view =====================
function goto(view) {
  $$(".nav-item").forEach((n) => n.classList.toggle("active", n.dataset.view === view));
  $$(".view").forEach((v) => v.classList.toggle("active", v.id === "view-" + view));
}
$$(".nav-item").forEach((n) => n.addEventListener("click", () => goto(n.dataset.view)));
$$("[data-goto]").forEach((b) => b.addEventListener("click", () => goto(b.dataset.goto)));

// ===================== Mode toggle =====================
// Đổi chế độ WiFi/USB: cập nhật UI + (tuỳ chọn) lưu nhớ lựa chọn cho lần mở sau.
function setMode(mode, { persist = true, rescan = true } = {}) {
  if (mode !== "wifi" && mode !== "usb") mode = "wifi";
  currentMode = mode;
  $$(".mode").forEach((m) => m.classList.toggle("active", m.dataset.mode === mode));
  if (persist) poke.settingsSet({ mode });
  if (rescan) { devices = []; renderAll(); scan(); }
}
$("#modeToggle").addEventListener("click", (e) => {
  const b = e.target.closest(".mode");
  if (!b || scanning) return;
  if (b.dataset.mode === currentMode) return;
  setMode(b.dataset.mode);
});

// ===================== Feed hoạt động =====================
const homeFeed = $("#homeFeed");
const fullFeed = $("#fullFeed");
const feedItems = [];
function nowHM() { const d = new Date(); return d.toTimeString().slice(0, 8); }
function pushFeed(icon, title, sub, kind) {
  feedItems.unshift({ icon, title, sub, time: nowHM(), kind: kind || "" });
  if (feedItems.length > 200) feedItems.pop();
  renderFeed();
}
function feedRow(f) {
  return `<div class="feed-row"><div class="feed-ic">${f.icon}</div>
    <div class="feed-body"><div class="ft">${esc(f.title)}</div><div class="fs">${esc(f.sub || "")}</div></div>
    <div class="feed-time">${f.time}</div></div>`;
}
function renderFeed() {
  homeFeed.innerHTML = feedItems.length ? feedItems.slice(0, 6).map(feedRow).join("") : `<div class="feed-empty">Chưa có hoạt động.</div>`;
  fullFeed.innerHTML = feedItems.length ? feedItems.map(feedRow).join("") : `<div class="feed-empty">Chưa có hoạt động nào.</div>`;
}
$("#feedClear").onclick = () => { feedItems.length = 0; renderFeed(); };

// ===================== Quét thiết bị =====================
const progressWrap = $("#progressWrap"), progressBar = $("#progressBar"), progressText = $("#progressText");
const scanStatus = $("#scanStatus");
poke.onScanProgress((p) => {
  if (!p) return;
  if (p.mode === "wifi" && typeof p.done === "number") {
    progressWrap.hidden = false;
    const pct = p.total ? Math.round((p.done / p.total) * 100) : 0;
    progressBar.style.width = pct + "%"; progressText.textContent = p.msg || `Quét ${p.done}/${p.total}`;
  } else if (p.msg) { progressWrap.hidden = false; progressBar.style.width = "100%"; progressText.textContent = p.msg; }
});

async function scan() {
  if (scanning) return;
  scanning = true;
  [$("#btnScan"), $("#homeScan")].forEach((b) => b && (b.disabled = true));
  scanStatus.textContent = currentMode === "usb" ? "Đang dò USB…" : "Đang quét WiFi…";
  progressWrap.hidden = false; progressBar.style.width = currentMode === "usb" ? "35%" : "0%";
  progressText.textContent = currentMode === "usb" ? "Liệt kê thiết bị USB…" : "Bắt đầu quét…";
  pushFeed("🔍", `Bắt đầu quét ${currentMode.toUpperCase()}`, "Đang dò thiết bị…");
  try {
    const r = await poke.scanDevices(currentMode);
    if (!r.ok) {
      scanStatus.textContent = "⚠ " + (r.msg || "Quét lỗi");
      showEmpty(r.error === "NO_TOOL" ? "Chưa có công cụ kết nối USB." : "Không quét được.", r.msg || "");
      devices = []; pushFeed("⚠️", "Quét lỗi", r.msg || "", "bad");
    } else {
      devices = r.devices || [];
      scanStatus.textContent = `Thấy ${devices.length} thiết bị (${currentMode.toUpperCase()})`;
      pushFeed("✅", `Quét xong — ${devices.length} thiết bị`, currentMode.toUpperCase());
    }
  } catch (e) { scanStatus.textContent = "⚠ Lỗi: " + (e.message || e); }
  finally {
    progressBar.style.width = "100%";
    setTimeout(() => { progressWrap.hidden = true; progressBar.style.width = "0%"; }, 500);
    [$("#btnScan"), $("#homeScan")].forEach((b) => b && (b.disabled = false));
    scanning = false;
    runningState = {}; noticeDismissed = false; autoUploaded = new Set();   // quét mới → reset
    renderAll();
    Promise.all(devices.map((d) => Promise.all([refreshLicense(d), fetchAppLicense(d)]))).then(() => {
      const bad = devices.filter((d) => licCache[d.id] && !licCache[d.id].valid);
      if (bad.length) toast(`${bad.length} thiết bị chưa kích hoạt pokemontool`, { type: "warn", timeout: 6000 });
      pollRunning();      // quét trạng thái chạy ngay sau khi có danh sách
      autoUploadAll();    // tự nạp sẵn script + config (không cần người dùng bấm)
    });
  }
}
$("#btnScan").onclick = scan;
$("#homeScan").onclick = scan;

// ===================== Danh sách script chạy được =====================
let scripts = [], selectedScriptId = null;
const scriptSelect = $("#scriptSelect"), scriptDesc = $("#scriptDesc");
async function loadScripts() {
  scripts = (await poke.scriptsList()) || [];
  scriptSelect.innerHTML = scripts.map((s) => `<option value="${esc(s.id)}">${esc(s.name)}</option>`).join("");
  selectedScriptId = scripts[0] ? scripts[0].id : null;
  updateScriptDesc();
}
function updateScriptDesc() {
  const s = scripts.find((x) => x.id === selectedScriptId);
  scriptDesc.textContent = s && s.desc ? "— " + s.desc : "";
}
scriptSelect.onchange = () => { selectedScriptId = scriptSelect.value; updateScriptDesc(); };

// Chạy script đã chọn trên 1 thiết bị (tự đẩy config.txt apikey trước, ở phía main).
async function runScriptOn(d, { openDrawer = true } = {}) {
  if (!selectedScriptId) { alert("Chưa có script để chạy."); return; }
  const s = scripts.find((x) => x.id === selectedScriptId);
  const r = await poke.scriptRun(d.host, d.port, selectedScriptId);
  if (r && r.ok) {
    markRunning(d.id, true);   // đổi nút sang Dừng ngay (khỏi chờ poll)
    pushFeed("▶️", `Chạy ${s ? s.name : selectedScriptId} · ${d.name}`, r.pushedConfig ? "đã đẩy apikey" : "chưa có apikey", "ok");
    if (openDrawer) openLog(d);
  } else {
    pushFeed("⚠️", `Chạy lỗi · ${d.name}`, (r && r.msg) || "", "bad");
    toast(`Chạy lỗi · ${d.name}: ${(r && r.msg) || "không rõ"}`, { type: "bad", timeout: 6000 });
  }
}

// Tự nạp sẵn script (đã nhúng trong tool) + config lên MỌI máy — người dùng khỏi bấm gì.
let autoUploaded = new Set();   // id máy đã tự nạp trong phiên (tránh nạp lại mỗi vòng)
async function autoUploadAll({ force = false } = {}) {
  if (!selectedScriptId || !devices.length) return;
  const targets = devices.filter((d) => force || !autoUploaded.has(d.id));
  if (!targets.length) return;
  const rs = await Promise.all(targets.map((d) =>
    poke.scriptUpload(d.host, d.port, selectedScriptId).then((r) => { if (r && r.ok) autoUploaded.add(d.id); return r; }).catch(() => null)));
  const ok = rs.filter((r) => r && r.ok).length;
  if (ok) pushFeed("⬆️", `Tự nạp sẵn script lên ${ok}/${targets.length} máy`, "không cần thao tác");
}

// ===================== Render thiết bị =====================
const rowsEl = $("#deviceRows"), emptyEl = $("#emptyState"), homeDevList = $("#homeDevList");

function ipLocalOf(d) {
  if (d.mode === "usb") return "localhost :" + d.port;  // USB: luôn hiện cổng forward local (127.0.0.1:port), KHÔNG lấy IP LAN của máy
  return d.host;
}
function licBadge(d, compact) {
  const l = licCache[d.id];
  if (!d.serial) return `<span class="badge warn">Không serial</span>`;
  if (!l) return `<span class="badge load">Đang kiểm…</span>`;
  if (l.valid) {
    const detail = (l.plan || "") + (l.expiresAt ? (l.plan ? " · " : "") + "HSD " + fmtDate(l.expiresAt) : "");
    if (compact) return `<span class="badge ok" title="${esc(detail)}">Active</span>`;
    return `<span class="badge ok">Đã active${detail ? " · " + esc(detail) : ""}</span>`;
  }
  if (compact) return `<span class="badge bad" title="${esc(l.reasonVi || "")}">Khoá</span>`;
  return `<span class="badge bad">${esc(l.reasonVi || "Chưa active")}</span>`;
}
// Badge trạng thái license iOSAuto (app).
function appLicBadge(d, compact) {
  const l = appLicCache[d.id];
  if (!l) return `<span class="badge load">Đang kiểm…</span>`;
  if (l.activated) {
    const detail = [l.tierName, l.plan, l.expiresAt ? "HSD " + fmtDate(l.expiresAt) : ""].filter(Boolean).join(" · ");
    if (compact) return `<span class="badge ok" title="${esc(detail)}">Active</span>`;
    return `<span class="badge ok">Đã kích hoạt${detail ? " · " + esc(detail) : ""}</span>`;
  }
  if (compact) return `<span class="badge bad" title="${esc(l.reason || "")}">Khoá</span>`;
  return `<span class="badge bad" title="${esc(l.reason || "")}">Chưa kích hoạt</span>`;
}
async function fetchAppLicense(d) {
  const r = await poke.deviceAppLicense(d.host, d.port);
  appLicCache[d.id] = r;
  const cell = rowsEl.querySelector(`tr[data-id="${cssEsc(d.id)}"] td:nth-child(6)`);
  if (cell) cell.innerHTML = appLicBadge(d, true);
}

function renderAll() {
  renderTable(); renderHomeList(); renderStats(); updateSelUI(); renderNotActivated();
}
function renderTable() {
  if (!devices.length) { rowsEl.innerHTML = ""; if (!scanning) showEmpty(); return; }
  emptyEl.classList.remove("show");
  rowsEl.innerHTML = devices.map((d, i) => `<tr data-id="${esc(d.id)}">
    <td class="col-check"><input type="checkbox" class="row-check" ${selected.has(d.id) ? "checked" : ""}/></td>
    <td class="col-idx">${i + 1}</td>
    <td><div class="dev-name">${esc(d.name)}<small>${esc(d.model || "")}${d.ios ? " · iOS " + esc(d.ios) : ""}</small></div></td>
    <td class="dev-ip">${esc(ipLocalOf(d))}</td>
    <td class="dev-serial">${esc(d.serial || "—")}</td>
    <td>${appLicBadge(d, true)}</td>
    <td>${licBadge(d, true)}</td>
    <td><div class="row-act">
      ${runBtnHTML(d)}
      <button class="btn sm" data-act="view" title="Mở trang view">🖥 View</button>
      <button class="btn sm" data-act="log" title="Đọc log">📜 Log</button>
    </div></td></tr>`).join("");
}
function renderHomeList() {
  if (!devices.length) { homeDevList.innerHTML = `<div class="dev-empty">Chưa có thiết bị — bấm Quét.</div>`; return; }
  homeDevList.innerHTML = devices.slice(0, 4).map((d) => `<div class="dev-item" data-id="${esc(d.id)}">
    <div class="dev-thumb">📱</div>
    <div class="dev-meta"><div class="dn">${esc(d.name)}</div>
      <div class="ds">${esc(d.ios ? "iOS " + d.ios + " · " : "")}${esc(d.serial || ipLocalOf(d))}</div></div>
    <div class="dev-right">${licBadge(d)}</div>
    <img class="ball-mini" src="assets/pokeball3d.png" alt="">
  </div>`).join("");
}
function renderStats() {
  const active = devices.filter((d) => licCache[d.id]?.valid).length;
  const inactive = devices.filter((d) => licCache[d.id] && !licCache[d.id].valid).length;
  $("#stConnected").textContent = devices.length;
  $("#stActive").textContent = active;
  $("#stInactive").textContent = inactive;
}
function showEmpty(msg, hint) {
  rowsEl.innerHTML = ""; emptyEl.classList.add("show");
  $("#emptyMsg").innerHTML = msg ? esc(msg) : "Chưa có thiết bị. Bấm <b>Quét thiết bị</b> để dò máy.";
  const h = $("#emptyHint");
  if (hint) h.textContent = hint;
  else if (currentMode === "usb") h.textContent = "USB: cần usbmuxd (3uTools / iTunes / Apple Devices), cắm cáp iPhone, daemon cổng 8081.";
  else h.textContent = "WiFi: iPhone cùng mạng LAN, daemon bật cổng 8080.";
}
function fmtDate(iso) { try { return new Date(iso).toLocaleDateString("vi-VN"); } catch (_) { return iso; } }

async function refreshLicense(d) {
  if (!d.serial) { licCache[d.id] = null; return; }
  const r = await poke.checkLicense(d.serial);
  licCache[d.id] = r;
  markServer(r.reason !== "network");
  // cập nhật badge tại chỗ (bảng + home) mà không render lại toàn bộ
  const cell = rowsEl.querySelector(`tr[data-id="${cssEsc(d.id)}"] td:nth-child(7)`);
  if (cell) cell.innerHTML = licBadge(d, true);
  const hr = homeDevList.querySelector(`.dev-item[data-id="${cssEsc(d.id)}"] .dev-right`);
  if (hr) hr.innerHTML = licBadge(d);
  renderStats();
  renderNotActivated();
  pushFeed(r.valid ? "🟢" : "🔴", `${d.name} — ${r.valid ? "đã active" : (r.reasonVi || "chưa active")}`, d.serial, r.valid ? "ok" : "bad");
}

// Bảng thông báo: liệt kê thiết bị CHƯA kích hoạt pokemontool (license không hợp lệ).
let noticeDismissed = false;
function renderNotActivated() {
  const banner = $("#notActivated");
  const bad = devices.filter((d) => licCache[d.id] && !licCache[d.id].valid);
  if (!bad.length || noticeDismissed) { banner.hidden = true; return; }
  banner.hidden = false;
  $("#notActivatedTitle").textContent = `${bad.length} thiết bị chưa kích hoạt pokemontool`;
  $("#notActivatedList").innerHTML =
    "Cần cấp / kích hoạt license cho: " + bad.map((d) => `<b>${esc(d.name)}</b> — ${esc(d.serial || "?")} <span style="color:var(--bad)">(${esc(licCache[d.id].reasonVi || "chưa active")})</span>`).join(" · ");
}
$("#notActivatedClose").onclick = () => { noticeDismissed = true; $("#notActivated").hidden = true; };

// Click nút trong bảng + home list.
function actOn(d, act) {
  if (!d) return;
  if (act === "run") runScriptOn(d);
  if (act === "stop") {
    poke.deviceStop(d.host, d.port); markRunning(d.id, false);
    pushFeed("⏹️", `Dừng ${d.name}`, ipLocalOf(d), "bad"); toast(`Đã gửi Dừng · ${d.name}`, { type: "info" });
  }
  if (act === "view") { poke.openView(d.host, d.port, d.name); pushFeed("🖥️", `Mở view ${d.name}`, ipLocalOf(d)); }
  if (act === "log") openLog(d);
}
rowsEl.addEventListener("click", (e) => {
  const btn = e.target.closest("button[data-act]"); if (!btn) return;
  actOn(devices.find((x) => x.id === e.target.closest("tr").dataset.id), btn.dataset.act);
});
homeDevList.addEventListener("click", (e) => {
  const item = e.target.closest(".dev-item"); if (!item) return;
  actOn(devices.find((x) => x.id === item.dataset.id), "view");
});

// ----- Chọn thiết bị (checkbox) + chạy/dừng hàng loạt -----
function updateSelUI() {
  // bỏ id không còn trong danh sách hiện tại
  for (const id of [...selected]) if (!devices.find((d) => d.id === id)) selected.delete(id);
  const n = selected.size;
  const cnt = $("#selCount"); if (cnt) cnt.textContent = n + " đã chọn";
  const all = $("#checkAll");
  if (all) { all.checked = devices.length > 0 && n === devices.length; all.indeterminate = n > 0 && n < devices.length; }
  const has = n > 0;
  $("#btnRunSel").disabled = !has; $("#btnStopSel").disabled = !has;
  $("#btnCopySerial").disabled = !has;
}
rowsEl.addEventListener("change", (e) => {
  const cb = e.target.closest(".row-check"); if (!cb) return;
  const id = e.target.closest("tr").dataset.id;
  if (cb.checked) selected.add(id); else selected.delete(id);
  updateSelUI();
});
$("#checkAll").addEventListener("change", (e) => {
  selected.clear();
  if (e.target.checked) devices.forEach((d) => selected.add(d.id));
  rowsEl.querySelectorAll(".row-check").forEach((cb) => (cb.checked = e.target.checked));
  updateSelUI();
});
function selectedDevices() { return devices.filter((d) => selected.has(d.id)); }
$("#btnCopySerial").onclick = async () => {
  const serials = selectedDevices().map((d) => d.serial).filter(Boolean);
  if (!serials.length) { toast("Máy đã chọn không có serial", { type: "warn" }); return; }
  await poke.clipboardWrite(serials.join("\n"));
  toast(`Đã copy ${serials.length} serial`, { type: "ok" });
  pushFeed("📋", `Copy ${serials.length} serial`, serials.join(", "));
};
// ===================== Auto-update =====================
let updateInfo = null;
async function checkUpdate() {
  const r = await poke.updateCheck().catch(() => null);
  if (!r || !r.available) return;
  updateInfo = r;
  $("#ubTitle").textContent = `Có bản mới v${r.version}` + (r.mandatory ? " (bắt buộc)" : "");
  $("#ubSub").textContent = r.notes || `Đang chạy v${r.current}`;
  if (r.mandatory) $("#ubLater").hidden = true;
  $("#updateBar").hidden = false;
}
$("#ubLater").onclick = () => { $("#updateBar").hidden = true; };
$("#ubBtn").onclick = async () => {
  if (!updateInfo) return;
  const btn = $("#ubBtn");
  btn.disabled = true;
  const mb = (n) => (n / 1048576).toFixed(0);
  const off = poke.onUpdateProgress(({ got, total }) => {
    btn.textContent = total ? `Tải ${mb(got)}/${mb(total)} MB` : `Tải ${mb(got)} MB`;
  });
  const d = await poke.updateDownload(updateInfo).catch(() => null);
  off && off();
  if (!d || !d.ok) {
    btn.disabled = false; btn.textContent = "Thử lại";
    toast("Tải bản cập nhật lỗi: " + ((d && d.msg) || "không rõ"), { type: "bad", timeout: 6000 });
    return;
  }
  btn.textContent = "Khởi động lại…";
  const a = await poke.updateApply(d.path).catch(() => null);
  if (!a || !a.ok) {
    btn.disabled = false; btn.textContent = "Cập nhật ngay";
    toast((a && a.msg) || "Không cài được bản mới", { type: "bad", timeout: 6000 });
  }
  // Thành công → app tự thoát & khởi động lại (helper .cmd xử lý).
};

// Nút "Tải script" đã bỏ — script tự nạp sẵn qua autoUploadAll() (không cần thao tác tay).
$("#btnRunSel").onclick = async () => {
  const list = selectedDevices();
  if (!list.length) return;
  const s = scripts.find((x) => x.id === selectedScriptId);
  pushFeed("▶️", `Chạy hàng loạt: ${s ? s.name : selectedScriptId}`, `${list.length} máy`);
  for (const d of list) await runScriptOn(d, { openDrawer: false });
};
$("#btnStopSel").onclick = async () => {
  const list = selectedDevices();
  if (!list.length) return;
  pushFeed("⏹️", "Dừng hàng loạt", `${list.length} máy`, "bad");
  toast(`Đã gửi Dừng cho ${list.length} máy`, { type: "info" });
  for (const d of list) { await poke.deviceStop(d.host, d.port); markRunning(d.id, false); }
};

// ----- Trạng thái đang chạy: nút Chạy ↔ Dừng, poll nhẹ không lag -----
function runBtnHTML(d) {
  return runningState[d.id]
    ? `<button class="btn danger sm" data-act="stop" title="Dừng script">⏹ Dừng</button>`
    : `<button class="btn primary sm" data-act="run" title="Chạy script đã chọn">▶ Chạy</button>`;
}
// Đổi nút của 1 hàng tại chỗ (không render lại cả bảng → không nháy/lag, giữ nguyên checkbox).
function setRowRunBtn(id) {
  const row = rowsEl.querySelector(`tr[data-id="${cssEsc(id)}"]`);
  const btn = row && row.querySelector('[data-act="run"],[data-act="stop"]');
  const d = devices.find((x) => x.id === id);
  if (btn && d) btn.outerHTML = runBtnHTML(d);
}
function markRunning(id, on) { if (runningState[id] !== on) { runningState[id] = on; setRowRunBtn(id); } }

// Poll gọn: 1 lần gọi cho tất cả máy (song song ở main), chỉ khi đang ở tab Thiết bị.
let runPollBusy = false;
async function pollRunning() {
  if (runPollBusy || scanning || !devices.length) return;
  if (!$("#view-devices").classList.contains("active")) return;
  runPollBusy = true;
  try {
    const map = await poke.devicesRunning(devices.map((d) => ({ id: d.id, host: d.host, port: d.port })));
    for (const d of devices) markRunning(d.id, !!map[d.id]);
  } catch (_) {} finally { runPollBusy = false; }
}
setInterval(pollRunning, 2500);

// ===================== Tác vụ nhanh =====================
$(".quick-grid").addEventListener("click", async (e) => {
  const b = e.target.closest(".qa"); if (!b) return;
  const qa = b.dataset.qa;
  if (qa === "wifi") { if (currentMode !== "wifi") setMode("wifi"); else scan(); }
  else if (qa === "usb") { if (currentMode !== "usb") setMode("usb"); else scan(); }
  else if (qa === "runall") { if (!devices.length) pushFeed("⚠️", "Chưa có thiết bị để chạy", ""); else { pushFeed("▶️", "Chạy script tất cả máy", `${devices.length} máy`); for (const d of devices) await runScriptOn(d, { openDrawer: false }); } }
  else if (qa === "view") { if (devices[0]) actOn(devices[0], "view"); else pushFeed("⚠️", "Chưa có thiết bị để mở view", ""); }
  else if (qa === "license") { devices.forEach(refreshLicense); pushFeed("🔑", "Kiểm lại license tất cả máy", `${devices.length} máy`); }
  else if (qa === "stopall") { for (const d of devices) await poke.deviceStop(d.host, d.port); pushFeed("⏹️", "Đã gửi Dừng tất cả máy", `${devices.length} máy`); }
  else if (qa === "logs") goto("logs");
  else if (qa === "config") goto("config");
});

// ===================== Drawer log =====================
const logOverlay = $("#logOverlay"), logDrawer = $("#logDrawer"), logBody = $("#logBody"), runDot = $("#runDot");
let logCtx = null;
function openLog(d) {
  closeLog();
  logCtx = { host: d.host, port: d.port, offset: 0, timer: null };
  $("#logTitle").textContent = "📜 " + d.name;
  $("#logSub").textContent = `${ipLocalOf(d)} · serial ${d.serial || "?"}`;
  logBody.textContent = ""; logOverlay.hidden = false; logDrawer.hidden = false;
  pushFeed("📜", `Mở log ${d.name}`, ipLocalOf(d));
  pollLog(); logCtx.timer = setInterval(pollLog, 900);
}
let polling = false;
async function pollLog() {
  if (!logCtx || polling) return; polling = true;
  try {
    const r = await poke.deviceLog(logCtx.host, logCtx.port, logCtx.offset);
    if (r && r.log) { logBody.textContent += r.log; logBody.scrollTop = logBody.scrollHeight; }
    if (r && typeof r.next === "number") logCtx.offset = r.next;
    runDot.classList.toggle("on", !!(r && r.running));
    $("#btnLogStop").disabled = !(r && r.running);
  } catch (_) {} finally { polling = false; }
}
function closeLog() { if (logCtx && logCtx.timer) clearInterval(logCtx.timer); logCtx = null; logOverlay.hidden = true; logDrawer.hidden = true; }
$("#btnLogClose").onclick = closeLog;
logOverlay.onclick = closeLog;
$("#btnLogStop").onclick = async () => { if (!logCtx) return; await poke.deviceStop(logCtx.host, logCtx.port); logBody.textContent += "\n— đã gửi lệnh Dừng —\n"; };

// ===================== Cấu hình (apikey imapicloud + tuỳ chọn 4G) =====================
const cfgApiKey = $("#cfgApiKey"), cfgState = $("#cfgState"), use4g = $("#use4g");
function parseConfig(text) {
  const map = {};
  for (const line of String(text || "").split(/\r?\n/)) {
    const ln = line.trim(); if (!ln || ln.startsWith("#")) continue;
    const m = ln.match(/^([\w\-]+)\s*[:=]\s*(.*)$/); if (m) map[m[1].toLowerCase()] = m[2].trim();
  }
  return map;
}
const isOn = (v) => /^(1|true|on|yes)$/i.test(String(v || "").trim());
function buildConfigText() { return `apikey=${cfgApiKey.value.trim()}\nuse4g=${use4g.checked ? 1 : 0}\n`; }
async function loadConfig() {
  const m = parseConfig((await poke.configLoad()).text || "");
  cfgApiKey.value = m.apikey || "";
  use4g.checked = isOn(m.use4g);
  updateFooterKey();
}
cfgApiKey.oninput = updateFooterKey;
// Con mắt: hiện/ẩn apikey (mặc định che ••• vì input type=password). Nút ✕: xoá nhanh.
$("#cfgApiEye").onclick = () => { cfgApiKey.type = cfgApiKey.type === "password" ? "text" : "password"; };
$("#cfgApiClear").onclick = () => { cfgApiKey.value = ""; cfgApiKey.focus(); updateFooterKey(); };
$("#btnCfgSave").onclick = async () => {
  const r = await poke.configSave(buildConfigText());
  cfgState.textContent = r.ok ? "✓ Đã lưu cấu hình" : "⚠ " + (r.msg || "lỗi lưu");
  cfgState.style.color = r.ok ? "var(--ok)" : "var(--bad)";
  pushFeed("💾", "Lưu cấu hình", `API key ${cfgApiKey.value ? "✓" : "—"} · 4G ${use4g.checked ? "BẬT" : "tắt"}`, r.ok ? "ok" : "bad");
};

// ===================== Footer (API key + máy chủ) =====================
let apiVisible = false;
function updateFooterKey() {
  const k = (cfgApiKey.value || "").trim();
  $("#footApiKey").textContent = !k ? "(chưa có)" : apiVisible ? k : "•".repeat(Math.min(k.length, 20));
}
$("#apiEye").onclick = () => { apiVisible = !apiVisible; updateFooterKey(); };
function markServer(ok) {
  $("#footDot").className = "dot " + (ok ? "on" : "off");
  $("#footServer").textContent = ok ? "Đã kết nối máy chủ license" : "Mất kết nối máy chủ";
  const pill = $("#serverPill");
  pill.innerHTML = `<i class="dot ${ok ? "on" : "off"}"></i> ${ok ? "Online" : "Offline"}`;
}
async function pingServer() {
  const r = await poke.checkLicense("PINGCHECK0000");   // serial giả → chỉ cần biết server có trả lời
  markServer(r.reason !== "network");
}

// ===================== Uptime =====================
const startTs = Date.now();
setInterval(() => {
  const s = Math.floor((Date.now() - startTs) / 1000);
  const hh = String(Math.floor(s / 3600)).padStart(2, "0");
  const mm = String(Math.floor((s % 3600) / 60)).padStart(2, "0");
  const ss = String(s % 60).padStart(2, "0");
  $("#stUptime").textContent = `${hh}:${mm}:${ss}`;
}, 1000);

// ===================== Khởi động =====================
(async function init() {
  try { const v = await poke.appVersion(); const el = $("#appVer"); if (el && v) el.textContent = "v" + v; } catch (_) {}
  checkUpdate();   // kiểm tra bản mới nền, không chặn khởi động
  await loadConfig();
  await loadScripts();
  renderAll(); renderFeed(); showEmpty();
  pushFeed("🚀", "Khởi động PokémonTool", "sẵn sàng");
  pingServer();
  const t = await poke.usbTooling();
  if (!t.usbmuxd) $$(".mode").forEach((m) => { if (m.dataset.mode === "usb") m.title = "Chưa thấy usbmuxd — cài 3uTools / iTunes / Apple Devices"; });

  // Nhớ chế độ đã chọn lần trước → đặt toggle & TỰ QUÉT luôn (mặc định WiFi nếu chưa có).
  const s = await poke.settingsGet();
  const savedMode = s && (s.mode === "usb" || s.mode === "wifi") ? s.mode : "wifi";
  setMode(savedMode, { persist: false, rescan: false });   // đặt UI, không ghi đè, chưa quét
  pushFeed("🔄", `Tự quét theo chế độ đã lưu: ${savedMode.toUpperCase()}`, "");
  scan();
})();
