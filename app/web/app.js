"use strict";

import RFB from './novnc/core/rfb.js';

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

// ---- VNC Stream (thay MJPEG) ----
// noVNC kết nối WebSocket tới /vnc → VNC server (port 5900) → framebuffer
const vncContainer = $("#vncContainer");
const noimg = $("#noimg");
let rfb = null;
let streamOn = false;

function startStream() {
  if (streamOn && rfb) return;
  streamOn = true;

  const wsUrl = (location.protocol === "https:" ? "wss://" : "ws://") + location.host + "/vnc";

  try {
    rfb = new RFB(vncContainer, wsUrl, {
      shared: true,
      credentials: { password: '' }
    });

    rfb.scaleViewport = true;
    rfb.resizeSession = false;
    rfb.clipViewport = false;
    rfb.viewOnly = false;  // cho phép điều khiển qua VNC

    rfb.addEventListener('connect', () => {
      vncContainer.style.display = "block";
      noimg.style.display = "none";
      console.log("VNC connected");
    });

    rfb.addEventListener('disconnect', (e) => {
      console.log("VNC disconnected:", e.detail.clean ? "clean" : "unclean");
      if (streamOn) {
        // Auto reconnect
        setTimeout(() => {
          if (streamOn) {
            rfb = null;
            startStream();
          }
        }, 1000);
      }
    });

    rfb.addEventListener('credentialsrequired', () => {
      const password = prompt('VNC Password:');
      if (password) {
        rfb.sendCredentials({ password });
      } else {
        rfb.disconnect();
      }
    });

  } catch (e) {
    console.error("VNC error:", e);
    noimg.style.display = "flex";
    setTimeout(() => { if (streamOn) startStream(); }, 1000);
  }
}

function stopStream() {
  streamOn = false;
  if (rfb) {
    try { rfb.disconnect(); } catch (e) {}
    rfb = null;
  }
  vncContainer.style.display = "none";
  noimg.style.display = "flex";
}

function refreshShot() {
  // VNC tự cập nhật liên tục, không cần refresh
}

// Nút View Màn / Tắt View
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
$("#btnRefresh").onclick = () => { viewWanted = true; stopStream(); setTimeout(startStream, 100); updateViewBtn(); };

// Nút Home
let homeTapTimer = null;
let homeWasLocked = false;
$("#phoneHome").onclick = async () => {
  if (homeTapTimer) {
    clearTimeout(homeTapTimer); homeTapTimer = null;
    if (!homeWasLocked) {
      try { await api("switcher"); } catch (e) {}
    }
    return;
  }
  let res = null;
  try { res = await api("wake"); } catch (e) {}
  homeWasLocked = !!(res && typeof res.msg === "string" && /wake\+unlock/i.test(res.msg));
  homeTapTimer = setTimeout(async () => {
    homeTapTimer = null;
    try { await api("home"); } catch (e) {}
  }, 350);
};
updateViewBtn();

// ---- Toạ độ trên VNC canvas → point ----
const screen = $("#screen");
const crosshair = $("#crosshair");
const swipeLine = $("#swipeLine");
const coords = $("#coords");

function toPoint(ev) {
  // Lấy canvas của noVNC
  const canvas = vncContainer.querySelector("canvas");
  const r = canvas ? canvas.getBoundingClientRect() : screen.getBoundingClientRect();
  const px = Math.max(0, Math.min(ev.clientX - r.left, r.width));
  const py = Math.max(0, Math.min(ev.clientY - r.top, r.height));
  return {
    x: Math.round((px / r.width) * LOGICAL.w),
    y: Math.round((py / r.height) * LOGICAL.h),
    ox: ev.clientX - screen.getBoundingClientRect().left,
    oy: ev.clientY - screen.getBoundingClientRect().top,
  };
}

// VNC đã tự xử lý pointer events qua RFB protocol
// Nhưng vẫn giữ coords hiển thị và fallback REST API cho keyboard
screen.addEventListener("pointermove", (ev) => {
  const p = toPoint(ev);
  coords.textContent = `x: ${p.x}, y: ${p.y}`;
});

