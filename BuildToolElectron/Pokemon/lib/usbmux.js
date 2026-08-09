// lib/usbmux.js — Client usbmux THUẦN NODE (không cần Python/iproxy).
// Nói thẳng với dịch vụ usbmuxd của Apple (Apple Mobile Device Support — do iTunes / Apple
// Devices / 3uTools cài). Trên Windows usbmuxd nghe TCP 127.0.0.1:27015; mac/linux dùng
// unix socket /var/run/usbmuxd.
//
// Giao thức: gói = header 16 byte + payload plist XML.
//   header (4×uint32 little-endian): length(cả header) | version=1 | type=8(PLIST) | tag
//   payload: plist có "MessageType" = ListDevices | Connect …
// ListDevices → {DeviceList:[{DeviceID, Properties:{SerialNumber, ConnectionType}}]}.
// Connect(DeviceID, PortNumber) → {Number:0} là thành công; SAU ĐÓ chính socket đó thành
// ống dữ liệu thô tới cổng <PortNumber> trên máy (giống iproxy). LƯU Ý: PortNumber phải ở
// network byte order (đảo byte) — gotcha kinh điển của usbmux.
"use strict";
const net = require("net");

const IS_WIN = process.platform === "win32";
const MUX_PORT = 27015;
const MUX_HOST = "127.0.0.1";
const MUX_UNIX = process.env.USBMUXD_SOCKET_ADDRESS || "/var/run/usbmuxd";

// Kết nối tới usbmuxd (tự chọn TCP/unix theo nền tảng).
function muxConnect(onConnect) {
  return IS_WIN ? net.connect(MUX_PORT, MUX_HOST, onConnect)
                : net.connect(MUX_UNIX, onConnect);
}

const swap16 = (p) => ((p & 0xff) << 8) | ((p >> 8) & 0xff);

// ---------- plist XML: build (chỉ cần string/integer) ----------
function xmlEsc(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
function buildPlist(dict) {
  let b = '<?xml version="1.0" encoding="UTF-8"?>\n' +
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n' +
    '<plist version="1.0">\n<dict>\n';
  for (const [k, v] of Object.entries(dict)) {
    b += `\t<key>${xmlEsc(k)}</key>`;
    b += typeof v === "number" ? `<integer>${v}</integer>\n` : `<string>${xmlEsc(v)}</string>\n`;
  }
  return b + "</dict>\n</plist>\n";
}

// ---------- plist XML: parse (đệ quy tối thiểu, đủ cho phản hồi usbmuxd) ----------
function decodeEnt(s) {
  return s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"')
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(+n)).replace(/&amp;/g, "&");
}
function parsePlist(xml) {
  let pos = xml.indexOf("<plist");
  if (pos < 0) throw new Error("plist: không có <plist>");
  pos = xml.indexOf(">", pos) + 1;
  const s = xml;
  const skipWs = () => { while (pos < s.length && /\s/.test(s[pos])) pos++; };
  const readTag = () => {                          // giả định s[pos]==='<'
    const end = s.indexOf(">", pos);
    let raw = s.slice(pos + 1, end);
    pos = end + 1;
    const selfClose = raw.endsWith("/");
    if (selfClose) raw = raw.slice(0, -1);
    return { name: raw.split(/\s/)[0], selfClose };
  };
  const readTextUntilClose = (tag) => {            // pos đang ngay sau <tag>
    const close = "</" + tag + ">";
    const end = s.indexOf(close, pos);
    const text = s.slice(pos, end);
    pos = end + close.length;
    return text;
  };
  function parseValue() {
    skipWs();
    if (s[pos] !== "<") throw new Error("plist: lỗi cú pháp tại " + pos);
    const { name, selfClose } = readTag();
    switch (name) {
      case "true": return true;
      case "false": return false;
      case "dict": {
        if (selfClose) return {};                  // <dict/> rỗng
        const o = {};
        for (;;) {
          skipWs();
          if (s.startsWith("</dict>", pos)) { pos += 7; break; }
          readTag();                               // <key>
          const key = readTextUntilClose("key");
          o[key] = parseValue();
        }
        return o;
      }
      case "array": {
        if (selfClose) return [];                  // <array/> rỗng (không có máy nào)
        const a = [];
        for (;;) {
          skipWs();
          if (s.startsWith("</array>", pos)) { pos += 8; break; }
          a.push(parseValue());
        }
        return a;
      }
      case "string": return selfClose ? "" : decodeEnt(readTextUntilClose("string"));
      case "integer": return parseInt(readTextUntilClose("integer").trim(), 10);
      case "real": return parseFloat(readTextUntilClose("real").trim());
      case "data": return readTextUntilClose("data").trim();     // base64 (giữ nguyên)
      case "date": return readTextUntilClose("date").trim();
      default: return selfClose ? null : readTextUntilClose(name);
    }
  }
  return parseValue();
}

