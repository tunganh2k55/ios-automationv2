// iOSAuto — License server (Node/Express · Supabase)
//   • Tài khoản: đăng ký / đăng nhập (JWT ký HMAC), phân quyền user/admin.
//   • Nhiều "tool" cho thuê: admin tạo tool + gói giá; cấp/kích hoạt license theo serial.
//   • Verify ONLINE: app/tool gọi POST /api/verify {tool, machineId, key}.
// Chạy: xem README.md.
require('dotenv').config();
const express = require('express');
const path = require('path');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const { users, tools, licenses, orders, publicUser } = require('./lib/store');
const {
  normalizeMachineId, normalizeSlug, genKey,
  genOrderCode, normalizeOrderCode, extractOrderCodes,
  DEFAULT_PLANS, sanitizePlans, planById, expiryFromPlan,
} = require('./lib/keys');
const {
  hashPassword, verifyPassword, signToken, verifyToken,
  attachUser, requireAuth, requireAdmin, TOKEN_TTL_MS,
} = require('./lib/auth');
const { grantConfigured, issueGrant } = require('./lib/grant');
const { evaluate: evalDevice } = require('./lib/deviceguard');

const PORT = process.env.PORT || 8090;

const app = express();

// DEV mode (chạy `npm run dev`): bật livereload, nới CSP cho script livereload.
const DEV = !!process.env.LIVERELOAD;
const LR = 'http://localhost:35729';
if (DEV) app.use(require('connect-livereload')()); // chèn <script> livereload vào HTML

// Chỉ bật trust proxy khi THỰC SỰ chạy sau reverse proxy (nginx/Render…),
// nếu không kẻ xấu có thể giả X-Forwarded-For để né rate-limit. Mặc định: tắt.
if (process.env.TRUST_PROXY) app.set('trust proxy', Number(process.env.TRUST_PROXY) || 1);

// Lớp 1 — HTTP security headers (CSP, nosniff, no-x-powered-by, HSTS khi HTTPS…).
// Script chỉ từ 'self' (không inline) → chặn phần lớn XSS chèn script.
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: DEV ? ["'self'", "'unsafe-inline'", LR] : ["'self'"],
      styleSrc: ["'self'", "'unsafe-inline'"], // vì HTML có style="" attr
      imgSrc: ["'self'", 'data:', 'https://img.vietqr.io'], // ảnh QR VietQR

      connectSrc: DEV ? ["'self'", LR, 'ws://localhost:35729'] : ["'self'"],
      objectSrc: ["'none'"],
      frameAncestors: ["'none'"], // chống clickjacking
      baseUri: ["'self'"],
      formAction: ["'self'"],
    },
  },
  crossOriginResourcePolicy: { policy: 'same-site' },
}));

// Lớp 2 — giới hạn kích thước body (chống payload phình gây DoS).
app.use(express.json({ limit: '16kb' }));
app.use(attachUser); // gắn req.user nếu có Bearer token hợp lệ

// Lớp 3 — rate limit các endpoint nhạy cảm (chống brute-force / lạm dụng).
const rl = (windowMs, limit, msg) => rateLimit({
  windowMs, limit, standardHeaders: 'draft-7', legacyHeaders: false,
  message: { ok: false, msg },
});
// Đăng nhập/đăng ký/đổi mật khẩu: 30 lần / 15 phút / IP.
app.use(['/api/auth', '/api/me/password'], rl(15 * 60 * 1000, 30, 'Quá nhiều lần thử. Vui lòng đợi rồi thử lại.'));
// Verify (public, tool gọi nhiều) & mua & kích hoạt-thiết bị: 60 / phút / IP.
app.use(['/api/verify', '/api/grant', '/api/purchase', '/api/orders', '/api/activate/device', '/api/device/check'], rl(60 * 1000, 60, 'Quá nhiều yêu cầu. Chậm lại một chút.'));
// Webhook web2m gọi khi có biến động số dư — nới rộng hơn (ngân hàng có thể bắn dồn).
app.use('/api/webhook', rl(60 * 1000, 240, 'Quá nhiều webhook.'));

// (Phần phục vụ trang tĩnh + route đặt ở CUỐI file, sau các API.)

// Bọc handler async → tự bắt lỗi.
const wrap = (fn) => (req, res) => Promise.resolve(fn(req, res)).catch((err) => {
  console.error(err);
  res.status(500).json({ ok: false, msg: 'Lỗi server' });
});

// Đăng nhập/đăng ký OK → đặt cookie HttpOnly chứa token (để server gác trang khi
// điều hướng) VÀ trả token trong JSON (frontend dùng Bearer cho API).
function sendAuth(res, user) {
  const token = signToken(user);
  res.cookie('ia_token', token, {
    httpOnly: true, sameSite: 'lax', secure: !!process.env.COOKIE_SECURE,
    path: '/', maxAge: TOKEN_TTL_MS,
  });
  res.json({ ok: true, token, user: publicUser(user) });
}

// Đọc cookie thủ công (không thêm thư viện).
function cookies(req) {
  const out = {};
  const h = req.headers.cookie;
  if (h) for (const p of h.split(';')) {
    const i = p.indexOf('=');
    if (i > 0) out[p.slice(0, i).trim()] = decodeURIComponent(p.slice(i + 1).trim());
  }
  return out;
}

// Gác khu admin ngay khi điều hướng: đọc token từ cookie; KHÔNG phải admin → 404.
// (Giấu sự tồn tại của /281admin, không trả về code trang admin.)
function adminGate(req, res, next) {
  const p = verifyToken(cookies(req).ia_token || '');
  if (!p || p.role !== 'admin') return res.status(404).sendFile(path.join(__dirname, 'public', '404.html'));
  next();
}

// Đánh giá 1 license cho (tool, serial).
function evalLicense(lic, { toolSlug, machineId }) {
  if (!lic) return { valid: false, reason: 'not_found' };
  if (toolSlug && lic.toolSlug !== toolSlug) return { valid: false, reason: 'tool_mismatch' };
  if (lic.status !== 'active') return { valid: false, reason: 'revoked' };
  if (!lic.machineId) return { valid: false, reason: 'not_activated' };
  if (machineId && lic.machineId !== machineId) return { valid: false, reason: 'machine_mismatch' };
  if (lic.expiresAt && Date.now() > Date.parse(lic.expiresAt)) return { valid: false, reason: 'expired' };
  return { valid: true, reason: 'ok' };
}

