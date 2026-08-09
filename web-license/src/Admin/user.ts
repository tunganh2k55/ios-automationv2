// Admin · Users: danh sách người dùng. Cần role admin.
import { Auth, api, $, esc, fmtDate, fmtVND, ensureAuth } from '../shared/api';

interface UserStats {
  paid: number; orders: number;
  licTotal: number; licPending: number; licActive: number; licExpired: number;
}

(async function () {
  const user = await ensureAuth({ admin: true });
  if (!user) return;
  $('#who').innerHTML = `<b>${esc(user.email)}</b> · admin`;
  ($('#logout') as HTMLButtonElement).onclick = () => { Auth.logout(); location.replace('/'); };
  load();
})();

async function load() {
  try {
    const r = await api('/api/admin/users');
    const tb = $('#body');
    tb.innerHTML = r.users.length ? '' : '<tr><td colspan="6" class="sub">Chưa có user.</td></tr>';
    r.users.forEach((u: any) => {
      const s: UserStats = u.stats || { paid: 0, orders: 0, licTotal: 0, licPending: 0, licActive: 0, licExpired: 0 };
      const tr = document.createElement('tr');
      tr.innerHTML = `<td>${esc(u.email)}</td><td>${esc(u.name || '')}</td>
        <td><span class="badge ${u.role === 'admin' ? 'admin' : 'pending'}">${esc(u.role)}</span></td>
        <td><b>${s.paid ? fmtVND(s.paid) : '—'}</b>${s.orders ? ` <span class="sub">· ${s.orders} đơn</span>` : ''}</td>
        <td>${licenseCell(s)}</td>
        <td>${fmtDate(u.createdAt)}</td>`;
      tb.appendChild(tr);
    });
    $('#count').textContent = r.users.length + ' user';
  } catch (e) { console.error(e); }
}

// Ô license: tổng + phân loại (chưa kích hoạt / còn hạn / hết hạn) bằng badge màu.
function licenseCell(s: UserStats): string {
  if (!s.licTotal) return '<span class="sub">—</span>';
  const parts: string[] = [];
  if (s.licActive) parts.push(`<span class="badge active" title="Đã kích hoạt còn hạn">${s.licActive} còn hạn</span>`);
  if (s.licPending) parts.push(`<span class="badge pending" title="Chưa kích hoạt">${s.licPending} chưa KH</span>`);
  if (s.licExpired) parts.push(`<span class="badge expired" title="Đã kích hoạt hết hạn">${s.licExpired} hết hạn</span>`);
  return `<b>${s.licTotal}</b> <span class="sub">·</span> ${parts.join(' ')}`;
}
