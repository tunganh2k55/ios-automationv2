// Tạo QR từ nội dung license + modal xem/quét. Dùng chung User & Admin.
// QR sinh 100% phía client (không gửi key ra ngoài) → an toàn.
import qrcode from 'qrcode-generator';
import { $, toast, esc, licenseExpiry, License } from './api';

// Byte mode + UTF-8 để hỗ trợ tên tool tiếng Việt.
(qrcode as any).stringToBytes = (qrcode as any).stringToBytesFuncs['UTF-8'];

// Sinh QR (mức sửa lỗi M, tự chọn version) → chuỗi SVG scalable.
export function qrSvg(text: string): string {
  const qr = qrcode(0, 'M');
  qr.addData(text);
  qr.make();
  return qr.createSvgTag({ scalable: true, margin: 2 });
}

// Gộp thông tin license thành nội dung dễ đọc khi quét.
export function licenseText(l: License): string {
  return [
    'iOSAuto License',
    `Tool: ${l.toolName || l.toolSlug || '—'}`,
    `Key: ${l.key}`,
    `Gói: ${l.plan}`,
    `Serial: ${l.machineId || '(chưa kích hoạt)'}`,
    `Trạng thái: ${l.status}`,
    `Hạn: ${licenseExpiry(l)}`,
  ].join('\n');
}

// Hiện modal QR ở giữa màn hình.
export function showQrModal(title: string, content: string): void {
  const back = document.createElement('div');
  back.className = 'qr-back';
  back.innerHTML = `
    <div class="qr-modal" role="dialog" aria-modal="true" aria-label="${esc(title)}">
      <button class="qr-close" aria-label="Đóng">&times;</button>
      <h3 class="qr-title">${esc(title)}</h3>
      <div class="qr-img"></div>
      <pre class="qr-text"></pre>
      <button class="mini qr-copy">Sao chép nội dung</button>
    </div>`;
  $('.qr-img', back).innerHTML = qrSvg(content);
  $('.qr-text', back).textContent = content;

  const close = () => { document.removeEventListener('keydown', onKey); back.remove(); };
  const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') close(); };
  back.addEventListener('click', (e) => { if (e.target === back) close(); });
  ($('.qr-close', back) as HTMLButtonElement).onclick = close;
  ($('.qr-copy', back) as HTMLButtonElement).onclick = async () => {
    try { await navigator.clipboard.writeText(content); toast('Đã sao chép nội dung', 'ok'); }
    catch { toast('Không sao chép được', 'bad'); }
  };
  document.addEventListener('keydown', onKey);
  document.body.appendChild(back);
}

// Tiện dụng: mở QR cho 1 license.
export function showLicenseQr(l: License): void {
  showQrModal(`QR license · ${l.toolName || l.toolSlug || l.key}`, licenseText(l));
}
