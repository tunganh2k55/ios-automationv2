-- Migration 006 — chú thích của khách hàng (customer_note)
--   • Khách nhập ở trang /dashboard khi đặt mua (tuỳ chọn, có thể để trống).
--   • Lưu trên đơn hàng → cấp key thì chép sang license → hiển thị ở /license.
-- Dán vào Supabase → SQL Editor → Run. CHẠY SAU 005.

alter table public.orders    add column if not exists customer_note text default '';
alter table public.licenses  add column if not exists customer_note text default '';
