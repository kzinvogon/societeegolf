-- ============================================================
-- Migration 015: course_rates — per-society negotiated green-fee rates
-- ============================================================
-- Rates are society-negotiated, so they belong to the society, not the
-- shared external_courses catalog. Schema:
--   course_rates.society_id          -> societies(id)
--   course_rates.external_course_id  -> external_courses(id)
-- A society can have multiple rate rows per course (low/high seasons,
-- player-count tiers, day-of-week splits).
--
-- Seeded from JPGS's "Societies 2026 V3" rate card scoped to the
-- 'default' society (which is JPGS in current state).
-- ============================================================

-- ===========================
-- 1. Add the 4 courses the rate card references but external_courses
--    didn't yet have. Idempotent via the existing unique index.
-- ===========================
INSERT INTO external_courses (name, city, region, country, holes, source) VALUES
  ('El Bosque',                       'Chiva',     'Valencia',     'Spain', 18, 'jpgs-rates'),
  ('La Galiana',                      'Llombai',   'Valencia',     'Spain', 18, 'jpgs-rates'),
  ('Villaitana — Levante Course',     'Benidorm',  'Costa Blanca', 'Spain', 18, 'jpgs-rates'),
  ('Villaitana — Poniente Course',    'Benidorm',  'Costa Blanca', 'Spain', 18, 'jpgs-rates')
ON CONFLICT (lower(name), lower(country)) DO NOTHING;

