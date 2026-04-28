-- ============================================================
-- Migration 008: Schedule nightly demo-anon cleanup via pg_cron
-- ============================================================
-- Each demo visitor gets a real auth.users row (is_anonymous=true) plus
-- a members row in the demo society. Without cleanup these accumulate.
--
-- This migration enables pg_cron and schedules cleanup_demo_anon_users()
-- (defined in migration 007) to run every night at 03:15 UTC.
--
-- pg_cron lives in the public schema in Supabase managed projects. The
-- cron.schedule call is idempotent at the job-name level — re-running
-- replaces the schedule rather than duplicating it.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Drop any existing job with this name so re-applies don't error.
SELECT cron.unschedule('demo-anon-cleanup-nightly')
  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'demo-anon-cleanup-nightly');

-- Schedule nightly cleanup. 03:15 UTC = quiet window in EU/UK; offset
-- from the top of the hour to avoid bunching with other scheduled jobs.
SELECT cron.schedule(
  'demo-anon-cleanup-nightly',
  '15 3 * * *',
  $$ SELECT public.cleanup_demo_anon_users(); $$
);

-- Also harden cleanup_demo_anon_users so it removes the orphan members
-- rows for the demo society in the same transaction. The original
-- definition only deleted auth.users, leaving members rows behind
-- because there's no FK cascade between members.id and auth.users.id.
CREATE OR REPLACE FUNCTION public.cleanup_demo_anon_users()
RETURNS INT AS $$
DECLARE
  v_demo_society UUID := '00000000-0000-0000-0000-000000000002';
  v_user_count INT := 0;
BEGIN
  -- Collect stale anon user IDs into a temp set.
  CREATE TEMP TABLE _stale_anon_ids ON COMMIT DROP AS
  SELECT id
  FROM auth.users
  WHERE is_anonymous = true
    AND created_at < NOW() - INTERVAL '24 hours';

  -- Delete the orphan demo member rows first (no FK cascade).
  DELETE FROM public.members
  WHERE society_id = v_demo_society
    AND id IN (SELECT id FROM _stale_anon_ids);

  -- Then delete the auth.users rows. Cascades through Supabase's own
  -- internal auth schema FKs (sessions, identities, etc).
  DELETE FROM auth.users
  WHERE id IN (SELECT id FROM _stale_anon_ids);
  GET DIAGNOSTICS v_user_count = ROW_COUNT;

  RETURN v_user_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE ALL ON FUNCTION public.cleanup_demo_anon_users() FROM PUBLIC;
