-- Migration 004 — phân biệt "app mẹ" (iosauto) với "tool con" bên trong.
-- Mô hình: 1 license cho APP + mỗi TOOL con 1 license riêng.
-- Dán vào Supabase → SQL Editor → Run. An toàn chạy lại (if not exists).

-- kind: 'app' = ứng dụng mẹ (vd iosauto) | 'tool' = tool con bên trong app.
alter table public.tools add column if not exists kind text not null default 'tool';

-- parent_slug: tool con thuộc app nào (lưu SLUG của app mẹ). App mẹ để null.
alter table public.tools add column if not exists parent_slug text;

create index if not exists tools_kind_idx   on public.tools (kind);
create index if not exists tools_parent_idx on public.tools (parent_slug);

-- (Tuỳ chọn) Nếu đã tạo sẵn tool 'iosauto' và muốn đánh dấu nó là app mẹ:
--   update public.tools set kind = 'app' where slug = 'iosauto';
-- Và gán các tool con về app iosauto:
--   update public.tools set parent_slug = 'iosauto' where slug in ('ocr','tap','video');