// =================== THANH TOÁN (VietQR + web2m webhook) ===================
const ORDER_TTL_MS = (parseInt(process.env.ORDER_TTL_MINUTES, 10) || 15) * 60 * 1000;

// Cấu hình tài khoản nhận tiền (dùng sinh QR). Thiếu → chưa bán được.
function bankInfo() {
  return {
    bankId: String(process.env.BANK_ID || '').trim(),
    account: String(process.env.BANK_ACCOUNT || '').trim(),
    accountName: String(process.env.BANK_ACCOUNT_NAME || '').trim(),
    template: String(process.env.BANK_QR_TEMPLATE || 'compact2').trim(),
  };
}
const bankConfigured = () => { const b = bankInfo(); return !!(b.bankId && b.account); };

// URL ảnh QR VietQR (img.vietqr.io) cho số tiền + nội dung (mã đơn).
function buildQrUrl(amount, code) {
  const b = bankInfo();
  const q = new URLSearchParams({ amount: String(amount), addInfo: code });
  if (b.accountName) q.set('accountName', b.accountName);
  return `https://img.vietqr.io/image/${encodeURIComponent(b.bankId)}-${encodeURIComponent(b.account)}-${encodeURIComponent(b.template || 'compact2')}.png?${q.toString()}`;
}

// Xác thực webhook: secret khớp qua ?secret= | header X-Webhook-Secret | Authorization.
function checkWebhookSecret(req) {
  const want = String(process.env.WEB2M_WEBHOOK_SECRET || '');
  if (!want) return false; // chưa cấu hình secret → từ chối (an toàn mặc định)
  const auth = String(req.headers.authorization || '').replace(/^(Bearer|Apikey)\s+/i, '');
  const got = String(req.query.secret || req.headers['x-webhook-secret'] || auth || '');
  return got === want;
}

// Chuẩn hoá 1 giao dịch từ payload webhook (chấp nhận nhiều tên trường theo từng nhà cung cấp).
function normalizeTx(raw) {
  const pick = (...ks) => { for (const k of ks) if (raw[k] != null && raw[k] !== '') return raw[k]; return undefined; };
  const amount = Math.round(Number(pick('transferAmount', 'amount', 'creditAmount', 'amountIn', 'money', 'value')) || 0);
  const content = String(pick('content', 'description', 'transferContent', 'comment', 'noiDung', 'addInfo', 'memo') || '');
  const ref = String(pick('referenceCode', 'transactionID', 'transactionId', 'tid', 'id', 'transactionNumber', 'reference') || '');
  const typeStr = String(pick('transferType', 'type', 'direction') || '').toLowerCase();
  const isIn = raw.creditAmount != null ? Number(raw.creditAmount) > 0
    : (typeStr ? /in|credit|money_in|cong|\+/.test(typeStr) : amount > 0);
  return { amount, content, ref, isIn };
}

// Cấp license cho 1 đơn đã thanh toán (dùng plan/tool của đơn).
// Chưa kích hoạt (không có machineId) → CHƯA tính hạn (expiresAt = null); hạn tính từ lúc kích hoạt.
async function issueLicenseForOrder(order) {
  const tool = (order.toolId && await tools.byId(order.toolId)) || await tools.bySlug(order.toolSlug);
  const machineId = order.machineId || null;
  const lic = {
    key: genKey(order.toolSlug),
    toolId: tool ? tool.id : order.toolId, toolSlug: order.toolSlug, toolName: order.toolName,
    userId: order.userId, userEmail: order.userEmail,
    machineId,
    plan: order.plan,
    createdAt: new Date().toISOString(),
    expiresAt: machineId ? (expiryFromPlan(tool ? tool.plans : [], order.plan) ?? null) : null,
    status: 'active', paid: order.provider || 'web2m', note: 'order ' + order.code,
    customerNote: order.customerNote || '', // chú thích khách nhập khi đặt mua
  };
  await licenses.insert(lic);
  return lic;
}

// Cấp NHIỀU license cho đơn có nhiều serial. Mỗi serial = 1 license riêng.
async function issueLicensesForOrder(order) {
  const tool = (order.toolId && await tools.byId(order.toolId)) || await tools.bySlug(order.toolSlug);
  const machineIds = order.machineIds ? JSON.parse(order.machineIds) : [];
  const quantity = order.quantity || Math.max(1, machineIds.length);
  const keys = [];

  for (let i = 0; i < quantity; i++) {
    const machineId = machineIds[i] || null;
    const lic = {
      key: genKey(order.toolSlug),
      toolId: tool ? tool.id : order.toolId, toolSlug: order.toolSlug, toolName: order.toolName,
      userId: order.userId, userEmail: order.userEmail,
      machineId,
      plan: order.plan,
      createdAt: new Date().toISOString(),
      expiresAt: machineId ? (expiryFromPlan(tool ? tool.plans : [], order.plan) ?? null) : null,
      status: 'active', paid: order.provider || 'web2m', note: 'order ' + order.code,
      customerNote: order.customerNote || '',
    };
    await licenses.insert(lic);
    keys.push(lic.key);
  }
  return keys;
}

// Patch khi kích hoạt lần đầu: gán machineId và BẮT ĐẦU tính hạn (now + số ngày gói).
//   • Chỉ tính hạn ở lần kích hoạt ĐẦU TIÊN (khi lic chưa có machineId).
//   • Gói vĩnh viễn (days = null) → expiresAt vẫn null.
async function firstActivationPatch(lic, machineId) {
  const patch = { machineId };
  if (!lic.machineId) {
    const tool = (lic.toolId && await tools.byId(lic.toolId)) || await tools.bySlug(lic.toolSlug);
    patch.expiresAt = expiryFromPlan(tool ? tool.plans : [], lic.plan) ?? null;
  }
  return patch;
}

// =================== AUTH ===================
app.post('/api/auth/register', wrap(async (req, res) => {
  const email = String(req.body.email || '').toLowerCase().trim();
  const pw = String(req.body.password || '');
  const name = String(req.body.name || '').slice(0, 80);
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return res.status(400).json({ ok: false, msg: 'Email không hợp lệ' });
  if (pw.length < 6) return res.status(400).json({ ok: false, msg: 'Mật khẩu tối thiểu 6 ký tự' });
  if (await users.byEmail(email)) return res.status(409).json({ ok: false, msg: 'Email đã được đăng ký' });

  const user = await users.create({ email, passwordHash: hashPassword(pw), role: 'user', name });
  sendAuth(res, user);
}));

