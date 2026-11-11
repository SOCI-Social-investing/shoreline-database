-- ---------------------------------------------------------------------------------
-- Terminations: a record of each offboarding, the Admin's checklist for it, and
-- the Client emails it sends. Phase 1 of shoreline-nextjs/docs/termination-
-- lifecycle/OFFBOARDING-SPEC.md. Decision record: docs/adr/0002-terminations-
-- are-a-record.md.
--
-- MODEL
--   terminations              — one row per filing. status:
--                                 submitted → completed (every task done / n/a)
--                                 submitted → cancelled (member reactivated)
--   termination_tasks         — what Shoreline, as EOR, still owes for it: final
--                               pay, ROE, benefits carrier, GIP, T4. One row per
--                               (termination, kind).
--   termination_notifications — outbox for the Client summary emails ('filed',
--                               'completed'), drained by the backend cron.
--
-- team_members.termination_reason / termination_effective_date stay exactly as
-- they are. They are still the inputs daily-termination-job reads, and
-- file_termination() writes them in the same transaction as the record.
--
-- WHAT THE DATABASE GUARANTEES
--   1. At most one open (submitted) termination per Team Member.
--   2. Filing writes the member's termination columns, the record, its tasks and
--      the 'filed' email in ONE transaction (file_termination).
--   3. Clearing a member's termination date, by any path, cancels the open
--      termination and its unsent emails (trigger on team_members).
--   4. An ROE task cannot be marked done without its serial number.
--   5. A termination completes, and its 'completed' email is queued, in the same
--      transaction as the last task being closed (update_termination_task).
--
-- SAFE TO APPLY AHEAD OF THE BACKEND DEPLOY: new tables only, plus a trigger that
-- acts only when terminations rows exist (none until the backend writes them).
--
-- After applying: regenerate shoreline-database/types.ts (never hand-edit it).
-- ---------------------------------------------------------------------------------

BEGIN;

-- ---------------------------------------------------------------------------------
-- 1. The record
-- ---------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.terminations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,
  team_member_id uuid NOT NULL REFERENCES public.team_members(id) ON DELETE CASCADE,

  status text NOT NULL DEFAULT 'submitted'
    CHECK (status IN ('submitted', 'completed', 'cancelled')),

  reason text NOT NULL CHECK (btrim(reason) <> ''),
  -- The Team Member's last working day — same meaning as
  -- team_members.termination_effective_date.
  last_working_day date NOT NULL,

  -- auth.users ids. Deliberately NOT FKs: payroll records outlive the account.
  filed_by uuid,
  filed_by_email text,
  filed_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  cancelled_at timestamptz,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT terminations_completed_stamped
    CHECK (status <> 'completed' OR completed_at IS NOT NULL),
  CONSTRAINT terminations_cancelled_stamped
    CHECK (status <> 'cancelled' OR cancelled_at IS NOT NULL)
);

COMMENT ON TABLE public.terminations IS
  'One offboarding of one team member. team_members.termination_* remain the inputs to daily-termination-job; this is the record and the parent of the admin checklist.';

-- Guarantee 1.
CREATE UNIQUE INDEX IF NOT EXISTS terminations_one_open_per_member_uidx
  ON public.terminations (team_member_id)
  WHERE status = 'submitted';
CREATE INDEX IF NOT EXISTS terminations_company_idx
  ON public.terminations (company_id);
CREATE INDEX IF NOT EXISTS terminations_status_idx
  ON public.terminations (status);

-- ---------------------------------------------------------------------------------
-- 2. The Admin checklist
-- ---------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.termination_tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  termination_id uuid NOT NULL REFERENCES public.terminations(id) ON DELETE CASCADE,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,

  kind text NOT NULL CHECK (kind IN (
    'final_pay',              -- final regular pay (prorated) processed
    'roe',                    -- Record of Employment issued to Service Canada
    'benefits_carrier',       -- carrier told coverage ends
    'group_investment_plan',  -- GIP / RRSP enrolment closed out
    't4_flag'                 -- flagged for year-end T4
  )),
  -- Null when it could not be computed (e.g. no payroll period found).
  due_date date,

  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'done', 'not_applicable')),
  -- Free text, e.g. the ROE serial number.
  reference text,
  note text,
  document_id uuid REFERENCES public.documents(id) ON DELETE SET NULL,
  completed_at timestamptz,
  completed_by_email text,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT termination_tasks_one_per_kind UNIQUE (termination_id, kind),
  -- Guarantee 4.
  CONSTRAINT termination_tasks_roe_needs_serial
    CHECK (kind <> 'roe' OR status <> 'done'
           OR (reference IS NOT NULL AND btrim(reference) <> '')),
  CONSTRAINT termination_tasks_closed_stamped
    CHECK (status = 'pending' OR completed_at IS NOT NULL)
);

