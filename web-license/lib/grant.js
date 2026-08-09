// Cấp "grant" bản quyền THIẾT BỊ có chữ ký Ed25519 (Nhóm 1).
//
// Ý tưởng: thay vì client tin cache boolean (dễ giả), server ký một "grant" TTL NGẮN (20').
// Daemon nhúng SẴN public key (compile-time) và CHỈ tin dữ liệu sau khi verify chữ ký.
//
// Chống replay: challenge-response. Client tự sinh `nonce` NGẪU NHIÊN gửi lên; server băm
// nonce (sha256) rồi đưa `nh` vào payload TRƯỚC KHI ký. Client verify chữ ký xong kiểm tra
// nh có đúng bằng sha256(nonce vừa gửi) → response cũ (nonce khác) không dùng lại được.
//
// Canonical payload: server tự dựng CHUỖI JSON theo THỨ TỰ FIELD CỐ ĐỊNH rồi ký ĐÚNG byte
// UTF-8 đó. Client verify chính byte nhận được, verify xong MỚI parse (không serialize lại)
// → tránh sai khác do JSON serialize hai bên.

const crypto = require('crypto');

const KEY_ID = process.env.GRANT_KEY_ID || 'license-2026-01';
const GRANT_TTL_SEC = (parseInt(process.env.GRANT_TTL_MINUTES, 10) || 20) * 60; // mặc định 20'
const ISS = 'iosautos';
const AUD = 'com.iosautos.daemon';
const PAYLOAD_VERSION = 1;

// Nạp private key Ed25519 từ seed 32-byte (base64) trong .env → KeyObject.
// Sinh seed 1 lần bằng: node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"
let _priv = null;
let _keyErr = null;
function privKey() {
  if (_priv || _keyErr) { if (_keyErr) throw _keyErr; return _priv; }
  try {
    const b64 = String(process.env.GRANT_ED25519_SEED || '').trim();
    if (!b64) throw new Error('Thiếu GRANT_ED25519_SEED trong .env');
    const seed = Buffer.from(b64, 'base64');
    if (seed.length !== 32) throw new Error('GRANT_ED25519_SEED phải là 32 byte (base64)');
    // Bọc seed thành PKCS8 DER chuẩn của Ed25519 (prefix cố định 16 byte) rồi import.
    const pkcs8 = Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]);
    _priv = crypto.createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' });
  } catch (e) { _keyErr = e; throw e; }
  return _priv;
}

// Có cấu hình khóa ký chưa? (để server báo lỗi rõ nếu quên set .env, không fail-silent).
function grantConfigured() {
  try { privKey(); return true; } catch { return false; }
}

// Public key thô (32 byte) — in ra để NHÚNG vào daemon (compile-time). Chỉ dùng lúc setup.
function publicKeyRaw() {
  const pub = crypto.createPublicKey(privKey());
  return pub.export({ type: 'spki', format: 'der' }).slice(-32);
}

const sha256b64 = (str) => crypto.createHash('sha256').update(String(str), 'utf8').digest('base64');

// Dựng chuỗi payload canonical — THỨ TỰ FIELD PHẢI KHỚP với parser trong daemon (chỉ để
// đọc; daemon verify byte trước khi parse nên thứ tự không ảnh hưởng verify, nhưng ta vẫn
// cố định để dễ đọc log & ổn định). Trả { str, obj }.
function buildPayload({ licKey, machineId, generation, nonce, plan, licenseExpiresAt, features, now }) {
  const iat = Math.floor((now || Date.now()) / 1000);
  const obj = {
    v: PAYLOAD_VERSION,
    iss: ISS,
    aud: AUD,
    lic: String(licKey || ''),
    dev: String(machineId || ''),
    iat,
    exp: iat + GRANT_TTL_SEC,
    gen: Number.isFinite(generation) ? generation : 0,
    nh: sha256b64(nonce),
    // hạn THẬT của license (epoch giây) hoặc null nếu vĩnh viễn — để daemon hiển thị.
    lexp: licenseExpiresAt ? Math.floor(Date.parse(licenseExpiresAt) / 1000) : null,
    plan: plan || null,
    feat: Array.isArray(features) && features.length ? features : ['app'],
  };
  return { str: JSON.stringify(obj), obj };
}

// Ký payload → { payload(base64 của chuỗi JSON), signature(base64 Ed25519 64B), keyId }.
// LƯU Ý: ký trên ĐÚNG byte UTF-8 của chuỗi JSON, không phải trên base64.
function signPayload(payloadStr) {
  const raw = Buffer.from(payloadStr, 'utf8');
  const sig = crypto.sign(null, raw, privKey()); // Ed25519: thuật toán = null
  return {
    payload: raw.toString('base64'),
    signature: sig.toString('base64'),
    keyId: KEY_ID,
  };
}

// Tiện lợi: dựng + ký trong 1 bước.
function issueGrant(args) {
  const { str, obj } = buildPayload(args);
  return { ...signPayload(str), _payload: obj };
}

module.exports = {
  KEY_ID, GRANT_TTL_SEC, ISS, AUD, PAYLOAD_VERSION,
  grantConfigured, publicKeyRaw, buildPayload, signPayload, issueGrant, sha256b64,
};
