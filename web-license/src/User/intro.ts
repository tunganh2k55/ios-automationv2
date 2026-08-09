// Trang giới thiệu (/) — render TOÀN BỘ bằng TypeScript vào #app.
// Góc trên phải: Đăng nhập / Tạo tài khoản (hoặc Dashboard nếu đã đăng nhập).
import { Auth, esc } from '../shared/api';

const app = document.getElementById('app')!;

interface Feature { icon: string; title: string; desc: string; }
const FEATURES: Feature[] = [
  { icon: '⌁', title: 'Tự động chạm & vuốt', desc: 'Mô phỏng thao tác cảm ứng chính xác, lặp lại kịch bản không cần trông máy.' },
  { icon: '{ }', title: 'Chạy script Lua', desc: 'Viết kịch bản tự động hoá linh hoạt, chạy trực tiếp trên thiết bị.' },
  { icon: '◐', title: 'Đổi Dark Mode toàn máy', desc: 'Bật/tắt giao diện tối cấp hệ thống theo lịch hoặc độ sáng môi trường.' },
  { icon: '🔑', title: 'Cấp phép theo serial', desc: 'Mỗi license khóa vào Machine ID; verify online mỗi lần chạy để chống dùng chung.' },
];

interface Step { n: string; title: string; desc: string; }
const STEPS: Step[] = [
  { n: '01', title: 'Mua gói', desc: 'Chọn tool & thời hạn, nhận license key ngay.' },
  { n: '02', title: 'Kích hoạt serial', desc: 'Nhập Machine ID của thiết bị để khóa key vào đúng máy.' },
  { n: '03', title: 'Verify online', desc: 'Tool gọi máy chủ mỗi lần chạy; sai hạn/sai máy là khoá.' },
  { n: '04', title: 'Quản lý', desc: 'Xem key, gia hạn; admin thu hồi hoặc cấp thêm bất cứ lúc nào.' },
];

function authButtons(): string {
  if (Auth.token && Auth.user) {
    return `<a class="navbtn" href="/dashboard">Dashboard</a>
      <button class="navbtn" id="logout">Đăng xuất</button>`;
  }
  return `<a class="navbtn" href="/login">Đăng nhập</a>
    <a class="navbtn primary" href="/login?tab=register">Tạo tài khoản</a>`;
}

function featureCard(f: Feature): string {
  return `<div class="tool">
    <div class="pill mono" style="margin-bottom:10px">${esc(f.icon)}</div>
    <h3>${esc(f.title)}</h3>
    <div class="desc">${esc(f.desc)}</div>
  </div>`;
}

function stepCard(s: Step): string {
  return `<div class="tool">
    <div class="mono" style="color:var(--accent);font-weight:700;margin-bottom:8px">${esc(s.n)}</div>
    <h3 style="font-size:16px">${esc(s.title)}</h3>
    <div class="desc">${esc(s.desc)}</div>
  </div>`;
}

function render(): void {
  app.innerHTML = `
    <nav class="nav">
      <div class="inner">
        <a class="brand" href="/"><img class="logo" src="/assets/logo.png" alt="iOSAuto"> iOSAuto</a>
        <div class="spacer"></div>
        <div class="navauth" id="navAuth">${authButtons()}</div>
      </div>
    </nav>

    <div class="wrap">
      <section class="hero">
        <img class="hero-logo" src="/assets/logo.png" alt="iOSAuto">
        <div class="pill eyebrow">iOS Automation · License</div>
        <h1>Tự động hoá iPhone của bạn — và cấp phép gọn gàng.</h1>
        <p class="lead">iOSAuto điều khiển chạm/vuốt, chạy kịch bản Lua và đổi giao diện hệ thống;
          đồng thời bán &amp; kích hoạt bản quyền cho từng thiết bị qua một cổng duy nhất.</p>
      </section>

      <div class="section-title">Tính năng chính</div>
      <div class="grid">${FEATURES.map(featureCard).join('')}</div>

      <div class="section-title">Cách hoạt động</div>
      <div class="grid">${STEPS.map(stepCard).join('')}</div>
    </div>

    <div class="foot">iOSAuto License · trang demo — thanh toán &amp; số liệu chỉ mang tính minh hoạ.</div>
  `;

  const lo = document.getElementById('logout');
  if (lo) lo.onclick = () => { Auth.logout(); render(); };
}

render();