// ---------- Đóng gói / đọc 1 gói usbmux ----------
const TYPE_PLIST = 8;
function packRequest(dict, tag) {
  const payload = Buffer.from(buildPlist(dict), "utf8");
  const hdr = Buffer.alloc(16);
  hdr.writeUInt32LE(16 + payload.length, 0);
  hdr.writeUInt32LE(1, 4);            // version = 1 (plist)
  hdr.writeUInt32LE(TYPE_PLIST, 8);  // message = 8 (payload là plist)
  hdr.writeUInt32LE(tag >>> 0, 12);
  return Buffer.concat([hdr, payload]);
}

// Đọc đúng 1 gói phản hồi từ socket usbmux. Gọi cb(err, plistObj, residual)
// residual = byte thừa sau gói (thường rỗng — dùng khi chuyển sang ống thô).
function readOnePacket(sock, cb) {
  let buf = Buffer.alloc(0), need = -1, done = false;
  const onData = (d) => {
    if (done) return;
    buf = Buffer.concat([buf, d]);
    if (need < 0 && buf.length >= 16) need = buf.readUInt32LE(0);
    if (need >= 0 && buf.length >= need) {
      done = true;
      sock.removeListener("data", onData);
      sock.removeListener("error", onErr);
      sock.removeListener("close", onClose);
      let obj;
      try { obj = parsePlist(buf.slice(16, need).toString("utf8")); }
      catch (e) { return cb(e); }
      cb(null, obj, buf.slice(need));
    }
  };
  const onErr = (e) => { if (!done) { done = true; cb(e); } };
  const onClose = () => { if (!done) { done = true; cb(new Error("usbmuxd đóng kết nối")); } };
  sock.on("data", onData);
  sock.on("error", onErr);
  sock.on("close", onClose);
}

let _tag = 0;
const COMMON = { ClientVersionString: "pokemontool", ProgName: "pokemontool", kLibUSBMuxVersion: 3 };

// Gửi 1 request đơn (ListDevices…) trên 1 socket mới → trả plist phản hồi.
function request(dict, timeout = 4000) {
  return new Promise((resolve, reject) => {
    const sock = muxConnect(() => sock.write(packRequest({ ...COMMON, ...dict }, ++_tag)));
    const timer = setTimeout(() => { sock.destroy(); reject(new Error("usbmuxd timeout")); }, timeout);
    sock.on("error", (e) => { clearTimeout(timer); reject(e); });
    readOnePacket(sock, (err, obj) => {
      clearTimeout(timer);
      sock.destroy();
      if (err) return reject(err);
      resolve(obj);
    });
  });
}

// usbmuxd có sẵn không? (thử kết nối nhanh)
function probe(timeout = 1200) {
  return new Promise((resolve) => {
    const sock = muxConnect(() => { sock.destroy(); resolve(true); });
    const timer = setTimeout(() => { sock.destroy(); resolve(false); }, timeout);
    sock.on("error", () => { clearTimeout(timer); resolve(false); });
    sock.on("close", () => clearTimeout(timer));
  });
}

// Liệt kê thiết bị đang cắm USB → [{deviceId, serial, connectionType}].
async function listDevices() {
  const r = await request({ MessageType: "ListDevices" });
  const list = (r && r.DeviceList) || [];
  return list.map((d) => {
    const p = d.Properties || {};
    return { deviceId: d.DeviceID, serial: p.SerialNumber || "", connectionType: p.ConnectionType || "" };
  }).filter((d) => d.serial);
}

// Tạo forwarder: mở TCP server ở 127.0.0.1:<localPort>. Mỗi kết nối vào → Connect qua usbmux
// tới cổng <devicePort> của deviceId rồi nối ống 2 chiều (thay iproxy). Trả net.Server.
function startForward(deviceId, devicePort, localPort) {
  const server = net.createServer((local) => {
    const mux = muxConnect(() => {
      mux.write(packRequest({ ...COMMON, MessageType: "Connect", DeviceID: deviceId, PortNumber: swap16(devicePort) }, ++_tag));
    });
    mux.on("error", () => local.destroy());
    local.on("error", () => mux.destroy());
    readOnePacket(mux, (err, obj, residual) => {
      if (err || !obj || obj.Number !== 0) { local.destroy(); mux.destroy(); return; }
      if (residual && residual.length) local.write(residual);   // byte thừa (hiếm) → đẩy sang local
      mux.pipe(local);
      local.pipe(mux);
    });
  });
  server.on("error", () => {});   // cổng bận… — scan sẽ xử lý ở tầng trên
  server.listen(localPort, "127.0.0.1");
  return server;
}

module.exports = {
  probe, listDevices, startForward,
  // export nội bộ để test
  _buildPlist: buildPlist, _parsePlist: parsePlist, _swap16: swap16,
};
