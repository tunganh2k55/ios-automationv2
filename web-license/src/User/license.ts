// Trang /license: người dùng quản lý license của mình (kích hoạt, lọc theo trạng thái).
// Nếu không có key nào đang dùng (chưa kích hoạt / còn hạn) → hiện nút "Mua License" giữa bảng → về /dashboard.
import { Auth, api, $, $$, esc, licenseExpiry, statusBadge, ensureAuth } from '../shared/api';
import { showLicenseQr } from '../shared/qr';

// License APP iOSAuto được kích hoạt bằng CÁCH QUÉT QR vào app → chỉ app này còn nút QR.
// Tool nhỏ kích hoạt theo serial (không quét QR) → không hiện QR. Khớp APP_SLUG của daemon.
const APP_SLUG = 'iosauto';
const isAppLicense = (l: any) => String(l.toolSlug || '').toLowerCase() === APP_SLUG;

(async function () {
  const user = await ensureAuth();
  if (!user) return;
  $('#who').innerHTML = `Xin chào, <b>${esc(user.name || user.email)}</b>`;
  ($('#logout') as HTMLButtonElement).onclick = () => { Auth.logout(); location.replace('/'); };
  loadMine();
})();

// Trạng thái 1 license → nhóm để lọc theo tab.
//   pending = chưa kích hoạt · valid = đã active còn hạn · expired = đã active hết hạn · revoked = thu hồi
type LicState = 'pending' | 'valid' | 'expired' | 'revoked';
function licState(l: any): LicState {
  if (l.status === 'revoked') return 'revoked';
  if (!l.machineId) return 'pending';
  if (l.expiresAt && Date.now() > Date.parse(l.expiresAt)) return 'expired';
  return 'valid';
}

let MINE: any[] = [];          // toàn bộ license của user (cache)
let FILTER = 'all';            // tab đang chọn: all | pending | valid | expired

async function loadMine() {
  try {
    const r = await api('/api/me/licenses');
    MINE = r.licenses || [];
    renderMine();
  } catch (e) { const m = $('#mineMsg'); m.className = 'msg bad'; m.textContent = (e as Error).message; }
}

function renderMine() {
  // Đếm theo trạng thái (cho tiles + nhãn tab).
  const c = { all: MINE.length, pending: 0, valid: 0, expired: 0, revoked: 0 };
  MINE.forEach((l) => { c[licState(l)]++; });

  // Tiles tổng quan.
  const tiles = $('#mineTiles');
  tiles.innerHTML = [
    ['pending', c.pending, 'Chưa kích hoạt'],
    ['valid',   c.valid,   'Đang hiệu lực'],
    ['expired', c.expired, 'Hết hạn'],
  ].map(([, n, label]) => `<div class="tile"><div class="n">${n}</div><div class="l">${label}</div></div>`).join('');

  // Nhãn tab kèm số lượng.
  $$('#mineTabs .tab').forEach((t) => {
    const f = t.getAttribute('data-f') as keyof typeof c;
    const base = { all: 'Tất cả', pending: 'Chưa kích hoạt', valid: 'Đang hiệu lực', expired: 'Hết hạn', revoked: 'Đã thu hồi' }[f] || f;
    t.textContent = `${base} (${c[f] ?? 0})`;
    t.classList.toggle('on', f === FILTER);
  });

  const tb = $('#mineBody');
  tb.innerHTML = '';

  // Không có key nào đang dùng (chưa kích hoạt hoặc còn hạn) → CTA mua license giữa bảng.
  const usable = c.pending + c.valid;
  if (usable === 0) {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td colspan="8">
      <div class="empty-cta">
        <div class="ttl">Bạn chưa có license nào đang sử dụng</div>
        <div class="sub">${MINE.length ? 'Các key hiện có đã hết hạn hoặc bị thu hồi.' : 'Mua một license để bắt đầu.'}</div>
        <button class="primary" id="buyCta">Mua License</button>
      </div></td>`;
    tb.appendChild(tr);
    ($('#buyCta', tb) as HTMLButtonElement).onclick = () => location.assign('/dashboard');
    return;
  }

  // Bảng đã lọc.
  const rows = FILTER === 'all' ? MINE : MINE.filter((l) => licState(l) === FILTER);
  if (!rows.length) {
    tb.innerHTML = `<tr><td colspan="8" class="sub">Không có key nào ở trạng thái này.</td></tr>`;
    return;
  }
  rows.forEach((l: any) => {
    const tr = document.createElement('tr');
    const act = (l.status === 'active' && !l.machineId)
      ? `<button class="mini" data-act="${l.key}">Kích hoạt</button>` : '';
    tr.innerHTML = `<td>${esc(l.toolName || l.toolSlug)}</td><td class="key">${l.key}</td>
      <td>${esc(l.plan)}</td><td>${esc(l.machineId || '—')}</td>
      <td>${statusBadge(l)}</td><td>${licenseExpiry(l)}</td>
      <td class="note">${l.customerNote ? esc(l.customerNote) : '—'}</td>
      <td class="rowacts">${act}${isAppLicense(l) ? `<button class="mini qr" data-qr="${esc(l.key)}">QR</button>` : ''}</td>`;
    if (isAppLicense(l)) ($('.qr', tr) as HTMLButtonElement).onclick = () => showLicenseQr(l);
    tb.appendChild(tr);
  });
}

// Chuyển tab lọc.
$('#mineTabs').addEventListener('click', (e) => {
  const f = (e.target as HTMLElement).closest('.tab')?.getAttribute('data-f');
  if (!f || f === FILTER) return;
  FILTER = f;
  renderMine();
});

// Kích hoạt key theo serial / Machine ID.
document.addEventListener('click', async (e) => {
  const key = (e.target as HTMLElement).getAttribute('data-act');
  if (!key) return;
  const mid = prompt('Nhập serial / Machine ID của thiết bị để kích hoạt key:\n' + key +
    '\n\n⚠️ Mỗi key chỉ gắn DUY NHẤT 1 máy và KHÔNG thể đổi hay dùng lại trên máy khác sau khi kích hoạt.');
  if (!mid) return;
  try { await api('/api/activate', { method: 'POST', body: { key, machineId: mid } }); loadMine(); }
  catch (err) { alert((err as Error).message); }
});
