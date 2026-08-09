// lib/usb.js — Kết nối iPhone qua USB, KHÔNG cần Python/iproxy.
// Dùng usbmux THUẦN NODE (lib/usbmux.js) nói thẳng với usbmuxd của Apple (do iTunes / Apple
// Devices / 3uTools cài). Cơ chế: mỗi máy USB được cấp 1 cổng local trên PC, forward tới cổng
// 8081 (loopback) trên iPhone nơi daemon nghe. Sau forward, hỏi GET /api/status để lấy name/serial/ip.
"use strict";
const usbmux = require("./usbmux");
const daemon = require("./daemon");

const DEVICE_PORT = 8081;     // cổng daemon phía iPhone qua USB (loopback, cố định mọi máy)
const BASE_LOCAL = 8081;      // cổng local bắt đầu trên PC

// Công cụ USB sẵn có: giờ chỉ cần usbmuxd (Apple Mobile Device Support) — 3uTools/iTunes/Apple Devices.
async function tooling() {
  const usbmuxd = await usbmux.probe();
  return { usbmuxd };
}

// ---- Quản lý forwarder đang chạy (theo serial) ----
const forwards = new Map();   // serial -> { server, local }

function startForward(dev, localPort) {
  if (forwards.has(dev.serial)) return forwards.get(dev.serial).local;
  const server = usbmux.startForward(dev.deviceId, DEVICE_PORT, localPort);
  forwards.set(dev.serial, { server, local: localPort });
  return localPort;
}

function stopAll() {
  for (const { server } of forwards.values()) { try { server.close(); } catch (_) {} }
  forwards.clear();
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Quét USB: kiểm usbmuxd → liệt kê máy USB → forward + thăm dò TẤT CẢ máy SONG SONG → gom /api/status.
// Song song hoá: tổng thời gian ≈ máy chậm nhất, KHÔNG cộng dồn theo số máy.
async function scan({ base = BASE_LOCAL, onProgress } = {}) {
  if (!(await usbmux.probe())) {
    const err = new Error("no_usbmuxd");
    err.code = "NO_TOOL";
    throw err;
  }
  let devs;
  try { devs = await usbmux.listDevices(); }
  catch (e) { const err = new Error("list_fail"); err.code = "NO_TOOL"; throw err; }
  const usbDevs = devs.filter((d) => /usb/i.test(d.connectionType));
  if (!usbDevs.length) return [];
  const results = await Promise.all(
    usbDevs.map((d, i) => probeDevice(d, base + i, onProgress))
  );
  return results.filter(Boolean);
}

// Forward 1 máy rồi thăm dò daemon: thử NGAY, rồi lặp 120ms/lần tới ~6s (cổng chưa mở → fast-fail).
async function probeDevice(dev, localPort, onProgress) {
  onProgress && onProgress(`Đang mở cổng ${short(dev.serial)} → localhost:${localPort}…`);
  startForward(dev, localPort);
  const DEADLINE = 6000, STEP = 120;
  let st = null;
  for (let waited = 0; ; waited += STEP) {
    st = await daemon.status("127.0.0.1", localPort, 1000);
    if (st && st.ok && st.device) return toDevice(dev, localPort, st);
    if (waited >= DEADLINE) break;
    await sleep(STEP);
  }
  onProgress && onProgress(`⚠ Không đọc được daemon ở localhost:${localPort} (${short(dev.serial)})`);
  return null;
}

function toDevice(dev, local, st) {
  return {
    id: "usb:" + (st.device.serial || dev.serial),
    mode: "usb",
    host: "127.0.0.1",
    port: local,        // cổng local đã forward — gọi API/mở view đều qua đây
    udid: dev.serial,
    name: st.device.name || "iPhone",
    model: st.device.model || "",
    ios: st.device.ios || "",
    serial: st.device.serial || "",
    ip: st.ip || "",     // IP LAN thật của máy (nếu daemon biết)
    usbPort: st.usbPort || DEVICE_PORT,
    screen: st.screen || null,
  };
}

function short(u) { return u && u.length > 14 ? u.slice(0, 8) + "…" + u.slice(-4) : u; }

module.exports = { scan, tooling, stopAll, DEVICE_PORT, BASE_LOCAL };
