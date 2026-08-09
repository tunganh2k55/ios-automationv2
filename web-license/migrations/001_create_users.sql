-- Migration 001 — bảng users
-- Dán TOÀN BỘ file này vào Supabase → SQL Editor → Run.
-- (Chạy lại nhiều lần vẫn an toàn nhờ "if not exists".)

create table if not exists public.users (
  id            uuid primary key default gen_random_uuid(),
  email         text unique not null,
  password_hash text not null,
  name          text default '',
  role          text not null default 'user',   -- user | admin
  created_at    timestamptz not null default now()
);

-- Server dùng service_role key (bỏ qua RLS). Bật RLS để chặn anon key.
alter table public.users enable row level security;
