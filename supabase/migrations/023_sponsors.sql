-- ============================================================
-- Migration 023 — Phase F: Sponsors
-- ============================================================
-- 1. society_sponsors — per-society sponsor directory
-- 2. event_sponsors — link sponsors to events with role
-- 3. RLS policies

-- ============================================================
-- 1. society_sponsors
-- ============================================================
CREATE TABLE IF NOT EXISTS society_sponsors (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  society_id  UUID NOT NULL REFERENCES societies(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  logo_url    TEXT,
  link_url    TEXT,
  blurb       TEXT,
  active_from DATE DEFAULT CURRENT_DATE,
  active_until DATE,
  is_active   BOOLEAN NOT NULL DEFAULT true,
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  updated_at  TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_society_sponsors_society ON society_sponsors(society_id);

-- ============================================================
-- 2. event_sponsors
-- ============================================================
CREATE TABLE IF NOT EXISTS event_sponsors (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id    INT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  sponsor_id  UUID NOT NULL REFERENCES society_sponsors(id) ON DELETE CASCADE,
  role        TEXT NOT NULL DEFAULT 'supporting'
              CHECK (role IN ('primary', 'supporting', 'prize_donor')),
  created_at  TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(event_id, sponsor_id)
);

CREATE INDEX IF NOT EXISTS idx_event_sponsors_event ON event_sponsors(event_id);

-- ============================================================
-- 3. RLS
-- ============================================================
ALTER TABLE society_sponsors ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_sponsors ENABLE ROW LEVEL SECURITY;

-- society_sponsors: readable by same-society members
CREATE POLICY "sponsors_read" ON society_sponsors
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM members m
      WHERE m.society_id = society_sponsors.society_id
        AND m.user_id = auth.uid()
    )
  );

-- society_sponsors: writable by admin, treasurer, sponsor role
CREATE POLICY "sponsors_write" ON society_sponsors
  FOR ALL USING (
    public.has_role_in(society_id, ARRAY['admin','treasurer','sponsor'])
  ) WITH CHECK (
    public.has_role_in(society_id, ARRAY['admin','treasurer','sponsor'])
  );

-- event_sponsors: readable by same-society members (through events)
CREATE POLICY "event_sponsors_read" ON event_sponsors
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM events e
      JOIN members m ON m.society_id = e.society_id
      WHERE e.id = event_sponsors.event_id
        AND m.user_id = auth.uid()
    )
  );

-- event_sponsors: writable by event-running roles
CREATE POLICY "event_sponsors_write" ON event_sponsors
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM events e
      WHERE e.id = event_sponsors.event_id
        AND public.has_role_in(e.society_id, ARRAY['admin','captain','vice_captain','treasurer'])
    )
  ) WITH CHECK (
    EXISTS (
      SELECT 1 FROM events e
      WHERE e.id = event_sponsors.event_id
        AND public.has_role_in(e.society_id, ARRAY['admin','captain','vice_captain','treasurer'])
    )
  );

-- ============================================================
-- Done
-- ============================================================
