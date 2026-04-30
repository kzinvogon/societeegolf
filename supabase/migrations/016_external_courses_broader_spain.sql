-- ============================================================
-- Migration 016: external_courses — broader Spain coverage
-- ============================================================
-- Adds well-known society-friendly courses across Costa del Sol,
-- Mallorca, Catalonia/Costa Brava, and Madrid so that future
-- SocieteeGolf customers in those regions land with a populated
-- catalog. No course_rates seeded — these will read as
-- "Contact for pricing" in the UI until each adopting society
-- negotiates and seeds their own rates.
--
-- Courses chosen for likely society-market relevance (public-access
-- or society-friendly, mid-market). Excludes ultra-private clubs
-- like Real Club Puerta de Hierro that don't take society bookings.
-- ============================================================

INSERT INTO external_courses (name, city, region, country, holes, source) VALUES
  -- Costa del Sol (Málaga province)
  ('La Cala Resort — Asia Course',         'Mijas Costa',           'Costa del Sol', 'Spain', 18, 'manual'),
  ('La Cala Resort — Europa Course',       'Mijas Costa',           'Costa del Sol', 'Spain', 18, 'manual'),
  ('La Cala Resort — America Course',      'Mijas Costa',           'Costa del Sol', 'Spain', 18, 'manual'),
  ('Mijas Golf — Los Lagos',               'Mijas Costa',           'Costa del Sol', 'Spain', 18, 'manual'),
  ('Mijas Golf — Los Olivos',              'Mijas Costa',           'Costa del Sol', 'Spain', 18, 'manual'),
  ('Santana Golf',                         'Mijas Costa',           'Costa del Sol', 'Spain', 18, 'manual'),
  ('Atalaya Golf — Old Course',            'Estepona',              'Costa del Sol', 'Spain', 18, 'manual'),
  ('Atalaya Golf — New Course',            'Estepona',              'Costa del Sol', 'Spain', 18, 'manual'),
  ('Cabopino Golf',                        'Marbella',              'Costa del Sol', 'Spain', 18, 'manual'),
  ('Los Naranjos Golf',                    'Marbella',              'Costa del Sol', 'Spain', 18, 'manual'),
  ('Marbella Golf & Country Club',         'Marbella',              'Costa del Sol', 'Spain', 18, 'manual'),
  ('Calanova Golf',                        'La Cala de Mijas',      'Costa del Sol', 'Spain', 18, 'manual'),
  ('Guadalhorce Golf',                     'Málaga',                'Costa del Sol', 'Spain', 18, 'manual'),
  ('Añoreta Golf',                         'Rincón de la Victoria', 'Costa del Sol', 'Spain', 18, 'manual'),
  ('Baviera Golf',                         'Caleta de Vélez',       'Costa del Sol', 'Spain', 18, 'manual'),

  -- Mallorca / Balearic Islands
  ('Son Antem Golf — East Course',         'Llucmajor',             'Mallorca',      'Spain', 18, 'manual'),
  ('Son Antem Golf — West Course',         'Llucmajor',             'Mallorca',      'Spain', 18, 'manual'),
  ('Maioris Golf',                         'Llucmajor',             'Mallorca',      'Spain', 18, 'manual'),
  ('Pula Golf',                            'Son Servera',           'Mallorca',      'Spain', 18, 'manual'),
  ('T Golf Calvià',                        'Calvià',                'Mallorca',      'Spain', 18, 'manual'),
  ('Capdepera Golf',                       'Capdepera',             'Mallorca',      'Spain', 18, 'manual'),
  ('Pollença Golf',                        'Pollença',              'Mallorca',      'Spain', 9,  'manual'),
  ('Golf Alcanada',                        'Port d''Alcúdia',       'Mallorca',      'Spain', 18, 'manual'),
  ('Son Muntaner Golf',                    'Palma',                 'Mallorca',      'Spain', 18, 'manual'),

  -- Catalonia / Costa Brava
  ('Empordà Golf — Forest Course',         'Gualta',                'Costa Brava',   'Spain', 18, 'manual'),
  ('Empordà Golf — Links Course',          'Gualta',                'Costa Brava',   'Spain', 18, 'manual'),
  ('PGA Catalunya — Stadium Course',       'Caldes de Malavella',   'Costa Brava',   'Spain', 18, 'manual'),
  ('PGA Catalunya — Tour Course',          'Caldes de Malavella',   'Costa Brava',   'Spain', 18, 'manual'),
  ('Pals Golf',                            'Pals',                  'Costa Brava',   'Spain', 18, 'manual'),
  ('Real Club de Golf de Cerdanya',        'Puigcerdà',             'Catalonia',     'Spain', 18, 'manual'),
  ('Lumine Mediterránea Beach & Golf',     'Tarragona',             'Catalonia',     'Spain', 18, 'manual'),

  -- Madrid area (society-friendly only)
  ('Centro Nacional de Golf',              'Madrid',                'Madrid',        'Spain', 18, 'manual'),
  ('Olivar de la Hinojosa',                'Madrid',                'Madrid',        'Spain', 18, 'manual'),
  ('Encín Golf',                           'Alcalá de Henares',     'Madrid',        'Spain', 18, 'manual'),

  -- Canary Islands (popular winter society destination)
  ('Costa Adeje Golf',                     'Adeje',                 'Tenerife',      'Spain', 18, 'manual'),
  ('Buenavista Golf',                      'Buenavista del Norte',  'Tenerife',      'Spain', 18, 'manual'),
  ('Las Américas Golf',                    'Playa de las Américas', 'Tenerife',      'Spain', 18, 'manual')
ON CONFLICT (lower(name), lower(country)) DO NOTHING;