app.post('/api/auth/login', wrap(async (req, res) => {
  const email = String(req.body.email || '').toLowerCase().trim();
  const pw = String(req.body.password || '');
  const user = await users.byEmail(email);
  if (!user || !verifyPassword(pw, user.passwordHash))
    return res.status(401).json({ ok: false, msg: 'Sai email hoặc mật khẩu' });
  sendAuth(res, user);
}));

// Đăng xuất: xoá cookie gác trang (frontend tự xoá localStorage).
app.post('/api/auth/logout', (req, res) => {
  res.clearCookie('ia_token', { path: '/' });
  res.json({ ok: true });
});

app.get('/api/auth/me', requireAuth, wrap(async (req, res) => {
  const user = await users.byId(req.user.id);
  if (!user) return res.status(401).json({ ok: false, msg: 'Tài khoản không tồn tại' });
  res.json({ ok: true, user: publicUser(user) });
}));

// =================== PUBLIC: tools & verify ===================
// Danh sách tool đang bán (kèm gói giá) — cho trang store.
app.get('/api/tools', wrap(async (req, res) => {
  const list = await tools.listActive();
  res.json({ ok: true, tools: list.map((t) => ({ id: t.id, slug: t.slug, name: t.name, description: t.description, kind: t.kind, parentSlug: t.parentSlug, plans: t.plans })) });
}));

// Verify — app/tool gọi để kiểm tra bản quyền theo (tool, serial).
app.post('/api/verify', wrap(async (req, res) => {
  const toolSlug = normalizeSlug(req.body.tool);
  const machineId = normalizeMachineId(req.body.machineId);
  const lic = await licenses.byKey(req.body.key);
  const v = evalLicense(lic, { toolSlug, machineId });
  res.json({
    valid: v.valid, reason: v.reason,
    tool: lic ? lic.toolSlug : null,
    plan: lic ? lic.plan : null,
    expiresAt: lic ? lic.expiresAt : null,
  });
}));

// Verify theo THIẾT BỊ (PUBLIC) — chỉ cần (tool, machineId), KHÔNG cần key.
// Dùng khi license đã kích hoạt gắn serial rồi: tool tự đọc serial máy (getSN) và hỏi
// "máy này còn quyền dùng tool X không?". Tìm license đã bind đúng máy+tool, còn hiệu lực.
//   Body: { tool, machineId }
//   Trả:  { valid, reason, tool, plan, expiresAt }
//   reason: ok · not_found (máy chưa có license tool này) · expired · revoked · bad_request
app.post('/api/verify/device', wrap(async (req, res) => {
  const toolSlug = normalizeSlug(req.body.tool);
  const machineId = normalizeMachineId(req.body.machineId);
  if (!toolSlug || machineId.length < 4)
    return res.json({ valid: false, reason: 'bad_request', tool: toolSlug || null });

  const list = await licenses.byMachineTool(toolSlug, machineId);
  if (!list.length) return res.json({ valid: false, reason: 'not_found', tool: toolSlug });

  // Chọn dòng còn hiệu lực (evalLicense đã khớp tool+machine). Không có dòng hợp lệ → giữ lý do
  // "gần đúng nhất" (expired ưu tiên hơn revoked) để client hiển thị đúng.
  let best = null, reason = 'revoked';
  for (const lic of list) {
    const v = evalLicense(lic, { toolSlug, machineId });
    if (v.valid) { best = lic; reason = 'ok'; break; }
    if (v.reason === 'expired') reason = 'expired';
  }
  if (best) return res.json({ valid: true, reason: 'ok', tool: best.toolSlug, plan: best.plan, expiresAt: best.expiresAt });
  return res.json({ valid: false, reason, tool: toolSlug });
}));

// Kích hoạt theo THIẾT BỊ (PUBLIC — app/daemon gọi trực tiếp, KHÔNG cần đăng nhập web).
// Gắn (bind) machineId vào key nếu key chưa gắn máy nào; nếu đã gắn đúng máy → coi như thành công
// (idempotent). Đây là cách app "Kích hoạt" ngay trên thiết bị mà không cần lên web.
//   Body: { tool, key, machineId }
//   Trả:  { ok, reason, tool, plan, expiresAt, machineId }
// Bảo mật: ai có key + serial đều bind được (bản chất kích hoạt theo key). First-come giữ máy;
// muốn đổi máy phải thu hồi/gia hạn qua admin (giữ nguyên hành vi /api/activate cũ).
app.post('/api/activate/device', wrap(async (req, res) => {
  const toolSlug = normalizeSlug(req.body.tool);
  const machineId = normalizeMachineId(req.body.machineId);
  if (machineId.length < 4) return res.status(400).json({ ok: false, reason: 'bad_machine', msg: 'Serial không hợp lệ' });
  const lic = await licenses.byKey(req.body.key);
  if (!lic) return res.json({ ok: false, reason: 'not_found' });
  if (toolSlug && lic.toolSlug !== toolSlug) return res.json({ ok: false, reason: 'tool_mismatch' });
  if (lic.status !== 'active') return res.json({ ok: false, reason: 'revoked' });
  if (lic.expiresAt && Date.now() > Date.parse(lic.expiresAt)) return res.json({ ok: false, reason: 'expired' });
  if (lic.machineId && lic.machineId !== machineId) return res.json({ ok: false, reason: 'machine_mismatch' });
  let stacked = false;
  if (!lic.machineId) {                                 // bind lần đầu → bắt đầu tính hạn
    // CỘNG DỒN (gia hạn): nếu máy đang dùng 1 key KHÁC còn hạn, cùng tool → cộng số ngày của
    // key mới lên NỀN hạn còn lại của key cũ, rồi thu hồi key cũ (chống dùng lại). Vd còn 6 ngày
    // + kích hoạt key 15 ngày → 21 ngày. Không có currentKey → carryBase = now (như cũ).
    let carryBase = Date.now(), superseded = null;
    const curKeyRaw = String(req.body.currentKey || '').trim();
    if (curKeyRaw) {
      const cur = await licenses.byKey(curKeyRaw);
      if (cur && cur.key !== lic.key && cur.status === 'active' && cur.machineId === machineId
          && cur.toolSlug === lic.toolSlug
          && cur.expiresAt && Date.parse(cur.expiresAt) > Date.now()) {
        carryBase = Date.parse(cur.expiresAt);
        superseded = cur.key;
      }
    }
    const tool = (lic.toolId && await tools.byId(lic.toolId)) || await tools.bySlug(lic.toolSlug);
    const expiresAt = expiryFromPlan(tool ? tool.plans : [], lic.plan, carryBase) ?? null;
    await licenses.update(lic.key, { machineId, expiresAt });
    lic.machineId = machineId; lic.expiresAt = expiresAt;
    if (superseded) { await licenses.update(superseded, { status: 'revoked', note: 'đã gộp vào ' + lic.key }); stacked = true; }
  }
  res.json({ ok: true, reason: 'ok', tool: lic.toolSlug, plan: lic.plan, expiresAt: lic.expiresAt, machineId, stacked });
}));

