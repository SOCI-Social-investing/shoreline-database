-- ---------------------------------------------------------------------------------
-- Offers: time-limited discounts on the Shoreline plan fee, given to Companies
-- that sign up through an offer link (/signup-step1?offer=<code>).
-- See docs/adr/0002-offers-are-data-and-apply-a-coupon-directly.md.
--
--   offers          one row per campaign. Adding a campaign is an INSERT — no
--                   code change or deploy. Staging and production each hold their
--                   own row with their own Stripe coupon id.
--   company_offers  a Company's claim on an offer, made at signup, and its
--                   redemption (set by the subscription webhook). One claim per
--                   Company per offer; a claim can be redeemed once.
--
-- Checkout applies offers.stripe_coupon_id directly. There is deliberately no
-- Stripe promotion code: customers could type one into any checkout (including
-- yearly), and a 3-month coupon on a yearly invoice frees the whole year. The
-- "new customers only" rule is enforced here instead — only a Company that
-- claimed the offer at signup can redeem it.
--
-- Both tables are backend-only (service role), like every other table since
-- 20261006000000: RLS on, no policies, no anon/authenticated grants.
-- ---------------------------------------------------------------------------------

BEGIN;

create table public.offers (
  id uuid primary key default gen_random_uuid(),
  -- What appears in the link. Lowercase so ?offer=HOLIDAY26 and holiday26 match.
  code text not null unique
    check (code ~ '^[a-z0-9][a-z0-9-]{1,39}$'),
  -- Coupon on the CC (subscriptions) Stripe account. Its own settings decide the
  -- discount itself (percent, months, applies_to products, redeem_by).
  stripe_coupon_id text not null,
  eligible_plans public.plan_name_enum[] not null
    check (cardinality(eligible_plans) > 0),
  eligible_terms public.billing_term[] not null default array['Monthly']::public.billing_term[]
    check (cardinality(eligible_terms) > 0),
  starts_at timestamptz not null default now(),
  -- First instant the offer is no longer honoured (exclusive).
  ends_at timestamptz not null,
  -- Banner copy on "Choose your plan". eyebrow: small label ("Holiday offer");
  -- title: the figure ("3 months free"); body: one short sentence.
  banner_eyebrow text not null check (length(trim(banner_eyebrow)) > 0),
  banner_title text not null check (length(trim(banner_title)) > 0),
  banner_body text not null check (length(trim(banner_body)) > 0),
  -- Kill switch: false stops new claims and redemptions immediately.
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint offers_ends_after_starts check (ends_at > starts_at)
);

comment on table public.offers is
  'Signup offers (discounts on the plan fee). One row per campaign; see docs/adr/0002.';

create table public.company_offers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  -- RESTRICT: an offer that has been claimed is history; switch it off with
  -- is_active instead of deleting it.
  offer_id uuid not null references public.offers (id) on delete restrict,
  claimed_at timestamptz not null default now(),
  redeemed_at timestamptz,
  stripe_subscription_id text,
  constraint company_offers_company_offer_key unique (company_id, offer_id),
  constraint company_offers_redemption_complete
    check ((redeemed_at is null) = (stripe_subscription_id is null))
);

comment on table public.company_offers is
  'A Company''s claim on an offer (at signup) and its redemption (at subscription). See docs/adr/0002.';

-- company_id is covered by the unique constraint's index; offer_id needs its own
-- for "who used this offer" reporting and the RESTRICT check.
create index company_offers_offer_id_idx on public.company_offers (offer_id);

alter table public.offers enable row level security;
alter table public.company_offers enable row level security;
revoke all on public.offers from anon, authenticated;
revoke all on public.company_offers from anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ---------------------------------------------------------------------------------
-- Seeding a campaign (per environment — coupon ids differ). holiday26:
--   insert into public.offers
--     (code, stripe_coupon_id, eligible_plans, eligible_terms, ends_at,
--      banner_eyebrow, banner_title, banner_body)
--   values ('holiday26', '<coupon id>', '{Essential,Professional}', '{Monthly}',
--           '2027-01-01T05:00:00Z', 'Holiday offer', '3 months free', '<one sentence>');
-- ---------------------------------------------------------------------------------
