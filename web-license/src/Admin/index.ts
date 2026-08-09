// Admin home (/281admin): tổng quan. KHÔNG có form đăng nhập —
// admin đăng nhập ở /login như user, rồi tự truy cập link này.
import { Auth, api, $, esc, ensureAuth } from '../shared/api';

(async function () {
  const user = await ensureAuth({ admin: true }); // chưa login → /login; không phải admin → /dashboard
  if (!user) return;
  $('#who').innerHTML = `<b>${esc(user.email)}</b> · admin`;
  ($('#logout') as HTMLButtonElement).onclick = () => { Auth.logout(); location.replace('/'); };
  try {
    const [t, l, u] = await Promise.all([
      api('/api/admin/tools'), api('/api/admin/licenses'), api('/api/admin/users'),
    ]);
    $('#cTools').textContent = t.tools.length;
    $('#cLicenses').textContent = l.licenses.length;
    $('#cUsers').textContent = u.users.length;
  } catch (e) { console.error(e); }
})();
