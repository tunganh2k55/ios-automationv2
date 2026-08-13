// main.js — Electron main process cho PokémonTool.
// Giữ toàn bộ logic mạng (quét WiFi/USB, gọi daemon, kiểm license) ở main; renderer chỉ vẽ UI
// và gọi qua IPC (preload contextBridge). USB forward process bị kill khi thoát app.
"use strict";
const { app, BrowserWindow, ipcMain, shell, clipboard } = require("electron");
const path = require("path");
const fs = require("fs");

const daemon = require("./lib/daemon");
const wifi = require("./lib/wifi");
const usb = require("./lib/usb");
const license = require("./lib/license");
const updater = require("./lib/updater");

let mainWin = null;
const viewWins = new Map();   // key host:port -> BrowserWindow

function configPath() {
  return path.join(app.getPath("userData"), "config.txt");
}

function settingsPath() {
  return path.join(app.getPath("userData"), "settings.json");
}
function readSettings() {
  try { return JSON.parse(fs.readFileSync(settingsPath(), "utf8")) || {}; }
  catch (_) { return {}; }
}

function createWindow() {
  mainWin = new BrowserWindow({
    width: 1300,
    height: 820,
    minWidth: 1040,
    minHeight: 640,
    frame: false,                 // titlebar tuỳ biến (nút min/max/close vẽ trong renderer)
    backgroundColor: "#0a0e1a",
    title: "PokémonTool",
    icon: path.join(__dirname, "build", "icon.ico"),
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  mainWin.setMenuBarVisibility(false);
  mainWin.loadFile(path.join(__dirname, "renderer", "index.html"));
  // mainWin.webContents.openDevTools({ mode: "detach" });
}

// Phiên bản app (đọc từ package.json qua Electron) — renderer hiển thị động, không hard-code.
ipcMain.handle("app:version", () => app.getVersion());

// ---- Auto-update (bản portable) ----
// Kiểm tra bản mới trên /tool/pokemontool/latest.json.
ipcMain.handle("update:check", async () => {
  try { return await updater.checkForUpdate(app.getVersion()); }
  catch (e) { return { available: false, error: String((e && e.message) || e) }; }
});
// Tải bản mới về temp (verify sha256), báo tiến trình qua 'update:progress'.
ipcMain.handle("update:download", async (evt, info) => {
  try {
    const r = await updater.downloadUpdate(info, app.getPath("temp"),
      (got, total) => { try { evt.sender.send("update:progress", { got, total }); } catch (_) {} });
    return { ok: true, path: r.path };
  } catch (e) { return { ok: false, msg: String((e && e.message) || e) }; }
});
// Áp bản mới + khởi động lại (chỉ bản portable mới có PORTABLE_EXECUTABLE_FILE).
ipcMain.handle("update:apply", async (evt, { path: newExe }) => {
  const target = process.env.PORTABLE_EXECUTABLE_FILE;
  if (!target) return { ok: false, msg: "Chỉ tự cập nhật được ở bản portable. Tải bản mới thủ công." };
  try {
    updater.applyUpdate(newExe, target, process.pid);
    setTimeout(() => app.quit(), 300);
    return { ok: true };
  } catch (e) { return { ok: false, msg: String((e && e.message) || e) }; }
});

// ---- Điều khiển cửa sổ (frameless) ----
ipcMain.handle("win:minimize", () => { mainWin && mainWin.minimize(); });
ipcMain.handle("win:maximize", () => {
  if (!mainWin) return false;
  if (mainWin.isMaximized()) { mainWin.unmaximize(); return false; }
  mainWin.maximize(); return true;
});
ipcMain.handle("win:close", () => { mainWin && mainWin.close(); });
ipcMain.handle("win:isMaximized", () => !!(mainWin && mainWin.isMaximized()));

// ---------------- IPC ----------------

// Quét thiết bị theo mode ("wifi" | "usb"). Gửi tiến trình về renderer qua 'scan:progress'.
ipcMain.handle("devices:scan", async (evt, { mode }) => {
  const send = (payload) => { try { evt.sender.send("scan:progress", payload); } catch (_) {} };
  try {
    if (mode === "usb") {
      const devices = await usb.scan({
        onProgress: (msg) => send({ mode, msg }),
      });
      return { ok: true, devices };
    }
    // wifi
    const devices = await wifi.scan({
      onProgress: (done, total, found) =>
        send({ mode, done, total, found, msg: `Quét WiFi ${done}/${total} — thấy ${found}` }),
    });
    return { ok: true, devices };
  } catch (e) {
    if (e && e.code === "NO_TOOL") {
      return { ok: false, error: "NO_TOOL", msg: "Chưa thấy usbmuxd (Apple Mobile Device Support). Cài 3uTools hoặc iTunes / Apple Devices, rồi cắm cáp iPhone." };
    }
    return { ok: false, error: "SCAN_FAIL", msg: String((e && e.message) || e) };
  }
});

ipcMain.handle("usb:tooling", async () => usb.tooling());

// Kiểm active pokemontool theo serial.
ipcMain.handle("license:check", async (evt, { serial }) => license.checkDevice(serial));

// Trạng thái license iOSAuto (app) của máy — hỏi thẳng daemon /api/license.
ipcMain.handle("device:appLicense", async (evt, { host, port }) => {
  const r = await daemon.apiRequest(host, port, "license", { timeout: 4000 });
  const j = (r && r.json) || {};
  const app = j.app || {};
  return {
    ok: !!(r && r.ok),
    activated: !!j.activated,
    reason: j.reason || "",
    tierName: j.tierName || "",
    plan: app.plan || j.plan || "",
    expiresAt: app.expiresAt || null,
  };
});

// Poll log chạy nền của 1 thiết bị.
ipcMain.handle("device:log", async (evt, { host, port, offset }) =>
  daemon.runLog(host, port, offset || 0)
);

// Dừng script đang chạy trên thiết bị.
ipcMain.handle("device:stop", async (evt, { host, port }) => daemon.runStop(host, port));

// Lấy lại status 1 thiết bị (làm mới trạng thái kết nối).
ipcMain.handle("device:status", async (evt, { host, port }) => daemon.status(host, port));

// Mở trang view (web UI daemon) trong cửa sổ Electron riêng.
ipcMain.handle("device:openView", async (evt, { host, port, name }) => {
  const key = `${host}:${port}`;
  const url = `http://${host}:${port}/`;
  const existing = viewWins.get(key);
  if (existing && !existing.isDestroyed()) { existing.focus(); return { ok: true }; }
  const w = new BrowserWindow({
    width: 480,
    height: 900,
    title: `${name || "iPhone"} — ${host}:${port}`,
    icon: path.join(__dirname, "build", "icon.ico"),
    backgroundColor: "#111",
    webPreferences: { contextIsolation: true, nodeIntegration: false },
  });
  w.setMenuBarVisibility(false);
  w.loadURL(url);
  w.on("closed", () => viewWins.delete(key));
  viewWins.set(key, w);
  return { ok: true };
});

// Mở URL bằng trình duyệt hệ thống (nếu người dùng thích).
ipcMain.handle("shell:open", async (evt, { url }) => { shell.openExternal(url); return { ok: true }; });

// Chép văn bản vào clipboard hệ thống.
ipcMain.handle("clipboard:write", async (evt, { text }) => { clipboard.writeText(String(text || "")); return { ok: true }; });

// ---- Cài đặt app (settings.json ở userData) — nhớ mode WiFi/USB đã chọn ----
ipcMain.handle("settings:get", async () => readSettings());
ipcMain.handle("settings:set", async (evt, patch) => {
  const s = { ...readSettings(), ...(patch || {}) };
  try { fs.writeFileSync(settingsPath(), JSON.stringify(s, null, 2), "utf8"); } catch (_) {}
  return s;
});

// ---- Cấu hình (config.txt lưu ở userData; đẩy xuống thiết bị qua script_save) ----
ipcMain.handle("config:load", async () => {
  try { return { ok: true, text: fs.readFileSync(configPath(), "utf8") }; }
  catch (_) { return { ok: true, text: "apikey=\nlicensekey=\n" }; }
});

ipcMain.handle("config:save", async (evt, { text }) => {
  try { fs.writeFileSync(configPath(), text, "utf8"); return { ok: true, path: configPath() }; }
  catch (e) { return { ok: false, msg: String(e.message || e) }; }
});

// Đẩy config.txt xuống danh sách thiết bị. Trả kết quả từng máy.
ipcMain.handle("config:push", async (evt, { text, devices }) => {
  const results = [];
  for (const d of devices || []) {
    const r = await daemon.scriptSave(d.host, d.port, "config.txt", text);
    results.push({ id: d.id, name: d.name, ok: !!(r.json && r.json.ok), msg: (r.json && r.json.msg) || r.error || "" });
  }
  return { ok: true, results };
});

// ---- Script chạy được (mở rộng dần) ----
// Thêm script mới: bỏ file .lua vào ./scripts và khai báo 1 dòng ở đây.
// Script nhúng ở dạng ĐÃ MÃ HOÁ (.luax) để KHÔNG lộ mã nguồn trong .exe. Daemon /api/script tự
// nhận diện blob .luax → giải mã + verify trong RAM rồi chạy (khoá nhúng trong daemon).
// Sửa script: chỉnh Demo/pokemon/reg-poke.lua → chạy build/encrypt_script.py để sinh lại .luax.
const SCRIPTS = [
  // file: tên file trong ./scripts (blob .luax) · remoteFile: tên lưu trên máy · configFile: file config
  { id: "regpoke", name: "RegPoke", file: "reg-poke.luax", remoteFile: "reg-poke.luax", configFile: "config_reg_poke.txt", desc: "Đăng ký tài khoản Pokémon tự động" },
  { id: "chyusen_honin", name: "Chyusen 本人 (1,3,5)", file: "chyusen_honin.luax", remoteFile: "chyusen_honin.luax", configFile: "config_reg_poke.txt", desc: "本人認証済み枠 - items 1,3,5" },
  { id: "chyu_246", name: "Chyusen (2,4,6)", file: "chyu_246.luax", remoteFile: "chyu_246.luax", configFile: "config_reg_poke.txt", desc: "Chyusen poll song song - items 2,4,6" },
];
function scriptsDir() { return path.join(__dirname, "scripts"); }
function findScript(id) { return SCRIPTS.find((s) => s.id === id) || null; }

// Toàn bộ config đã lưu (config.txt ở userData: apikey, use4g, …) để đẩy xuống máy trước khi chạy.
function readSavedConfigText() {
  try { return fs.readFileSync(configPath(), "utf8"); } catch (_) { return ""; }
}
function configHasApiKey(txt) { return /(^|\n)\s*apikey\s*[:=]\s*\S/i.test(txt || ""); }

ipcMain.handle("scripts:list", async () => SCRIPTS.map((s) => ({ id: s.id, name: s.name, desc: s.desc })));

// Tải (upload) file script + config lên thư mục scripts của máy qua /api/script_save.
ipcMain.handle("scripts:upload", async (evt, { host, port, scriptId }) => {
  const s = findScript(scriptId);
  if (!s) return { ok: false, msg: "Script không tồn tại" };
  let code;
  try { code = fs.readFileSync(path.join(scriptsDir(), s.file), "utf8"); }
  catch (e) { return { ok: false, msg: "Không đọc được file script: " + s.file }; }
  const remote = s.remoteFile || s.file;
  const rs = await daemon.scriptSave(host, port, remote, code);
  if (!(rs.json && rs.json.ok)) return { ok: false, msg: (rs.json && rs.json.msg) || rs.error || "lỗi lưu script", name: s.name };
  // Kèm đẩy config (nếu có apikey đã lưu) để chạy được ngay.
  const cfgText = readSavedConfigText();
  let cfgOk = false;
  if (cfgText.trim()) { const rc = await daemon.scriptSave(host, port, s.configFile || "config.txt", cfgText); cfgOk = !!(rc.json && rc.json.ok); }
  return { ok: true, name: s.name, remoteFile: remote, configFile: s.configFile || "config.txt", pushedConfig: cfgOk };
});

// Trạng thái "đang chạy script" của NHIỀU máy trong 1 lần gọi (song song, timeout ngắn → không lag).
// Hỏi /api/run/log với offset rất lớn: không kéo log, chỉ lấy cờ running của daemon đó.
ipcMain.handle("devices:running", async (evt, { list }) => {
  const out = {};
  await Promise.all((list || []).map(async (d) => {
    try { const r = await daemon.runLog(d.host, d.port, 2000000000, 1400); out[d.id] = !!(r && r.running); }
    catch (_) { out[d.id] = false; }
  }));
  return out;
});

// Chạy 1 script (theo id) trên thiết bị: tự đẩy config.txt (apikey) rồi chạy nội dung .lua.
ipcMain.handle("scripts:run", async (evt, { host, port, scriptId }) => {
  const s = findScript(scriptId);
  if (!s) return { ok: false, msg: "Script không tồn tại" };
  let code;
  try { code = fs.readFileSync(path.join(scriptsDir(), s.file), "utf8"); }
  catch (e) { return { ok: false, msg: "Không đọc được file script: " + s.file }; }
  const cfgText = readSavedConfigText();
  const hasKey = configHasApiKey(cfgText);
  const cfgName = s.configFile || "config.txt";
  if (cfgText.trim()) await daemon.scriptSave(host, port, cfgName, cfgText);   // apikey + use4g
  const r = await daemon.runScript(host, port, code);
  const ok = !!(r.json && r.json.ok);
  return { ok, runid: r.json && r.json.runid, msg: (r.json && r.json.msg) || r.error || "", pushedConfig: hasKey, name: s.name };
});

app.whenReady().then(createWindow);

app.on("window-all-closed", () => {
  usb.stopAll();
  if (process.platform !== "darwin") app.quit();
});

app.on("before-quit", () => usb.stopAll());

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});
