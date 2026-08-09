-- Migration 007 — thêm cột `generation` cho licenses (Nhóm 1: grant Ed25519).
-- Dán vào Supabase → SQL Editor → Run. CHẠY SAU 003.
--
-- generation = "thế hệ" của license. Server nhét giá trị hiện tại vào payload grant khi ký.
-- Khi THU HỒI / đổi gói / đổi thiết bị / ép cấp lại → tăng generation lên 1.
-- Grant cũ (TTL 20') mang generation nhỏ hơn sẽ tự hết hiệu lực trong ≤20 phút vì lần
-- refresh kế tiếp server cấp grant mới với generation mới (client chỉ giữ grant mới nhất).
-- HIỆU LỰC THẬT nằm ở server: mỗi lần cấp grant server đọc generation hiện tại từ DB.

alter table public.licenses
  add column if not exists generation integer not null default 0;
