// Dashboard = CỬA HÀNG (wizard): chọn license → chọn gói → thanh toán.
// Đơn chờ thanh toán hiện ở panel góc phải kèm đồng hồ đếm ngược 15 phút.
import { Auth, api, $, $$, esc, fmtVND, fmtDate, toast, ensureAuth, Tool, Plan } from '../shared/api';

let TOOLS: Tool[] = [];
let selTool: Tool | null = null;
let selPlan: string | null = null;
let poll = 0, cd = 0, ttlMs = 15 * 60 * 1000;
let payActivated = false; // user có nhập serial khi mua? (để biết đã tính hạn hay chưa)

// Đếm số serial (mỗi dòng không trống = 1 serial)
function countSerials(): number {
  const val = ($('#mid') as HTMLTextAreaElement).value;
  const lines = val.split(/\r?\n/).map(l => l.trim()).filter(l => l.length > 0);
  return Math.max(1, lines.length); // tối thiểu 1 máy
}

// Cập nhật hiển thị giá dựa trên số serial
function updatePriceCalc() {
  const calcEl = $('#priceCalc');
  if (!selTool || !selPlan) { calcEl.textContent = ''; return; }
  const plan = selTool.plans.find(p => p.id === selPlan);
  if (!plan) { calcEl.textContent = ''; return; }

  const qty = countSerials();
  const total = plan.price * qty;
  const midVal = ($('#mid') as HTMLTextAreaElement).value.trim();

  if (midVal.length === 0) {
    calcEl.innerHTML = `<b>Tổng: ${fmtVND(plan.price)}</b> (1 máy)`;
  } else if (qty === 1) {
    calcEl.innerHTML = `<b>Tổng: ${fmtVND(plan.price)}</b> (1 máy)`;
  } else {
    calcEl.innerHTML = `<b>Tổng: ${fmtVND(total)}</b> (${qty} máy × ${fmtVND(plan.price)})`;
  }
}

(async function () {
  const user = await ensureAuth();
  if (!user) return;
  $('#who').innerHTML = `Xin chào, <b>${esc(user.name || user.email)}</b>`;
  ($('#logout') as HTMLButtonElement).onclick = () => { Auth.logout(); location.replace('/'); };
  ($('#pdClose') as HTMLButtonElement).onclick = closeDrawer;
  ($('#drawerBack') as HTMLElement).onclick = closeDrawer;
  ($('#payBtn') as HTMLButtonElement).onclick = pay;
  // Cập nhật giá khi nhập serial
  ($('#mid') as HTMLTextAreaElement).oninput = updatePriceCalc;
  loadTools();
})();

// ---------- Bước 1: chọn license ----------
async function loadTools() {
  const box = $('#tools');
  try {
    const r = await api('/api/tools');
    TOOLS = r.tools || [];
    if (!TOOLS.length) { box.innerHTML = '<div class="sub">Chưa có tool nào được bán.</div>'; return; }
    box.innerHTML = '';
    TOOLS.forEach((t) => {
      const c = document.createElement('button');
      c.className = 'tool-pick';
      c.type = 'button';
      c.dataset.id = t.id;
      const from = t.plans.length ? Math.min(...t.plans.map((p) => p.price | 0)) : 0;
      c.innerHTML = `
        <div class="tp-top"><span class="tp-name">${esc(t.name)}</span><span class="pill">${esc(t.slug)}</span></div>
        <div class="tp-desc">${esc(t.description)}</div>
        <div class="tp-from">${t.plans.length ? 'Từ ' + fmtVND(from) : '—'}</div>
        <span class="tp-check">✓</span>`;
      c.onclick = () => selectTool(t.id);
      box.appendChild(c);
    });
  } catch (e) { const m = $('#storeMsg'); m.className = 'msg bad'; m.textContent = (e as Error).message; }
}

function selectTool(id: string) {
  selTool = TOOLS.find((t) => t.id === id) || null;
  selPlan = null;
  $$('.tool-pick').forEach((el) => el.classList.toggle('sel', (el as HTMLElement).dataset.id === id));
  if (!selTool) return;

  $('#planStep').classList.remove('is-locked');
  $('#planFor').innerHTML = `License đang chọn: <b>${esc(selTool.name)}</b>`;
  ($('#buyErr')).textContent = '';

  const plansBox = $('#plans');
  plansBox.innerHTML = '';
  selTool.plans.forEach((p: Plan) => {
    const pe = document.createElement('button');
    pe.className = 'plan';
    pe.type = 'button';
    pe.dataset.id = p.id;
    pe.innerHTML = `<div class="pname">${esc(p.label)}</div>
      <div class="price">${fmtVND(p.price)}</div>
      <div class="dur">${p.days ? p.days + ' ngày' : 'Vĩnh viễn'}</div>`;
    pe.onclick = () => {
      selPlan = p.id;
      $$('.plan', plansBox).forEach((x) => x.classList.remove('sel'));
      pe.classList.add('sel');
      ($('#payBtn') as HTMLButtonElement).disabled = false;
      updatePriceCalc();
    };
    plansBox.appendChild(pe);
  });
  ($('#payBtn') as HTMLButtonElement).disabled = true;
  $('#planStep').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
}

