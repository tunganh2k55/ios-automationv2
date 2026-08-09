// Sinh/định dạng license key + chuẩn hoá serial + tính hạn theo gói.
const crypto = require('crypto');

// Serial / Machine ID: chữ HOA, chỉ [A-Z0-9], tối đa 32 (IDFV, serial number…).
function normalizeMachineId(mid) {
  return String(mid || '').toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 32);
}

// Slug tool: chữ thường, [a-z0-9-].
function normalizeSlug(s) {
  return String(s || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);
}

// Bảng chữ bỏ ký tự dễ nhầm (0/O, 1/I…). Key dạng PREFIX-XXXX-XXXX-XXXX.
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
function genKey(prefix = 'LIC') {
  const p = String(prefix || 'LIC').toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 5) || 'LIC';
  const rnd = crypto.randomBytes(12);
  let out = '';
  for (let i = 0; i < 12; i++) {
    out += ALPHABET[rnd[i] % ALPHABET.length];
    if (i % 4 === 3 && i !== 11) out += '-';
  }
  return `${p}-${out}`; // VD: IOSA-XXXX-XXXX-XXXX
}

// --- Mã đơn hàng (dùng làm NỘI DUNG chuyển khoản để đối soát webhook) ---
// Prefix cố định + 8 ký tự [A-Z0-9] → ngắn, sống sót qua nội dung CK ngân hàng.
const ORDER_PREFIX = 'IA';
function genOrderCode() {
  const rnd = crypto.randomBytes(8);
  let s = '';
  for (let i = 0; i < 8; i++) s += ALPHABET[rnd[i] % ALPHABET.length];
  return ORDER_PREFIX + s; // VD: IA7K3M9QAB
}
function normalizeOrderCode(c) {
  return String(c || '').toUpperCase().replace(/[^A-Z0-9]/g, '').slice(0, 20);
}
// Trích mọi mã đơn xuất hiện trong nội dung CK (ngân hàng hay chèn ký tự thừa/hoa).
const ORDER_CODE_RE = new RegExp(ORDER_PREFIX + '[A-Z0-9]{8}', 'g');
function extractOrderCodes(text) {
  const norm = String(text || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
  return norm.match(ORDER_CODE_RE) || [];
}

// Gói mặc định khi tạo tool mới (admin có thể sửa). days=null => vĩnh viễn.
const DEFAULT_PLANS = [
  { id: 'trial',    label: 'Dùng thử 7 ngày', days: 7,    price: 0 },
  { id: '30d',      label: '1 tháng',         days: 30,   price: 150000 },
  { id: '90d',      label: '3 tháng',         days: 90,   price: 400000 },
  { id: '365d',     label: '1 năm',           days: 365,  price: 1200000 },
  { id: 'lifetime', label: 'Vĩnh viễn',       days: null, price: 3000000 },
];

// Chuẩn hoá & kiểm tra một mảng plans (từ admin nhập).
function sanitizePlans(plans) {
  if (!Array.isArray(plans)) return [];
  const seen = new Set();
  const out = [];
  for (const p of plans) {
    const id = String(p && p.id || '').trim().toLowerCase().replace(/[^a-z0-9]+/g, '');
    if (!id || seen.has(id)) continue;
    seen.add(id);
    const days = p.days === null || p.days === '' || p.days === undefined ? null : parseInt(p.days, 10);
    out.push({
      id,
      label: String(p.label || id).slice(0, 60),
      days: Number.isFinite(days) ? days : null,
      price: Math.max(0, parseInt(p.price, 10) || 0),
    });
  }
  return out;
}

function planById(plans, id) {
  return (plans || []).find((p) => p.id === id) || null;
}

// ISO string hạn dùng theo gói của tool; null nếu vĩnh viễn; undefined nếu gói sai.
function expiryFromPlan(plans, planId, now = Date.now()) {
  const p = planById(plans, planId);
  if (!p) return undefined;
  if (p.days == null) return null;
  return new Date(now + p.days * 86400000).toISOString();
}

module.exports = {
  normalizeMachineId, normalizeSlug, genKey,
  genOrderCode, normalizeOrderCode, extractOrderCodes,
  DEFAULT_PLANS, sanitizePlans, planById, expiryFromPlan,
};
