// deviceguard — CHẤM ĐIỂM tín hiệu toàn vẹn thiết bị (phát hiện spoof / hook / jailbreak).
//   Đây là logic PHÁT HIỆN (defensive), KHÔNG thực hiện spoof.
//   Client (app iosauto) tự thu tín hiệu runtime rồi POST lên /api/device/check;
//   server đối chiếu chéo và trả verdict để app/server quyết định chặn hay cảnh báo.
//
// Nguyên lý: một "sự thật" phần cứng được suy ra từ nhiều nguồn độc lập. Nếu model
// khai báo (hw.machine) mâu thuẫn với RAM/màn hình thật, hoặc phát hiện hàm hệ thống
// bị hook / có /var/jb → khả năng cao đang chạy trên môi trường bị can thiệp.

'use strict';

// Bảng tham chiếu tối thiểu: model (hw.machine) → { memGB kỳ vọng, tập độ phân giải native hợp lệ }.
// Chỉ dùng để đối chiếu khi model NẰM trong bảng; model lạ → bỏ qua (không phạt oan).
// nativeW/H theo UIScreen.nativeBounds (pixel thật). Cho phép hoán đổi ngang/dọc.
const MODEL_TABLE = {
  'iPhone12,1': { memGB: 4, screens: [[828, 1792]] },   // iPhone 11
  'iPhone13,1': { memGB: 4, screens: [[1080, 2340]] },  // iPhone 12 mini
  'iPhone13,2': { memGB: 4, screens: [[1170, 2532]] },  // iPhone 12
  'iPhone13,3': { memGB: 6, screens: [[1170, 2532]] },  // iPhone 12 Pro
  'iPhone13,4': { memGB: 6, screens: [[1284, 2778]] },  // iPhone 12 Pro Max
  'iPhone14,5': { memGB: 4, screens: [[1170, 2532]] },  // iPhone 13
  'iPhone14,2': { memGB: 6, screens: [[1170, 2532]] },  // iPhone 13 Pro
  'iPhone14,3': { memGB: 6, screens: [[1284, 2778]] },  // iPhone 13 Pro Max
  'iPhone14,7': { memGB: 6, screens: [[1170, 2532]] },  // iPhone 14
  'iPhone15,2': { memGB: 6, screens: [[1179, 2556]] },  // iPhone 14 Pro
  'iPhone15,3': { memGB: 6, screens: [[1290, 2796]] },  // iPhone 14 Pro Max
  'iPhone15,4': { memGB: 6, screens: [[1179, 2556]] },  // iPhone 15
  'iPhone15,5': { memGB: 6, screens: [[1290, 2796]] },  // iPhone 15 Plus
  'iPhone16,1': { memGB: 8, screens: [[1179, 2556]] },  // iPhone 15 Pro
  'iPhone16,2': { memGB: 8, screens: [[1290, 2796]] },  // iPhone 15 Pro Max
};

// RAM khai báo (bytes) → GB làm tròn tới mốc phổ biến (3/4/6/8) để so bảng.
function memBytesToGB(bytes) {
  const gb = Number(bytes) / (1024 * 1024 * 1024);
  if (!isFinite(gb) || gb <= 0) return 0;
  // iOS report hw.memsize hơi thấp hơn mốc thương mại (vd ~5.7 cho 6GB) → làm tròn lên gần nhất.
  for (const m of [2, 3, 4, 6, 8, 12, 16]) if (gb <= m + 0.4) return m;
  return Math.round(gb);
}

function screenMatches(table, w, h) {
  if (!w || !h) return true; // thiếu dữ liệu → không phạt
  return table.screens.some(([sw, sh]) =>
    (Math.abs(sw - w) <= 2 && Math.abs(sh - h) <= 2) ||
    (Math.abs(sw - h) <= 2 && Math.abs(sh - w) <= 2)); // cho phép xoay
}

// Đánh giá 1 bộ tín hiệu → { verdict, score, flags[] }.
//   signals = {
//     model, memBytes, iosVersion,
//     screen: { w, h, scale },
//     jailbreak: { varJb, canWriteRoot, suspiciousPaths:[..] },
//     hooks:     { sysctl, uiscreen, nsbundle, foundation },  // true = phát hiện trampoline lạ
//     dyldImages: <số ảnh dyld lạ ngoài hệ thống>,
//   }
// score: 0 (sạch) … 100+. verdict: clean (<20) | suspicious (20–49) | spoof_or_tampered (>=50).
function evaluate(signals = {}) {
  const flags = [];
  let score = 0;
  const add = (pts, code, detail) => { score += pts; flags.push({ code, weight: pts, detail }); };

  // 1) Jailbreak — bản thân không phải spoof, nhưng là tiền đề để spoof và là cờ rủi ro mạnh.
  const jb = signals.jailbreak || {};
  if (jb.varJb) add(35, 'jailbreak_varjb', 'Phát hiện /var/jb (rootless jailbreak)');
  if (jb.canWriteRoot) add(25, 'jailbreak_rootwrite', 'Ghi được vùng hệ thống chỉ-đọc');
  if (Array.isArray(jb.suspiciousPaths) && jb.suspiciousPaths.length)
    add(15, 'jailbreak_paths', `Đường dẫn nghi vấn: ${jb.suspiciousPaths.slice(0, 5).join(', ')}`);

  // 2) Hook — chính là kỹ thuật spoof: hàm đọc thông tin thiết bị bị trỏ ra ngoài vùng dyld chuẩn.
  const hk = signals.hooks || {};
  const hooked = ['sysctl', 'uiscreen', 'nsbundle', 'foundation'].filter((k) => hk[k]);
  if (hooked.length) add(50, 'api_hook', `Hàm bị hook: ${hooked.join(', ')}`);
  if (Number(signals.dyldImages) > 0)
    add(20, 'dyld_injection', `${signals.dyldImages} ảnh dyld lạ được nạp`);

  // 3) Consistency — model khai báo có khớp RAM/màn hình thật không (chỉ khi model có trong bảng).
  const model = String(signals.model || '').trim();
  const t = MODEL_TABLE[model];
  if (model && t) {
    const gb = memBytesToGB(signals.memBytes);
    if (gb && gb !== t.memGB)
      add(30, 'mem_mismatch', `Model ${model} kỳ vọng ${t.memGB}GB nhưng báo ${gb}GB`);
    const s = signals.screen || {};
    if (!screenMatches(t, Number(s.w), Number(s.h)))
      add(30, 'screen_mismatch', `Độ phân giải ${s.w}x${s.h} không khớp ${model}`);
  } else if (model && /^iPhone\d/.test(model)) {
    flags.push({ code: 'model_unknown', weight: 0, detail: `Model ${model} chưa có trong bảng — bỏ qua đối chiếu` });
  } else if (model) {
    add(15, 'model_malformed', `hw.machine bất thường: "${model.slice(0, 32)}"`);
  }

  const verdict = score >= 50 ? 'spoof_or_tampered' : score >= 20 ? 'suspicious' : 'clean';
  return { verdict, score, flags };
}

module.exports = { evaluate, memBytesToGB, MODEL_TABLE };
