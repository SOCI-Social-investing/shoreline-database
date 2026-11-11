# Terminations are a record, not three columns on team_members

A termination used to be `termination_reason`, `termination_effective_date` and
`terminated_at` on `team_members`. That was enough to stop pay and billing, but
not to offboard someone: Shoreline, as the legal employer, still owes final pay,
a Record of Employment, a benefits-carrier notice and a T4, and none of that had
anywhere to live — it ran through Slack and email. We added a `terminations`
table (one row per filing), `termination_tasks` (what the Admin still owes) and
`termination_notifications` (the Client emails), and kept the three
`team_members` columns as they are: they remain the inputs `daily-termination-job`
reads.

Filing writes the columns, the record, the tasks and the email in one
transaction (`file_termination`). A trigger on `team_members` cancels the open
termination whenever the date is cleared, by any path. Closing the last task
completes the termination and queues the "complete" email in the same
transaction (`update_termination_task`).

## Considered options

- **Move the cron onto `terminations` and drop the columns.** Cleaner end state,
  but it rewrites the payment reconciliation and deactivation sweeps, which have
  a test plan and are working. Rejected for now. The columns can become a view
  over `terminations` later, once nothing else writes them.
- **Write the record from the route after updating the columns.** Rejected: two
  writes from the app is the partial-state failure CLAUDE.md forbids. One RPC is
  atomic.
- **Cancel on reactivation in the activate route.** Rejected in favour of a
  trigger, so that any future path that clears the date (admin edits) can't leave
  an open termination behind.

## Consequences

- Two sources of the last working day: `team_members.termination_effective_date`
  and `terminations.last_working_day`. Only `file_termination` and the trigger may
  change them. A direct update of the column that *sets* a new date (rather than
  clearing it) would bypass the record; nothing does that today.
- Task due dates are computed by the backend (they need payroll-period lookups)
  and passed into `file_termination`, so the rules live in one tested TS module
  (`lib/terminations/tasks.ts`), not in SQL.
- A wizard filing also writes its One-Time Payments (`termination_id`) in the
  same transaction (20261111000001). Payment reconciliation never cancels
  those for falling after the last working day.
- Terminations filed before this migration have no record. They need a one-off
  backfill if Admins want them in the tracker.