// ================== Bàn phím từ web UI ==================
const kbCapture = $("#kbCapture");
const kbBtn = $("#btnKb");
let kbAuto = true;
let kbComposing = false;

function kbUpdateBtn() { kbBtn.classList.toggle("on", kbAuto); }
function kbFocus() { if (kbAuto) try { kbCapture.focus({ preventScroll: true }); } catch (e) {} }
kbBtn.onclick = () => { kbAuto = !kbAuto; kbUpdateBtn(); if (kbAuto) kbFocus(); else kbCapture.blur(); };
kbUpdateBtn();

async function kbType(text) { if (text) try { await api("type", { text }); } catch (e) {} }
async function kbKey(name) { try { await api("touchcmd", { cmd: "KEY " + name }); } catch (e) {} }

function kbFlush() { const v = kbCapture.value; if (v) { kbCapture.value = ""; kbType(v); } }
kbCapture.addEventListener("compositionstart", () => { kbComposing = true; });
kbCapture.addEventListener("compositionend", () => { kbComposing = false; kbFlush(); });
kbCapture.addEventListener("input", () => { if (!kbComposing) kbFlush(); });
kbCapture.addEventListener("keydown", (e) => {
  if (e.key === "Backspace") { e.preventDefault(); kbKey("BACK"); }
  else if (e.key === "Enter") { e.preventDefault(); kbKey("RETURN"); }
});
kbCapture.addEventListener("paste", (e) => {
  const t = (e.clipboardData || window.clipboardData) && (e.clipboardData || window.clipboardData).getData("text");
  if (t) { e.preventDefault(); kbCapture.value = ""; kbType(t); }
});

document.addEventListener("paste", (e) => {
  const t = e.target;
  if (t === kbCapture) return;
  if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
  const txt = (e.clipboardData || window.clipboardData) && (e.clipboardData || window.clipboardData).getData("text");
  if (txt) { e.preventDefault(); kbType(txt); }
});

// ---- Script Lua ----
const scriptBox = $("#scriptBox");
const scriptName = $("#scriptName");
const fileList = $("#fileList");
const saveState = $("#saveState");
const scriptOut = $("#scriptOut");
const logTitle = $("#logTitle");
let scriptDirty = false;
let gScripts = [];
let currentFile = "";
const btnEncrypt = $("#btnEncrypt");
const btnSaveEl = $("#btnSave");

function isEncName(n) { return /\.luax$/i.test((n || "").trim()); }

function applyEncMode(name) {
  const enc = isEncName(name);
  scriptBox.readOnly = enc;
  scriptBox.classList.toggle("locked", enc);
  if (window.iosautoEditor) window.iosautoEditor.updateOptions({ readOnly: enc });
  btnSaveEl.disabled = enc;
  btnEncrypt.disabled = enc;
}

function markDirty(d) {
  scriptDirty = d;
  saveState.textContent = d ? "● chưa lưu" : "";
  saveState.style.color = d ? "var(--warn)" : "";
}
scriptBox.addEventListener("input", () => markDirty(true));

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

// ================== Import file ==================
const importFile = $("#importFile");
const IMPORT_IMG_EXT = /\.(png|jpe?g|gif|bmp|webp)$/i;
const IMPORT_TXT_EXT = /\.(lua|luax|txt|json|csv|md|ini|conf)$/i;

$("#btnImport").onclick = () => importFile.click();