COMMENT ON TABLE public.termination_tasks IS
  'What Shoreline still owes for a termination. A termination completes when none of its tasks is pending.';

-- The admin list and the due-soon alert both read open tasks by date.
CREATE INDEX IF NOT EXISTS termination_tasks_open_due_idx
  ON public.termination_tasks (due_date)
  WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS termination_tasks_company_idx
  ON public.termination_tasks (company_id);

-- ---------------------------------------------------------------------------------
-- 3. Client summary email outbox (same shape as cashback_rate_notifications)
-- ---------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.termination_notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  termination_id uuid NOT NULL REFERENCES public.terminations(id) ON DELETE CASCADE,
  company_id uuid NOT NULL REFERENCES public.companies(id) ON DELETE CASCADE,

  kind text NOT NULL CHECK (kind IN ('filed', 'completed')),
  -- Snapshot: a re-filing with a new date is a new email; the same date is not.
  last_working_day date NOT NULL,

  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'processing', 'sent', 'failed', 'cancelled')),
  attempts integer NOT NULL DEFAULT 0,
  last_error text,
  recipient_email text,
  sent_at timestamptz,

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT termination_notifications_once
    UNIQUE (termination_id, kind, last_working_day)
);

CREATE INDEX IF NOT EXISTS termination_notifications_processable_idx
  ON public.termination_notifications (created_at)
  WHERE status IN ('pending', 'failed');

-- Service-role only: every read and write goes through the Next.js API.
ALTER TABLE public.terminations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.termination_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.termination_notifications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.terminations FROM anon, authenticated;
REVOKE ALL ON public.termination_tasks FROM anon, authenticated;
REVOKE ALL ON public.termination_notifications FROM anon, authenticated;

