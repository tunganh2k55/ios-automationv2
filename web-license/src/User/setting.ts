// Trang /setting: xem thông tin, đổi tên, đổi mật khẩu. Cần đăng nhập.
import { Auth, api, $, esc, fmtDate, ensureAuth } from '../shared/api';

(async function () {
  const user = await ensureAuth();
  if (!user) return;
  $('#who').innerHTML = `<b>${esc(user.email)}</b>`;
  ($('#logout') as HTMLButtonElement).onclick = () => { Auth.logout(); location.replace('/'); };
  $('#acEmail').textContent = user.email;
  $('#acRole').textContent = user.role;
  $('#acCreated').textContent = fmtDate(user.createdAt);
  ($('#pName') as HTMLInputElement).value = user.name || '';
})();

($('#saveName') as HTMLButtonElement).onclick = async () => {
  const m = $('#nameMsg'); m.textContent = '';
  try {
    const r = await api('/api/me/profile', { method: 'POST', body: { name: ($('#pName') as HTMLInputElement).value } });
    Auth.user = r.user;
    m.className = 'msg ok'; m.textContent = 'Đã lưu tên.';
  } catch (e) { m.className = 'msg bad'; m.textContent = (e as Error).message; }
};

($('#savePass') as HTMLButtonElement).onclick = async () => {
  const m = $('#passMsg'); m.textContent = '';
  try {
    await api('/api/me/password', { method: 'POST', body: {
      oldPassword: ($('#oldPass') as HTMLInputElement).value,
      newPassword: ($('#newPass') as HTMLInputElement).value } });
    m.className = 'msg ok'; m.textContent = 'Đã đổi mật khẩu.';
    ($('#oldPass') as HTMLInputElement).value = ''; ($('#newPass') as HTMLInputElement).value = '';
  } catch (e) { m.className = 'msg bad'; m.textContent = (e as Error).message; }
};
