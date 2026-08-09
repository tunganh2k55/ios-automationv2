// Trang /orders: lịch sử đơn hàng của user (chờ thanh toán / đã thanh toán / hết hạn).
// Đơn chờ thanh toán hiển thị đếm ngược 15 phút; quá giờ server tự chuyển 'expired'.
import { Auth, api, $, $$, esc, fmtVND, fmtDate, orderBadge, ensureAuth } from '../shared/api';

(async function () {
  const user = await ensureAuth();
  if (!user) return;
  $('#who').innerHTML = `Xin chào, <b>${esc(user.name || user.email)}</b>`;
  ($('#logout') as HTMLButtonElement).onclick = () => { Auth.logout(); location.replace('/'); };
  loadOrders();
  setInterval(tickCountdowns, 1000);
})();

async function loadOrders() {
  const tb = $('#orderBody');
  try {
    const r = await api('/api/me/orders');
    const list: any[] = r.orders || [];

    // Đếm theo nhóm trạng thái cho tiles.
    const c = { pending: 0, paid: 0, expired: 0 };
    list.forEach((o) => {
      if (o.status === 'pending') c.pending++;
      else if (o.status === 'paid') c.paid++;
      else c.expired++; // expired | canceled
    });
    $('#orderTiles').innerHTML = [
      ['pending', c.pending, 'Chờ thanh toán'],
      ['paid',    c.paid,    'Đã thanh toán'],
      ['expired', c.expired, 'Hết hạn / huỷ'],
    ].map(([, n, label]) => `<div class="tile"><div class="n">${n}</div><div class="l">${label}</div></div>`).join('');

    tb.innerHTML = '';
    if (!list.length) {
      tb.innerHTML = `<tr><td colspan="7" class="sub">Chưa có đơn hàng nào. Vào <a href="/dashboard">Cửa hàng</a> để mua license.</td></tr>`;
      return;
    }
    list.forEach((o) => {
      // Cột "Còn lại": chỉ đơn pending mới đếm ngược; các đơn khác để '—'.
      const remain = (o.status === 'pending' && o.expiresAt)
        ? `<span class="cd" data-exp="${esc(o.expiresAt)}">--:--</span>`
        : '—';
      const tr = document.createElement('tr');
      tr.innerHTML = `<td class="key">${esc(o.code)}</td>
        <td>${esc(o.toolName || o.toolSlug || '—')}</td>
        <td>${esc(o.plan)}</td>
        <td>${fmtVND(o.amount)}</td>
        <td>${orderBadge(o.status)}</td>
        <td>${fmtDate(o.createdAt)}</td>
        <td>${remain}</td>`;
      tb.appendChild(tr);
    });
    tickCountdowns();
  } catch (e) { const m = $('#orderMsg'); m.className = 'msg bad'; m.textContent = (e as Error).message; }
}

// Cập nhật các đếm ngược mỗi giây; khi đơn nào hết giờ → tải lại để lấy trạng thái mới từ server.
let reloading = false;
function tickCountdowns() {
  let expiredNow = false;
  $$('.cd[data-exp]').forEach((sp) => {
    const ms = Date.parse(sp.getAttribute('data-exp')!) - Date.now();
    if (ms <= 0) {
      sp.removeAttribute('data-exp');
      sp.textContent = 'đang cập nhật…';
      expiredNow = true;
    } else {
      const s = Math.floor(ms / 1000);
      sp.textContent = String(Math.floor(s / 60)).padStart(2, '0') + ':' + String(s % 60).padStart(2, '0');
    }
  });
  if (expiredNow && !reloading) {
    reloading = true;
    // Server đã đánh dấu 'expired' trong /api/me/orders → tải lại là thấy trạng thái đúng.
    loadOrders().finally(() => { reloading = false; });
  }
}