// Verify GỘP — app iosauto gọi 1 lần để check license APP + từng TOOL con.
// Body: {
//   app: "iosauto",                 // slug của app mẹ
//   appKey: "IOSA-...",             // key license của app
//   machineId: "<serial/IDFV>",
//   tools: [                        // (tuỳ chọn) danh sách tool con cần check
//     { tool: "ocr", key: "OCR-..." },
//     { tool: "tap", key: "TAP-..." }
//   ]
// }
// Quy tắc: APP không hợp lệ → khoá toàn bộ; mỗi tool con còn cần license riêng.
// Kết quả tool con có `enabled = app.valid && tool.valid` để client bật/tắt cho gọn.
app.post('/api/verify/app', wrap(async (req, res) => {
  const appSlug = normalizeSlug(req.body.app);
  const machineId = normalizeMachineId(req.body.machineId);

  // --- License APP ---
  const appLic = await licenses.byKey(req.body.appKey);
  const av = evalLicense(appLic, { toolSlug: appSlug, machineId });
  const appOut = {
    slug: appSlug || (appLic ? appLic.toolSlug : null),
    valid: av.valid, reason: av.reason,
    plan: appLic ? appLic.plan : null,
    expiresAt: appLic ? appLic.expiresAt : null,
  };

  // --- License từng TOOL con ---
  const reqTools = Array.isArray(req.body.tools) ? req.body.tools.slice(0, 50) : [];
  const toolsOut = {};
  for (const t of reqTools) {
    const slug = normalizeSlug(t && t.tool);
    if (!slug) continue;
    const lic = await licenses.byKey(t && t.key);
    const v = evalLicense(lic, { toolSlug: slug, machineId });
    toolsOut[slug] = {
      valid: v.valid, reason: v.reason,
      enabled: av.valid && v.valid, // chỉ bật khi cả app lẫn tool đều hợp lệ
      plan: lic ? lic.plan : null,
      expiresAt: lic ? lic.expiresAt : null,
    };
  }

  res.json({ ok: true, app: appOut, tools: toolsOut });
}));

// Device integrity CHECK — PHÁT HIỆN spoof/hook/jailbreak (defensive). PUBLIC.
// App iosauto tự thu tín hiệu runtime rồi POST lên đây; server đối chiếu chéo & chấm điểm.
//   Body: {
//     machineId,                         // (tuỳ chọn) để log/đối soát
//     model: "iPhone15,3",               // hw.machine khai báo
//     memBytes: 6127…,                   // hw.memsize
//     iosVersion: "17.1",
//     screen: { w, h, scale },           // UIScreen.nativeBounds
//     jailbreak: { varJb, canWriteRoot, suspiciousPaths:[…] },
//     hooks: { sysctl, uiscreen, nsbundle, foundation },  // true = phát hiện hook lạ
//     dyldImages: <số ảnh dyld lạ>
//   }
//   Trả: { ok, verdict: clean|suspicious|spoof_or_tampered, score, flags:[{code,weight,detail}] }
// Lưu ý: đây là detection dựa tín hiệu client (client bị can thiệp có thể nói dối) → nên coi là
// MỘT lớp; lớp không giả được là App Attest/DeviceCheck (ký ở Secure Enclave) — cắm thêm sau.
app.post('/api/device/check', wrap(async (req, res) => {
  const b = req.body || {};
  const signals = {
    model: String(b.model || '').slice(0, 40),
    memBytes: Number(b.memBytes) || 0,
    iosVersion: String(b.iosVersion || '').slice(0, 16),
    screen: {
      w: Number(b.screen && b.screen.w) || 0,
      h: Number(b.screen && b.screen.h) || 0,
      scale: Number(b.screen && b.screen.scale) || 0,
    },
    jailbreak: {
      varJb: !!(b.jailbreak && b.jailbreak.varJb),
      canWriteRoot: !!(b.jailbreak && b.jailbreak.canWriteRoot),
      suspiciousPaths: Array.isArray(b.jailbreak && b.jailbreak.suspiciousPaths)
        ? b.jailbreak.suspiciousPaths.slice(0, 20).map((p) => String(p).slice(0, 128)) : [],
    },
    hooks: {
      sysctl: !!(b.hooks && b.hooks.sysctl),
      uiscreen: !!(b.hooks && b.hooks.uiscreen),
      nsbundle: !!(b.hooks && b.hooks.nsbundle),
      foundation: !!(b.hooks && b.hooks.foundation),
    },
    dyldImages: Number(b.dyldImages) || 0,
  };
  const result = evalDevice(signals);
  res.json({ ok: true, ...result });
}));

// Cấp GRANT có chữ ký Ed25519 cho THIẾT BỊ (PUBLIC — daemon gọi mỗi ~10'). Nhóm 1.
//   Body: { app, appKey, machineId, nonce }   (nonce: chuỗi ngẫu nhiên client TỰ SINH trước)
//   Trả hợp lệ:      { ok:true, grant:{ payload, signature, keyId } }
//   Không hợp lệ:    { ok:false, reason }  — KHÔNG ký; daemon giữ offline/khoá theo phân tầng.
// generation LẤY TỪ DB mỗi lần cấp → thu hồi (bump generation) làm grant cũ chết trong ≤TTL.
app.post('/api/grant', wrap(async (req, res) => {
  if (!grantConfigured())
    return res.status(503).json({ ok: false, reason: 'server_no_key', msg: 'Server chưa cấu hình khóa ký' });
  const appSlug = normalizeSlug(req.body.app);
  const machineId = normalizeMachineId(req.body.machineId);
  const nonce = String(req.body.nonce || '');
  if (nonce.length < 8 || nonce.length > 256)
    return res.status(400).json({ ok: false, reason: 'bad_nonce' });

  const lic = await licenses.byKey(req.body.appKey);
  const v = evalLicense(lic, { toolSlug: appSlug, machineId });
  if (!v.valid) return res.json({ ok: false, reason: v.reason });

  const grant = issueGrant({
    licKey: lic.key, machineId, generation: lic.generation, nonce,
    plan: lic.plan, licenseExpiresAt: lic.expiresAt, features: ['app'], now: Date.now(),
  });
  res.json({ ok: true, grant: { payload: grant.payload, signature: grant.signature, keyId: grant.keyId } });
}));