function importSanitizeName(name) {
  name = (name || "").split(/[\\/]/).pop().trim();
  return name.replace(/[^A-Za-z0-9._-]/g, "_");
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
  importFile.value = "";
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
  if (isEncName(currentFile)) { return; }
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

async function encryptScript() {
  if (isEncName(currentFile)) { alert("File này đã mã hoá rồi."); return; }
  const content = scriptBox.value;
  if (!content.trim()) { alert("Editor trống — không có gì để mã hoá."); return; }
  const base = normName(scriptName.value) || "script.lua";
  const outName = base.replace(/\.[A-Za-z0-9]+$/, "") + ".luax";
  if (!confirm(
    `Mã hoá nội dung hiện tại → lưu thành "${outName}"?\n\n` +
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
  currentFile = "";
  markDirty(false);
  await loadScriptList();
  await openFile(outName);
  saveState.textContent = "🔒 đã mã hoá → " + outName;
  saveState.style.color = "var(--ok)";
}
btnEncrypt.onclick = encryptScript;

async function downloadScript() {
  const name = normName(scriptName.value);
  if (!name) { alert("Chưa có file để tải (nhập tên hoặc mở 1 file)."); scriptName.focus(); return; }
  let content = scriptBox.value;
  if (currentFile && !scriptDirty) {
    try {
      const r = await api("script_read", { name: currentFile });
      if (r.ok) content = r.content || "";
    } catch (e) {}
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

scriptBox.addEventListener("keydown", (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s") { e.preventDefault(); saveScript(); }
});

// ---- Chạy script ----
let runId = null, runPoll = null, runOffset = 0;
const btnRun = $("#btnRun");
function setRunningUI(on) {
  if (on) { btnRun.textContent = "⏹ Dừng"; btnRun.classList.remove("run"); btnRun.classList.add("danger"); btnRun.title = "Dừng script"; }
  else { btnRun.textContent = "▶ Chạy"; btnRun.classList.remove("danger"); btnRun.classList.add("run"); btnRun.title = "Chạy script"; }
}
let runPolling = false;
async function pollRun() {
  if (runPolling) return;
  runPolling = true;
  let r;
  try { r = await api("run/log", { offset: runOffset }); }
  catch (e) { return; }
  finally { runPolling = false; }
  if (r.log) { scriptOut.textContent += r.log; scriptOut.scrollTop = scriptOut.scrollHeight; }
  if (typeof r.next === "number") runOffset = r.next;
  if (!r.running && runId !== null) {
    if (runPoll) { clearInterval(runPoll); runPoll = null; }
    runId = null; setRunningUI(false);
    scriptOut.textContent += "\n— xong —"; scriptOut.scrollTop = scriptOut.scrollHeight;
  }
}

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
  if (runId) { api("run/stop", {}).catch(() => {}); return; }
  startRun(scriptBox.value);
};

async function syncRunState() {
  let rs;
  try { rs = await api("run"); } catch (e) { return; }
  if (!rs) return;
  if (rs.busy && !runId) {
    runId = rs.runid; runOffset = 0;
    logTitle.textContent = "▶ Log chạy";
    scriptOut.textContent = "";
    setRunningUI(true);
    if (!runPoll) { runPoll = setInterval(pollRun, 500); pollRun(); }
  } else if (!rs.busy && runId) {
    if (runPoll) { clearInterval(runPoll); runPoll = null; }
    runId = null; setRunningUI(false);
  }
}

// ---- Cầu nối docs.js ----
window.iosauto = {
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
    document.title = `${devName} - iOSAuto`;
    if (s.screen) { LOGICAL.w = s.screen.w; LOGICAL.h = s.screen.h; }
  } catch (e) {
    $("#statusDot").className = "dot off";
    $("#deviceLine").textContent = "mất kết nối daemon";
  }
}

let gApps = [];
async function loadApps() {
  const r = await api("apps");
  gApps = (r.apps || [])
    .filter((a) => (a.type || "") === "User")
    .sort((a, b) => (a.name || "").localeCompare(b.name || ""));
}

// ---- Menu helper ----
const helperMenu = $("#helperMenu");
$("#btnHelper").onclick = (e) => { e.stopPropagation(); helperMenu.hidden = !helperMenu.hidden; };
helperMenu.addEventListener("click", (e) => e.stopPropagation());
document.addEventListener("click", () => { helperMenu.hidden = true; });
$("#miApps").onclick = () => { helperMenu.hidden = true; openApps(); };

// OCR
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

// Dump XML
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

// ---- Panel helper: app ----
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
  helperPanel.hidden = false;
  appsSearch.value = "";
  renderAppsList("");
  appsSearch.focus();
}
function closeApps() { helperPanel.hidden = true; }
$("#helperClose").onclick = closeApps;
appsSearch.addEventListener("input", () => renderAppsList(appsSearch.value));

// ---- Bố cục ----
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
    let h = rect.bottom - e.clientY - 6;
    const maxH = Math.max(90, rect.height - 210);
    h = Math.max(90, Math.min(h, maxH));
    logPane.style.flex = "none";
    logPane.style.height = h + "px";
  });
  const end = (e) => { if (dragging) { dragging = false; try { rez.releasePointerCapture(e.pointerId); } catch (_) {} } };
  rez.addEventListener("pointerup", end);
  rez.addEventListener("pointercancel", end);
})();
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !helperPanel.hidden) closeApps(); });

