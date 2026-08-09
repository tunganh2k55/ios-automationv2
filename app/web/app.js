"use strict";

// Toạ độ logic (điểm) — lấy từ /api/status (màn thật, vd 375x667).
const LOGICAL = { w: 375, h: 667 };

const $ = (s) => document.querySelector(s);
const api = async (path, body) => {
  const opt = body
    ? { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }
    : {};
  const r = await fetch("/api/" + path, opt);
  return r.json();
};

// ---- Ảnh màn hình (STREAM MJPEG) ----
// Một kết nối mở sẵn: daemon đẩy khung liên tục, <img> render như video.
// Không còn poll từng ảnh (bỏ overhead bắt tay HTTP + lịch JS mỗi khung).
const shot = $("#shot");
const noimg = $("#noimg");
const STREAM_URL = "/api/stream";
let streamOn = false;

function startStream() {
  if (streamOn) return;
  streamOn = true;
  shot.onload = () => { shot.style.display = "block"; noimg.style.display = "none"; };
  shot.onerror = () => {
    if (!streamOn) return;
    noimg.style.display = "flex";
    setTimeout(() => { if (streamOn) shot.src = STREAM_URL + "?t=" + Date.now(); }, 800);
  };
  shot.src = STREAM_URL + "?t=" + Date.now();
}
function stopStream() {
  streamOn = false;
  shot.src = "";               // đóng kết nối MJPEG
  shot.style.display = "none";
  noimg.style.display = "flex";
}
// Stream tự cập nhật → refresh thủ công không cần nữa (giữ hàm để chỗ khác gọi khỏi lỗi).
function refreshShot() {}

// Nút View Màn / Tắt View: người dùng chủ động bật/tắt xem màn. Tab bị ẩn thì tạm dừng.
let viewWanted = true;
const btnView = $("#btnView");
function updateViewBtn() {
  btnView.textContent = viewWanted ? "Tắt View" : "View Màn";
  btnView.classList.toggle("on", viewWanted);
}
function syncStream() {
  const want = viewWanted && !document.hidden;
  if (want) startStream(); else stopStream();
  updateViewBtn();
}
btnView.onclick = () => { viewWanted = !viewWanted; syncStream(); };
document.addEventListener("visibilitychange", syncStream);
$("#btnRefresh").onclick = () => { viewWanted = true; stopStream(); startStream(); updateViewBtn(); };  // nối lại stream
// Nút Home: 1 lần = về màn chính. Nhấn ĐÚP (trong 350ms):
//   - Màn ĐANG TẮT/khoá lúc bắt đầu → chỉ bật màn + mở khoá (lần bấm 1 đã làm), KHÔNG mở switcher.
//   - Màn đang bật → App Switcher (như iPhone bấm Home 2 lần).
// Biết màn tắt/bật nhờ msg của lần bấm đầu: WAKE trả "OK wake+unlock" khi máy đang khoá.
let homeTapTimer = null;
let homeWasLocked = false;                 // trạng thái màn lúc bắt đầu cử chỉ (từ lần bấm 1)
$("#phoneHome").onclick = async () => {
  if (homeTapTimer) {                      // ---- lần bấm THỨ 2 (bấm đúp) ----
    clearTimeout(homeTapTimer); homeTapTimer = null;
    if (!homeWasLocked) {                  // màn đang bật → App Switcher
      try { await api("switcher"); } catch (e) {}
    }                                       // màn đang tắt → lần bấm 1 đã bật+mở khoá, không làm gì thêm
    return;
  }
  // ---- lần bấm THỨ 1: bật màn + mở khoá, ghi nhớ màn trước đó có đang khoá không ----
  let res = null;
  try { res = await api("wake"); } catch (e) {}
  homeWasLocked = !!(res && typeof res.msg === "string" && /wake\+unlock/i.test(res.msg));
  homeTapTimer = setTimeout(async () => {  // không có bấm 2 → bấm 1 lần = về màn chính
    homeTapTimer = null;
    try { await api("home"); } catch (e) {}
  }, 350);
};
updateViewBtn();   // stream chỉ bật trong boot() SAU khi kiểm tra license

// ---- Toạ độ trên ảnh → point ----
const screen = $("#screen");
const crosshair = $("#crosshair");
const swipeLine = $("#swipeLine");
const coords = $("#coords");
let dragStart = null;

function toPoint(ev) {
  const r = (shot.style.display !== "none" ? shot : screen).getBoundingClientRect();
  const px = Math.max(0, Math.min(ev.clientX - r.left, r.width));
  const py = Math.max(0, Math.min(ev.clientY - r.top, r.height));
  return {
    x: Math.round((px / r.width) * LOGICAL.w),
    y: Math.round((py / r.height) * LOGICAL.h),
    // px/py tương đối so với khung screen (để vẽ overlay)
    ox: ev.clientX - screen.getBoundingClientRect().left,
    oy: ev.clientY - screen.getBoundingClientRect().top,
  };
}
function resetDrag() { dragStart = null; swipeLine.hidden = true; }

