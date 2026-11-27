-- Deleting a company failed with:
--   update or delete on table "companies" violates foreign key constraint
--   "topups_company_id_fkey" on table "topups"
--
-- topups was the only company-owned table whose company FK had no ON DELETE
-- rule (invoices, plans, team_members, contributions, cashback_* all CASCADE).
-- Its team member FK had none either, so a top-up whose team member is removed
-- by the company cascade (but whose own company_id is NULL or different) would
-- block the delete the same way. Both now cascade.
--
-- Nothing else is lost by cascading: subscription_invoices.topup_id already
-- uses ON DELETE SET NULL, so billing history keeps its rows.
--
-- NOT VALID + VALIDATE keeps the lock short: the swap itself doesn't scan the
-- table, and VALIDATE only takes a SHARE UPDATE EXCLUSIVE lock.

alter table public.topups
  drop constraint if exists topups_company_id_fkey,
  add constraint topups_company_id_fkey
    foreign key (company_id) references public.companies (id)
    on delete cascade not valid;

alter table public.topups validate constraint topups_company_id_fkey;

alter table public.topups
  drop constraint if exists topups_team_member_id_fkey,
  add constraint topups_team_member_id_fkey
    -- team_members' PK is `id` (renamed in 20260622190000); the child column
    -- keeps the name team_member_id.
    foreign key (team_member_id) references public.team_members (id)
    on delete cascade not valid;

alter table public.topups validate constraint topups_team_member_id_fkey;