-- ===========================
-- 2. course_rates table
-- ===========================
CREATE TABLE IF NOT EXISTS course_rates (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  society_id UUID NOT NULL REFERENCES societies(id) ON DELETE CASCADE,
  external_course_id UUID NOT NULL REFERENCES external_courses(id) ON DELETE CASCADE,

  days_label TEXT NOT NULL,
  season TEXT NOT NULL,
  date_range_label TEXT,
  date_ranges JSONB,

  min_players INT,
  min_players_max INT,

  currency TEXT NOT NULL DEFAULT 'EUR' CHECK (currency IN ('EUR','GBP','USD')),
  green_fee_cents INT,
  buggy_cents INT,
  buggy_included BOOLEAN NOT NULL DEFAULT false,

  captain_free_at INT,

  is_tbc BOOLEAN NOT NULL DEFAULT false,
  notes TEXT,
  active BOOLEAN NOT NULL DEFAULT true,
  sort_order INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_course_rates_society_course
  ON course_rates(society_id, external_course_id);

ALTER TABLE course_rates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "course_rates_select_same_society" ON course_rates;
CREATE POLICY "course_rates_select_same_society" ON course_rates
  FOR SELECT USING (
    society_id = public.get_society_id()
    OR EXISTS (SELECT 1 FROM members WHERE user_id = auth.uid() AND society_id = course_rates.society_id)
  );

DROP POLICY IF EXISTS "course_rates_admin_all" ON course_rates;
CREATE POLICY "course_rates_admin_all" ON course_rates
  FOR ALL USING (public.is_admin_of(society_id));

-- ===========================
-- 3. Seed JPGS rate card. Wipe existing JPGS rates first so reseed is
--    idempotent. Each insert resolves the external_course_id by name.
-- ===========================
DELETE FROM course_rates WHERE society_id = '00000000-0000-0000-0000-000000000001';

INSERT INTO course_rates (
  society_id, external_course_id, days_label, season, date_range_label,
  date_ranges, min_players, min_players_max, green_fee_cents, buggy_cents,
  buggy_included, captain_free_at, is_tbc
)
SELECT
  '00000000-0000-0000-0000-000000000001'::uuid,
  ec.id,
  v.days_label,
  v.season,
  v.date_range_label,
  v.date_ranges::jsonb,
  v.min_players,
  v.min_players_max,
  v.green_fee_cents,
  v.buggy_cents,
  v.buggy_included,
  v.captain_free_at,
  v.is_tbc
FROM (VALUES
  -- (course_name, days_label, season, date_range_label, date_ranges, min_players, min_players_max, green_fee_cents, buggy_cents, buggy_included, captain_free_at, is_tbc)
  ('El Bosque', 'Mon - Thur', 'all', 'Jan - Dec',
    '[{"start_month":1,"start_day":1,"end_month":12,"end_day":31}]',
    12, NULL, 7000, 3000, false, 20, false),
  ('El Saler', 'Mon - Fri', 'all', 'Jan - Dec',
    '[{"start_month":1,"start_day":1,"end_month":12,"end_day":31}]',
    12, NULL, 7500, 3000, false, 20, false),

  ('Foressos', 'Mon - Fri', 'low',  'To Be Confirmed', NULL, 12, NULL, 4500, 3000, false, NULL, true),
  ('Foressos', 'Mon - Fri', 'high', 'To Be Confirmed', NULL, 12, NULL, 5500, 3000, false, NULL, true),

  ('La Galiana', 'Mon - Sun', 'low', 'Jan - 1 Mar, June - Aug + Dec',
    '[{"start_month":1,"start_day":1,"end_month":3,"end_day":1},
      {"start_month":6,"start_day":1,"end_month":8,"end_day":31},
      {"start_month":12,"start_day":1,"end_month":12,"end_day":31}]',
    12, NULL, 6500, 3500, false, 16, false),
  ('La Galiana', 'Mon - Sun', 'mid', '1-20 Sept',
    '[{"start_month":9,"start_day":1,"end_month":9,"end_day":20}]',
    12, NULL, 7000, 3500, false, 16, false),
  ('La Galiana', 'Mon - Sun', 'high', '2 Mar - 31 May, 21 Sep - 30 Nov',
    '[{"start_month":3,"start_day":2,"end_month":5,"end_day":31},
      {"start_month":9,"start_day":21,"end_month":11,"end_day":30}]',
    12, NULL, 8000, 3500, false, 16, false),

  ('Oliva Nova Beach & Golf', 'Mon - Sun', 'low', 'Jan, Feb, June, July, Sep, Dec',
    '[{"start_month":1,"start_day":1,"end_month":2,"end_day":28},
      {"start_month":6,"start_day":1,"end_month":7,"end_day":31},
      {"start_month":9,"start_day":1,"end_month":9,"end_day":30},
      {"start_month":12,"start_day":1,"end_month":12,"end_day":31}]',
    13, NULL, 6000, 3500, false, NULL, false),
  ('Oliva Nova Beach & Golf', 'Mon - Sun', 'high', 'Mar, Apr, May, Aug, Oct, Nov',
    '[{"start_month":3,"start_day":1,"end_month":5,"end_day":31},
      {"start_month":8,"start_day":1,"end_month":8,"end_day":31},
      {"start_month":10,"start_day":1,"end_month":11,"end_day":30}]',
    13, NULL, 6500, 3500, false, NULL, false),

  ('La Sella Golf Resort', 'TBC', 'tbc', 'To Be Confirmed', NULL, NULL, NULL, NULL, NULL, false, NULL, true),

  ('Sierra Altea Golf', 'Mon - Sun', 'low', '1 Jan - 18 Feb, 1 July - 15 Sep & Dec',
    '[{"start_month":1,"start_day":1,"end_month":2,"end_day":18},
      {"start_month":7,"start_day":1,"end_month":9,"end_day":15},
      {"start_month":12,"start_day":1,"end_month":12,"end_day":31}]',
    9, 25, 4300, 2400, false, 12, false),
  ('Sierra Altea Golf', 'Mon - Sun', 'low', '1 Jan - 18 Feb, 1 July - 15 Sep & Dec',
    '[{"start_month":1,"start_day":1,"end_month":2,"end_day":18},
      {"start_month":7,"start_day":1,"end_month":9,"end_day":15},
      {"start_month":12,"start_day":1,"end_month":12,"end_day":31}]',
    25, NULL, 3300, 2400, false, 12, false),
  ('Sierra Altea Golf', 'Mon - Sun', 'high', '19 Feb - 30 June & 16 Sept - 30 Nov',
    '[{"start_month":2,"start_day":19,"end_month":6,"end_day":30},
      {"start_month":9,"start_day":16,"end_month":11,"end_day":30}]',
    9, 25, 5000, 3000, false, 12, false),
  ('Sierra Altea Golf', 'Mon - Sun', 'high', '19 Feb - 30 June & 16 Sept - 30 Nov',
    '[{"start_month":2,"start_day":19,"end_month":6,"end_day":30},
      {"start_month":9,"start_day":16,"end_month":11,"end_day":30}]',
    25, NULL, 4300, 2900, false, 12, false),

  ('Villaitana — Levante Course', 'Mon - Sun', 'low', 'Jan - 6 Mar, 1 Jun - 15 Sep, 23 Nov - 31 Dec',
    '[{"start_month":1,"start_day":1,"end_month":3,"end_day":6},
      {"start_month":6,"start_day":1,"end_month":9,"end_day":15},
      {"start_month":11,"start_day":23,"end_month":12,"end_day":31}]',
    20, NULL, 5500, 3000, false, NULL, false),
  ('Villaitana — Levante Course', 'Mon - Sun', 'high', '7 Mar - 31 May, 16 Sep - 22 Nov',
    '[{"start_month":3,"start_day":7,"end_month":5,"end_day":31},
      {"start_month":9,"start_day":16,"end_month":11,"end_day":22}]',
    20, NULL, 7000, 4000, false, NULL, false),

  ('Villaitana — Poniente Course', 'Mon - Sun', 'low', 'Jan - 6 Mar, 1 Jun - 15 Sep, 23 Nov - 31 Dec',
    '[{"start_month":1,"start_day":1,"end_month":3,"end_day":6},
      {"start_month":6,"start_day":1,"end_month":9,"end_day":15},
      {"start_month":11,"start_day":23,"end_month":12,"end_day":31}]',
    20, NULL, 4500, NULL, true, NULL, false),
  ('Villaitana — Poniente Course', 'Mon - Sun', 'high', '7 Mar - 31 May, 16 Sep - 22 Nov',
    '[{"start_month":3,"start_day":7,"end_month":5,"end_day":31},
      {"start_month":9,"start_day":16,"end_month":11,"end_day":22}]',
    20, NULL, 5500, NULL, true, NULL, false),

  ('Puig Campana', 'Mon - Sun', 'low', 'Jan, Feb - 17 June - 15 Sep & Dec',
    '[{"start_month":1,"start_day":1,"end_month":2,"end_day":28},
      {"start_month":6,"start_day":17,"end_month":9,"end_day":15},
      {"start_month":12,"start_day":1,"end_month":12,"end_day":31}]',
    12, NULL, 3800, 2600, false, NULL, false),
  ('Puig Campana', 'Mon - Sun', 'high', 'Mar - 16 June, 16 Sep - Nov',
    '[{"start_month":3,"start_day":1,"end_month":6,"end_day":16},
      {"start_month":9,"start_day":16,"end_month":11,"end_day":30}]',
    12, NULL, 5000, 2600, false, NULL, false),

  ('Bonalba Golf & Spa', 'Mon - Sun', 'low',  'To Be Confirmed', NULL, 12, NULL, 5000, 1600, false, 16, true),
  ('Bonalba Golf & Spa', 'Mon - Sun', 'high', 'To Be Confirmed', NULL, 12, NULL, 5500, 2800, false, 16, true),

  ('Alenda Golf', 'Mon - Sun', 'low', '1-25 Jan, 1 June - 6 Sept',
    '[{"start_month":1,"start_day":1,"end_month":1,"end_day":25},
      {"start_month":6,"start_day":1,"end_month":9,"end_day":6}]',
    8, NULL, 5000, 3500, false, 16, false),
  ('Alenda Golf', 'Mon - Sun', 'high', '26 Jan - 31 May',
    '[{"start_month":1,"start_day":26,"end_month":5,"end_day":31}]',
    8, NULL, 6100, 3500, false, 16, false),
  ('Alenda Golf', 'Mon - Sun', 'high', '7 Sep - 13 Dec',
    '[{"start_month":9,"start_day":7,"end_month":12,"end_day":13}]',
    8, NULL, 6300, 4000, false, 16, false),
  ('Alenda Golf', 'Mon - Sun', 'low', '14 Dec - 31 Dec',
    '[{"start_month":12,"start_day":14,"end_month":12,"end_day":31}]',
    8, NULL, 5100, 4000, false, 16, false),

  ('Font del Llop Golf Resort', 'Mon - Sun', 'low', '01 Jan - 17 Feb',
    '[{"start_month":1,"start_day":1,"end_month":2,"end_day":17}]',
    12, NULL, 4500, 2200, false, 12, false),
  ('Font del Llop Golf Resort', 'Mon - Sun', 'high', '18 Feb -1 June & 7 Sep - 30 Nov',
    '[{"start_month":2,"start_day":18,"end_month":6,"end_day":1},
      {"start_month":9,"start_day":7,"end_month":11,"end_day":30}]',
    12, NULL, 6100, 2400, false, 12, false),
  ('Font del Llop Golf Resort', 'Mon - Sun', 'low', '2 June - 24 Aug & Dec',
    '[{"start_month":6,"start_day":2,"end_month":8,"end_day":24},
      {"start_month":12,"start_day":1,"end_month":12,"end_day":31}]',
    12, NULL, 4700, 2400, false, 12, false),

  ('Alicante Golf', 'Mon - Sun', 'low', 'June, July + Aug',
    '[{"start_month":6,"start_day":1,"end_month":8,"end_day":31}]',
    15, NULL, 4500, NULL, true, 15, false),
  ('Alicante Golf', 'Mon - Sun', 'mid', 'Jan, Feb + Dec',
    '[{"start_month":1,"start_day":1,"end_month":2,"end_day":28},
      {"start_month":12,"start_day":1,"end_month":12,"end_day":31}]',
    15, NULL, 4500, 2500, false, 15, false),
  ('Alicante Golf', 'Mon - Sun', 'high', 'Mar, Apr, May, Sep, Oct + Nov',
    '[{"start_month":3,"start_day":1,"end_month":5,"end_day":31},
      {"start_month":9,"start_day":1,"end_month":11,"end_day":30}]',
    15, NULL, 5600, 2500, false, 15, false),

  ('El Plantío Golf', 'Mon - Sun', 'low', 'June, July + Aug',
    '[{"start_month":6,"start_day":1,"end_month":8,"end_day":31}]',
    15, NULL, 4500, NULL, true, 15, false),
  ('El Plantío Golf', 'Mon - Sun', 'mid', 'Jan, Feb + Dec',
    '[{"start_month":1,"start_day":1,"end_month":2,"end_day":28},
      {"start_month":12,"start_day":1,"end_month":12,"end_day":31}]',
    15, NULL, 4500, 2500, false, 15, false),
  ('El Plantío Golf', 'Mon - Sun', 'high', 'Mar, Apr, May, Sep, Oct + Nov',
    '[{"start_month":3,"start_day":1,"end_month":5,"end_day":31},
      {"start_month":9,"start_day":1,"end_month":11,"end_day":30}]',
    15, NULL, 5600, 2500, false, 15, false)
) AS v(course_name, days_label, season, date_range_label, date_ranges,
       min_players, min_players_max, green_fee_cents, buggy_cents,
       buggy_included, captain_free_at, is_tbc)
JOIN external_courses ec
  ON lower(ec.name) = lower(v.course_name) AND lower(ec.country) = 'spain';

-- ===========================
-- 4. Helper RPC: rates_for_course(course_id, players, on_date)
-- ===========================
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
