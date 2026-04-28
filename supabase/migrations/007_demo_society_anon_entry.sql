-- ============================================================
-- Migration 007: Demo society — anonymous-auth entry RPC
-- ============================================================
-- Lets a freshly-signed-anonymous-in user join the demo society as a
-- real member with full member view + admin tab access. Each demo
-- session = one auth.users row + one members row scoped to the demo
-- society. RLS keeps them walled in.
--
-- Also tightens register_society() to reject anonymous callers, so the
-- demo session can't be used to bootstrap a real society.
-- ============================================================

-- enter_demo_society():
-- Caller must be authenticated (anon JWT counts). Inserts a members row
-- in the demo society for auth.uid() if one doesn't already exist, and
-- returns the demo society's id + subdomain. Idempotent — calling
-- twice returns the existing membership.
CREATE OR REPLACE FUNCTION public.enter_demo_society()
RETURNS JSONB AS $$
DECLARE
  v_demo_society_id UUID := '00000000-0000-0000-0000-000000000002';
  v_uid UUID := auth.uid();
  v_existing UUID;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_authenticated');
  END IF;

  -- Idempotent — return existing membership if already a demo member.
  SELECT id INTO v_existing
  FROM public.members
  WHERE id = v_uid AND society_id = v_demo_society_id;

  IF v_existing IS NULL THEN
    INSERT INTO public.members (id, name, email, role, status, society_id)
    VALUES (
      v_uid,
      'Demo Visitor',
      'demo+' || substr(v_uid::text, 1, 8) || '@societeegolf.app',
      'admin',
      'full_member',
      v_demo_society_id
    );
  END IF;

  RETURN jsonb_build_object(
    'success', true,
    'society_id', v_demo_society_id,
    'subdomain', 'demo'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE ALL ON FUNCTION public.enter_demo_society() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.enter_demo_society() TO anon, authenticated;

-- Tighten register_society: a demo (anonymous) user must not be able to
-- create real societies. Anonymous users have is_anonymous=true on
-- their JWT (Supabase sets this for signInAnonymously sessions).
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
  -- Reject anonymous callers (demo users) up front.
  IF (auth.jwt() ->> 'is_anonymous')::boolean IS TRUE THEN
    RETURN jsonb_build_object('success', false, 'error', 'anon_disallowed');
  END IF;

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

-- Optional cleanup helper. Not scheduled — invoke manually or via
-- pg_cron when you set that up. Removes anonymous demo accounts older
-- than 24 hours and their member rows + signups.
CREATE OR REPLACE FUNCTION public.cleanup_demo_anon_users()
RETURNS INT AS $$
DECLARE
  v_deleted INT;
BEGIN
  WITH stale AS (
    SELECT u.id
    FROM auth.users u
    WHERE u.is_anonymous = true
      AND u.created_at < NOW() - INTERVAL '24 hours'
  )
  DELETE FROM auth.users WHERE id IN (SELECT id FROM stale);
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE ALL ON FUNCTION public.cleanup_demo_anon_users() FROM PUBLIC;
-- Intentionally not granted to anon/authenticated — admin-only invocation.
