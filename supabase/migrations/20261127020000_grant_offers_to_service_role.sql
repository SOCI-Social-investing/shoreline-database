-- 20261127010000_add_offers created offers and company_offers without granting
-- service_role anything. This project doesn't grant new public tables to
-- service_role automatically, so every backend read and write failed with
-- "permission denied" — signup skipped the offer (by design, it never blocks
-- signup on an offer error) and GET /api/offers/current returned 500.
--
-- Same explicit grants as subscription_invoices and payouts. anon and
-- authenticated stay revoked: both tables are backend-only.

grant select, insert, update, delete on public.offers to service_role;
grant select, insert, update, delete on public.company_offers to service_role;
