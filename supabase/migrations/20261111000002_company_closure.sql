-- ---------------------------------------------------------------------------------
-- Account closure (OFFBOARDING-SPEC F8, decisions 6 and 8).
--
-- companies.status:
--   active → closure_requested   Client asks; nothing blocks it (no active Team
--                                Members without a termination, invoices paid…)
--   closure_requested → active   Client withdraws, or an Admin declines
--   closure_requested → closing  Admin confirms; plan cancelled at period end
--   closing → closed             backend, once the plan has ended and every
--                                termination is completed
--
-- A closing or closed Company keeps read-only access until read_only_until
-- (closed_at + 6 years — the CRA retention period, decision 6).
--
-- WHAT THE DATABASE GUARANTEES
--   1. A closing or closed Company cannot gain Team Members, Recurring Payments,
--      Top-ups or One-Time Payments. The exception is a payment created by a
--      termination (termination_id set), so offboarding can still finish.
--
-- SAFE TO APPLY AHEAD OF THE BACKEND DEPLOY: every existing Company defaults to
-- 'active', and the guards only fire for the new statuses.
-- After applying: regenerate shoreline-database/types.ts.
-- ---------------------------------------------------------------------------------

BEGIN;

ALTER TABLE public.companies
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'closure_requested', 'closing', 'closed')),
  ADD COLUMN IF NOT EXISTS closure_requested_at timestamptz,
  ADD COLUMN IF NOT EXISTS closure_requested_by_email text,
  ADD COLUMN IF NOT EXISTS closure_reason text,
  ADD COLUMN IF NOT EXISTS closure_reviewed_at timestamptz,
  ADD COLUMN IF NOT EXISTS closure_reviewed_by_email text,
  ADD COLUMN IF NOT EXISTS closure_review_note text,
  ADD COLUMN IF NOT EXISTS closed_at timestamptz,
  ADD COLUMN IF NOT EXISTS read_only_until date;

ALTER TABLE public.companies
  ADD CONSTRAINT companies_closure_requested_stamped
    CHECK (status = 'active' OR closure_requested_at IS NOT NULL),
  ADD CONSTRAINT companies_closing_reviewed
    CHECK (status NOT IN ('closing', 'closed') OR closure_reviewed_at IS NOT NULL),
  ADD CONSTRAINT companies_closed_stamped
    CHECK (status <> 'closed' OR (closed_at IS NOT NULL AND read_only_until IS NOT NULL));

CREATE INDEX IF NOT EXISTS companies_status_idx
  ON public.companies (status)
  WHERE status <> 'active';

-- ---------------------------------------------------------------------------------
-- Guarantee 1
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reject_writes_for_closed_company()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_company_id uuid;
  v_status text;
BEGIN
  IF TG_TABLE_NAME = 'one_time_payments' THEN
    IF NEW.termination_id IS NOT NULL THEN
      RETURN NEW;
    END IF;
    SELECT company_id INTO v_company_id
      FROM public.team_members WHERE id = NEW.team_member_id;
  ELSE
    v_company_id := NEW.company_id;
  END IF;

  SELECT status INTO v_status FROM public.companies WHERE id = v_company_id;

  IF v_status IN ('closing', 'closed') THEN
    RAISE EXCEPTION 'company % is %; new % cannot be added', v_company_id, v_status, TG_TABLE_NAME
      USING ERRCODE = 'check_violation', HINT = 'company_closed';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS team_members_company_open_trg ON public.team_members;
CREATE TRIGGER team_members_company_open_trg
  BEFORE INSERT ON public.team_members
  FOR EACH ROW EXECUTE FUNCTION public.reject_writes_for_closed_company();

DROP TRIGGER IF EXISTS recurring_payments_company_open_trg ON public.recurring_payments;
CREATE TRIGGER recurring_payments_company_open_trg
  BEFORE INSERT ON public.recurring_payments
  FOR EACH ROW EXECUTE FUNCTION public.reject_writes_for_closed_company();

DROP TRIGGER IF EXISTS topups_company_open_trg ON public.topups;
CREATE TRIGGER topups_company_open_trg
  BEFORE INSERT ON public.topups
  FOR EACH ROW EXECUTE FUNCTION public.reject_writes_for_closed_company();

DROP TRIGGER IF EXISTS one_time_payments_company_open_trg ON public.one_time_payments;
CREATE TRIGGER one_time_payments_company_open_trg
  BEFORE INSERT ON public.one_time_payments
  FOR EACH ROW EXECUTE FUNCTION public.reject_writes_for_closed_company();

REVOKE EXECUTE ON FUNCTION public.reject_writes_for_closed_company()
  FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ---------------------------------------------------------------------------------
-- ROLLBACK (manual).
--
--   BEGIN;
--   DROP TRIGGER IF EXISTS team_members_company_open_trg ON public.team_members;
--   DROP TRIGGER IF EXISTS recurring_payments_company_open_trg ON public.recurring_payments;
--   DROP TRIGGER IF EXISTS topups_company_open_trg ON public.topups;
--   DROP TRIGGER IF EXISTS one_time_payments_company_open_trg ON public.one_time_payments;
--   DROP FUNCTION IF EXISTS public.reject_writes_for_closed_company();
--   ALTER TABLE public.companies
--     DROP CONSTRAINT IF EXISTS companies_closure_requested_stamped,
--     DROP CONSTRAINT IF EXISTS companies_closing_reviewed,
--     DROP CONSTRAINT IF EXISTS companies_closed_stamped,
--     DROP COLUMN IF EXISTS status, DROP COLUMN IF EXISTS closure_requested_at,
--     DROP COLUMN IF EXISTS closure_requested_by_email, DROP COLUMN IF EXISTS closure_reason,
--     DROP COLUMN IF EXISTS closure_reviewed_at, DROP COLUMN IF EXISTS closure_reviewed_by_email,
--     DROP COLUMN IF EXISTS closure_review_note, DROP COLUMN IF EXISTS closed_at,
--     DROP COLUMN IF EXISTS read_only_until;
--   NOTIFY pgrst, 'reload schema';
--   COMMIT;
-- ---------------------------------------------------------------------------------
