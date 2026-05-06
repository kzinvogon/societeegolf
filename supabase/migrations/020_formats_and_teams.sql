-- ============================================================
-- Migration 020: Format library + team generator (Phase C)
-- ============================================================
-- Replace the free-text events.format column with a proper format
-- library so the team generator knows how big a team is and how
-- scoring works. Formats are seeded as society_id = NULL ("global"
-- defaults — visible to every society). Captains can extend with
-- their own society-scoped customs.
--
-- Two new tables + a fk on events:
--   event_formats   — Stableford / Medal / Texas Scramble / etc.
--   events.format_id — fk to event_formats; events.format text kept
--                      for back-compat reads, written from the
--                      chosen format's name on insert.
--   event_teams     — generated lineup for an event (one row per
--                     team; member_ids[] uuid array; tee_time
--                     populated by the spreader).
--
-- RLS:
--   - event_formats: globals readable by any authenticated user;
--     society-scoped formats readable by same-society members and
--     writable by event-running roles (admin/captain/vice_captain).
--   - event_teams: readable by same-society members (via events.
--     society_id join); writable by event-running roles.
-- ============================================================

-- ===========================
-- 1. event_formats
-- ===========================
CREATE TABLE IF NOT EXISTS event_formats (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  -- NULL = global default; non-null = society-private custom format.
  society_id UUID REFERENCES societies(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  name TEXT NOT NULL,
  description TEXT,
  -- Team size bounds. team_size_min = team_size_max = 1 means
  -- individual play. The generator clamps team_size_max ≤ 4.
  team_size_min INT NOT NULL DEFAULT 1 CHECK (team_size_min BETWEEN 1 AND 4),
  team_size_max INT NOT NULL DEFAULT 1 CHECK (team_size_max BETWEEN 1 AND 4),
  CHECK (team_size_max >= team_size_min),
  -- How scores are computed. The client uses this to switch between
  -- per-player vs per-team result entry forms.
  scoring_method TEXT NOT NULL CHECK (scoring_method IN (
    'stableford',     -- per player, points; team total = sum of best-N
    'medal',          -- per player, gross/net strokes
    'scramble',       -- per team, single team gross
    'better_ball',    -- per team, best of N stableford per hole
    'matchplay',      -- per pair/individual, win/lose/halve
    'custom'          -- captain enters scores free-form
  )),
  -- Free-form hint for the captain — e.g. "Best 2 of 4 scores per
  -- hole count for the team total."
  scoring_notes TEXT,
  -- Whether this is a curated default. Globals are seeded with
  -- is_default=true; society customs are false.
  is_default BOOLEAN NOT NULL DEFAULT false,
  sort_order INT NOT NULL DEFAULT 100,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  -- A society can't have two formats with the same code; globals
  -- have society_id NULL and a partial unique index handles that
  -- case below.
  UNIQUE (society_id, code)
);

-- Globals: ensure unique code among society_id IS NULL rows.
CREATE UNIQUE INDEX IF NOT EXISTS event_formats_global_code_uniq
  ON event_formats(code) WHERE society_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_event_formats_society
  ON event_formats(society_id, sort_order);

-- ===========================
-- 2. Seed global formats
-- ===========================
INSERT INTO event_formats (society_id, code, name, description, team_size_min, team_size_max, scoring_method, scoring_notes, is_default, sort_order)
VALUES
  (NULL, 'individual_stableford', 'Individual Stableford',
   'Each player scores Stableford points individually. Highest total wins.',
   1, 1, 'stableford', NULL, true, 10),
  (NULL, 'individual_medal', 'Medal (Stroke Play)',
   'Each player counts every stroke. Lowest gross or net total wins.',
   1, 1, 'medal', NULL, true, 20),
  (NULL, 'individual_matchplay', 'Individual Matchplay',
   'Hole-by-hole head-to-head. Most holes won wins the match.',
   1, 1, 'matchplay', NULL, true, 30),
  (NULL, 'pairs_matchplay', 'Pairs Matchplay',
   'Pairs play head-to-head. Best score per side counts each hole.',
   2, 2, 'matchplay', NULL, true, 40),
  (NULL, 'better_ball', 'Better Ball (4BBB)',
   'Pairs; best Stableford score on each hole counts for the pair.',
   2, 2, 'better_ball', 'Best individual Stableford per hole.', true, 50),
  (NULL, 'greensomes', 'Greensomes',
   'Pairs both tee off, choose better drive, then alternate shots to the hole.',
   2, 2, 'medal', 'Pair''s combined handicap × 0.6 (roughly).', true, 60),
  (NULL, 'foursomes', 'Foursomes (Alternate Shot)',
   'Pairs alternate tee shots and alternate strokes throughout the hole.',
   2, 2, 'medal', NULL, true, 70),
  (NULL, 'texas_scramble', 'Texas Scramble',
   'Teams of 3–4. All tee off; pick best ball; everyone plays from there. Repeat each shot.',
   3, 4, 'scramble', 'One team score per hole. Min drives per player rule optional.', true, 80),
  (NULL, 'reverse_waltz', 'Reverse Waltz',
   'Teams of 3. Hole 1: 1 ball counts; hole 2: 2 best balls; hole 3: 3 best balls; repeat.',
   3, 3, 'better_ball', 'Rotating count: 1, 2, 3, 1, 2, 3 …', true, 90)
ON CONFLICT DO NOTHING;

-- ===========================
-- 3. events.format_id
-- ===========================
-- FK to event_formats. ON DELETE SET NULL so deleting a society's
-- custom format doesn't cascade into events; the events row keeps
-- its `format` text and the captain can re-link to a different
-- format if they want.
ALTER TABLE events
  ADD COLUMN IF NOT EXISTS format_id UUID REFERENCES event_formats(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_events_format ON events(format_id);

-- Best-effort backfill: match existing events.format text to a
-- global format by lowercased name. Anything that doesn't match
-- stays NULL (captain can pick a real format on next edit).
UPDATE events e
   SET format_id = f.id
  FROM event_formats f
 WHERE e.format_id IS NULL
   AND f.society_id IS NULL
   AND lower(trim(e.format)) IN (
     lower(f.name),
     lower(f.code),
     replace(lower(f.code), '_', ' ')
   );

-- ===========================
-- 4. events.tee_time_interval_minutes
-- ===========================
-- The tee-time spreader needs a per-event interval. Default 10
-- minutes (typical for societies; captain can override).
ALTER TABLE events
  ADD COLUMN IF NOT EXISTS tee_time_interval_minutes INT
    CHECK (tee_time_interval_minutes IS NULL OR tee_time_interval_minutes BETWEEN 5 AND 30);

-- ===========================
-- 5. event_teams
-- ===========================
CREATE TABLE IF NOT EXISTS event_teams (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id INT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  team_number INT NOT NULL,
  -- Members in the team. Order within the array is presentational
  -- (used for "first off the tee"). Validated by the trigger below
  -- to ensure each member is a current member of the event's society.
  member_ids UUID[] NOT NULL DEFAULT ARRAY[]::UUID[],
  -- Computed by the spreader: HH:MM string in the event's local
  -- time. NULL means "not yet scheduled".
  tee_time TEXT,
  -- Captain marks 'published' to make the lineup visible to members.
  status TEXT NOT NULL DEFAULT 'draft'
    CHECK (status IN ('draft','published')),
  -- Stamped automatically by the trigger when status flips to
  -- 'published'. NULL on draft. Cleared if status reverts to draft.
  published_at TIMESTAMPTZ,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (event_id, team_number)
);

CREATE INDEX IF NOT EXISTS idx_event_teams_event ON event_teams(event_id, team_number);

-- ===========================
-- 6. RLS
-- ===========================

-- event_formats
ALTER TABLE event_formats ENABLE ROW LEVEL SECURITY;

-- Read: globals are readable by every authenticated user; society
-- formats are readable by members of that society.
DROP POLICY IF EXISTS event_formats_read ON event_formats;
CREATE POLICY event_formats_read ON event_formats
  FOR SELECT
  USING (
    society_id IS NULL
    OR EXISTS (
      SELECT 1 FROM members m
       WHERE m.society_id = event_formats.society_id
         AND m.user_id = auth.uid()
    )
  );

-- Write: only event-running roles for the matching society can
-- insert / update / delete society customs. Globals are read-only
-- from the client (managed via this migration / future seeds).
DROP POLICY IF EXISTS event_formats_write ON event_formats;
CREATE POLICY event_formats_write ON event_formats
  FOR ALL
  USING (
    society_id IS NOT NULL
    AND has_role_in(society_id, ARRAY['admin','captain','vice_captain'])
  )
  WITH CHECK (
    society_id IS NOT NULL
    AND has_role_in(society_id, ARRAY['admin','captain','vice_captain'])
  );

-- event_teams
ALTER TABLE event_teams ENABLE ROW LEVEL SECURITY;

-- Read: same-society members can read published teams; admins/
-- captains/vice-captains can read draft teams too.
DROP POLICY IF EXISTS event_teams_read ON event_teams;
CREATE POLICY event_teams_read ON event_teams
  FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM events e
       JOIN members m ON m.society_id = e.society_id
       WHERE e.id = event_teams.event_id
         AND m.user_id = auth.uid()
         AND (
           event_teams.status = 'published'
           OR has_role_in(e.society_id, ARRAY['admin','captain','vice_captain'])
         )
    )
  );