// =================== USER (cần đăng nhập) ===================
// License của tôi.
app.get('/api/me/licenses', requireAuth, wrap(async (req, res) => {
  res.json({ ok: true, licenses: await licenses.listByUser(req.user.id) });
}));

// Mua license — MOCK thanh toán: cấp key ngay (CHỈ để test; production dùng /api/orders).
app.post('/api/purchase', requireAuth, wrap(async (req, res) => {
  if (!process.env.ALLOW_MOCK_PURCHASE) return res.status(403).json({ ok: false, msg: 'Mua thử đã tắt. Dùng thanh toán chuyển khoản.' });
  const tool = await tools.byId(req.body.toolId);
  if (!tool || !tool.active) return res.status(400).json({ ok: false, msg: 'Tool không hợp lệ' });
  const plan = String(req.body.plan || '');
  if (!planById(tool.plans, plan)) return res.status(400).json({ ok: false, msg: 'Gói không hợp lệ' });
  const machineId = normalizeMachineId(req.body.machineId); // tuỳ chọn

  const lic = {
    key: genKey(tool.slug),
    toolId: tool.id, toolSlug: tool.slug, toolName: tool.name,
    userId: req.user.id, userEmail: req.user.email,
    machineId: machineId || null,
    plan,
    createdAt: new Date().toISOString(),
    expiresAt: machineId ? (expiryFromPlan(tool.plans, plan) ?? null) : null, // chưa kích hoạt → chưa tính hạn
    status: 'active', paid: 'mock', note: '', customerNote: String(req.body.note || '').slice(0, 500),
  };
  await licenses.insert(lic);
  res.json({ ok: true, key: lic.key, tool: tool.slug, plan, expiresAt: lic.expiresAt });
}));

// Tạo ĐƠN mua — trả QR chuyển khoản + mã nội dung. web2m webhook xác nhận → cấp key.
// Hỗ trợ nhiều serial: mỗi serial = 1 máy, tính tiền riêng (quantity = số serial).
app.post('/api/orders', requireAuth, wrap(async (req, res) => {
  const tool = await tools.byId(req.body.toolId);
  if (!tool || !tool.active) return res.status(400).json({ ok: false, msg: 'Tool không hợp lệ' });
  const plan = planById(tool.plans, String(req.body.plan || ''));
  if (!plan) return res.status(400).json({ ok: false, msg: 'Gói không hợp lệ' });

  // Hỗ trợ nhiều serial: mỗi dòng = 1 serial
  const machineIdRaw = String(req.body.machineId || '');
  const machineIds = machineIdRaw.split(/\r?\n/).map(s => normalizeMachineId(s)).filter(s => s.length > 0);
  const quantity = Math.max(1, machineIds.length); // tối thiểu 1 máy
  const machineId = machineIds[0] || null; // serial đầu tiên (dùng cho license đầu)
  const machineIdsJson = machineIds.length > 1 ? JSON.stringify(machineIds) : null; // lưu tất cả serial nếu > 1

  const customerNote = String(req.body.note || '').slice(0, 500);
  const unitPrice = Math.max(0, plan.price | 0);
  const amount = unitPrice * quantity; // tổng tiền = giá × số máy

  // Gói miễn phí (giá 0) → cấp key ngay, không cần thanh toán.
  if (unitPrice === 0) {
    const order = await orders.create({
      code: genOrderCode(), toolId: tool.id, toolSlug: tool.slug, toolName: tool.name,
      userId: req.user.id, userEmail: req.user.email, plan: plan.id, amount: 0,
      machineId: machineId || null, machineIds: machineIdsJson, quantity,
      status: 'pending', provider: 'free', customerNote,
      expiresAt: new Date(Date.now() + ORDER_TTL_MS).toISOString(),
    });
    const keys = await issueLicensesForOrder(order);
    await orders.update(order.code, { status: 'paid', licenseKey: keys[0], licenseKeys: JSON.stringify(keys), paidAt: new Date().toISOString() });
    return res.json({ ok: true, free: true, status: 'paid', code: order.code, key: keys[0], keys, quantity, expiresAt: null });
  }

  if (!bankConfigured()) return res.status(503).json({ ok: false, msg: 'Cổng thanh toán chưa được cấu hình. Liên hệ quản trị.' });

  const order = await orders.create({
    code: genOrderCode(), toolId: tool.id, toolSlug: tool.slug, toolName: tool.name,
    userId: req.user.id, userEmail: req.user.email, plan: plan.id, amount,
    machineId: machineId || null, machineIds: machineIdsJson, quantity,
    status: 'pending', provider: 'web2m', customerNote,
    expiresAt: new Date(Date.now() + ORDER_TTL_MS).toISOString(),
  });
  const b = bankInfo();
  res.json({
    ok: true, status: 'pending', code: order.code, amount, quantity, plan: plan.id,
    expiresAt: order.expiresAt,
    qrUrl: buildQrUrl(amount, order.code),
    bank: { bankId: b.bankId, account: b.account, accountName: b.accountName },
    transferContent: order.code,
  });
}));

// Đơn pending quá 15 phút (ORDER_TTL_MS) → tự chuyển 'expired', không xử lý nữa.
// Dùng chung cho poll trạng thái, danh sách đơn, và webhook.
async function expireIfStale(order) {
  if (order && order.status === 'pending' && order.expiresAt && Date.now() > Date.parse(order.expiresAt)) {
    await orders.update(order.code, { status: 'expired' });
    order.status = 'expired';
  }
  return order;
}

// Trạng thái đơn (frontend poll). Chỉ chủ đơn xem được.
app.get('/api/orders/:code', requireAuth, wrap(async (req, res) => {
  const order = await orders.byCode(normalizeOrderCode(req.params.code));
  if (!order || order.userId !== req.user.id) return res.status(404).json({ ok: false, msg: 'Không tìm thấy đơn' });
  await expireIfStale(order); // quá giờ mà chưa thanh toán → hết hạn
  const keys = order.licenseKeys ? JSON.parse(order.licenseKeys) : (order.licenseKey ? [order.licenseKey] : []);
  res.json({
    ok: true, status: order.status, key: order.licenseKey || null, keys,
    quantity: order.quantity || 1, amount: order.amount, plan: order.plan, expiresAt: order.expiresAt
  });
}));