// ---------- Bước 3: thanh toán ----------
async function pay() {
  if (!selTool || !selPlan) return;
  const btn = $('#payBtn') as HTMLButtonElement;
  ($('#buyErr')).textContent = '';
  btn.disabled = true;
  const midVal = ($('#mid') as HTMLInputElement).value.trim();
  const noteVal = ($('#note') as HTMLTextAreaElement).value.trim(); // chú thích (tuỳ chọn)
  payActivated = midVal.length > 0; // có serial → key được kích hoạt & tính hạn ngay
  try {
    const r = await api('/api/orders', { method: 'POST',
      body: { toolId: selTool.id, plan: selPlan, machineId: midVal, note: noteVal } });
    if (r.status === 'paid') { showPaidDrawer(r.code, r.key, r.expiresAt, r.keys); return; }  // gói miễn phí
    showPendingDrawer(r);
  } catch (e) { ($('#buyErr')).textContent = (e as Error).message; } finally { btn.disabled = false; }
}

// ---------- Panel thanh toán (góc phải) ----------
function openDrawer() {
  $('#drawerBack').removeAttribute('hidden');
  $('#payDrawer').removeAttribute('hidden');
  requestAnimationFrame(() => $('#payDrawer').classList.add('open'));
}
function closeDrawer() {
  stopTimers();
  $('#payDrawer').classList.remove('open');
  setTimeout(() => { $('#payDrawer').setAttribute('hidden', ''); $('#drawerBack').setAttribute('hidden', ''); }, 260);
}
function stopTimers() { clearInterval(poll); clearInterval(cd); }

function payRows(r: any): string {
  const row = (k: string, v: string, mono = false) =>
    `<div class="kv"><span class="k">${k}</span><span class="v${mono ? ' mono' : ''}">${esc(v)}</span></div>`;
  const qty = r.quantity || 1;
  const qtyNote = qty > 1 ? ` (${qty} máy)` : '';
  return row('Ngân hàng', r.bank?.bankId || '') +
    row('Số tài khoản', r.bank?.account || '', true) +
    (r.bank?.accountName ? row('Chủ TK', r.bank.accountName) : '') +
    row('Số tiền', fmtVND(r.amount) + qtyNote, true) +
    row('Nội dung CK', r.transferContent, true);
}

function showPendingDrawer(r: any) {
  stopTimers();
  $('#pdResult').setAttribute('hidden', '');
  $('#pdPending').removeAttribute('hidden');
  $('#pdCode').textContent = r.code;
  ($('#pdQr') as HTMLImageElement).src = r.qrUrl;
  $('#pdKv').innerHTML = payRows(r);
  $('#pdStatus').innerHTML = '⏳ Đang chờ thanh toán…';
  openDrawer();
  startCountdown(r.expiresAt);
  startPoll(r.code);
}

// Đồng hồ đếm ngược tới hạn (expiresAt = tạo đơn + 15 phút).
function startCountdown(expiresAt?: string | null) {
  const timer = $('#pdTimer'), bar = $('#pdBar') as HTMLElement;
  const deadline = expiresAt ? Date.parse(expiresAt) : 0;
  const total = ttlMs;
  const tick = () => {
    const ms = deadline - Date.now();
    if (!deadline || ms <= 0) { clearInterval(cd); onExpired(); return; }
    const s = Math.floor(ms / 1000);
    timer.textContent = String(Math.floor(s / 60)).padStart(2, '0') + ':' + String(s % 60).padStart(2, '0');
    bar.style.width = Math.max(0, Math.min(100, (ms / total) * 100)) + '%';
    timer.classList.toggle('urgent', ms <= 60_000); // 1 phút cuối → đỏ
  };
  tick();
  cd = setInterval(tick, 1000) as unknown as number;
}

function startPoll(code: string) {
  const tick = async () => {
    try {
      const s = await api('/api/orders/' + encodeURIComponent(code));
      if (s.status === 'paid' && s.key) { stopTimers(); showPaidDrawer(code, s.key, s.expiresAt, s.keys); }
      else if (s.status === 'expired' || s.status === 'canceled') { stopTimers(); onExpired(); }
    } catch { /* mạng chập chờn — thử lại lần sau */ }
  };
  poll = setInterval(tick, 4000) as unknown as number;
}

function onExpired() {
  stopTimers();
  $('#pdTimer').textContent = '00:00';
  $('#pdStatus').innerHTML = '<span style="color:var(--bad)">Đơn đã hết hạn (quá 15 phút). Hãy tạo đơn mới.</span>';
}

function showPaidDrawer(code: string, key: string, expiresAt?: string | null, keys?: string[]) {
  stopTimers();
  $('#pdCode').textContent = code;
  $('#pdPending').setAttribute('hidden', '');
  const res = $('#pdResult');
  res.removeAttribute('hidden');

  const allKeys = keys && keys.length > 0 ? keys : [key];
  const keysHtml = allKeys.map(k => `<div class="keybox">${esc(k)}</div>`).join('');
  const keyLabel = allKeys.length > 1 ? `${allKeys.length} License keys của bạn` : 'License key của bạn';

  res.innerHTML = `
    <div class="pay-ok">✓ Thanh toán thành công</div>
    <div class="pay-ok-l">${keyLabel}</div>
    ${keysHtml}
    <div class="msg exp">Hạn: ${expiresAt ? fmtDate(expiresAt) : (payActivated ? 'Vĩnh viễn' : 'Tính từ khi bạn kích hoạt key')}</div>
    <button class="mini" id="pdCopy">Sao chép ${allKeys.length > 1 ? 'tất cả keys' : 'key'}</button>
    <a class="linkbtn" href="/license" style="display:inline-block;margin-top:12px">Tới License của tôi →</a>`;
  ($('#pdCopy') as HTMLButtonElement).onclick = async () => {
    try { await navigator.clipboard.writeText(allKeys.join('\n')); toast('Đã sao chép ' + allKeys.length + ' key(s)', 'ok'); } catch { toast('Không sao chép được', 'bad'); }
  };
  openDrawer();
  toast(`Đã cấp ${allKeys.length} license thành công`, 'ok');
}
