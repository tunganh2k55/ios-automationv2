-- Migration 002 — bảng tools (mỗi tool/app cho thuê, có gói giá riêng)
-- Dán vào Supabase → SQL Editor → Run.

create table if not exists public.tools (
  id          uuid primary key default gen_random_uuid(),
  slug        text unique not null,             -- vd: iosauto, tool-abc
  name        text not null,
  description text default '',
  plans       jsonb not null default '[]'::jsonb,  -- [{id,label,days,price}]
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

alter table public.tools enable row level security;