// ================== Helper: Chụp & cắt ảnh ==================
const imgTool = $("#imgTool");
const imgShot = $("#imgShot");
const imgStage = $("#imgStage");
const imgSel = $("#imgSel");
const imgSaveBtn = $("#imgSave");
const imgNameInp = $("#imgName");
const imgListEl = $("#imgList");
let imgSelRect = null;

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
  imgShot.src = "/api/screenshot?t=" + Date.now();
  imgClearSel();
}

function imgPointCoords(clientX, clientY, r) {
  const px = Math.max(0, Math.min(clientX - r.left, r.width));
  const py = Math.max(0, Math.min(clientY - r.top, r.height));
  return { x: Math.round((px / r.width) * LOGICAL.w), y: Math.round((py / r.height) * LOGICAL.h) };
}

let imgDrag = null;
imgStage.addEventListener("pointerdown", (e) => {
  if (e.target !== imgShot) return;
  const r = imgShot.getBoundingClientRect();
  imgDrag = { x0: e.clientX - r.left, y0: e.clientY - r.top, r, moved: false };
  try { imgStage.setPointerCapture(e.pointerId); } catch (_) {}
});
imgStage.addEventListener("pointermove", (e) => {
  if (!imgDrag) {
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
  if (wasClick) {
    const p = imgPointCoords(r.left + dx, r.top + dy, r);
    scriptOut.textContent += (scriptOut.textContent ? "\n" : "") + `📍 toạ độ điểm: (${p.x}, ${p.y}) — tap(${p.x}, ${p.y})`;
    scriptOut.scrollTop = scriptOut.scrollHeight;
    imgHint(`📍 (${p.x}, ${p.y}) — đã ghi vào log`);
  }
});

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

const imgImportFile = $("#imgImportFile");
$("#imgImport").onclick = () => imgImportFile.click();
imgImportFile.onchange = async () => {
  const files = Array.from(imgImportFile.files || []);
  imgImportFile.value = "";
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

// ================== LICENSE ==================
const licGate = $("#licenseGate");
function showGate(j) {
  $("#licMachine").textContent = (j && j.machineId) || "—";
  $("#licServer").textContent = (j && j.server) || "—";
  licGate.hidden = false;
  try { stopStream(); } catch (e) {}
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
    const j = await api("license");
    if (j && j.activated) { hideGate(); return true; }
    showGate(j || {});
    return false;
  } catch (e) { showGate({}); return false; }
}

// ---- Boot ----
async function boot() {
  const ok = await checkLicense();
  if (!ok) return;
  syncStream();
  refreshStatus();
  loadApps();
  loadScriptList();
  await syncRunState();
  setInterval(refreshStatus, 5000);
  setInterval(syncRunState, 5000);
  setInterval(async () => { const a = await checkLicense(); if (!a) location.reload(); }, 60000);
}
boot();
