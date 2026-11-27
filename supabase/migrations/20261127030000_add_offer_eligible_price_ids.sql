-- Offers name the exact Stripe prices they apply to.
--
-- Checkout used to decide eligibility by turning the price into a plan tier with
-- the backend's ESSENTIAL_/PROFESSIONAL_PLAN_PRICE_IDS settings. Staging didn't
-- list its prices there, so every offer checkout was refused as "plan not
-- eligible". Listing the prices on the offer row removes that dependency and is
-- more precise: each environment's row already holds its own Stripe coupon id,
-- and now also its own price ids.
--
-- Checkout applies an offer only when the chosen price is in eligible_price_ids
-- AND Stripe reports it billing on one of eligible_terms. eligible_plans and
-- eligible_terms otherwise only drive the banner's fine print.
--
-- Existing rows get an empty list (applies to nothing) until they are updated:
--   update public.offers set eligible_price_ids = '{price_…,price_…}' where code = '…';

alter table public.offers
  add column eligible_price_ids text[] not null default '{}'::text[];

comment on column public.offers.eligible_price_ids is
  'Stripe price ids (CC account) the offer can discount. Empty = none. See 20261127030000.';

NOTIFY pgrst, 'reload schema';
