-- ============================================================
-- Migration 006: Society directory + self-serve signup
-- ============================================================
-- Replaces the per-subdomain landing-page model with a single app
-- entry that lets visitors:
--   1. Find an existing society and request to join.
--   2. Register a new society and become its admin.
--   3. Try a seeded demo society without signing up.
--
-- Changes:
--   - societies gains is_demo + public_directory flags.
--   - society_directory() RPC: anon-callable list of joinable
--     societies for the "Find my society" search.
--   - register_society() RPC: anon-callable to create a society +
--     placeholder admin member. The handle_new_user trigger
--     (migration 005) re-keys the placeholder when the admin's
--     magic link is consumed.
--   - Reserved codes that match resolveTenantSlugFromHost() so the
--     URL routing (f7a3383, dormant for now) stays consistent if
--     turned on later.
--   - Seed a "demo" society for the Try Demo path.
-- ============================================================

-- 1. New columns on societies
ALTER TABLE societies ADD COLUMN IF NOT EXISTS is_demo BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE societies ADD COLUMN IF NOT EXISTS public_directory BOOLEAN NOT NULL DEFAULT true;

-- The seed default society is the SocieteeGolf "house" — keep it out
-- of the directory; demo lives in its own row below.
UPDATE societies SET public_directory = false
  WHERE id = '00000000-0000-0000-0000-000000000001';

-- 2. Directory RPC — anon-callable search list
CREATE OR REPLACE FUNCTION public.society_directory()
RETURNS TABLE (name TEXT, subdomain TEXT) AS $$
  SELECT name, subdomain
  FROM societies
  WHERE subscription_status IN ('active','trial','free')
    AND public_directory = true
    AND is_demo = false
  ORDER BY name;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

REVOKE ALL ON FUNCTION public.society_directory() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.society_directory() TO anon, authenticated;

-- 3. Register-society RPC — anon-callable, returns JSON envelope.
-- The placeholder member row is re-keyed to the real auth.users.id by
-- handle_new_user when the admin verifies the magic link.
CREATE OR REPLACE FUNCTION public.register_society(
  p_society_name TEXT,
  p_society_code TEXT,
  p_admin_name TEXT,
  p_admin_email TEXT
) RETURNS JSONB AS $$
DECLARE
  v_society_id UUID;
  v_code TEXT;
  v_email TEXT;
BEGIN
  v_code  := lower(trim(p_society_code));
  v_email := lower(trim(p_admin_email));

  IF v_code IS NULL OR v_code !~ '^[a-z0-9][a-z0-9-]{1,31}$' THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_code');
  END IF;

  IF v_code IN ('app','www','api','admin','mail','staging','preview','dev','demo','default','support','help','status','blog','docs') THEN
    RETURN jsonb_build_object('success', false, 'error', 'reserved_code');
  END IF;

  IF EXISTS (SELECT 1 FROM societies WHERE subdomain = v_code) THEN
    RETURN jsonb_build_object('success', false, 'error', 'code_taken');
  END IF;

  IF p_society_name IS NULL OR length(trim(p_society_name)) < 2 THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_society_name');
  END IF;

  IF v_email IS NULL OR v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_email');
  END IF;

  INSERT INTO societies (name, subdomain, subscription_status, public_directory)
  VALUES (trim(p_society_name), v_code, 'trial', true)
  RETURNING id INTO v_society_id;

  INSERT INTO members (id, name, email, role, status, society_id)
  VALUES (
    gen_random_uuid(),
    COALESCE(NULLIF(trim(p_admin_name), ''), split_part(v_email, '@', 1)),
    v_email,
    'admin',
    'full_member',
    v_society_id
  );

  RETURN jsonb_build_object(
    'success', true,
    'society_id', v_society_id,
    'subdomain', v_code
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE ALL ON FUNCTION public.register_society(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_society(TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;

-- 4. Seed the demo society
INSERT INTO societies (id, name, subdomain, subscription_status, is_demo, public_directory, config)
VALUES (
  '00000000-0000-0000-0000-000000000002',
  'Demo Golf Society',
  'demo',
  'free',
  true,
  false,
  '{
    "tagline": "See SocieteeGolf in action.",
    "description": "This is a demo society with sample events and members so you can see how SocieteeGolf works."
  }'::jsonb
) ON CONFLICT (id) DO UPDATE SET
  is_demo = true,
  public_directory = false,
  subdomain = EXCLUDED.subdomain;

-- Seed a couple of sample events for the demo society so the visitor
-- view has something to render. Only insert if the society has none.
INSERT INTO events (title, date, course, location, format, cost, signup_limit, signup_cutoff, tee_time_start, tee_interval, notes, society_id)
SELECT
  v.title, v.date, v.course, v.location, v.format, v.cost, v.signup_limit,
  v.signup_cutoff, v.tee_time_start::time, v.tee_interval, v.notes,
  '00000000-0000-0000-0000-000000000002'
FROM (VALUES
  ('Spring Stableford', (CURRENT_DATE + INTERVAL '14 days')::date, 'Sample Golf Club', 'Demo Town', 'Stableford',
    45.00, 24, (CURRENT_DATE + INTERVAL '10 days')::date, '09:00', 10, 'Demo event — buggies on request.'),
  ('Summer Medal',     (CURRENT_DATE + INTERVAL '45 days')::date, 'Demo Heath',       'Demo Town', 'Medal',
    50.00, 32, (CURRENT_DATE + INTERVAL '40 days')::date, '08:30', 10, 'Demo event — full handicap allowance.')
) AS v(title, date, course, location, format, cost, signup_limit, signup_cutoff, tee_time_start, tee_interval, notes)
WHERE NOT EXISTS (
  SELECT 1 FROM events
  WHERE society_id = '00000000-0000-0000-0000-000000000002'
);
