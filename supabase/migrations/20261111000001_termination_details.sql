-- ---------------------------------------------------------------------------------
-- Terminations, phases 2–4 of OFFBOARDING-SPEC.md: what the wizard decided
-- (notice, severance, vacation, benefits end, billing), the payments it created,
-- and the manager checklist.
--
-- Requires 20261111000000_create_terminations.sql.
--
-- WHAT THE DATABASE GUARANTEES (adds to that migration's list)
--   6. Filing writes the termination's One-Time Payments in the same transaction
--      as the record. A re-filing cancels the termination's UNINVOICED payments
--      and writes the new ones; invoiced ones are history and stay.
--   7. A termination's payments are tied to it (one_time_payments.termination_id),
--      so payment reconciliation can tell them apart from ordinary ones.
--
-- SAFE TO APPLY AHEAD OF THE BACKEND DEPLOY: new nullable columns, a widened
-- CHECK, and file_termination keeps its old named parameters (new ones default),
-- so the phase-1 backend still calls it unchanged.
--
-- After applying: regenerate shoreline-database/types.ts (never hand-edit it).
-- ---------------------------------------------------------------------------------

BEGIN;

-- ---------------------------------------------------------------------------------
-- 1. What the wizard decided
-- ---------------------------------------------------------------------------------
ALTER TABLE public.terminations
  ADD COLUMN IF NOT EXISTS reason_category text
    CHECK (reason_category IN ('resignation', 'without_cause', 'with_cause', 'end_of_contract', 'other')),
  -- e.g. 'CA-ON'. Null for contractors and when no province is on file.
  ADD COLUMN IF NOT EXISTS jurisdiction text,
  -- lib/terminations/rules.ts RULES_VERSION used for the calculation.
  ADD COLUMN IF NOT EXISTS rules_version text,
  ADD COLUMN IF NOT EXISTS pay_in_lieu_weeks numeric(6,4) CHECK (pay_in_lieu_weeks >= 0),
  ADD COLUMN IF NOT EXISTS severance_weeks numeric(6,4) CHECK (severance_weeks >= 0),
  ADD COLUMN IF NOT EXISTS vacation_days_unused numeric(6,2) CHECK (vacation_days_unused >= 0),
  ADD COLUMN IF NOT EXISTS benefits_end_option text
    CHECK (benefits_end_option IN ('last_day', 'period_end', 'custom')),
  -- Null = the end of the current billing period (Stripe cancel_at_period_end).
  ADD COLUMN IF NOT EXISTS benefits_end_date date,
  ADD COLUMN IF NOT EXISTS severance_billing text NOT NULL DEFAULT 'next_invoice'
    CHECK (severance_billing IN ('next_invoice', 'immediate')),
  -- Calculator inputs + outputs, frozen at filing. Audit trail for the figures.
  ADD COLUMN IF NOT EXISTS calculation jsonb,
  -- Manager checklist (F6): {"<item>": {"done_at": ts, "by": email}}.
  -- Informational only; nothing waits on it.
  ADD COLUMN IF NOT EXISTS client_checklist jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE public.terminations
  ADD CONSTRAINT terminations_custom_benefits_dated
    CHECK (benefits_end_option IS DISTINCT FROM 'custom' OR benefits_end_date IS NOT NULL);

-- ---------------------------------------------------------------------------------
-- 2. New task kinds
--   notice_review — no rules for this jurisdiction (US, unmodelled province):
--                   an Admin checks the notice and pay before it is final.
--   final_invoice — the final period (and the termination's payments) billed
--                   before the member is deactivated. Closed by the backend.
-- ---------------------------------------------------------------------------------
ALTER TABLE public.termination_tasks DROP CONSTRAINT IF EXISTS termination_tasks_kind_check;
ALTER TABLE public.termination_tasks
  ADD CONSTRAINT termination_tasks_kind_check CHECK (kind IN (
    'final_pay', 'roe', 'benefits_carrier', 'group_investment_plan', 't4_flag',
    'notice_review', 'final_invoice'
  ));

-- ---------------------------------------------------------------------------------
-- 3. Guarantee 7: payments tied to a termination
-- ---------------------------------------------------------------------------------
ALTER TABLE public.one_time_payments
  ADD COLUMN IF NOT EXISTS termination_id uuid REFERENCES public.terminations(id);

COMMENT ON COLUMN public.one_time_payments.termination_id IS
  'Set for pay in lieu, severance and vacation payout created by a termination. Reconciliation never cancels these for falling after the last working day.';

CREATE INDEX IF NOT EXISTS one_time_payments_termination_idx
  ON public.one_time_payments (termination_id)
  WHERE termination_id IS NOT NULL;

ALTER TABLE public.one_time_payments
  ADD CONSTRAINT one_time_payments_termination_has_period
    CHECK (termination_id IS NULL OR payroll_schedule_id IS NOT NULL);

-- ---------------------------------------------------------------------------------
-- 4. Guarantee 6: filing, now with details and payments
--
-- Same parameters as before plus two defaulted ones, so callers from phase 1 keep
-- working. p_details keys: the column names in section 1 (except
-- client_checklist). p_payments: [{payment_type, amount, description,
-- payroll_schedule_id}].
-- ---------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.file_termination(uuid, uuid, text, date, uuid, text, jsonb);

CREATE OR REPLACE FUNCTION public.file_termination(
  p_company_id uuid,
  p_team_member_id uuid,
  p_reason text,
  p_last_working_day date,
  p_filed_by uuid,
  p_filed_by_email text,
  p_tasks jsonb,
  p_details jsonb DEFAULT '{}'::jsonb,
  p_payments jsonb DEFAULT '[]'::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_id uuid;
  d jsonb := COALESCE(p_details, '{}'::jsonb);
BEGIN
  UPDATE public.team_members
     SET termination_reason = p_reason,
         termination_effective_date = p_last_working_day
   WHERE id = p_team_member_id
     AND company_id = p_company_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'team member % not found in company %', p_team_member_id, p_company_id
      USING ERRCODE = 'no_data_found';
  END IF;

  SELECT id INTO v_id
    FROM public.terminations
   WHERE team_member_id = p_team_member_id
     AND status = 'submitted'
   FOR UPDATE;

  IF v_id IS NULL THEN
    INSERT INTO public.terminations
      (company_id, team_member_id, reason, last_working_day, filed_by, filed_by_email)
    VALUES
      (p_company_id, p_team_member_id, p_reason, p_last_working_day, p_filed_by, p_filed_by_email)
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.terminations
       SET reason = p_reason,
           last_working_day = p_last_working_day,
           filed_by = p_filed_by,
           filed_by_email = p_filed_by_email,
           filed_at = now(),
           updated_at = now()
     WHERE id = v_id;
  END IF;

  UPDATE public.terminations
     SET reason_category      = d->>'reason_category',
         jurisdiction         = d->>'jurisdiction',
         rules_version        = d->>'rules_version',
         pay_in_lieu_weeks    = (d->>'pay_in_lieu_weeks')::numeric,
         severance_weeks      = (d->>'severance_weeks')::numeric,
         vacation_days_unused = (d->>'vacation_days_unused')::numeric,
         benefits_end_option  = d->>'benefits_end_option',
         benefits_end_date    = (d->>'benefits_end_date')::date,
         severance_billing    = COALESCE(d->>'severance_billing', 'next_invoice'),
         calculation          = d->'calculation'
   WHERE id = v_id;

  -- Payments: the uninvoiced ones from an earlier filing are replaced.
  UPDATE public.one_time_payments
     SET status = 'cancelled'
   WHERE termination_id = v_id
     AND invoice_id IS NULL
     AND status <> 'cancelled';

  INSERT INTO public.one_time_payments
    (team_member_id, payroll_schedule_id, payment_type, amount, description, termination_id)
  SELECT p_team_member_id,
         (p->>'payroll_schedule_id')::uuid,
         (p->>'payment_type')::public.one_time_payment_type,
         (p->>'amount')::numeric,
         p->>'description',
         v_id
    FROM jsonb_array_elements(COALESCE(p_payments, '[]'::jsonb)) AS p;

  INSERT INTO public.termination_tasks (termination_id, company_id, kind, due_date)
  SELECT v_id, p_company_id, t->>'kind', NULLIF(t->>'due_date', '')::date
    FROM jsonb_array_elements(COALESCE(p_tasks, '[]'::jsonb)) AS t
  ON CONFLICT (termination_id, kind) DO UPDATE
     SET due_date = EXCLUDED.due_date,
         updated_at = now()
   WHERE public.termination_tasks.status = 'pending';

  UPDATE public.termination_notifications
     SET status = 'cancelled', updated_at = now()
   WHERE termination_id = v_id
     AND kind = 'filed'
     AND last_working_day <> p_last_working_day
     AND status IN ('pending', 'failed');

  INSERT INTO public.termination_notifications
    (termination_id, company_id, kind, last_working_day)
  VALUES
    (v_id, p_company_id, 'filed', p_last_working_day)
  ON CONFLICT ON CONSTRAINT termination_notifications_once DO NOTHING;

  RETURN v_id;
END;
$$;

-- Reactivation also cancels the termination's uninvoiced payments: the trigger
-- from the previous migration is extended rather than duplicated.
CREATE OR REPLACE FUNCTION public.cancel_termination_on_clear()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_ids uuid[];
BEGIN
  WITH cancelled AS (
    UPDATE public.terminations
       SET status = 'cancelled', cancelled_at = now(), updated_at = now()
     WHERE team_member_id = NEW.id
       AND status = 'submitted'
    RETURNING id
  )
  SELECT array_agg(id) INTO v_ids FROM cancelled;

  IF v_ids IS NOT NULL THEN
    UPDATE public.termination_notifications
       SET status = 'cancelled', updated_at = now()
     WHERE termination_id = ANY (v_ids)
       AND status IN ('pending', 'failed');

    UPDATE public.one_time_payments
       SET status = 'cancelled'
     WHERE termination_id = ANY (v_ids)
       AND invoice_id IS NULL
       AND status <> 'cancelled';
  END IF;
  RETURN NEW;
END;
$$;

-- Manager checklist (F6): one item ticked or unticked, company-scoped.
CREATE OR REPLACE FUNCTION public.set_termination_checklist_item(
  p_termination_id uuid,
  p_company_id uuid,
  p_item text,
  p_done boolean,
  p_actor_email text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_checklist jsonb;
BEGIN
  UPDATE public.terminations
     SET client_checklist = CASE
           WHEN p_done THEN client_checklist || jsonb_build_object(
             p_item, jsonb_build_object('done_at', now(), 'by', p_actor_email))
           ELSE client_checklist - p_item
         END,
         updated_at = now()
   WHERE id = p_termination_id
     AND company_id = p_company_id
     AND status <> 'cancelled'
  RETURNING client_checklist INTO v_checklist;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'termination % not found in company %', p_termination_id, p_company_id
      USING ERRCODE = 'no_data_found';
  END IF;
  RETURN v_checklist;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.file_termination(uuid, uuid, text, date, uuid, text, jsonb, jsonb, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.set_termination_checklist_item(uuid, uuid, text, boolean, text)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.cancel_termination_on_clear()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.file_termination(uuid, uuid, text, date, uuid, text, jsonb, jsonb, jsonb)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.set_termination_checklist_item(uuid, uuid, text, boolean, text)
  TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ---------------------------------------------------------------------------------
-- ROLLBACK (manual). Payments created by terminations remain as ordinary rows.
--
--   BEGIN;
--   DROP FUNCTION IF EXISTS public.set_termination_checklist_item(uuid, uuid, text, boolean, text);
--   -- then re-run section 4 of 20261111000000 to restore the 7-argument file_termination
--   -- and the original cancel_termination_on_clear
--   ALTER TABLE public.one_time_payments DROP CONSTRAINT IF EXISTS one_time_payments_termination_has_period;
--   ALTER TABLE public.one_time_payments DROP COLUMN IF EXISTS termination_id;
--   ALTER TABLE public.termination_tasks DROP CONSTRAINT termination_tasks_kind_check;
--   ALTER TABLE public.termination_tasks ADD CONSTRAINT termination_tasks_kind_check
--     CHECK (kind IN ('final_pay','roe','benefits_carrier','group_investment_plan','t4_flag'));
--   ALTER TABLE public.terminations DROP CONSTRAINT IF EXISTS terminations_custom_benefits_dated,
--     DROP COLUMN IF EXISTS reason_category, DROP COLUMN IF EXISTS jurisdiction,
--     DROP COLUMN IF EXISTS rules_version, DROP COLUMN IF EXISTS pay_in_lieu_weeks,
--     DROP COLUMN IF EXISTS severance_weeks, DROP COLUMN IF EXISTS vacation_days_unused,
--     DROP COLUMN IF EXISTS benefits_end_option, DROP COLUMN IF EXISTS benefits_end_date,
--     DROP COLUMN IF EXISTS severance_billing, DROP COLUMN IF EXISTS calculation,
--     DROP COLUMN IF EXISTS client_checklist;
--   NOTIFY pgrst, 'reload schema';
--   COMMIT;
-- ---------------------------------------------------------------------------------
