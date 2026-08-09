// Tiện ích dùng chung cho cả User & Admin (được bundle vào từng trang).
export const ADMIN_BASE = '/281admin';

export interface User { id: string; email: string; role: string; name?: string; createdAt?: string; }
export interface Plan { id: string; label: string; days: number | null; price: number; }
export interface Tool { id: string; slug: string; name: string; description: string; plans: Plan[]; active?: boolean; }
export interface License {
  key: string; toolSlug?: string; toolName?: string; userEmail?: string;
  machineId?: string | null; plan: string; expiresAt?: string | null; status: string;
  note?: string; customerNote?: string;
}

export const Auth = {
  get token(): string { return localStorage.getItem('ia_token') || ''; },
  set token(t: string) { t ? localStorage.setItem('ia_token', t) : localStorage.removeItem('ia_token'); },
  get user(): User | null { try { return JSON.parse(localStorage.getItem('ia_user') || 'null'); } catch { return null; } },
  set user(u: User | null) { u ? localStorage.setItem('ia_user', JSON.stringify(u)) : localStorage.removeItem('ia_user'); },
  logout() {
    // Xoá cookie gác trang phía server (best-effort) + xoá localStorage.
    try { fetch('/api/auth/logout', { method: 'POST' }); } catch { /* bỏ qua */ }
    this.token = ''; this.user = null;
  },
};

// Gọi API JSON. Ném Error(msg) nếu !ok. Tự đính Bearer token.
export async function api(pathname: string, opts: { method?: string; body?: unknown } = {}): Promise<any> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (Auth.token) headers.Authorization = 'Bearer ' + Auth.token;
  const res = await fetch(pathname, {
    method: opts.method || 'GET', headers,
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  let data: any = {};
  try { data = await res.json(); } catch { /* body rỗng */ }
  if (res.status === 401 && Auth.token) Auth.logout();
  if (!res.ok || data.ok === false) throw new Error(data.msg || `Lỗi ${res.status}`);
  return data;
}

// Thông báo nổi góc phải: xanh (ok) khi thành công, đỏ (bad) khi thất bại.
export function toast(msg: string, type: 'ok' | 'bad' = 'ok', ms = 3200): void {
  let box = document.getElementById('toastBox');
  if (!box) {
    box = document.createElement('div');
    box.id = 'toastBox';
    box.className = 'toast-box';
    document.body.appendChild(box);
  }
  const el = document.createElement('div');
  el.className = `toast ${type}`;
  el.textContent = msg;
  box.appendChild(el);
  requestAnimationFrame(() => el.classList.add('show'));
  const kill = () => { el.classList.remove('show'); setTimeout(() => el.remove(), 260); };
  el.onclick = kill;
  setTimeout(kill, ms);
}

export const $ = <T extends Element = HTMLElement>(s: string, r: ParentNode = document) => r.querySelector<T>(s)!;
export const $$ = <T extends Element = HTMLElement>(s: string, r: ParentNode = document) => Array.from(r.querySelectorAll<T>(s));
export const fmtVND = (n?: number) => (n ? Number(n).toLocaleString('vi-VN') + '₫' : 'Miễn phí');
// Luôn hiển thị theo GIỜ VIỆT NAM (UTC+7) bất kể timezone trình duyệt người xem.
export const fmtDate = (iso?: string | null) =>
  (iso ? new Date(iso).toLocaleDateString('vi-VN', { timeZone: 'Asia/Ho_Chi_Minh' }) : 'Vĩnh viễn');
// Hạn của license theo trạng thái kích hoạt:
//   • chưa kích hoạt (không machineId) → "Chưa kích hoạt" (hạn tính từ lúc kích hoạt)
//   • đã kích hoạt → ngày hết hạn, hoặc "Vĩnh viễn" nếu gói không giới hạn.
export const licenseExpiry = (l: { machineId?: string | null; expiresAt?: string | null }) =>
  l.machineId ? fmtDate(l.expiresAt) : 'Chưa kích hoạt';
export const esc = (s: unknown) => String(s == null ? '' : s)
  .replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c] as string));

// Badge trạng thái đơn hàng (mua qua chuyển khoản).
export function orderBadge(status: string): string {
  const map: Record<string, [string, string]> = {
    pending: ['pending', 'Chờ thanh toán'],
    paid: ['active', 'Đã thanh toán'],
    expired: ['expired', 'Đã hết hạn'],
    canceled: ['revoked', 'Đã huỷ'],
  };
  const [cls, label] = map[status] || ['pending', status];
  return `<span class="badge ${cls}">${label}</span>`;
}

export function statusBadge(l: License): string {
  let s = l.status;
  if (s === 'active' && !l.machineId) return `<span class="badge pending">Chưa kích hoạt</span>`;
  if (s === 'active' && l.expiresAt && Date.now() > Date.parse(l.expiresAt)) s = 'expired';
  const label: Record<string, string> = { active: 'Hiệu lực', revoked: 'Đã thu hồi', expired: 'Hết hạn' };
  return `<span class="badge ${s}">${label[s] || s}</span>`;
}

// Guard trang: đảm bảo đã đăng nhập (và tuỳ chọn phải admin).
//   • Chưa đăng nhập  → /login (chung cho cả user & admin).
//   • Đã đăng nhập nhưng KHÔNG phải admin (khi trang cần admin) → /dashboard.
export async function ensureAuth(opts: { admin?: boolean } = {}): Promise<User | null> {
  if (!Auth.token) { location.replace('/login'); return null; }
  try {
    const r = await api('/api/auth/me');
    Auth.user = r.user;
    if (opts.admin && r.user.role !== 'admin') { location.replace('/dashboard'); return null; }
    return r.user;
  } catch { Auth.logout(); location.replace('/login'); return null; }
}
