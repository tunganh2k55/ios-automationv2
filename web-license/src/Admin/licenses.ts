// Admin · Licenses: cấp key, kích hoạt theo serial, lọc, thu hồi/gia hạn. Cần role admin.
import { Auth, api, $, esc, licenseExpiry, statusBadge, ensureAuth, Tool } from '../shared/api';
import { showLicenseQr } from '../shared/qr';

let tools: Tool[] = [];

(async function () {
  const user = await ensureAuth({ admin: true });
  if (!user) return;
  $('#who').innerHTML = `<b>${esc(user.email)}</b> · admin`;
  ($('#logout') as HTMLButtonElement).onclick = () => { Auth.logout(); location.replace('/'); };
  await loadTools();
  loadList();
})();

async function loadTools() {
  const r = await api('/api/admin/tools');
  tools = r.tools;
  const opts = tools.map((t) => `<option value="${t.id}">${esc(t.name)} (${esc(t.slug)})</option>`).join('');
  $('#iTool').innerHTML = opts;
  $('#fTool').innerHTML = '<option value="">— Tất cả tool —</option>' + opts;
  fillPlans();
}
function fillPlans() {
  const t = tools.find((x) => x.id === ($('#iTool') as HTMLSelectElement).value);
  $('#iPlan').innerHTML = (t ? t.plans : []).map((p) => `<option value="${p.id}">${esc(p.label)}</option>`).join('');
}
($('#iTool') as HTMLSelectElement).onchange = fillPlans;
($('#fTool') as HTMLSelectElement).onchange = loadList;

async function loadList() {
  try {
    const q = ($('#fTool') as HTMLSelectElement).value ? '?tool=' + encodeURIComponent(($('#fTool') as HTMLSelectElement).value) : '';
    const r = await api('/api/admin/licenses' + q);
    const tb = $('#body');
    tb.innerHTML = r.licenses.length ? '' : '<tr><td colspan="9" class="sub">Chưa có license.</td></tr>';
    r.licenses.forEach((l: any) => {
      const tr = document.createElement('tr');
      tr.innerHTML = `<td class="key">${l.key}</td><td>${esc(l.toolSlug || '')}</td>
        <td>${esc(l.userEmail || '—')}</td><td>${esc(l.machineId || '—')}</td><td>${esc(l.plan)}</td>
        <td>${statusBadge(l)}</td><td>${licenseExpiry(l)}</td><td class="note">${esc(l.note || '')}</td>
        <td style="white-space:nowrap">
          <button class="mini qr">QR</button>
          <button class="mini" data-ext="${l.key}">+30d</button>
          <button class="mini danger" data-rev="${l.key}">Thu hồi</button>
        </td>`;
      ($('.qr', tr) as HTMLButtonElement).onclick = () => showLicenseQr(l);
      tb.appendChild(tr);
    });
    $('#count').textContent = r.licenses.length + ' key';
  } catch (e) { console.error(e); }
}

($('#iBtn') as HTMLButtonElement).onclick = async () => {
  const m = $('#iMsg'); m.textContent = '';
  try {
    const r = await api('/api/admin/issue', { method: 'POST', body: {
      toolId: ($('#iTool') as HTMLSelectElement).value, plan: ($('#iPlan') as HTMLSelectElement).value,
      userEmail: ($('#iEmail') as HTMLInputElement).value, machineId: ($('#iMid') as HTMLInputElement).value,
      note: ($('#iNote') as HTMLInputElement).value } });
    m.className = 'msg ok'; m.textContent = 'Đã cấp: ' + r.license.key;
    ($('#iMid') as HTMLInputElement).value = ''; ($('#iNote') as HTMLInputElement).value = ''; ($('#iEmail') as HTMLInputElement).value = '';
    loadList();
  } catch (e) { m.className = 'msg bad'; m.textContent = (e as Error).message; }
};

($('#aBtn') as HTMLButtonElement).onclick = async () => {
  const m = $('#aMsg'); m.textContent = '';
  try {
    await api('/api/admin/activate', { method: 'POST', body: {
      key: ($('#aKey') as HTMLInputElement).value, machineId: ($('#aMid') as HTMLInputElement).value } });
    m.className = 'msg ok'; m.textContent = 'Đã kích hoạt.';
    ($('#aKey') as HTMLInputElement).value = ''; ($('#aMid') as HTMLInputElement).value = ''; loadList();
  } catch (e) { m.className = 'msg bad'; m.textContent = (e as Error).message; }
};

document.addEventListener('click', async (e) => {
  const el = e.target as HTMLElement;
  const rev = el.getAttribute('data-rev');
  const ext = el.getAttribute('data-ext');
  if (rev && confirm('Thu hồi key ' + rev + '?')) {
    await api('/api/admin/revoke', { method: 'POST', body: { key: rev } }); loadList();
  }
  if (ext) {
    await api('/api/admin/extend', { method: 'POST', body: { key: ext, days: 30 } }); loadList();
  }
});
