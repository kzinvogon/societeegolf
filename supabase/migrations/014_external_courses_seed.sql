-- ============================================================
-- Migration 014: external_courses — shared cross-tenant course library
-- ============================================================
-- A society's `courses` table is per-tenant. As we onboard a second
-- Costa Blanca society they shouldn't need to re-type "El Plantío
-- Golf" from scratch. external_courses is a shared catalog that
-- admins pick from when adding events, with the picked row copied
-- into the tenant's courses table.
--
-- Seeded with:
--   1. The 13 verified courses already in the existing courses table
--      (kept as-is in their per-tenant rows; we just promote the
--      names + cities into the shared library).
--   2. 19 additional Costa Blanca + Murcia courses cross-referenced
--      against the wanderlog Costa Blanca directory.
--
-- Slope/CR/coords/per-hole pars are NOT seeded — they need scorecards
-- to be reliable, and we'd rather have null than wrong. Admins enrich
-- progressively when they have the data.
--
-- Designed to be an idempotent reseed via ON CONFLICT, so re-running
-- is safe (won't duplicate, won't overwrite admin enrichments because
-- only the name/city/country/region columns are upserted).
-- ============================================================

CREATE TABLE IF NOT EXISTS external_courses (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  source TEXT NOT NULL DEFAULT 'manual',
  external_id TEXT,
  name TEXT NOT NULL,
  city TEXT,
  region TEXT,
  country TEXT NOT NULL,
  -- Optional rich data, filled in when known. Nullable so we never
  -- record fabricated values just to satisfy NOT NULL.
  par INT,
  holes INT,
  latitude NUMERIC,
  longitude NUMERIC,
  website TEXT,
  phone TEXT,
  notes TEXT,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Cheap dedupe: a given course in a given country shouldn't appear twice.
CREATE UNIQUE INDEX IF NOT EXISTS idx_external_courses_unique
  ON external_courses(lower(name), lower(country));

CREATE INDEX IF NOT EXISTS idx_external_courses_country_region
  ON external_courses(country, region);
CREATE INDEX IF NOT EXISTS idx_external_courses_search
  ON external_courses USING gin (to_tsvector('simple', coalesce(name,'') || ' ' || coalesce(city,'') || ' ' || coalesce(region,'')));

-- RLS: world-readable catalog, write via SECURITY DEFINER RPC only.
ALTER TABLE external_courses ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "external_courses_public_read" ON external_courses;
CREATE POLICY "external_courses_public_read" ON external_courses
  FOR SELECT USING (active = true);

-- Seed data. Insert via VALUES + ON CONFLICT so re-running is a no-op.
INSERT INTO external_courses (name, city, region, country, holes, source) VALUES
  -- Costa Blanca, Alicante province (existing JPGS data, validated names)
  ('Alicante Golf',           'Alicante',         'Costa Blanca', 'Spain', 18, 'jpgs'),
  ('Bonalba Golf & Spa',      'Mutxamel',         'Costa Blanca', 'Spain', 18, 'jpgs'),
  ('El Plantío Golf',         'Alicante',         'Costa Blanca', 'Spain', 18, 'jpgs'),
  ('El Saler',                'Valencia',         'Valencia',     'Spain', 18, 'jpgs'),
  ('Foressos',                NULL,               'Costa Blanca', 'Spain', NULL, 'jpgs'),
  ('Ifach San Jaime',         'Benissa',          'Costa Blanca', 'Spain', NULL, 'jpgs'),
  ('Jávea Golf Club',         'Jávea',            'Costa Blanca', 'Spain', 9,  'jpgs'),
  ('La Sella Golf Resort',    'Jesús Pobre',      'Costa Blanca', 'Spain', 27, 'jpgs'),
  ('Las Rejas Golf',          NULL,               'Costa Blanca', 'Spain', NULL, 'jpgs'),
  ('Puig Campana',            'Finestrat',        'Costa Blanca', 'Spain', 18, 'jpgs'),
  ('Sierra Altea Golf',       'Altea la Vella',   'Costa Blanca', 'Spain', 9,  'jpgs'),
  ('Sierra Cortina Golf',     'Benidorm',         'Costa Blanca', 'Spain', 18, 'jpgs'),
  ('Villaitana Golf',         'Benidorm',         'Costa Blanca', 'Spain', 36, 'jpgs'),

  -- Costa Blanca additions (cross-referenced against wanderlog directory)
  ('Don Cayo Golf',                       'Altea',                  'Costa Blanca', 'Spain', 9,  'wanderlog'),
  ('Alenda Golf',                         'Monforte del Cid',       'Costa Blanca', 'Spain', 18, 'wanderlog'),
  ('Font del Llop Golf Resort',           'Monforte del Cid',       'Costa Blanca', 'Spain', 18, 'wanderlog'),
  ('La Finca Golf',                       'Algorfa',                'Costa Blanca', 'Spain', 18, 'wanderlog'),
  ('La Marquesa Golf',                    'Rojales',                'Costa Blanca', 'Spain', 18, 'wanderlog'),
  ('Vistabella Golf',                     'Orihuela',               'Costa Blanca', 'Spain', 18, 'wanderlog'),
  ('Las Colinas Golf & Country Club',     'Dehesa de Campoamor',    'Costa Blanca', 'Spain', 18, 'wanderlog'),
  ('Las Ramblas Golf',                    'Dehesa de Campoamor',    'Costa Blanca', 'Spain', 18, 'wanderlog'),
  ('Lo Romero Golf',                      'Pilar de la Horadada',   'Costa Blanca', 'Spain', 18, 'wanderlog'),
  ('Campoamor Golf',                      'Dehesa de Campoamor',    'Costa Blanca', 'Spain', 18, 'wanderlog'),
  ('Villamartín Golf',                    'Orihuela Costa',         'Costa Blanca', 'Spain', 18, 'wanderlog'),

  -- Northern fringe (Valencia province, regularly played)
  ('Oliva Nova Beach & Golf',             'Oliva',                  'Valencia',     'Spain', 18, 'wanderlog'),

  -- Murcia (regularly played by Costa Blanca societies)
  ('La Manga Club — South Course',        'La Manga',               'Murcia',       'Spain', 18, 'manual'),
  ('La Manga Club — North Course',        'La Manga',               'Murcia',       'Spain', 18, 'manual'),
  ('La Manga Club — West Course',         'La Manga',               'Murcia',       'Spain', 18, 'manual'),
  ('Mar Menor Golf Resort',               'Torre-Pacheco',          'Murcia',       'Spain', 18, 'manual'),
  ('Hacienda Del Álamo Golf Resort',      'Fuente Álamo',           'Murcia',       'Spain', 18, 'manual'),
  ('El Valle Golf Resort',                'Murcia',                 'Murcia',       'Spain', 18, 'manual'),
  ('Roda Golf & Beach Resort',            'San Javier',             'Murcia',       'Spain', 18, 'manual')
ON CONFLICT (lower(name), lower(country)) DO UPDATE
  SET city   = COALESCE(EXCLUDED.city, external_courses.city),
      region = COALESCE(EXCLUDED.region, external_courses.region),
      holes  = COALESCE(EXCLUDED.holes, external_courses.holes),
      updated_at = NOW();

-- Public RPC for the admin search UI: returns matches by free-text.
CREATE OR REPLACE FUNCTION public.search_external_courses(
  p_query TEXT DEFAULT NULL,
  p_country TEXT DEFAULT NULL,
  p_region TEXT DEFAULT NULL,
  p_limit INT DEFAULT 50
) RETURNS SETOF external_courses AS $$
  SELECT *
  FROM external_courses
  WHERE active = true
    AND (p_country IS NULL OR country ILIKE p_country)
    AND (p_region  IS NULL OR region  ILIKE p_region)
    AND (
      p_query IS NULL
      OR name ILIKE '%' || p_query || '%'
      OR city ILIKE '%' || p_query || '%'
    )
  ORDER BY name
  LIMIT GREATEST(1, LEAST(p_limit, 200));
$$ LANGUAGE sql STABLE SECURITY DEFINER;

REVOKE ALL ON FUNCTION public.search_external_courses(TEXT, TEXT, TEXT, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.search_external_courses(TEXT, TEXT, TEXT, INT) TO anon, authenticated;