// ---- Kênh điều khiển realtime (WebSocket) → touch liên tục bám tay ----
// Tap (không di chuyển) vẫn qua /api/tap (tin cậy cho nút). Kéo/vuốt → stream d/m/u qua WS.
let ctrlWS = null;
function ctrlConnect() {
  try {
    ctrlWS = new WebSocket((location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/ws/control");
    ctrlWS.onclose = () => { ctrlWS = null; setTimeout(ctrlConnect, 1000); };
    ctrlWS.onerror = () => { try { ctrlWS.close(); } catch (e) {} };
  } catch (e) { setTimeout(ctrlConnect, 1000); }
}
// ctrlConnect() được gọi trong boot() sau khi xác nhận đã kích hoạt.
function ctrlSend(phase, p) {
  if (ctrlWS && ctrlWS.readyState === 1) ctrlWS.send(phase + " " + p.x + " " + p.y);
}

let dragging = false, lastMoveTs = 0;
screen.addEventListener("pointerdown", (ev) => {
  ev.preventDefault();
  dragStart = toPoint(ev);
  dragging = false;
  try { screen.setPointerCapture(ev.pointerId); } catch (e) {}
  swipeLine.hidden = true;
});
screen.addEventListener("pointermove", (ev) => {
  if (!dragStart) return;
  const p = toPoint(ev);
  coords.textContent = `x: ${p.x}, y: ${p.y}`;
  const dist = Math.hypot(p.ox - dragStart.ox, p.oy - dragStart.oy);
  if (!dragging && dist > 8) { dragging = true; ctrlSend("d", dragStart); }   // bắt đầu kéo: down tại điểm gốc
  if (dragging) {
    const now = performance.now();
    if (now - lastMoveTs > 16) { lastMoveTs = now; ctrlSend("m", p); }         // ~60 move/s
  }
});
screen.addEventListener("pointercancel", () => { if (dragging && dragStart) ctrlSend("u", dragStart); resetDrag(); dragging = false; });
screen.addEventListener("pointerup", async (ev) => {
  const end = toPoint(ev);
  const start = dragStart;
  const wasDrag = dragging;
  resetDrag(); dragging = false;
  if (!start) return;
  try {
    if (wasDrag) ctrlSend("u", end);                     // kết thúc kéo mượt
    else { await api("tap", { x: start.x, y: start.y }); kbFocus(); }  // tap: đường tin cậy + sẵn sàng gõ
  } catch (e) {}
  setTimeout(refreshShot, 150);
});

// ================== Bàn phím từ web UI → gõ vào ô đang focus trên iPhone ==================
// kbCapture = <textarea> ẩn. Khi nó ĐANG FOCUS thì mọi ký tự / IME / paste (Ctrl+V) được chuyển
// sang thiết bị qua /api/type; Backspace/Enter qua KEY. Tap vào màn iPhone sẽ tự focus kbCapture
// nên sau khi tap trúng ô nhập là gõ được ngay. Bấm vào ô nhập của web (editor, tên file, tìm app)
// sẽ lấy focus khỏi kbCapture → gõ/paste ở đó lại bình thường. Nút ⌨ bật/tắt cơ chế này.
const kbCapture = $("#kbCapture");
const kbBtn = $("#btnKb");
let kbAuto = true;          // tap vào màn có tự bật bàn phím thiết bị không
let kbComposing = false;    // đang gõ IME (tiếng Việt telex/unikey…) → chờ compositionend

function kbUpdateBtn() { kbBtn.classList.toggle("on", kbAuto); }
function kbFocus() { if (kbAuto) try { kbCapture.focus({ preventScroll: true }); } catch (e) {} }
kbBtn.onclick = () => { kbAuto = !kbAuto; kbUpdateBtn(); if (kbAuto) kbFocus(); else kbCapture.blur(); };
kbUpdateBtn();

async function kbType(text) { if (text) try { await api("type", { text }); } catch (e) {} }
async function kbKey(name) { try { await api("touchcmd", { cmd: "KEY " + name }); } catch (e) {} }

// Gửi nội dung vừa nhập rồi xoá sạch để lần sau chỉ còn phần MỚI (mỗi ký tự/paste gửi 1 lần).
function kbFlush() { const v = kbCapture.value; if (v) { kbCapture.value = ""; kbType(v); } }
kbCapture.addEventListener("compositionstart", () => { kbComposing = true; });
kbCapture.addEventListener("compositionend", () => { kbComposing = false; kbFlush(); });
kbCapture.addEventListener("input", () => { if (!kbComposing) kbFlush(); });
kbCapture.addEventListener("keydown", (e) => {
  if (e.key === "Backspace") { e.preventDefault(); kbKey("BACK"); }
  else if (e.key === "Enter") { e.preventDefault(); kbKey("RETURN"); }
  // ký tự thường + paste để sự kiện 'input' xử lý (bắt được cả IME lẫn Ctrl+V)
});
kbCapture.addEventListener("paste", (e) => {   // dán trực tiếp cho chắc (không lệ thuộc 'input')
  const t = (e.clipboardData || window.clipboardData) && (e.clipboardData || window.clipboardData).getData("text");
  if (t) { e.preventDefault(); kbCapture.value = ""; kbType(t); }
});

// Ctrl+V khi KHÔNG đứng trong ô nhập web nào → vẫn dán sang thiết bị.
document.addEventListener("paste", (e) => {
  const t = e.target;
  if (t === kbCapture) return;   // đã xử lý ở trên
  if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return; // dán vào ô web
  const txt = (e.clipboardData || window.clipboardData) && (e.clipboardData || window.clipboardData).getData("text");
  if (txt) { e.preventDefault(); kbType(txt); }
});

// ---- Script Lua: danh sách file · editor · lưu/mở/xoá · chạy ----
const scriptBox = $("#scriptBox");
const scriptName = $("#scriptName");
const fileList = $("#fileList");
const saveState = $("#saveState");
const scriptOut = $("#scriptOut");
const logTitle = $("#logTitle");
let scriptDirty = false;
let gScripts = [];       // tên các file
let currentFile = "";    // file đang mở
const btnEncrypt = $("#btnEncrypt");
const btnSaveEl = $("#btnSave");

// File .luax = script đã mã hoá + ký (bảo vệ mã nguồn). Không đọc/sửa lại được, chỉ chạy.
function isEncName(n) { return /\.luax$/i.test((n || "").trim()); }

// Bật/tắt "chế độ đã mã hoá": editor read-only, khoá nút Lưu/Mã hoá khi đang mở .luax.
function applyEncMode(name) {
  const enc = isEncName(name);
  scriptBox.readOnly = enc;                 // trường hợp fallback <textarea>
  scriptBox.classList.toggle("locked", enc);
  if (window.iosautoEditor) window.iosautoEditor.updateOptions({ readOnly: enc });  // Monaco
  btnSaveEl.disabled = enc;
  btnEncrypt.disabled = enc;
}

function markDirty(d) {
  scriptDirty = d;
  saveState.textContent = d ? "● chưa lưu" : "";
  saveState.style.color = d ? "var(--warn)" : "";
}
scriptBox.addEventListener("input", () => markDirty(true));

// Chuẩn hoá tên: tự thêm .lua nếu thiếu.
function normName(n) {
  n = (n || "").trim();
  if (!n) return "";
  if (!/\.[A-Za-z0-9]+$/.test(n)) n += ".lua";
  return n;
}

function renderFileList() {
  $("#fileCount").textContent = gScripts.length ? `(${gScripts.length})` : "";
  fileList.innerHTML = "";
  if (!gScripts.length) {
    const e = document.createElement("div");
    e.className = "file-empty";
    e.textContent = "Chưa có file. Bấm ＋ Mới.";
    fileList.appendChild(e);
    return;
  }
  gScripts.forEach((name) => {
    const item = document.createElement("div");
    item.className = "file-item" + (name === currentFile ? " active" : "") + (isEncName(name) ? " enc" : "");
    item.textContent = (isEncName(name) ? "🔒 " : "") + name;
    item.title = isEncName(name) ? name + " (đã mã hoá — chỉ chạy được)" : name;
    item.onclick = () => openFile(name);
    fileList.appendChild(item);
  });
}

async function loadScriptList(selName) {
  const r = await api("scripts");
  gScripts = (r.files || []).map((f) => f.name).sort((a, b) => a.localeCompare(b));
  if (selName) currentFile = selName;
  renderFileList();
}

async function openFile(name) {
  if (name === currentFile && !scriptDirty) return;
  if (scriptDirty && !confirm("File hiện tại chưa lưu. Mở file khác và bỏ thay đổi?")) return;
  const r = await api("script_read", { name });
  if (r.ok) {
    scriptBox.value = r.content || "";
    scriptName.value = r.name;
    currentFile = r.name;
    markDirty(false);
    applyEncMode(r.name);
    if (isEncName(r.name)) {
      saveState.textContent = "🔒 đã mã hoá — chỉ chạy được (▶), không sửa/đọc lại";
      saveState.style.color = "var(--muted)";
    }
    renderFileList();
  } else alert("Không mở được: " + (r.msg || name));
}

$("#btnNew").onclick = () => {
  if (scriptDirty && !confirm("File hiện tại chưa lưu. Tạo file mới và bỏ thay đổi?")) return;
  scriptBox.value = "";
  scriptName.value = "";
  currentFile = "";
  markDirty(false);
  applyEncMode("");
  renderFileList();
  scriptName.focus();
};

// ================== ⬆ Nhập file từ máy tính ==================
// Định tuyến theo ĐUÔI: .lua/.luax/.txt/.json/.csv/.md/.ini/.conf -> script_save (thư mục scripts);
// .png/.jpg/.jpeg/.gif/.bmp/.webp -> image_save (thư mục images). Đuôi khác -> bỏ qua.
const importFile = $("#importFile");
const IMPORT_IMG_EXT = /\.(png|jpe?g|gif|bmp|webp)$/i;
const IMPORT_TXT_EXT = /\.(lua|luax|txt|json|csv|md|ini|conf)$/i;

$("#btnImport").onclick = () => importFile.click();

function importSanitizeName(name) {
  name = (name || "").split(/[\\/]/).pop().trim();     // bỏ đường dẫn, chỉ giữ tên file
  return name.replace(/[^A-Za-z0-9._-]/g, "_");        // ký tự lạ -> _ (khớp *_valid_name của daemon)
}
function importReadText(file) {
  return new Promise((res, rej) => {
    const r = new FileReader();
    r.onload = () => res(r.result); r.onerror = () => rej(r.error);
    r.readAsText(file);
  });
}
function importReadDataURL(file) {
  return new Promise((res, rej) => {
    const r = new FileReader();
    r.onload = () => res(r.result); r.onerror = () => rej(r.error);
    r.readAsDataURL(file);
  });
}

importFile.onchange = async () => {
  const files = Array.from(importFile.files || []);
  importFile.value = "";   // reset để lần sau chọn lại cùng file vẫn kích hoạt onchange
  if (!files.length) return;

  let okScript = 0, okImg = 0, skipped = 0, failed = 0;
  const errs = [];
  for (const f of files) {
    const name = importSanitizeName(f.name);
    try {
      if (IMPORT_IMG_EXT.test(name)) {
        if (f.size > 4 * 1024 * 1024) { failed++; errs.push(name + " (ảnh > 4MB)"); continue; }
        const data = String(await importReadDataURL(f)).split(",")[1] || "";
        const r = await api("image_save", { name, data });
        if (r.ok) okImg++; else { failed++; errs.push(name + ": " + (r.msg || "lỗi")); }
      } else if (IMPORT_TXT_EXT.test(name)) {
        if (f.size > 128 * 1024) { failed++; errs.push(name + " (text > 128KB)"); continue; }
        const content = await importReadText(f);
        const r = await api("script_save", { name, content });
        if (r.ok) okScript++; else { failed++; errs.push(name + ": " + (r.msg || "lỗi")); }
      } else {
        skipped++; errs.push(name + " (đuôi không hỗ trợ)");
      }
    } catch (e) {
      failed++; errs.push(name + " (đọc file lỗi)");
    }
  }

  await loadScriptList();
  try { loadImages(); } catch (_) {}

  let msg = `Nhập: ${okScript} script, ${okImg} ảnh`;
  if (skipped) msg += `, ${skipped} bỏ qua`;
  if (failed) msg += `, ${failed} lỗi`;
  saveState.textContent = "⬆ " + msg;
  saveState.style.color = (failed || skipped) ? "var(--warn)" : "var(--ok)";
  if (errs.length) {
    console.warn("Import:", errs);
    if (failed || skipped) alert(msg + "\n\n" + errs.slice(0, 12).join("\n"));
  }
};

async function saveScript() {
  if (isEncName(currentFile)) { return; }   // .luax không sửa/lưu đè
  const name = normName(scriptName.value);
  if (!name) { alert("Nhập tên file trước (vd auto.lua)"); scriptName.focus(); return; }
  scriptName.value = name;
  const r = await api("script_save", { name, content: scriptBox.value });
  if (r.ok) {
    markDirty(false);
    saveState.textContent = "✓ đã lưu " + name;
    saveState.style.color = "var(--ok)";
    await loadScriptList(name);
  } else alert("Lưu lỗi: " + (r.msg || ""));
}
$("#btnSave").onclick = saveScript;

// 🔒 Mã hoá: mã hoá + ký nội dung editor → lưu thành <tên>.luax (bảo vệ mã nguồn).
// Một chiều: file .luax không giải mã/đọc lại được nếu không có khoá nhúng trong app.
async function encryptScript() {
  if (isEncName(currentFile)) { alert("File này đã mã hoá rồi."); return; }
  const content = scriptBox.value;
  if (!content.trim()) { alert("Editor trống — không có gì để mã hoá."); return; }
  const base = normName(scriptName.value) || "script.lua";
  const outName = base.replace(/\.[A-Za-z0-9]+$/, "") + ".luax";
  if (!confirm(
    `Mã hoá nội dung hiện tại → lưu thành “${outName}”?\n\n` +
    `• File .luax KHÔNG đọc/sửa lại được (mã nguồn đã được bảo vệ).\n` +
    `• Chỉ app này (mang đúng khoá) mới giải mã & chạy được.\n` +
    `• Nên giữ lại bản .lua gốc để chỉnh sửa về sau.`)) return;
  saveState.textContent = "🔒 đang mã hoá…"; saveState.style.color = "var(--muted)";
  let r;
  try { r = await api("script_encrypt", { content }); }
  catch (e) { alert("Lỗi kết nối khi mã hoá"); return; }
  if (!r.ok || !r.blob) { alert("Mã hoá lỗi: " + (r.msg || "")); return; }
  const s = await api("script_save", { name: outName, content: r.blob });
  if (!s.ok) { alert("Lưu .luax lỗi: " + (s.msg || "")); return; }
  currentFile = "";                 // ép mở lại để hiện chế độ đã mã hoá
  markDirty(false);
  await loadScriptList();
  await openFile(outName);
  saveState.textContent = "🔒 đã mã hoá → " + outName;
  saveState.style.color = "var(--ok)";
}
btnEncrypt.onclick = encryptScript;

// ⬇ Tải: tải file script đang mở về máy tính.
// Nếu đang mở 1 file đã lưu → lấy bản đã lưu trên thiết bị qua script_read (đúng nguyên bản,
// dùng được cho cả .luax). Nếu là file mới/chưa lưu → tải thẳng nội dung trong editor.
async function downloadScript() {
  const name = normName(scriptName.value);
  if (!name) { alert("Chưa có file để tải (nhập tên hoặc mở 1 file)."); scriptName.focus(); return; }
  let content = scriptBox.value;
  if (currentFile && !scriptDirty) {
    try {
      const r = await api("script_read", { name: currentFile });
      if (r.ok) content = r.content || "";
    } catch (e) { /* dùng nội dung editor làm dự phòng */ }
  }
  const blob = new Blob([content], { type: "text/plain;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url; a.download = name;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  saveState.textContent = "⬇ đã tải " + name;
  saveState.style.color = "var(--ok)";
}
$("#btnDownload").onclick = downloadScript;

$("#btnDelete").onclick = async () => {
  const name = normName(scriptName.value);
  if (!name) return;
  if (!confirm("Xoá file " + name + "?")) return;
  const r = await api("script_delete", { name });
  if (r.ok) {
    scriptBox.value = ""; scriptName.value = ""; currentFile = ""; markDirty(false);
    saveState.textContent = "đã xoá " + name; saveState.style.color = "var(--muted)";
    await loadScriptList();
  } else alert("Xoá lỗi: " + (r.msg || ""));
};

// Ctrl+S để lưu, khỏi rời bàn phím.
scriptBox.addEventListener("keydown", (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s") { e.preventDefault(); saveScript(); }
});

// ---- Chạy script NỀN: nút Chạy ↔ Dừng, theo dõi log tăng dần qua /api/run/log ----
let runId = null, runPoll = null, runOffset = 0;
const btnRun = $("#btnRun");
function setRunningUI(on) {
  if (on) { btnRun.textContent = "⏹ Dừng"; btnRun.classList.remove("run"); btnRun.classList.add("danger"); btnRun.title = "Dừng script"; }
  else { btnRun.textContent = "▶ Chạy"; btnRun.classList.remove("danger"); btnRun.classList.add("run"); btnRun.title = "Chạy script"; }
}
let runPolling = false;   // chống các lần poll chồng nhau khi daemon trả lời chậm
async function pollRun() {
  if (runPolling) return;
  runPolling = true;
  let r;
  try { r = await api("run/log", { offset: runOffset }); }
  catch (e) { return; }
  finally { runPolling = false; }
  if (r.log) { scriptOut.textContent += r.log; scriptOut.scrollTop = scriptOut.scrollHeight; }
  if (typeof r.next === "number") runOffset = r.next;
  if (!r.running && runId !== null) {   // chỉ kết thúc 1 LẦN (tránh in trùng "— xong —")
    if (runPoll) { clearInterval(runPoll); runPoll = null; }
    runId = null; setRunningUI(false);
    scriptOut.textContent += "\n— xong —"; scriptOut.scrollTop = scriptOut.scrollHeight;
    setTimeout(refreshShot, 150);
  }
}
// Bắt đầu chạy 1 đoạn code (mặc định = nội dung editor). Dùng chung cho nút ▶ Chạy và "Chạy thử" ở bảng Hàm Lua.
async function startRun(code) {
  logTitle.textContent = "▶ Log chạy";
  scriptOut.textContent = "";
  runOffset = 0;
  let r;
  try { r = await api("script", { code }); } catch (e) { scriptOut.textContent = "(lỗi kết nối)"; return; }
  if (!r.ok) { scriptOut.textContent = "⚠ " + (r.msg || "không chạy được") + (r.runid ? " (runid " + r.runid + ")" : ""); return; }
  runId = r.runid; setRunningUI(true);
  runPoll = setInterval(pollRun, 500);
  pollRun();
}
btnRun.onclick = () => {
  if (runId) { api("run/stop", {}).catch(() => {}); return; }   // đang chạy → dừng
  startRun(scriptBox.value);
};
// Đồng bộ nút Chạy/Dừng với trạng thái THẬT của thiết bị.
// Dùng khi: mở app, kéo-reload trang, mở lại tab, hoặc script được start từ máy khác.
// Gọi lúc boot() và lặp lại 5s/lần (xem cuối file).
async function syncRunState() {
  let rs;
  try { rs = await api("run"); } catch (e) { return; }
  if (!rs) return;
  if (rs.busy && !runId) {                 // thiết bị đang chạy mà UI tưởng rảnh → nối lại + hiện ⏹ Dừng
    runId = rs.runid; runOffset = 0;
    logTitle.textContent = "▶ Log chạy";
    scriptOut.textContent = "";
    setRunningUI(true);
    if (!runPoll) { runPoll = setInterval(pollRun, 500); pollRun(); }
  } else if (!rs.busy && runId) {          // thiết bị đã rảnh mà UI vẫn tưởng đang chạy → về ▶ Chạy
    if (runPoll) { clearInterval(runPoll); runPoll = null; }
    runId = null; setRunningUI(false);
  }
}

// ---- Cầu nối cho bảng tra Hàm Lua (docs.js) ----
window.iosauto = {
  // Chèn đoạn ví dụ vào editor tại vị trí con trỏ (không ghi đè script đang có).
  insertCode(code) {
    const el = scriptBox;
    const s = el.selectionStart ?? el.value.length;
    const e = el.selectionEnd ?? el.value.length;
    const before = el.value.slice(0, s), after = el.value.slice(e);
    const pad = before && !before.endsWith("\n") ? "\n" : "";
    const snippet = pad + code + (after && !after.startsWith("\n") ? "\n" : "");
    el.value = before + snippet + after;
    const pos = (before + snippet).length;
    el.selectionStart = el.selectionEnd = pos;
    el.focus();
    markDirty(true);
  },
  // Chạy thử ví dụ ngay (không đụng nội dung editor). Đang chạy dở → báo để tránh chồng lệnh.
  runCode(code) {
    if (runId) { alert("Đang chạy một script khác — bấm ⏹ Dừng trước đã."); return false; }
    startRun(code);
    return true;
  },
  isRunning() { return !!runId; },
};
$("#btnClear").onclick = () => (scriptOut.textContent = "");

// ---- Status + apps ----
async function refreshStatus() {
  try {
    const s = await api("status");
    const devName = s.device?.name || "iPhone";
    $("#statusDot").className = "dot on";
    const usb = s.usbPort ? ` · USB localhost:${s.usbPort}` : "";
    const el = $("#deviceLine");
    el.textContent = `${devName} · iOS ${s.device?.ios || "?"} · ${s.ip || ""}:${s.port || ""}${usb}`;
    if (s.usbPort) el.title =
      `Qua WiFi/LAN:  http://${s.ip || "<ip>"}:${s.port}\n` +
      `Qua USB (cắm cáp, mở trên PC):  http://localhost:${s.usbPort}\n` +
      `Nhiều máy cùng cắm USB: chạy app/control/usb_web.py để tự chia cổng (8081, 8082, …); ` +
      `cổng trên iPhone luôn ${s.usbPort}, chỉ cổng localhost phía PC tăng dần.`;
    document.title = `${devName} - iOSAuto`;   // vd "SE2 - iOSAuto"
    if (s.screen) { LOGICAL.w = s.screen.w; LOGICAL.h = s.screen.h; }
  } catch (e) {
    $("#statusDot").className = "dot off";
    $("#deviceLine").textContent = "mất kết nối daemon";
  }
}
// gApps = CHỈ app do người dùng cài (type "User": App Store/sideload), loại app hệ thống.
let gApps = [];
async function loadApps() {
  const r = await api("apps");
  gApps = (r.apps || [])
    .filter((a) => (a.type || "") === "User")
    .sort((a, b) => (a.name || "").localeCompare(b.name || ""));
}

// ---- Menu helper (cạnh nút ↻) ----
const helperMenu = $("#helperMenu");
$("#btnHelper").onclick = (e) => { e.stopPropagation(); helperMenu.hidden = !helperMenu.hidden; };
helperMenu.addEventListener("click", (e) => e.stopPropagation());
document.addEventListener("click", () => { helperMenu.hidden = true; });
$("#miApps").onclick = () => { helperMenu.hidden = true; openApps(); };

// OCR: nhận dạng chữ trên màn (ảnh fbcap độ phân giải cao, Vision revision 3) → mỗi dòng bấm để tap.
const ocrLangSelect = $("#ocrLangSelect");
let ocrLang = localStorage.getItem("iosauto.ocrLang") || "en-US,vi-VN";
if (ocrLangSelect) {
  ocrLangSelect.value = ocrLang;
  if (ocrLangSelect.value !== ocrLang) {
    ocrLang = "en-US,vi-VN";
    ocrLangSelect.value = ocrLang;
  }
  ocrLangSelect.onchange = () => {
    ocrLang = ocrLangSelect.value || "en-US,vi-VN";
    localStorage.setItem("iosauto.ocrLang", ocrLang);
  };
}
async function runOcr() {
  logTitle.textContent = "🔤 OCR màn";
  scriptOut.innerHTML = "";
  if (ocrLangSelect) ocrLang = ocrLangSelect.value || ocrLang;
  const bar = document.createElement("div");
  bar.style.marginBottom = "6px";
  bar.textContent = "OCR lang: " + ocrLang;
  scriptOut.appendChild(bar);
  const status = document.createElement("div"); status.textContent = "🔤 đang nhận dạng…"; scriptOut.appendChild(status);
  let r;
  try { r = await api("ocr", { lang: ocrLang }); } catch (e) { status.textContent = "OCR lỗi kết nối"; return; }
  if (!r.ok) { status.textContent = "OCR lỗi: " + (r.msg || "?"); return; }
  status.remove();
  const lines = r.lines || [];
  if (!lines.length) { const d = document.createElement("div"); d.textContent = "(không thấy chữ)"; scriptOut.appendChild(d); return; }
  lines.forEach((o) => {
    const d = document.createElement("div");
    d.className = "ocr-line";
    d.textContent = `(${o.cx},${o.cy})  ${o.text}`;
    d.title = "Bấm để tap vào chữ này (x:" + o.cx + " y:" + o.cy + ")";
    d.onclick = () => api("tap", { x: o.cx, y: o.cy });
    scriptOut.appendChild(d);
  });
}
$("#miOcr").onclick = () => { helperMenu.hidden = true; runOcr(); };

// Dump XML: xuất cây UIView của app foreground (page source) vào khung log.
$("#miDump").onclick = async () => {
  helperMenu.hidden = true;
  logTitle.textContent = "🧬 Dump XML";
  scriptOut.textContent = "🧬 đang lấy cây view…";
  try {
    const res = await fetch("/api/dump");
    const t = await res.text();
    scriptOut.textContent = t;
    scriptOut.scrollTop = 0;
  } catch (e) { scriptOut.textContent = "Dump lỗi kết nối"; }
};

// ---- Panel helper: app người dùng đã cài (bấm để MỞ app trên iPhone) ----
// Mở trong khung editor (editor thu nhỏ lại), không phải modal che màn.
const helperPanel = $("#helperPanel");
const appsList = $("#appsList");
const appsSearch = $("#appsSearch");
function renderAppsList(filter) {
  const q = (filter || "").trim().toLowerCase();
  const list = gApps.filter((a) => !q || (`${a.name} ${a.bundleId}`).toLowerCase().includes(q));
  $("#appsCount").textContent = `(${list.length})`;
  appsList.innerHTML = "";
  if (!list.length) {
    const e = document.createElement("div");
    e.className = "apps-empty";
    e.textContent = gApps.length ? "Không tìm thấy app khớp." : "Không có app cài ngoài (chỉ toàn app hệ thống).";
    appsList.appendChild(e);
    return;
  }
  list.forEach((a) => {
    const row = document.createElement("div");
    row.className = "app-row";
    const n = document.createElement("span"); n.className = "app-name"; n.textContent = a.name || "(không tên)";
    const b = document.createElement("span"); b.className = "app-bid"; b.textContent = a.bundleId;
    row.appendChild(n); row.appendChild(b);
    row.title = "Bấm để mở app này trên iPhone";
    row.onclick = async () => {
      closeApps();
      const r = await api("launch", { bundleId: a.bundleId });
      if (!r.ok) alert("Mở lỗi: " + (r.msg || a.bundleId));
    };
    appsList.appendChild(row);
  });
}
function openApps() {
  helperPanel.hidden = false;   // editor thu nhỏ lại nhường chỗ panel
  appsSearch.value = "";
  renderAppsList("");
  appsSearch.focus();
}
function closeApps() { helperPanel.hidden = true; }
$("#helperClose").onclick = closeApps;
appsSearch.addEventListener("input", () => renderAppsList(appsSearch.value));

// ---- Bố cục linh hoạt: thu/mở danh sách script · mở rộng helper · kéo chỉnh chiều cao log ----
const ideEl = document.querySelector(".ide");
$("#btnToggleFiles").onclick = () => {
  const collapsed = ideEl.classList.toggle("files-collapsed");
  $("#btnToggleFiles").textContent = collapsed ? "▶ Script" : "◀ Script";
};
$("#helperWide").onclick = () => { helperPanel.classList.toggle("wide"); };

(function () {
  const rez = $("#logResizer");
  const pane = document.querySelector(".editor-pane");
  const logPane = document.querySelector(".log-pane");
  if (!rez || !pane || !logPane) return;
  let dragging = false;
  rez.addEventListener("pointerdown", (e) => {
    dragging = true; try { rez.setPointerCapture(e.pointerId); } catch (_) {} e.preventDefault();
  });
  rez.addEventListener("pointermove", (e) => {
    if (!dragging) return;
    const rect = pane.getBoundingClientRect();
    let h = rect.bottom - e.clientY - 6;                 // chiều cao log theo con trỏ
    const maxH = Math.max(90, rect.height - 210);        // chừa tối thiểu cho editor
    h = Math.max(90, Math.min(h, maxH));
    logPane.style.flex = "none";
    logPane.style.height = h + "px";
  });
  const end = (e) => { if (dragging) { dragging = false; try { rez.releasePointerCapture(e.pointerId); } catch (_) {} } };
  rez.addEventListener("pointerup", end);
  rez.addEventListener("pointercancel", end);
})();
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !helperPanel.hidden) closeApps(); });

// ================== Helper: Chụp & cắt ảnh → lưu thư mục images của iosauto ==================
const imgTool = $("#imgTool");
const imgShot = $("#imgShot");
const imgStage = $("#imgStage");
const imgSel = $("#imgSel");
const imgSaveBtn = $("#imgSave");
const imgNameInp = $("#imgName");
const imgListEl = $("#imgList");
let imgSelRect = null;   // vùng chọn theo px hiển thị + kích thước ảnh hiển thị lúc chọn

// Copy chạy được cả trên HTTP thường: navigator.clipboard CHỈ có ở HTTPS/localhost,
// còn trang này mở qua http://<ip>:8080 → phải fallback execCommand("copy").
function copyTextCompat(text) {
  if (navigator.clipboard && window.isSecureContext)
    return navigator.clipboard.writeText(text).then(() => true).catch(() => copyTextFallback(text));
  return Promise.resolve(copyTextFallback(text));
}
function copyTextFallback(text) {
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.style.cssText = "position:fixed;left:-9999px;top:0;";
  document.body.appendChild(ta);
  ta.focus(); ta.select();
  let ok = false;
  try { ok = document.execCommand("copy"); } catch (_) {}
  ta.remove();
  return ok;
}

function imgHint(t) { $("#imgHint").textContent = t; }
function imgClearSel() { imgSelRect = null; imgSel.hidden = true; imgSaveBtn.disabled = true; }
function captureShot() {
  imgHint("⏳ đang chụp…");
  imgShot.onload = () => imgHint("Kéo chuột trên ảnh để chọn vùng cắt");
  imgShot.onerror = () => imgHint("chụp lỗi (bật daemon?)");
  imgShot.src = "/api/screenshot?t=" + Date.now();   // khung mới, không cache
  imgClearSel();
}

// Đổi vị trí chuột trên ảnh hiển thị → toạ độ ĐIỂM MÀN (point, khớp tap/tapText/vùng OCR).
function imgPointCoords(clientX, clientY, r) {
  const px = Math.max(0, Math.min(clientX - r.left, r.width));
  const py = Math.max(0, Math.min(clientY - r.top, r.height));
  return { x: Math.round((px / r.width) * LOGICAL.w), y: Math.round((py / r.height) * LOGICAL.h) };
}

// Kéo chuột trên ảnh → vẽ khung chọn. Click (không kéo) → in toạ độ điểm vào log.
let imgDrag = null;
imgStage.addEventListener("pointerdown", (e) => {
  if (e.target !== imgShot) return;
  const r = imgShot.getBoundingClientRect();
  imgDrag = { x0: e.clientX - r.left, y0: e.clientY - r.top, r, moved: false };
  try { imgStage.setPointerCapture(e.pointerId); } catch (_) {}
});
imgStage.addEventListener("pointermove", (e) => {
  if (!imgDrag) {
    // Không kéo: rê chuột trên ảnh → hiện toạ độ điểm màn ngay trên hint.
    if (e.target === imgShot) {
      const p = imgPointCoords(e.clientX, e.clientY, imgShot.getBoundingClientRect());
      imgHint(`📍 (${p.x}, ${p.y}) — kéo để chọn vùng, click để ghi toạ độ vào log`);
    }
    return;
  }
  const r = imgDrag.r;
  const x1 = Math.max(0, Math.min(e.clientX - r.left, r.width));
  const y1 = Math.max(0, Math.min(e.clientY - r.top, r.height));
  const x = Math.min(imgDrag.x0, x1), y = Math.min(imgDrag.y0, y1);
  const w = Math.abs(x1 - imgDrag.x0), h = Math.abs(y1 - imgDrag.y0);
  if (w > 4 || h > 4) imgDrag.moved = true;
  Object.assign(imgSel.style, { left: x + "px", top: y + "px", width: w + "px", height: h + "px" });
  imgSel.hidden = false;
  imgSelRect = { x, y, w, h, dispW: r.width, dispH: r.height };
});
imgStage.addEventListener("pointerup", (e) => {
  if (!imgDrag) return;
  const wasClick = !imgDrag.moved;
  const r = imgDrag.r, dx = imgDrag.x0, dy = imgDrag.y0;
  imgDrag = null;
  if (!wasClick && imgSelRect && imgSelRect.w > 4 && imgSelRect.h > 4) {
    imgSaveBtn.disabled = false; imgHint("Đặt tên rồi bấm Lưu vùng cắt");
    return;
  }
  imgClearSel();
  if (wasClick) {   // click không kéo → in toạ độ điểm màn vào log chạy
    const p = imgPointCoords(r.left + dx, r.top + dy, r);
    scriptOut.textContent += (scriptOut.textContent ? "\n" : "") + `📍 toạ độ điểm: (${p.x}, ${p.y}) — tap(${p.x}, ${p.y})`;
    scriptOut.scrollTop = scriptOut.scrollHeight;
    imgHint(`📍 (${p.x}, ${p.y}) — đã ghi vào log`);
  }
});

// Cắt theo vùng chọn (quy đổi về toạ độ ảnh GỐC) → base64 → POST image_save
imgSaveBtn.onclick = async () => {
  if (!imgSelRect || !imgShot.naturalWidth) return;
  const sX = imgShot.naturalWidth / imgSelRect.dispW, sY = imgShot.naturalHeight / imgSelRect.dispH;
  const sx = Math.round(imgSelRect.x * sX), sy = Math.round(imgSelRect.y * sY);
  const sw = Math.max(1, Math.round(imgSelRect.w * sX)), sh = Math.max(1, Math.round(imgSelRect.h * sY));
  const cv = document.createElement("canvas"); cv.width = sw; cv.height = sh;
  cv.getContext("2d").drawImage(imgShot, sx, sy, sw, sh, 0, 0, sw, sh);
  let name = (imgNameInp.value || "").trim();
  if (!name) name = "crop_" + Date.now() + ".jpg";
  if (!/\.(jpg|jpeg|png)$/i.test(name)) name += ".jpg";
  name = name.replace(/[^A-Za-z0-9._-]/g, "_");
  const isPng = /\.png$/i.test(name);
  const data = cv.toDataURL(isPng ? "image/png" : "image/jpeg", 0.92).split(",")[1];
  imgSaveBtn.disabled = true; imgHint("💾 đang lưu…");
  try {
    const r = await api("image_save", { name, data });
    if (r.ok) { imgHint("✅ đã lưu " + name); imgNameInp.value = ""; imgClearSel(); loadImages(); }
    else { imgHint("❌ " + (r.msg || "lưu lỗi")); imgSaveBtn.disabled = false; }
  } catch (e) { imgHint("❌ lỗi kết nối"); imgSaveBtn.disabled = false; }
};

// ⬆ Nhập ảnh từ máy tính → lưu THẲNG vào thư mục images (không cần chụp/cắt).
const imgImportFile = $("#imgImportFile");
$("#imgImport").onclick = () => imgImportFile.click();
imgImportFile.onchange = async () => {
  const files = Array.from(imgImportFile.files || []);
  imgImportFile.value = "";   // reset để chọn lại cùng file vẫn kích hoạt
  if (!files.length) return;
  let ok = 0, failed = 0;
  const errs = [];
  imgHint("💾 đang nhập ảnh…");
  for (const f of files) {
    const name = importSanitizeName(f.name);
    if (!/\.(png|jpe?g|gif|bmp|webp)$/i.test(name)) { failed++; errs.push(name + " (không phải ảnh)"); continue; }
    if (f.size > 4 * 1024 * 1024) { failed++; errs.push(name + " (> 4MB)"); continue; }
    try {
      const data = String(await importReadDataURL(f)).split(",")[1] || "";
      const r = await api("image_save", { name, data });
      if (r.ok) ok++; else { failed++; errs.push(name + ": " + (r.msg || "lỗi")); }
    } catch (e) { failed++; errs.push(name + " (đọc lỗi)"); }
  }
  loadImages();
  imgHint(`✅ nhập ${ok} ảnh` + (failed ? `, ${failed} lỗi` : ""));
  if (failed && errs.length) alert(`Nhập ảnh: ${ok} OK, ${failed} lỗi\n\n` + errs.slice(0, 12).join("\n"));
};

// Gallery ảnh đã lưu
async function loadImages() {
  let r; try { r = await api("images"); } catch (e) { return; }
  const list = (r.images || []).sort((a, b) => (b.mtime || 0) - (a.mtime || 0));
  $("#imgCount").textContent = list.length ? `(${list.length})` : "";
  imgListEl.innerHTML = "";
  if (!list.length) { const d = document.createElement("div"); d.className = "muted"; d.textContent = "Chưa có ảnh."; imgListEl.appendChild(d); return; }
  for (const it of list) {
    const box = document.createElement("div"); box.className = "imgtool-thumb";
    const im = document.createElement("img"); im.alt = it.name; im.loading = "lazy";
    const cap = document.createElement("div"); cap.className = "cap";
    const nm = document.createElement("span"); nm.textContent = it.name; nm.title = it.name;
    nm.style.cssText = "overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1;";
    const cpy = document.createElement("span"); cpy.className = "cpy"; cpy.textContent = "📋"; cpy.title = "Copy tên ảnh (dùng cho tapImage)";
    cpy.onclick = async (e) => {
      e.stopPropagation();
      const ok = await copyTextCompat(it.name);
      cpy.textContent = ok ? "✓" : "✗";
      if (!ok) imgHint("copy lỗi — chọn tên rồi Ctrl+C: " + it.name);
      setTimeout(() => (cpy.textContent = "📋"), 900);
    };
    const del = document.createElement("span"); del.className = "del"; del.textContent = "🗑"; del.title = "Xoá";
    del.onclick = async (e) => { e.stopPropagation(); if (!confirm("Xoá " + it.name + "?")) return; const d = await api("image_delete", { name: it.name }); if (d.ok) loadImages(); };
    cap.appendChild(nm); cap.appendChild(cpy); cap.appendChild(del);
    box.appendChild(im); box.appendChild(cap); imgListEl.appendChild(box);
    api("image_read", { name: it.name }).then((rd) => {
      if (rd && rd.ok) im.src = "data:image/" + (/\.png$/i.test(it.name) ? "png" : "jpeg") + ";base64," + rd.data;
    }).catch(() => {});
  }
}

function openImgTool() { imgTool.hidden = false; captureShot(); loadImages(); }
function closeImgTool() { imgTool.hidden = true; }
$("#miShot").onclick = () => { helperMenu.hidden = true; openImgTool(); };
$("#imgClose").onclick = closeImgTool;
$("#imgRecap").onclick = captureShot;
imgTool.addEventListener("click", (e) => { if (e.target === imgTool) closeImgTool(); });
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !imgTool.hidden) closeImgTool(); });

