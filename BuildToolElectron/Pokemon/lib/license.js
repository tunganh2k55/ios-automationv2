// lib/license.js — Hỏi server license "máy (serial) này còn quyền dùng pokemontool không?".
// POST https://iosautos.com/api/verify/device { tool:"pokemontool", machineId:<serial> }
// Trả { valid, reason, plan, expiresAt }. KHÔNG cần license key (đã bind serial phía server).
"use strict";
const https = require("https");

const BASE = "https://iosautos.com";
const SLUG = "pokemontool";

function postJson(url, obj, timeout = 6000) {
  return new Promise((resolve) => {
    const data = JSON.stringify(obj);
    const u = new URL(url);
    const req = https.request(
      {
        hostname: u.hostname,
        port: u.port || 443,
        path: u.pathname,
        method: "POST",
        headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(data) },
        timeout,
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8"))); }
          catch (_) { resolve(null); }
        });
      }
    );
    req.on("error", () => resolve(null));
    req.on("timeout", () => { req.destroy(); resolve(null); });
    req.write(data);
    req.end();
  });
}

// Chuẩn hoá serial giống server (normalizeMachineId): [A-Z0-9], hoa.
function normSerial(s) { return String(s || "").toUpperCase().replace(/[^A-Z0-9]/g, ""); }

const REASON_VI = {
  ok: "Đã kích hoạt",
  not_found: "Chưa cấp license",
  expired: "Hết hạn",
  revoked: "Đã thu hồi",
  bad_request: "Serial không hợp lệ",
  network: "Lỗi mạng",
};

// Trả { valid, reason, reasonVi, plan, expiresAt }.
async function checkDevice(serial) {
  const mid = normSerial(serial);
  if (mid.length < 4) return { valid: false, reason: "bad_request", reasonVi: REASON_VI.bad_request };
  const d = await postJson(BASE + "/api/verify/device", { tool: SLUG, machineId: mid });
  if (!d) return { valid: false, reason: "network", reasonVi: REASON_VI.network };
  return {
    valid: d.valid === true,
    reason: d.reason || "",
    reasonVi: REASON_VI[d.reason] || d.reason || "Không rõ",
    plan: d.plan || "",
    expiresAt: d.expiresAt || null,
  };
}

module.exports = { checkDevice, SLUG, BASE };