-- Write: event-running roles only.
DROP POLICY IF EXISTS event_teams_write ON event_teams;
CREATE POLICY event_teams_write ON event_teams
  FOR ALL
  USING (
    EXISTS (
      SELECT 1 FROM events e
       WHERE e.id = event_teams.event_id
         AND has_role_in(e.society_id, ARRAY['admin','captain','vice_captain'])
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM events e
       WHERE e.id = event_teams.event_id
         AND has_role_in(e.society_id, ARRAY['admin','captain','vice_captain'])
    )
  );

-- updated_at + published_at maintenance for event_teams.
-- Stamps published_at when status flips draft → published; clears
-- it on the reverse so a republish gets a fresh timestamp.
CREATE OR REPLACE FUNCTION set_updated_at_event_teams()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  IF NEW.status = 'published' AND (OLD.status IS DISTINCT FROM 'published') THEN
    NEW.published_at = NOW();
  ELSIF NEW.status = 'draft' AND OLD.status = 'published' THEN
    NEW.published_at = NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS event_teams_set_updated_at ON event_teams;
CREATE TRIGGER event_teams_set_updated_at
  BEFORE UPDATE ON event_teams
  FOR EACH ROW EXECUTE FUNCTION set_updated_at_event_teams();

-- Cover the insert-as-published case too (rare, but possible if a
-- generator publishes immediately).
CREATE OR REPLACE FUNCTION set_published_at_on_insert_event_teams()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status = 'published' AND NEW.published_at IS NULL THEN
    NEW.published_at = NOW();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS event_teams_set_published_at_insert ON event_teams;
CREATE TRIGGER event_teams_set_published_at_insert
  BEFORE INSERT ON event_teams
  FOR EACH ROW EXECUTE FUNCTION set_published_at_on_insert_event_teams();
