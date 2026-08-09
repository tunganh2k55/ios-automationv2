// lib/updater.js — Auto-update cho BẢN PORTABLE (không phụ thuộc electron, main truyền path vào).
// Luồng: đọc manifest /tool/pokemontool/latest.json → so version → tải exe mới → verify sha256 →
// ghi helper .cmd đợi tiến trình thoát rồi ghi đè file portable & khởi động lại.
// Portable KHÔNG tự ghi đè khi đang chạy (Windows khoá exe) → phải nhờ helper chạy sau khi thoát.
"use strict";
const https = require("https");
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { spawn } = require("child_process");

const MANIFEST_URL = process.env.POKE_UPDATE_URL ||
  "https://iosautos.com/tool/pokemontool/latest.json";

const pick = (url) => (url.startsWith("http:") ? http : https);

// GET JSON (theo redirect).
function getJson(url, timeout = 8000, depth = 0) {
  return new Promise((resolve, reject) => {
    if (depth > 5) return reject(new Error("quá nhiều redirect"));
    const req = pick(url).get(url, { timeout }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        return resolve(getJson(new URL(res.headers.location, url).toString(), timeout, depth + 1));
      }
      if (res.statusCode !== 200) { res.resume(); return reject(new Error("HTTP " + res.statusCode)); }
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => { try { resolve(JSON.parse(Buffer.concat(chunks).toString("utf8"))); } catch (e) { reject(e); } });
    });
    req.on("timeout", () => { req.destroy(); reject(new Error("timeout")); });
    req.on("error", reject);
  });
}

// So sánh semver đơn giản (x.y.z[-pre]). >0 nếu a mới hơn b.
function cmpSemver(a, b) {
  const pa = String(a).split(/[.\-+]/).map((n) => parseInt(n, 10) || 0);
  const pb = String(b).split(/[.\-+]/).map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d) return d > 0 ? 1 : -1;
  }
  return 0;
}

// Kiểm tra có bản mới không. Trả {available, current, version, notes, mandatory, url, sha256, size}.
async function checkForUpdate(currentVersion) {
  const m = await getJson(MANIFEST_URL);
  const p = (m && m.portable) || {};
  return {
    available: !!p.url && cmpSemver(m.version, currentVersion) > 0,
    current: currentVersion,
    version: m.version,
    notes: m.notes || "",
    mandatory: !!m.mandatory,
    url: p.url,
    sha256: (p.sha256 || "").toLowerCase(),
    size: p.size || 0,
  };
}

// Tải exe (theo redirect) → destPath, tính sha256, gọi onProgress(got,total). Verify sha256 nếu có.
function download(url, destPath, onProgress, expectSha, timeout = 120000, depth = 0) {
  return new Promise((resolve, reject) => {
    if (depth > 5) return reject(new Error("quá nhiều redirect"));
    const req = pick(url).get(url, { timeout }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        return resolve(download(new URL(res.headers.location, url).toString(), destPath, onProgress, expectSha, timeout, depth + 1));
      }
      if (res.statusCode !== 200) { res.resume(); return reject(new Error("HTTP " + res.statusCode)); }
      const total = parseInt(res.headers["content-length"] || "0", 10);
      let got = 0;
      const hash = crypto.createHash("sha256");
      const out = fs.createWriteStream(destPath);
      res.on("data", (c) => { got += c.length; hash.update(c); onProgress && onProgress(got, total); });
      res.on("error", reject);
      out.on("error", reject);
      res.pipe(out);
      out.on("finish", () => out.close(() => {
        const sha = hash.digest("hex");
        if (expectSha && sha !== expectSha) return reject(new Error("sha256 không khớp — file tải hỏng"));
        resolve({ path: destPath, sha256: sha, size: got });
      }));
    });
    req.on("timeout", () => { req.destroy(); reject(new Error("timeout")); });
    req.on("error", reject);
  });
}

// Gắn cache-buster theo sha256 vào URL tải: mỗi NỘI DUNG có cache-key CDN riêng → Cloudflare
// KHÔNG bao giờ serve nhầm bản cũ khi 1 URL bị publish ĐÈ bằng bytes khác (đúng sự cố 1.0.8:
// exe cũ 75MB bị kẹt cache HIT → sha256 client tính ra luôn lệch latest.json → chặn cập nhật).
// Query-string là 1 phần cache-key trên Cloudflare (đã kiểm chứng), nên ?cb=<sha> đủ để né stale.
function bustUrl(url, sha) {
  if (!sha) return url;
  return url + (url.includes("?") ? "&" : "?") + "cb=" + sha;
}

// Tải bản cập nhật vào thư mục temp. Trả {path}.
async function downloadUpdate(info, destDir, onProgress) {
  const dest = path.join(destDir, `PokemonTool-${info.version}-update.exe`);
  const r = await download(bustUrl(info.url, info.sha256), dest, onProgress, info.sha256);
  return { path: r.path, sha256: r.sha256 };
}

// Ghi helper .cmd: đợi PID thoát → ghi đè file portable → khởi động lại. Spawn tách rời rồi để
// main gọi app.quit(). target = file portable trên đĩa (process.env.PORTABLE_EXECUTABLE_FILE).
function applyUpdate(newExe, target, pid) {
  const helper = path.join(os.tmpdir(), "poke-update.cmd");
  const script = [
    "@echo off",
    "setlocal enableextensions",
    ":waitpid",
    `tasklist /fi "PID eq ${pid}" 2>nul | find "${pid}" >nul && ( timeout /t 1 /nobreak >nul & goto waitpid )`,
    "set /a n=0",
    ":copyloop",
    `copy /y "${newExe}" "${target}" >nul 2>&1`,
    "if not errorlevel 1 goto done",
    "set /a n+=1",
    "if %n% geq 20 goto done",
    "timeout /t 1 /nobreak >nul",
    "goto copyloop",
    ":done",
    `start "" "${target}"`,
    'del "%~f0"',
    "",
  ].join("\r\n");
  fs.writeFileSync(helper, script, "utf8");
  const child = spawn(process.env.ComSpec || "cmd.exe", ["/c", helper], {
    detached: true, stdio: "ignore", windowsHide: true,
  });
  child.unref();
}

module.exports = { checkForUpdate, downloadUpdate, applyUpdate, cmpSemver, MANIFEST_URL };