// Đơn của tôi. Quét & đánh dấu hết hạn các đơn pending quá giờ trước khi trả về.
app.get('/api/me/orders', requireAuth, wrap(async (req, res) => {
  const list = await orders.listByUser(req.user.id);
  await Promise.all(list.map(expireIfStale));
  res.json({ ok: true, orders: list });
}));

// Webhook web2m — biến động số dư. Đối soát theo (mã nội dung + số tiền) → cấp key.
// Khai báo URL cho web2m: https://<domain>/api/webhook/web2m?secret=<WEB2M_WEBHOOK_SECRET>
app.post('/api/webhook/web2m', wrap(async (req, res) => {
  if (!checkWebhookSecret(req)) return res.status(401).json({ success: false, msg: 'Sai secret' });

  const body = req.body || {};
  const list = Array.isArray(body) ? body
    : Array.isArray(body.data) ? body.data
    : Array.isArray(body.transactions) ? body.transactions
    : [body];

  let matched = 0;
  for (const raw of list) {
    const tx = normalizeTx(raw);
    if (!tx.isIn || tx.amount <= 0) continue;
    if (tx.ref && await orders.byTxRef(tx.ref)) continue; // giao dịch đã xử lý

    for (const code of extractOrderCodes(tx.content)) {
      const order = await orders.byCode(code);
      if (!order || order.status !== 'pending') continue;
      await expireIfStale(order);              // quá 15 phút → không xử lý nữa
      if (order.status !== 'pending') continue; // đã bị đánh dấu hết hạn ở trên
      if (tx.amount < order.amount) continue;  // chưa đủ tiền
      const keys = await issueLicensesForOrder(order);
      await orders.update(order.code, {
        status: 'paid', licenseKey: keys[0], licenseKeys: JSON.stringify(keys),
        txRef: tx.ref || null, paidAt: new Date().toISOString(), raw,
      });
      matched++;
      console.log(`💰 Order ${order.code} PAID (${tx.amount}₫) → ${keys.length} key(s): ${keys.join(', ')}`);
      break; // 1 giao dịch khớp tối đa 1 đơn
    }
  }
  if (!matched) console.log('ℹ️  webhook web2m: không khớp đơn nào', JSON.stringify(body).slice(0, 500));
  res.json({ success: true, matched });
}));

// Kích hoạt theo serial — gắn Machine ID vào license của mình.
// RÀNG BUỘC: 1 license chỉ gắn 1 Machine ID, đã gắn thì KHÔNG đổi/tái sử dụng sang máy khác.
app.post('/api/activate', requireAuth, wrap(async (req, res) => {
  const lic = await licenses.byKey(req.body.key);
  if (!lic || lic.userId !== req.user.id) return res.status(404).json({ ok: false, msg: 'Không tìm thấy key của bạn' });
  if (lic.status !== 'active') return res.status(400).json({ ok: false, msg: 'Key đã bị thu hồi' });
  const machineId = normalizeMachineId(req.body.machineId);
  if (machineId.length < 4) return res.status(400).json({ ok: false, msg: 'Serial không hợp lệ' });
  if (lic.machineId && lic.machineId !== machineId)
    return res.status(409).json({ ok: false, msg: 'Key đã gắn với máy khác — không thể đổi hay dùng lại trên máy này.' });
  const patch = await firstActivationPatch(lic, machineId); // lần đầu → bắt đầu tính hạn
  await licenses.update(lic.key, patch);
  res.json({ ok: true, machineId, expiresAt: 'expiresAt' in patch ? patch.expiresAt : lic.expiresAt });
}));

// Cập nhật hồ sơ (tên hiển thị).
app.post('/api/me/profile', requireAuth, wrap(async (req, res) => {
  const name = String(req.body.name || '').slice(0, 80);
  const user = await users.updateProfile(req.user.id, { name });
  res.json({ ok: true, user: publicUser(user) });
}));

// Đổi mật khẩu (cần mật khẩu hiện tại).
app.post('/api/me/password', requireAuth, wrap(async (req, res) => {
  const oldPw = String(req.body.oldPassword || '');
  const newPw = String(req.body.newPassword || '');
  if (newPw.length < 6) return res.status(400).json({ ok: false, msg: 'Mật khẩu mới tối thiểu 6 ký tự' });
  const user = await users.byId(req.user.id);
  if (!user || !verifyPassword(oldPw, user.passwordHash))
    return res.status(400).json({ ok: false, msg: 'Mật khẩu hiện tại không đúng' });
  await users.updatePassword(user.id, hashPassword(newPw));
  res.json({ ok: true });
}));

// =================== ADMIN ===================
// --- Tools ---
app.get('/api/admin/tools', requireAdmin, wrap(async (req, res) => {
  res.json({ ok: true, tools: await tools.list(), defaultPlans: DEFAULT_PLANS });
}));

app.post('/api/admin/tools', requireAdmin, wrap(async (req, res) => {
  const slug = normalizeSlug(req.body.slug || req.body.name);
  const name = String(req.body.name || '').trim().slice(0, 80);
  if (!slug || !name) return res.status(400).json({ ok: false, msg: 'Cần tên tool (và slug)' });
  if (await tools.bySlug(slug)) return res.status(409).json({ ok: false, msg: 'Slug đã tồn tại' });
  const plans = sanitizePlans(req.body.plans && req.body.plans.length ? req.body.plans : DEFAULT_PLANS);
  const kind = req.body.kind === 'app' ? 'app' : 'tool';
  const parentSlug = kind === 'tool' && req.body.parentSlug ? normalizeSlug(req.body.parentSlug) : null;
  const tool = await tools.create({ slug, name, description: String(req.body.description || '').slice(0, 500), plans, kind, parentSlug });
  res.json({ ok: true, tool });
}));

app.patch('/api/admin/tools/:id', requireAdmin, wrap(async (req, res) => {
  const fields = {};
  if ('name' in req.body) fields.name = String(req.body.name || '').slice(0, 80);
  if ('description' in req.body) fields.description = String(req.body.description || '').slice(0, 500);
  if ('active' in req.body) fields.active = !!req.body.active;
  if ('plans' in req.body) fields.plans = sanitizePlans(req.body.plans);
  if ('kind' in req.body) fields.kind = req.body.kind === 'app' ? 'app' : 'tool';
  if ('parentSlug' in req.body) fields.parentSlug = req.body.parentSlug ? normalizeSlug(req.body.parentSlug) : null;
  const tool = await tools.update(req.params.id, fields);
  res.json({ ok: true, tool });
}));