-- ---------------------------------------------------------------------------------
-- 4. Guarantee 2: filing
--
-- p_tasks: jsonb array of {"kind": text, "due_date": "YYYY-MM-DD" | null}. Due
-- dates are computed by the backend (they need payroll-period lookups). On a
-- re-filing, pending tasks take the new due dates; closed tasks are left alone.
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.file_termination(
  p_company_id uuid,
  p_team_member_id uuid,
  p_reason text,
  p_last_working_day date,
  p_filed_by uuid,
  p_filed_by_email text,
  p_tasks jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_id uuid;
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

  INSERT INTO public.termination_tasks (termination_id, company_id, kind, due_date)
  SELECT v_id, p_company_id, t->>'kind', NULLIF(t->>'due_date', '')::date
    FROM jsonb_array_elements(COALESCE(p_tasks, '[]'::jsonb)) AS t
  ON CONFLICT (termination_id, kind) DO UPDATE
     SET due_date = EXCLUDED.due_date,
         updated_at = now()
   WHERE public.termination_tasks.status = 'pending';

  -- A 'filed' email still unsent for an earlier date is now wrong; only the
  -- latest date goes out.
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

-- ---------------------------------------------------------------------------------
-- 5. Guarantee 5: closing a task
--
-- Locks the termination first so two admins closing the last two tasks at once
-- can't both see "one still pending". Reopening a task (p_status = 'pending')
-- on a completed termination puts it back to submitted; the 'completed' email is
-- not sent twice (unique on termination + kind + date).
-- Returns {termination_id, termination_status}.
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_termination_task(
  p_task_id uuid,
  p_status text,
  p_reference text,
  p_note text,
  p_document_id uuid,
  p_actor_email text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_termination public.terminations%ROWTYPE;
  v_status text;
BEGIN
  SELECT t.* INTO v_termination
    FROM public.terminations t
    JOIN public.termination_tasks k ON k.termination_id = t.id
   WHERE k.id = p_task_id
   FOR UPDATE OF t;

  IF v_termination.id IS NULL THEN
    RAISE EXCEPTION 'termination task % not found', p_task_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_termination.status = 'cancelled' THEN
    RAISE EXCEPTION 'termination % was cancelled; its tasks cannot change', v_termination.id
      USING ERRCODE = 'check_violation';
  END IF;

  UPDATE public.termination_tasks
     SET status = p_status,
         reference = p_reference,
         note = p_note,
         document_id = p_document_id,
         completed_at = CASE WHEN p_status = 'pending' THEN NULL ELSE now() END,
         completed_by_email = CASE WHEN p_status = 'pending' THEN NULL ELSE p_actor_email END,
         updated_at = now()
   WHERE id = p_task_id;

  IF EXISTS (
    SELECT 1 FROM public.termination_tasks
     WHERE termination_id = v_termination.id AND status = 'pending'
  ) THEN
    UPDATE public.terminations
       SET status = 'submitted', completed_at = NULL, updated_at = now()
     WHERE id = v_termination.id AND status = 'completed';
    v_status := 'submitted';
  ELSE
    UPDATE public.terminations
       SET status = 'completed', completed_at = now(), updated_at = now()
     WHERE id = v_termination.id AND status = 'submitted';

    INSERT INTO public.termination_notifications
      (termination_id, company_id, kind, last_working_day)
    VALUES
      (v_termination.id, v_termination.company_id, 'completed', v_termination.last_working_day)
    ON CONFLICT ON CONSTRAINT termination_notifications_once DO NOTHING;
    v_status := 'completed';
  END IF;

  RETURN jsonb_build_object('termination_id', v_termination.id, 'termination_status', v_status);
END;
$$;

-- ---------------------------------------------------------------------------------
-- 6. Guarantee 3: reactivation cancels
--
-- Fires on any path that clears the date (activate route today, admin edits
-- later), so the record can't drift from the column the cron reads.
-- ---------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_termination_on_clear()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
BEGIN
  WITH cancelled AS (
    UPDATE public.terminations
       SET status = 'cancelled', cancelled_at = now(), updated_at = now()
     WHERE team_member_id = NEW.id
       AND status = 'submitted'
    RETURNING id
  )
  UPDATE public.termination_notifications
     SET status = 'cancelled', updated_at = now()
   WHERE termination_id IN (SELECT id FROM cancelled)
     AND status IN ('pending', 'failed');
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS team_members_cancel_termination_trg ON public.team_members;
CREATE TRIGGER team_members_cancel_termination_trg
  AFTER UPDATE OF termination_effective_date ON public.team_members
  FOR EACH ROW
  WHEN (OLD.termination_effective_date IS NOT NULL
        AND NEW.termination_effective_date IS NULL)
  EXECUTE FUNCTION public.cancel_termination_on_clear();

-- Functions are executable by PUBLIC by default; these are backend-only.
REVOKE EXECUTE ON FUNCTION public.file_termination(uuid, uuid, text, date, uuid, text, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.update_termination_task(uuid, text, text, text, uuid, text)
  FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.cancel_termination_on_clear()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.file_termination(uuid, uuid, text, date, uuid, text, jsonb)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.update_termination_task(uuid, text, text, text, uuid, text)
  TO service_role;

NOTIFY pgrst, 'reload schema';

COMMIT;

-- ---------------------------------------------------------------------------------
-- ROLLBACK (run manually if needed — Supabase migrations are forward-only).
-- team_members' termination columns are untouched, so the cron keeps working.
--
--   BEGIN;
--   DROP TRIGGER IF EXISTS team_members_cancel_termination_trg ON public.team_members;
--   DROP FUNCTION IF EXISTS public.cancel_termination_on_clear();
--   DROP FUNCTION IF EXISTS public.update_termination_task(uuid, text, text, text, uuid, text);
--   DROP FUNCTION IF EXISTS public.file_termination(uuid, uuid, text, date, uuid, text, jsonb);
--   DROP TABLE IF EXISTS public.termination_notifications;
--   DROP TABLE IF EXISTS public.termination_tasks;
--   DROP TABLE IF EXISTS public.terminations;
--   NOTIFY pgrst, 'reload schema';
--   COMMIT;
-- ---------------------------------------------------------------------------------
