// lib/daemon.js — HTTP client gọn tới daemon iOSAuto (/api/*) trên 1 base URL.
// Daemon trả JSON: /api/status, /api/script (chạy nền), /api/run/log, /api/run/stop,
// /api/script_save (ghi file, dùng để đẩy config.txt), ...
"use strict";
const http = require("http");

// GET/POST JSON tới http://host:port/api/<path>. Trả {ok, status, json, text}.
function apiRequest(host, port, path, { method = "GET", body = null, timeout = 4000 } = {}) {
  return new Promise((resolve) => {
    let data = null;
    const headers = {};
    if (body != null) {
      data = typeof body === "string" ? body : JSON.stringify(body);
      headers["Content-Type"] = "application/json";
      headers["Content-Length"] = Buffer.byteLength(data);
    }
    const req = http.request(
      { host, port, path: "/api/" + path.replace(/^\/+/, ""), method, headers, timeout },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let json = null;
          try { json = JSON.parse(text); } catch (_) {}
          resolve({ ok: res.statusCode >= 200 && res.statusCode < 300, status: res.statusCode, json, text });
        });
      }
    );
    req.on("error", (e) => resolve({ ok: false, status: 0, json: null, text: "", error: e.message }));
    req.on("timeout", () => { req.destroy(); resolve({ ok: false, status: 0, json: null, text: "", error: "timeout" }); });
    if (data != null) req.write(data);
    req.end();
  });
}

// Lấy /api/status — device{name,model,ios,serial}, ip, port, usbPort, screen{w,h}.
async function status(host, port, timeout = 4000) {
  const r = await apiRequest(host, port, "status", { timeout });
  return r.ok && r.json ? r.json : null;
}

// Chạy 1 đoạn code Lua ở nền → trả runid. reg-poke.lua nạp bằng dofile/loadstring của daemon;
// đơn giản nhất: chạy nội dung script trực tiếp.
async function runScript(host, port, code, timeout = 8000) {
  return apiRequest(host, port, "script", { method: "POST", body: { code }, timeout });
}

// Poll log tăng dần từ offset → {log, next, running}.
async function runLog(host, port, offset = 0, timeout = 4000) {
  const r = await apiRequest(host, port, "run/log", { method: "POST", body: { offset }, timeout });
  return r.json || { log: "", next: offset, running: false };
}

async function runStop(host, port, timeout = 4000) {
  return apiRequest(host, port, "run/stop", { method: "POST", body: {}, timeout });
}

// Đẩy 1 file (vd config.txt) xuống thư mục scripts của daemon.
async function scriptSave(host, port, name, content, timeout = 8000) {
  return apiRequest(host, port, "script_save", { method: "POST", body: { name, content }, timeout });
}

module.exports = { apiRequest, status, runScript, runLog, runStop, scriptSave };
