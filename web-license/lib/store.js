// Truy cập dữ liệu trên Supabase: users · tools · licenses.
const { supabase } = require('./supabase');

const T_USERS = process.env.SUPABASE_USERS_TABLE || 'users';
const T_TOOLS = process.env.SUPABASE_TOOLS_TABLE || 'tools';
const T_LIC = process.env.SUPABASE_TABLE || 'licenses';
const T_ORD = process.env.SUPABASE_ORDERS_TABLE || 'orders';

const normKey = (k) => String(k || '').toUpperCase().trim();
const normEmail = (e) => String(e || '').toLowerCase().trim();

// ---------- Mapping DB(snake) ⇄ app(camel) ----------
function fromUser(r) {
  if (!r) return null;
  return { id: r.id, email: r.email, role: r.role, name: r.name || '', createdAt: r.created_at,
           passwordHash: r.password_hash };
}
const publicUser = (u) => u && { id: u.id, email: u.email, role: u.role, name: u.name, createdAt: u.createdAt };

function fromTool(r) {
  if (!r) return null;
  return { id: r.id, slug: r.slug, name: r.name, description: r.description || '',
           kind: r.kind || 'tool', parentSlug: r.parent_slug || null,
           plans: r.plans || [], active: r.active, createdAt: r.created_at };
}

function fromLic(r) {
  if (!r) return null;
  return {
    key: r.key, toolId: r.tool_id, toolSlug: r.tool_slug, toolName: r.tool_name,
    userId: r.user_id, userEmail: r.user_email, machineId: r.machine_id,
    plan: r.plan, createdAt: r.created_at, expiresAt: r.expires_at,
    status: r.status, paid: r.paid, note: r.note || '', customerNote: r.customer_note || '',
    generation: Number.isFinite(r.generation) ? r.generation : 0,
  };
}
function toLicRow(l) {
  return {
    key: l.key, tool_id: l.toolId, tool_slug: l.toolSlug, tool_name: l.toolName,
    user_id: l.userId || null, user_email: l.userEmail || null, machine_id: l.machineId || null,
    plan: l.plan, created_at: l.createdAt, expires_at: l.expiresAt,
    status: l.status, paid: l.paid, note: l.note || '', customer_note: l.customerNote || '',
  };
}

// ---------- Users ----------
const users = {
  async byEmail(email) {
    const { data, error } = await supabase.from(T_USERS).select('*').eq('email', normEmail(email)).maybeSingle();
    if (error) throw error;
    return fromUser(data);
  },
  async byId(id) {
    const { data, error } = await supabase.from(T_USERS).select('*').eq('id', id).maybeSingle();
    if (error) throw error;
    return fromUser(data);
  },
  async create({ email, passwordHash, role = 'user', name = '' }) {
    const row = { email: normEmail(email), password_hash: passwordHash, role, name };
    const { data, error } = await supabase.from(T_USERS).insert(row).select().single();
    if (error) throw error;
    return fromUser(data);
  },
  async list() {
    const { data, error } = await supabase.from(T_USERS).select('*').order('created_at', { ascending: false });
    if (error) throw error;
    return (data || []).map(fromUser).map(publicUser);
  },
  async updateProfile(id, { name }) {
    const { data, error } = await supabase.from(T_USERS).update({ name }).eq('id', id).select().single();
    if (error) throw error;
    return fromUser(data);
  },
  async updatePassword(id, passwordHash) {
    const { error } = await supabase.from(T_USERS).update({ password_hash: passwordHash }).eq('id', id);
    if (error) throw error;
  },
};

// ---------- Tools ----------
const tools = {
  async list() {
    const { data, error } = await supabase.from(T_TOOLS).select('*').order('created_at', { ascending: false });
    if (error) throw error;
    return (data || []).map(fromTool);
  },
  async listActive() {
    const { data, error } = await supabase.from(T_TOOLS).select('*').eq('active', true).order('created_at');
    if (error) throw error;
    return (data || []).map(fromTool);
  },
  async byId(id) {
    const { data, error } = await supabase.from(T_TOOLS).select('*').eq('id', id).maybeSingle();
    if (error) throw error;
    return fromTool(data);
  },
  async bySlug(slug) {
    const { data, error } = await supabase.from(T_TOOLS).select('*').eq('slug', slug).maybeSingle();
    if (error) throw error;
    return fromTool(data);
  },
  // Các tool con thuộc 1 app mẹ (theo slug của app). Dùng cho verify gộp.
  async listByParent(parentSlug) {
    const { data, error } = await supabase.from(T_TOOLS).select('*')
      .eq('parent_slug', parentSlug).order('created_at');
    if (error) throw error;
    return (data || []).map(fromTool);
  },
  async create({ slug, name, description = '', plans = [], kind = 'tool', parentSlug = null }) {
    const { data, error } = await supabase.from(T_TOOLS)
      .insert({ slug, name, description, plans, kind, parent_slug: parentSlug }).select().single();
    if (error) throw error;
    return fromTool(data);
  },
  async update(id, fields) {
    const patch = {};
    if ('name' in fields) patch.name = fields.name;
    if ('description' in fields) patch.description = fields.description;
    if ('plans' in fields) patch.plans = fields.plans;
    if ('active' in fields) patch.active = fields.active;
    if ('kind' in fields) patch.kind = fields.kind;
    if ('parentSlug' in fields) patch.parent_slug = fields.parentSlug;
    const { data, error } = await supabase.from(T_TOOLS).update(patch).eq('id', id).select().single();
    if (error) throw error;
    return fromTool(data);
  },
};

