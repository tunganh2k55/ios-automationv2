// Trang /login: đăng nhập / đăng ký. Thành công → /dashboard.
import { Auth, api, toast, $, $$ } from '../shared/api';

if (Auth.token) location.replace('/dashboard');

function switchTab(t: string) {
  $$('[data-atab]').forEach((x) => x.classList.toggle('on', (x as HTMLElement).dataset.atab === t));
  $$('[data-apane]').forEach((p) => p.classList.toggle('hidden', (p as HTMLElement).dataset.apane !== t));
  $('#authErr').textContent = '';
}

$$('[data-atab]').forEach((b) => (b as HTMLElement).onclick = () => switchTab((b as HTMLElement).dataset.atab!));

// Mở đúng tab theo ?tab=register
if (new URLSearchParams(location.search).get('tab') === 'register') switchTab('register');

async function doAuth(pathname: string, body: unknown) {
  $('#authErr').textContent = '';
  try {
    const r = await api(pathname, { method: 'POST', body });
    Auth.token = r.token; Auth.user = r.user;
    toast('Đăng nhập thành công', 'ok');
    setTimeout(() => location.replace('/dashboard'), 600);
  } catch (e) {
    const msg = (e as Error).message;
    $('#authErr').textContent = msg;
    toast(msg || 'Đăng nhập thất bại', 'bad');
  }
}

($('#loginForm') as HTMLFormElement).onsubmit = (e) => { e.preventDefault();
  doAuth('/api/auth/login', { email: ($('#lEmail') as HTMLInputElement).value, password: ($('#lPass') as HTMLInputElement).value }); };
($('#registerForm') as HTMLFormElement).onsubmit = (e) => { e.preventDefault();
  doAuth('/api/auth/register', {
    name: ($('#rName') as HTMLInputElement).value,
    email: ($('#rEmail') as HTMLInputElement).value,
    password: ($('#rPass') as HTMLInputElement).value }); };
