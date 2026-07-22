-- supabase/migrations/008_stripe_customers.sql
--
-- Maps our user_id to a Stripe Customer object so Checkout and the Billing
-- Portal reuse one Customer per user instead of creating a new one every
-- time. Service-role only -- the client never queries this table directly.

create table if not exists stripe_customers (
  user_id uuid primary key references auth.users(id) on delete cascade,
  stripe_customer_id text not null unique,
  created_at timestamptz not null default now()
);

alter table stripe_customers enable row level security;
