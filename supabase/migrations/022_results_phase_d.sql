-- ============================================================
-- Migration 022 — Phase D: Results publish gate + team results
-- ============================================================
-- 1. Add results.team_id FK to event_teams (nullable; NULL for individual formats)
-- 2. Add events.results_published_at to gate member visibility
-- 3. Update results RLS: public reads only when results are published
-- 4. Add results_select policy for published results (society-scoped)

-- ============================================================
-- 1. results.team_id
-- ============================================================
ALTER TABLE results
  ADD COLUMN IF NOT EXISTS team_id UUID REFERENCES event_teams(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_results_team ON results(team_id);

-- ============================================================
-- 2. events.results_published_at
-- ============================================================
ALTER TABLE events
  ADD COLUMN IF NOT EXISTS results_published_at TIMESTAMPTZ;

-- ============================================================
-- 3. Update results RLS
-- ============================================================
-- Drop the old "anyone can view" policy — results should only be
-- visible to members of the same society once published.
DROP POLICY IF EXISTS "Anyone can view results" ON results;

-- Published results: readable by same-society authenticated members
CREATE POLICY "results_published_read" ON results
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM events e
      JOIN members m ON m.society_id = e.society_id
      WHERE e.id = results.event_id
        AND m.user_id = auth.uid()
        AND e.results_published_at IS NOT NULL
    )
  );

-- Unpublished results: readable by event-running roles (so captains can
-- review before publishing)
CREATE POLICY "results_draft_read" ON results
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM events e
      WHERE e.id = results.event_id
        AND public.has_role_in(e.society_id, ARRAY['admin','captain','vice_captain'])
    )
  );

-- results_admin_all (write) already exists from migration 018 — no change needed.

-- ============================================================
-- Done
-- ============================================================