// --- Licenses ---
app.get('/api/admin/licenses', requireAdmin, wrap(async (req, res) => {
  res.json({ ok: true, licenses: await licenses.listAll({ toolId: req.query.tool || undefined }) });
}));

app.post('/api/admin/issue', requireAdmin, wrap(async (req, res) => {
  const tool = await tools.byId(req.body.toolId);
  if (!tool) return res.status(400).json({ ok: false, msg: 'Tool không hợp lệ' });
  const plan = String(req.body.plan || '');
  if (!planById(tool.plans, plan)) return res.status(400).json({ ok: false, msg: 'Gói không hợp lệ' });

  let owner = null;
  const email = String(req.body.userEmail || '').toLowerCase().trim();
  if (email) {
    owner = await users.byEmail(email);
    if (!owner) return res.status(404).json({ ok: false, msg: 'Không tìm thấy user với email đó' });
  }
  const lic = {
    key: genKey(tool.slug),
    toolId: tool.id, toolSlug: tool.slug, toolName: tool.name,
    userId: owner ? owner.id : null, userEmail: owner ? owner.email : null,
    machineId: normalizeMachineId(req.body.machineId) || null,
    plan,
    createdAt: new Date().toISOString(),
    expiresAt: (normalizeMachineId(req.body.machineId) || null)
      ? (expiryFromPlan(tool.plans, plan) ?? null) : null, // chưa kích hoạt → chưa tính hạn
    status: 'active', paid: 'admin', note: String(req.body.note || '').slice(0, 200),
  };
  await licenses.insert(lic);
  res.json({ ok: true, license: lic });
}));

// Kích hoạt/gán serial (admin). 1 license chỉ gắn 1 Machine ID — đã gắn thì KHÔNG đổi được.
app.post('/api/admin/activate', requireAdmin, wrap(async (req, res) => {
  const lic = await licenses.byKey(req.body.key);
  if (!lic) return res.status(404).json({ ok: false, msg: 'Không tìm thấy key' });
  const machineId = normalizeMachineId(req.body.machineId);
  if (machineId.length < 4) return res.status(400).json({ ok: false, msg: 'Serial không hợp lệ' });
  if (lic.machineId && lic.machineId !== machineId)
    return res.status(409).json({ ok: false, msg: 'Key đã gắn Machine ID khác — không thể đổi hay tái sử dụng.' });
  const patch = await firstActivationPatch(lic, machineId); // lần đầu → bắt đầu tính hạn
  patch.status = 'active';
  await licenses.update(lic.key, patch);
  res.json({ ok: true, machineId, expiresAt: 'expiresAt' in patch ? patch.expiresAt : lic.expiresAt });
}));

app.post('/api/admin/revoke', requireAdmin, wrap(async (req, res) => {
  const lic = await licenses.byKey(req.body.key);
  if (!lic) return res.status(404).json({ ok: false, msg: 'Không tìm thấy key' });
  await licenses.update(lic.key, { status: 'revoked' });
  await licenses.bumpGeneration(lic.key); // giết mọi grant Ed25519 cũ trong ≤TTL (Nhóm 1)
  res.json({ ok: true });
}));

app.post('/api/admin/extend', requireAdmin, wrap(async (req, res) => {
  const lic = await licenses.byKey(req.body.key);
  if (!lic) return res.status(404).json({ ok: false, msg: 'Không tìm thấy key' });
  const days = parseInt(req.body.days, 10) || 0;
  const base = lic.expiresAt ? Math.max(Date.parse(lic.expiresAt), Date.now()) : Date.now();
  const expiresAt = new Date(base + days * 86400000).toISOString();
  await licenses.update(lic.key, { expiresAt, status: 'active' });
  res.json({ ok: true, expiresAt });
}));

app.get('/api/admin/users', requireAdmin, wrap(async (req, res) => {
  const [list, allLic, allOrders] = await Promise.all([
    users.list(), licenses.listAll(), orders.listAll(),
  ]);
  const now = Date.now();

  // Gộp thống kê theo user_id, kèm fallback theo email (đơn/license có thể chỉ có email).
  const stat = new Map(); // key: userId → { paid, orders, licTotal, licPending, licActive, licExpired }
  const byEmail = new Map(); // key: email → cùng object stat (để tra khi thiếu userId)
  for (const u of list) {
    const s = { paid: 0, orders: 0, licTotal: 0, licPending: 0, licActive: 0, licExpired: 0 };
    stat.set(u.id, s);
    if (u.email) byEmail.set(String(u.email).toLowerCase(), s);
  }
  const find = (userId, userEmail) =>
    (userId && stat.get(userId)) ||
    (userEmail && byEmail.get(String(userEmail).toLowerCase())) || null;

  // Tiền đã thanh toán = tổng amount các đơn status 'paid'.
  for (const o of allOrders) {
    if (o.status !== 'paid') continue;
    const s = find(o.userId, o.userEmail);
    if (!s) continue;
    s.paid += Number(o.amount) || 0;
    s.orders += 1;
  }

  // License theo trạng thái:
  //   • chưa kích hoạt: chưa gắn máy (machineId rỗng) và chưa bị thu hồi
  //   • đã kích hoạt còn hạn: đã gắn máy, active, chưa hết hạn (hoặc vĩnh viễn)
  //   • đã kích hoạt hết hạn: đã gắn máy, có expiresAt đã qua
  for (const l of allLic) {
    const s = find(l.userId, l.userEmail);
    if (!s) continue;
    s.licTotal += 1;
    const expired = l.expiresAt && Date.parse(l.expiresAt) < now;
    if (!l.machineId) s.licPending += 1;
    else if (expired) s.licExpired += 1;
    else s.licActive += 1;
  }

  const users2 = list.map((u) => ({ ...u, stats: stat.get(u.id) }));
  res.json({ ok: true, users: users2 });
}));

// =================== Trang tĩnh & routing (đặt SAU mọi API) ===================
const PUB = path.join(__dirname, 'public');
const ADMIN_BASE = '/281admin'; // prefix bí mật cho khu quản trị
const page = (folder, file) => (req, res) => res.sendFile(path.join(PUB, folder, file));

// Asset dùng chung (style.css, api.js) — tham chiếu bằng /assets/*
app.use('/assets', express.static(path.join(PUB, 'assets')));

