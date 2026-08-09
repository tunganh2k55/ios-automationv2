// lib/wifi.js — Quét mạng LAN tìm iPhone chạy daemon iOSAuto qua WiFi (cổng 8080).
// Tối ưu tốc độ bằng 2 pha:
//   Pha 1 — probe TCP thô (net.connect) tới cổng 8080 trên TOÀN BỘ .1–.254 cùng lúc (rất nhẹ,
//           cổng đóng bị RST tức thì, chỉ IP vắng mới chờ hết timeout ngắn). Lọc ra IP mở cổng.
//   Pha 2 — chỉ gọi HTTP GET /api/status trên vài IP mở cổng để lấy thông tin thiết bị.
// Nhờ vậy quét 1 subnet ~ một cửa sổ timeout (vài trăm ms) thay vì nhiều đợt HTTP.
"use strict";
const os = require("os");
const net = require("net");
const daemon = require("./daemon");

const WIFI_PORT = 8080;

// Các subnet /24 suy ra từ IPv4 nội bộ của máy (bỏ loopback & APIPA 169.254).
function localSubnets() {
  const nets = os.networkInterfaces();
  const subs = new Set();
  for (const name of Object.keys(nets)) {
    for (const ni of nets[name] || []) {
      if (ni.family !== "IPv4" || ni.internal) continue;
      if (ni.address.startsWith("169.254.")) continue;
      const p = ni.address.split(".");
      subs.add(`${p[0]}.${p[1]}.${p[2]}`);
    }
  }
  return [...subs];
}

// Probe TCP thô 1 host:port. Trả true nếu bắt tay được (cổng mở), false nếu đóng/hết giờ.
function tcpOpen(host, port, timeout) {
  return new Promise((resolve) => {
    const sock = new net.Socket();
    let done = false;
    const fin = (ok) => { if (done) return; done = true; try { sock.destroy(); } catch (_) {} resolve(ok); };
    sock.setTimeout(timeout);
    sock.once("connect", () => fin(true));
    sock.once("timeout", () => fin(false));
    sock.once("error", () => fin(false));
    sock.connect(port, host);
  });
}

// Chạy 1 pool promise với giới hạn đồng thời.
async function pool(items, limit, worker, onProgress) {
  const results = [];
  let idx = 0, done = 0;
  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (idx < items.length) {
      const i = idx++;
      const r = await worker(items[i]);
      done++;
      if (onProgress) onProgress(done, items.length);
      if (r) results.push(r);
    }
  });
  await Promise.all(runners);
  return results;
}

// Quét toàn bộ subnet. onProgress(done,total,found) tuỳ chọn (theo tiến trình pha 1).
async function scan({ port = WIFI_PORT, timeout = 350, concurrency = 512, onProgress } = {}) {
  const subs = localSubnets();
  const hosts = [];
  for (const s of subs) for (let i = 1; i <= 254; i++) hosts.push(`${s}.${i}`);

  // Pha 1: lọc nhanh IP mở cổng 8080 (probe TCP song song rộng).
  const found = [];
  const openHosts = await pool(
    hosts,
    concurrency,
    async (ip) => ((await tcpOpen(ip, port, timeout)) ? ip : null),
    (done, total) => onProgress && onProgress(done, total, found.length)
  );

  // Pha 2: xác nhận là daemon + lấy thông tin (chỉ vài IP → cho timeout rộng hơn chút).
  await pool(openHosts, 32, async (ip) => {
    const st = await daemon.status(ip, port, 2500);
    if (st && st.ok && st.device) {
      const dev = toDevice(ip, port, st);
      found.push(dev);
      onProgress && onProgress(hosts.length, hosts.length, found.length);
      return dev;
    }
    return null;
  });

  return found;
}

function toDevice(ip, port, st) {
  return {
    id: "wifi:" + (st.device.serial || ip),
    mode: "wifi",
    host: ip,
    port,
    name: st.device.name || "iPhone",
    model: st.device.model || "",
    ios: st.device.ios || "",
    serial: st.device.serial || "",
    ip: st.ip || ip,
    usbPort: st.usbPort || 0,
    screen: st.screen || null,
  };
}

module.exports = { scan, localSubnets, WIFI_PORT, toDevice };
