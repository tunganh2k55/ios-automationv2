-- Migration 005 — bảng orders (mua license qua chuyển khoản, web2m webhook xác nhận)
-- Dán vào Supabase → SQL Editor → Run. CHẠY SAU 001 & 002 (khoá ngoại tools/users).

create table if not exists public.orders (
  id           uuid primary key default gen_random_uuid(),
  code         text unique not null,             -- nội dung chuyển khoản để đối soát (vd IA7K3M9QAB)
  tool_id      uuid references public.tools(id) on delete set null,
  tool_slug    text,
  tool_name    text,
  user_id      uuid references public.users(id) on delete set null,
  user_email   text,
  plan         text not null,
  amount       integer not null,                 -- số tiền VND cần chuyển
  machine_id   text,                             -- serial (tuỳ chọn, gắn vào license khi cấp)
  status       text not null default 'pending',  -- pending | paid | expired | canceled
  license_key  text,                             -- key cấp ra khi paid
  provider     text default 'web2m',
  tx_ref       text,                             -- mã giao dịch ngân hàng (chống xử lý trùng)
  raw          jsonb,                            -- payload webhook khớp (debug/đối soát)
  created_at   timestamptz not null default now(),
  paid_at      timestamptz,
  expires_at   timestamptz                       -- hạn thanh toán (hết hạn → pending chuyển expired)
);

create index if not exists orders_status_idx  on public.orders (status);
create index if not exists orders_user_idx    on public.orders (user_id);
create index if not exists orders_created_idx  on public.orders (created_at desc);
-- 1 giao dịch ngân hàng chỉ xử lý 1 lần.
create unique index if not exists orders_txref_uidx on public.orders (tx_ref) where tx_ref is not null;

alter table public.orders enable row level security;