// ---------- Licenses ----------
const licenses = {
  async byKey(key) {
    const { data, error } = await supabase.from(T_LIC).select('*').eq('key', normKey(key)).maybeSingle();
    if (error) throw error;
    return fromLic(data);
  },
  // Các license đã gắn (bind) 1 máy CHO 1 tool — dùng check theo serial (không cần key).
  // Mới nhất trước; có thể nhiều dòng (gộp/gia hạn), caller tự chọn dòng còn hiệu lực.
  async byMachineTool(toolSlug, machineId) {
    if (!toolSlug || !machineId) return [];
    const { data, error } = await supabase.from(T_LIC).select('*')
      .eq('tool_slug', String(toolSlug)).eq('machine_id', String(machineId))
      .order('created_at', { ascending: false });
    if (error) throw error;
    return (data || []).map(fromLic);
  },
  async listAll({ toolId } = {}) {
    let q = supabase.from(T_LIC).select('*').order('created_at', { ascending: false });
    if (toolId) q = q.eq('tool_id', toolId);
    const { data, error } = await q;
    if (error) throw error;
    return (data || []).map(fromLic);
  },
  async listByUser(userId) {
    const { data, error } = await supabase.from(T_LIC).select('*')
      .eq('user_id', userId).order('created_at', { ascending: false });
    if (error) throw error;
    return (data || []).map(fromLic);
  },
  async insert(lic) {
    const { error } = await supabase.from(T_LIC).insert(toLicRow(lic));
    if (error) throw error;
    return lic;
  },
  async update(key, fields) {
    const patch = {};
    if ('status' in fields) patch.status = fields.status;
    if ('expiresAt' in fields) patch.expires_at = fields.expiresAt;
    if ('machineId' in fields) patch.machine_id = fields.machineId;
    if ('note' in fields) patch.note = fields.note;
    if ('customerNote' in fields) patch.customer_note = fields.customerNote;
    if ('userId' in fields) patch.user_id = fields.userId;
    if ('userEmail' in fields) patch.user_email = fields.userEmail;
    if ('generation' in fields) patch.generation = fields.generation;
    const { error } = await supabase.from(T_LIC).update(patch).eq('key', normKey(key));
    if (error) throw error;
  },
  // Tăng generation lên 1 (thu hồi/đổi gói/đổi thiết bị/ép cấp lại). Read-modify-write —
  // đủ dùng vì đây là thao tác admin, không đồng thời cao. Trả generation mới.
  async bumpGeneration(key) {
    const lic = await this.byKey(key);
    if (!lic) return null;
    const next = (Number.isFinite(lic.generation) ? lic.generation : 0) + 1;
    const { error } = await supabase.from(T_LIC).update({ generation: next }).eq('key', normKey(key));
    if (error) throw error;
    return next;
  },
};

// ---------- Orders (mua license qua chuyển khoản) ----------
function fromOrder(r) {
  if (!r) return null;
  return {
    id: r.id, code: r.code, toolId: r.tool_id, toolSlug: r.tool_slug, toolName: r.tool_name,
    userId: r.user_id, userEmail: r.user_email, plan: r.plan, amount: r.amount,
    machineId: r.machine_id, status: r.status, licenseKey: r.license_key,
    provider: r.provider, txRef: r.tx_ref, createdAt: r.created_at, paidAt: r.paid_at, expiresAt: r.expires_at,
    customerNote: r.customer_note || '',
  };
}
function toOrderRow(o) {
  return {
    code: o.code, tool_id: o.toolId, tool_slug: o.toolSlug, tool_name: o.toolName,
    user_id: o.userId || null, user_email: o.userEmail || null, plan: o.plan, amount: o.amount,
    machine_id: o.machineId || null, status: o.status || 'pending', license_key: o.licenseKey || null,
    provider: o.provider || 'web2m', tx_ref: o.txRef || null, expires_at: o.expiresAt || null,
    customer_note: o.customerNote || '',
  };
}

const orders = {
  async create(o) {
    const { data, error } = await supabase.from(T_ORD).insert(toOrderRow(o)).select().single();
    if (error) throw error;
    return fromOrder(data);
  },
  async byCode(code) {
    const { data, error } = await supabase.from(T_ORD).select('*').eq('code', code).maybeSingle();
    if (error) throw error;
    return fromOrder(data);
  },
  async byTxRef(ref) {
    if (!ref) return null;
    const { data, error } = await supabase.from(T_ORD).select('*').eq('tx_ref', ref).maybeSingle();
    if (error) throw error;
    return fromOrder(data);
  },
  async listByUser(userId) {
    const { data, error } = await supabase.from(T_ORD).select('*')
      .eq('user_id', userId).order('created_at', { ascending: false });
    if (error) throw error;
    return (data || []).map(fromOrder);
  },
  async listAll() {
    const { data, error } = await supabase.from(T_ORD).select('*')
      .order('created_at', { ascending: false });
    if (error) throw error;
    return (data || []).map(fromOrder);
  },
  async update(code, fields) {
    const patch = {};
    if ('status' in fields) patch.status = fields.status;
    if ('licenseKey' in fields) patch.license_key = fields.licenseKey;
    if ('txRef' in fields) patch.tx_ref = fields.txRef;
    if ('paidAt' in fields) patch.paid_at = fields.paidAt;
    if ('raw' in fields) patch.raw = fields.raw;
    const { data, error } = await supabase.from(T_ORD).update(patch).eq('code', code).select().maybeSingle();
    if (error) throw error;
    return fromOrder(data);
  },
};

module.exports = { users, tools, licenses, orders, publicUser };
