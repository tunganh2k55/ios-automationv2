-- Migration 003 — bảng licenses (gắn tool + user, kích hoạt theo serial)
-- Dán vào Supabase → SQL Editor → Run. CHẠY SAU 001 & 002 (vì có khoá ngoại).

create table if not exists public.licenses (
  key         text primary key,
  tool_id     uuid references public.tools(id) on delete set null,
  tool_slug   text,                             -- denormalize cho verify/hiển thị
  tool_name   text,
  user_id     uuid references public.users(id) on delete set null,
  user_email  text,
  machine_id  text,                             -- serial; null = chưa kích hoạt
  plan        text not null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz,                      -- null = vĩnh viễn
  status      text not null default 'active',   -- active | revoked
  paid        text not null default 'mock',     -- mock | admin | <cổng thanh toán>
  note        text default ''
);

create index if not exists licenses_user_idx    on public.licenses (user_id);
create index if not exists licenses_tool_idx     on public.licenses (tool_id);
create index if not exists licenses_machine_idx  on public.licenses (machine_id);
create index if not exists licenses_created_idx  on public.licenses (created_at desc);

alter table public.licenses enable row level security;
