// Supabase client dùng chung (service_role → bỏ qua RLS, chỉ chạy ở server).
const { createClient } = require('@supabase/supabase-js');

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_KEY;

if (!URL || !KEY) {
  console.error('❌ Thiếu SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (xem .env.example).');
  process.exit(1);
}

const supabase = createClient(URL, KEY, { auth: { persistSession: false } });

module.exports = { supabase };