// ================== CỔNG LICENSE: chặn cứng khi thiết bị chưa kích hoạt ==================
const licGate = $("#licenseGate");
function showGate(j) {
  $("#licMachine").textContent = (j && j.machineId) || "—";
  $("#licServer").textContent = (j && j.server) || "—";
  licGate.hidden = false;
  try { stopStream(); } catch (e) {}   // đảm bảo không còn xem màn
  // USB Local: hỏi /api/status (route status KHÔNG bị cổng chặn) để hiện cổng USB.
  api("status").then((s) => {
    if (s && s.usbPort) {
      $("#licUsb").textContent = "localhost:" + s.usbPort;
      $("#licUsbFoot").hidden = false;
    }
  }).catch(() => {});
}
function hideGate() { licGate.hidden = true; }
async function licActivate() {
  const key = ($("#licKey").value || "").trim();
  const msg = $("#licMsg");
  if (key.length < 4) { msg.className = "lic-msg bad"; msg.textContent = "Nhập license key trước"; return; }
  msg.className = "lic-msg"; msg.textContent = "Đang kích hoạt…";
  try {
    const r = await api("license/activate", { key });
    if (r.ok) {
      msg.className = "lic-msg ok";
      msg.textContent = (r.msg || "Đã kích hoạt") + " — đang tải lại…";
      setTimeout(() => location.reload(), 1200);
    } else { msg.className = "lic-msg bad"; msg.textContent = r.msg || "Kích hoạt thất bại"; }
  } catch (e) { msg.className = "lic-msg bad"; msg.textContent = "Lỗi kết nối daemon"; }
}
$("#licActivate").onclick = licActivate;
$("#licCopy").onclick = () => { const m = $("#licMachine").textContent; if (m && m !== "—") copyTextCompat(m); };
$("#licKey").addEventListener("keydown", (e) => { if (e.key === "Enter") licActivate(); });

async function checkLicense() {
  try {
    const j = await api("license");          // route này KHÔNG bị cổng chặn
    if (j && j.activated) { hideGate(); return true; }
    showGate(j || {});
    return false;
  } catch (e) { showGate({}); return false; }
}

// Chỉ khởi động stream/điều khiển/loader khi ĐÃ kích hoạt.
async function boot() {
  const ok = await checkLicense();
  if (!ok) return;
  ctrlConnect();
  syncStream();
  refreshStatus();
  loadApps();
  loadScriptList();
  refreshShot();
  // Nếu thiết bị đang chạy sẵn 1 script (mở lại tab / máy khác / vừa kéo-reload) → nối lại + hiện ⏹ Dừng.
  await syncRunState();
  setInterval(refreshStatus, 5000);
  setInterval(syncRunState, 5000);   // luôn giữ nút Chạy/Dừng khớp trạng thái thật, kể cả khi start từ nơi khác
  // Kiểm tra lại license định kỳ — bị thu hồi/hết hạn → hiện lại cổng chặn.
  setInterval(async () => { const a = await checkLicense(); if (!a) location.reload(); }, 60000);
}
boot();
