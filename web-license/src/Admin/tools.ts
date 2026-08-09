// Admin · Tools: tạo/sửa/ẩn tool + đặt gói giá. Cần role admin.
import { Auth, api, $, esc, ensureAuth, Tool, Plan } from '../shared/api';

let cache: Tool[] = [];
let editingId: string | null = null;
let defaultPlans: Plan[] = [];

(async function () {
  const user = await ensureAuth({ admin: true });
  if (!user) return;
  $('#who').innerHTML = `<b>${esc(user.email)}</b> · admin`;
  ($('#logout') as HTMLButtonElement).onclick = () => { Auth.logout(); location.replace('/'); };
  load();
})();

async function load() {
  try {
    const r = await api('/api/admin/tools');
    cache = r.tools; defaultPlans = r.defaultPlans || [];
    const ta = $('#tPlans') as HTMLTextAreaElement;
    if (!ta.value) ta.value = JSON.stringify(defaultPlans, null, 2);
    renderTable();
  } catch (e) { const m = $('#msg'); m.className = 'msg bad'; m.textContent = (e as Error).message; }
}

function renderTable() {
  const tb = $('#body');
  tb.innerHTML = cache.length ? '' : '<tr><td colspan="5" class="sub">Chưa có tool.</td></tr>';
  cache.forEach((t) => {
    const tr = document.createElement('tr');
    tr.innerHTML = `<td>${esc(t.name)}</td><td><span class="pill">${esc(t.slug)}</span></td>
      <td>${t.plans.length} gói</td>
      <td><span class="badge ${t.active ? 'active' : 'revoked'}">${t.active ? 'Đang bán' : 'Ẩn'}</span></td>
      <td style="white-space:nowrap">
        <button class="mini" data-edit="${t.id}">Sửa</button>
        <button class="mini" data-toggle="${t.id}">${t.active ? 'Ẩn' : 'Bán'}</button>
      </td>`;
    tb.appendChild(tr);
  });
}

($('#save') as HTMLButtonElement).onclick = async () => {
  const m = $('#msg'); m.textContent = '';
  let plans: Plan[];
  try { plans = JSON.parse(($('#tPlans') as HTMLTextAreaElement).value || '[]'); }
  catch { m.className = 'msg bad'; m.textContent = 'JSON gói không hợp lệ'; return; }
  const name = ($('#tName') as HTMLInputElement).value;
  const slug = ($('#tSlug') as HTMLInputElement).value;
  const description = ($('#tDesc') as HTMLInputElement).value;
  try {
    if (editingId) await api('/api/admin/tools/' + editingId, { method: 'PATCH', body: { name, description, plans } });
    else await api('/api/admin/tools', { method: 'POST', body: { name, slug, description, plans } });
    m.className = 'msg ok'; m.textContent = 'Đã lưu.';
    resetForm(); load();
  } catch (e) { m.className = 'msg bad'; m.textContent = (e as Error).message; }
};

function resetForm() {
  editingId = null;
  $('#formTitle').textContent = 'Tạo tool mới';
  ($('#tName') as HTMLInputElement).value = '';
  ($('#tSlug') as HTMLInputElement).value = '';
  ($('#tDesc') as HTMLInputElement).value = '';
  ($('#tPlans') as HTMLTextAreaElement).value = JSON.stringify(defaultPlans, null, 2);
  ($('#tSlug') as HTMLInputElement).disabled = false;
}
($('#reset') as HTMLElement).onclick = (e) => { e.preventDefault(); resetForm(); };

document.addEventListener('click', async (e) => {
  const el = e.target as HTMLElement;
  const edit = el.getAttribute('data-edit');
  const toggle = el.getAttribute('data-toggle');
  if (edit) {
    const t = cache.find((x) => x.id === edit); if (!t) return;
    editingId = t.id;
    $('#formTitle').textContent = 'Sửa tool: ' + t.name;
    ($('#tName') as HTMLInputElement).value = t.name;
    ($('#tSlug') as HTMLInputElement).value = t.slug;
    ($('#tSlug') as HTMLInputElement).disabled = true;
    ($('#tDesc') as HTMLInputElement).value = t.description;
    ($('#tPlans') as HTMLTextAreaElement).value = JSON.stringify(t.plans, null, 2);
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }
  if (toggle) {
    const t = cache.find((x) => x.id === toggle); if (!t) return;
    await api('/api/admin/tools/' + t.id, { method: 'PATCH', body: { active: !t.active } });
    load();
  }
});
