-- ============================================================
-- Migration 009: register_society — block already-known emails
-- ============================================================
-- The previous register_society always inserted with gen_random_uuid()
-- and relied on handle_new_user (migration 005) to re-key by email.
-- That trigger only fires on auth.users INSERT — so when an admin
-- registering a new society already had an auth.users row (e.g. they'd
-- previously joined another society), the trigger never re-keyed the
-- new placeholder, leaving members.id mismatched with auth.users.id.
--
-- A clean fix would let one auth.users.id back multiple member rows,
-- but the members PK is just `id`, so the same auth uid can only
-- appear once across the whole table. That's a real multi-society
-- design limit which needs a separate schema migration to fix
-- (recommended: add members.user_id UUID, drop the id == auth.uid()
-- linkage, update RLS + queries to filter on user_id).
--
-- Until that lands, this migration:
--  1. Adds a guard to register_society that rejects the request if the
--     admin email already has an auth.users row OR an existing members
--     row anywhere — so we fail loudly with a clear error instead of
--     creating an orphan row.
--  2. Does NOT touch the existing function body otherwise.
--  3. Does NOT backfill the orphan rows from earlier registrations —
--     the constraint above prevents the obvious fix and the proper
--     answer is the schema migration above.
-- ============================================================

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

  -- Multi-society membership isn't supported by the current schema
  -- (members PK is `id` = auth.uid(), so one auth user → one member
  -- row across the entire table). If this email already has an
  -- auth.users row OR an existing members row, fail loudly.
  IF EXISTS (SELECT 1 FROM auth.users WHERE lower(email) = v_email) THEN
    RETURN jsonb_build_object('success', false, 'error', 'admin_email_in_use');
  END IF;
  IF EXISTS (SELECT 1 FROM members WHERE lower(email) = v_email) THEN
    RETURN jsonb_build_object('success', false, 'error', 'admin_email_in_use');
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
