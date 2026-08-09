// Xác thực: băm mật khẩu (scrypt) + token ký HMAC (không cần thư viện ngoài).
const crypto = require('crypto');

const SECRET = process.env.SESSION_SECRET
  || process.env.ADMIN_TOKEN
  || 'doi-session-secret-truoc-khi-chay-that';
// Cảnh báo nếu chạy production mà quên đổi secret (fail-loud, không fail-silent).
if (SECRET === 'doi-session-secret-truoc-khi-chay-that' && process.env.NODE_ENV === 'production')
  console.warn('⚠️  SESSION_SECRET đang là mặc định — token có thể bị giả mạo. ĐỔI ngay!');
const TOKEN_TTL_MS = (Number(process.env.TOKEN_TTL_DAYS) || 7) * 86400000; // mặc định 7 ngày

// ---------- Mật khẩu (scrypt) ----------
function hashPassword(pw) {
  const salt = crypto.randomBytes(16);
  const hash = crypto.scryptSync(String(pw), salt, 32);
  return `scrypt$${salt.toString('hex')}$${hash.toString('hex')}`;
}

function verifyPassword(pw, stored) {
  try {
    const [algo, saltHex, hashHex] = String(stored || '').split('$');
    if (algo !== 'scrypt') return false;
    const salt = Buffer.from(saltHex, 'hex');
    const expected = Buffer.from(hashHex, 'hex');
    const got = crypto.scryptSync(String(pw), salt, expected.length);
    return crypto.timingSafeEqual(expected, got);
  } catch { return false; }
}

// ---------- Token (payload.signature, ký HMAC-SHA256) ----------
const b64u = (buf) => Buffer.from(buf).toString('base64url');
const sign = (data) => crypto.createHmac('sha256', SECRET).update(data).digest('base64url');

function signToken(user) {
  const payload = { uid: user.id, role: user.role, email: user.email, exp: Date.now() + TOKEN_TTL_MS };
  const body = b64u(JSON.stringify(payload));
  return `${body}.${sign(body)}`;
}

function verifyToken(token) {
  const [body, sig] = String(token || '').split('.');
  if (!body || !sig) return null;
  const expect = sign(body);
  // So sánh chống timing; độ dài phải bằng nhau trước.
  if (sig.length !== expect.length
    || !crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expect))) return null;
  try {
    const payload = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
    if (!payload.exp || Date.now() > payload.exp) return null;
    return payload; // {uid, role, email, exp}
  } catch { return null; }
}

// ---------- Middleware ----------
function bearer(req) {
  const h = req.get('authorization') || '';
  return h.startsWith('Bearer ') ? h.slice(7).trim() : '';
}

// Gắn req.user nếu có token hợp lệ (không bắt buộc).
function attachUser(req, _res, next) {
  const p = verifyToken(bearer(req));
  if (p) req.user = { id: p.uid, role: p.role, email: p.email };
  next();
}

function requireAuth(req, res, next) {
  if (!req.user) return res.status(401).json({ ok: false, msg: 'Cần đăng nhập' });
  next();
}

function requireAdmin(req, res, next) {
  if (!req.user) return res.status(401).json({ ok: false, msg: 'Cần đăng nhập' });
  if (req.user.role !== 'admin') return res.status(403).json({ ok: false, msg: 'Chỉ dành cho admin' });
  next();
}

module.exports = {
  hashPassword, verifyPassword, signToken, verifyToken,
  attachUser, requireAuth, requireAdmin, TOKEN_TTL_MS,
};
