-- ============================================================
-- Migration 017: home course, dual rates, buggy at signup,
--                signup cutoff as timestamp
-- ============================================================
-- Four related additions:
--   1. societies.home_course_external_id — admin-designated default
--      course for event creation; shown with a 🏠 badge.
--   2. course_rates.green_fee_guest_cents — second rate column for
--      society members who are NOT members of the host golf club.
--      The existing green_fee_cents becomes the "club member" rate;
--      anyone who isn't a club member at this course pays the guest
--      rate.
--   3. signups.buggy_requested + signups.player_type — players opt in
--      for a buggy at signup time, and self-declare member-of-club vs
--      guest so the right rate is charged.
--   4. events.signup_cutoff_at — replaces the date-only signup_cutoff
--      with a precise timestamp ("by 17:00 on the Friday before").
--      Backfilled from signup_cutoff at 17:00 local-equivalent UTC.
-- ============================================================

-- 1. societies.home_course_external_id
ALTER TABLE societies
  ADD COLUMN IF NOT EXISTS home_course_external_id UUID REFERENCES external_courses(id) ON DELETE SET NULL;

-- 2. course_rates.green_fee_guest_cents
ALTER TABLE course_rates
  ADD COLUMN IF NOT EXISTS green_fee_guest_cents INT;

-- 3. signups
ALTER TABLE signups
  ADD COLUMN IF NOT EXISTS buggy_requested BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE signups
  ADD COLUMN IF NOT EXISTS player_type TEXT
    CHECK (player_type IN ('club_member','guest'));

-- 4. events.signup_cutoff_at — backfill from signup_cutoff at 17:00
ALTER TABLE events
  ADD COLUMN IF NOT EXISTS signup_cutoff_at TIMESTAMPTZ;

UPDATE events
   SET signup_cutoff_at = (signup_cutoff::timestamp + interval '17 hours') AT TIME ZONE 'Europe/Madrid'
 WHERE signup_cutoff_at IS NULL
   AND signup_cutoff IS NOT NULL;

-- The old DATE column stays for now so existing reads (visitor view,
-- past events) keep working. New writes should populate
-- signup_cutoff_at; we'll drop the date column in a later migration
-- once the client is confirmed reading the timestamp version.

-- 5. Update rates_for_course to expose the second GF column.
DROP FUNCTION IF EXISTS public.rates_for_course(UUID, INT, DATE);
CREATE OR REPLACE FUNCTION public.rates_for_course(
  p_course_id UUID,
  p_players INT DEFAULT 12,
  p_on_date DATE DEFAULT CURRENT_DATE
) RETURNS TABLE (
  id UUID,
  days_label TEXT,
  season TEXT,
  date_range_label TEXT,
  min_players INT,
  min_players_max INT,
  green_fee_cents INT,
  green_fee_guest_cents INT,
  buggy_cents INT,
  buggy_included BOOLEAN,
  captain_free_at INT,
  currency TEXT,
  is_tbc BOOLEAN,
  is_active_today BOOLEAN,
  matches_player_count BOOLEAN
) AS $$
  SELECT
    cr.id,
    cr.days_label,
    cr.season,
    cr.date_range_label,
    cr.min_players,
    cr.min_players_max,
    cr.green_fee_cents,
    cr.green_fee_guest_cents,
    cr.buggy_cents,
    cr.buggy_included,
    cr.captain_free_at,
    cr.currency,
    cr.is_tbc,
    COALESCE((
      SELECT bool_or(
        make_date(
          EXTRACT(YEAR FROM p_on_date)::INT,
          (r->>'start_month')::INT,
          (r->>'start_day')::INT
        ) <= p_on_date
        AND make_date(
          EXTRACT(YEAR FROM p_on_date)::INT,
          (r->>'end_month')::INT,
          (r->>'end_day')::INT
        ) >= p_on_date
      )
      FROM jsonb_array_elements(cr.date_ranges) r
    ), cr.season = 'all') AS is_active_today,
    (cr.min_players IS NULL
     OR (cr.min_players <= p_players
         AND (cr.min_players_max IS NULL OR p_players < cr.min_players_max))
    ) AS matches_player_count
  FROM course_rates cr
  WHERE cr.external_course_id = p_course_id
    AND cr.active = true
    AND (
      cr.society_id = public.get_society_id()
      OR EXISTS (SELECT 1 FROM members WHERE user_id = auth.uid() AND society_id = cr.society_id)
    )
  ORDER BY cr.sort_order, cr.season, cr.min_players NULLS FIRST;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

REVOKE ALL ON FUNCTION public.rates_for_course(UUID, INT, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rates_for_course(UUID, INT, DATE) TO anon, authenticated;