// ---- Repo Sileo/APT TĨNH tại /repo (khách add source: https://iosautos.com/repo) ----
// File sinh bởi app/repo/make_repo.py, commit trong web-license/repo/ (gồm cả *.deb).
// Sileo tải: /repo/Release, /repo/Packages(.gz), và /repo/debs/*.deb (Filename tương đối).
const REPO_DIR = path.join(__dirname, 'repo');
app.use('/repo', express.static(REPO_DIR, {
  index: 'index.html',
  setHeaders: (res, fp) => {
    const b = path.basename(fp);
    if (['Packages', 'Release', 'InRelease', 'Release.gpg'].includes(b)) res.type('text/plain');
    else if (fp.endsWith('.deb')) res.type('application/x-debian-package');
  },
}));

// ---- TEST Repo Sileo/APT tại /test-repo (bản build mới từ CI) ----
// git pull ci-builds vào thư mục test-repo để test bản mới trước khi release chính thức.
const TEST_REPO_DIR = path.join(__dirname, 'test-repo');
app.use('/test-repo', express.static(TEST_REPO_DIR, {
  index: 'index.html',
  setHeaders: (res, fp) => {
    const b = path.basename(fp);
    if (['Packages', 'Release', 'InRelease', 'Release.gpg'].includes(b)) res.type('text/plain');
    else if (fp.endsWith('.deb')) res.type('application/x-debian-package');
  },
}));

// ---- Kho TẢI & CẬP NHẬT tool desktop TĨNH tại /tool/<slug>/ (mở rộng nhiều tool nhỏ) ----
// Mỗi tool 1 thư mục web-license/tool/<slug>/ gồm:
//   • latest.json         — manifest cập nhật (version, notes, portable{url,sha256,size}, mandatory)
//   • <Tên>-<ver>-portable.exe — bản build (đặt tên có version)
//   • index.html          — trang tải cho người dùng (tuỳ chọn)
// Client (Electron) auto-update: GET /tool/<slug>/latest.json → so version → tải portable.url.
// Sinh/ cập nhật bằng tool/publish_tool.py (tính sha256 + ghi latest.json).
const TOOL_DIR = path.join(__dirname, 'tool');

// Link tải ỔN ĐỊNH (không đổi theo version): 302 sang exe hiện hành đọc từ latest.json.
// Dùng cho nút tải trên trang & chia sẻ cho khách: https://iosautos.com/tool/<slug>/download
app.get('/tool/:slug/download', wrap(async (req, res) => {
  const slug = normalizeSlug(req.params.slug);
  const fs = require('fs');
  let manifest = null;
  try { manifest = JSON.parse(fs.readFileSync(path.join(TOOL_DIR, slug, 'latest.json'), 'utf8')); } catch (_) {}
  const p = manifest && manifest.portable;
  if (!p || !p.file) return res.status(404).sendFile(path.join(PUB, '404.html'));
  // Chuyển tới file theo đường dẫn tương đối (giữ trong phạm vi /tool/<slug>/).
  res.redirect(302, `/tool/${slug}/${encodeURIComponent(p.file)}`);
}));

app.use('/tool', express.static(TOOL_DIR, {
  index: 'index.html',
  setHeaders: (res, fp) => {
    const b = path.basename(fp);
    // Manifest luôn tươi: không cache (client phải thấy version mới ngay).
    if (b === 'latest.json' || b === 'index.json') { res.type('application/json'); res.set('Cache-Control', 'no-cache'); }
    // Binary có version trong tên → bất biến, cache dài.
    else if (fp.endsWith('.exe')) { res.type('application/octet-stream'); res.set('Cache-Control', 'public, max-age=31536000, immutable'); }
  },
}));

// URL "sạch": chặn truy cập trực tiếp *.html của trang → chuyển về route gọn.
const cleanUrl = (from, to) => app.get(from, (req, res) => res.redirect(301, to));
cleanUrl('/index.html', '/');
cleanUrl('/login.html', '/login');
cleanUrl('/dashboard.html', '/dashboard');
cleanUrl('/orders.html', '/orders');
cleanUrl('/license.html', '/license');
cleanUrl('/setting.html', '/setting');

// --- Admin (/281admin ...) — GÁC TOÀN BỘ prefix bằng cookie: không phải admin → 404 ---
app.use(ADMIN_BASE, adminGate); // chặn TRƯỚC khi phục vụ bất kỳ HTML/JS admin nào
app.get(ADMIN_BASE + '/index.html', (req, res) => res.redirect(301, ADMIN_BASE));
app.get(ADMIN_BASE, page('Admin', 'index.html'));
app.get(ADMIN_BASE + '/tools', page('Admin', 'tools.html'));
app.get(ADMIN_BASE + '/licenses', page('Admin', 'licenses.html'));
app.get(ADMIN_BASE + '/user', page('Admin', 'user.html'));
app.use(ADMIN_BASE, express.static(path.join(PUB, 'Admin'), { index: false }));

// --- User (domain/...) ---
app.get('/', page('User', 'index.html'));         // trang giới thiệu
app.get('/login', page('User', 'login.html'));    // đăng nhập / đăng ký
app.get('/dashboard', page('User', 'dashboard.html'));
app.get('/orders', page('User', 'orders.html'));
app.get('/license', page('User', 'license.html'));
app.get('/setting', page('User', 'setting.html'));
app.use(express.static(path.join(PUB, 'User'), { index: false })); // chỉ phục vụ *.js

// --- 404 dùng chung (đặt CUỐI, sau mọi route/static) ---
app.use((req, res) => {
  if (req.path.startsWith('/api/')) return res.status(404).json({ ok: false, msg: 'Không tìm thấy' });
  res.status(404).sendFile(path.join(PUB, '404.html'));
});

// =================== Seed admin & start ===================
async function seedAdmin() {
  const email = String(process.env.ADMIN_EMAIL || '').toLowerCase().trim();
  const pw = process.env.ADMIN_PASSWORD || '';
  if (!email || !pw) {
    // Luồng khuyến nghị: đăng ký tài khoản bình thường rồi nâng role='admin' trong Supabase.
    // (Đặt ADMIN_EMAIL/ADMIN_PASSWORD nếu muốn tự tạo admin lúc khởi động.)
    return;
  }
  const existing = await users.byEmail(email);
  if (existing) {
    if (existing.role !== 'admin') console.warn(`⚠️  ${email} tồn tại nhưng KHÔNG phải admin.`);
    return;
  }
  await users.create({ email, passwordHash: hashPassword(pw), role: 'admin', name: 'Admin' });
  console.log(`✅ Đã tạo tài khoản admin: ${email}`);
}

seedAdmin()
  .catch((e) => console.error('Seed admin lỗi:', e.message))
  .finally(() => {
    app.listen(PORT, () => console.log(`iOSAuto license server → http://0.0.0.0:${PORT}`));
  });
