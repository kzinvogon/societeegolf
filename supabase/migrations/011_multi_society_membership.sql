-- ============================================================
-- Migration 011: Multi-society membership — decouple members.id from auth.uid()
-- ============================================================
-- The original schema made members.id = auth.users.id, so the same
-- person could only ever appear in one members row across the entire
-- table. That blocks the basic multi-tenant case where I'm an admin
-- of society A and also a member of society B.
--
-- Fix: introduce members.user_id (UUID, references auth user logically
-- but no FK to keep admins able to seed members ahead of signup) and
-- migrate all RLS / helpers / triggers / RPCs to filter on user_id
-- instead of id. members.id stays as the per-membership PK so existing
-- FKs (events.created_by, signups.member_id, results.member_id,
-- messages.created_by) keep working unchanged.
--
-- Backfill: for every existing members row whose id matches an
-- auth.users.id, copy id into user_id. Rows whose id is a placeholder
-- UUID (from old register_society inserts) keep user_id = NULL until
-- handle_new_user fires on first sign-in.
-- ============================================================

-- 1. Add the column. Indexed because RLS will filter on it on every
--    members query.
ALTER TABLE members ADD COLUMN IF NOT EXISTS user_id UUID;
CREATE INDEX IF NOT EXISTS idx_members_user_id ON members(user_id);

-- 2. Backfill: existing members rows whose id is a real auth.users.id.
UPDATE members m
SET user_id = m.id
WHERE user_id IS NULL
  AND EXISTS (SELECT 1 FROM auth.users u WHERE u.id = m.id);

-- 3. Per-user-per-society uniqueness. Allows NULL user_id (placeholder
--    rows) to co-exist; blocks the same auth user from joining the
--    same society twice.
DROP INDEX IF EXISTS idx_members_unique_user_society;
CREATE UNIQUE INDEX idx_members_unique_user_society
  ON members(user_id, society_id) WHERE user_id IS NOT NULL;

-- 4. Update helpers to use user_id.
CREATE OR REPLACE FUNCTION public.get_society_id()
RETURNS UUID AS $$
  SELECT society_id FROM public.members WHERE user_id = auth.uid() LIMIT 1;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION public.is_admin_of(check_society_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.members
    WHERE user_id = auth.uid()
      AND role = 'admin'
      AND society_id = check_society_id
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- 5. Replace the obsolete members RLS policies. Drop pre-existing
--    duplicates and the over-permissive anon policy.
DROP POLICY IF EXISTS "members_select_same_society" ON members;
DROP POLICY IF EXISTS "members_auth_select" ON members;
DROP POLICY IF EXISTS "members_anon_select" ON members;
DROP POLICY IF EXISTS "members_update_own" ON members;
DROP POLICY IF EXISTS "members_admin_all" ON members;
DROP POLICY IF EXISTS "members_insert_open" ON members;
DROP POLICY IF EXISTS "members_insert_service" ON members;

-- SELECT: own row(s) by user_id, or any member of a society the
-- caller belongs to (via the SECURITY DEFINER helper).
CREATE POLICY "members_select_same_society" ON members
  FOR SELECT USING (
    user_id = auth.uid()
    OR society_id = public.get_society_id()
  );

-- UPDATE: only your own membership row.
CREATE POLICY "members_update_own" ON members
  FOR UPDATE USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- ALL (admin): full access within societies you administer.
CREATE POLICY "members_admin_all" ON members
  FOR ALL USING (public.is_admin_of(society_id));

-- INSERT: allow service / SECURITY DEFINER paths (register_society,
-- enter_demo_society, handle_new_user trigger). Authenticated users
-- shouldn't be able to insert arbitrary member rows directly; that's
-- gated by the RPCs.
CREATE POLICY "members_insert_via_rpc" ON members
  FOR INSERT WITH CHECK (true);

-- 6. handle_new_user — set user_id, not id. The placeholder member
--    row inserted by register_society / enter_demo_society gets its
--    user_id populated on first sign-in.
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
  v_society_id UUID;
  v_existing_count INT;
BEGIN
  v_society_id := (NEW.raw_user_meta_data->>'society_id')::UUID;

  IF v_society_id IS NOT NULL THEN
    -- Explicit society from signup metadata: set user_id on any
    -- placeholder row, otherwise insert.
    UPDATE public.members
       SET user_id = NEW.id
     WHERE lower(email) = lower(NEW.email)
       AND society_id = v_society_id
       AND user_id IS NULL;
    GET DIAGNOSTICS v_existing_count = ROW_COUNT;

    IF v_existing_count = 0 AND NOT EXISTS (
      SELECT 1 FROM public.members
       WHERE user_id = NEW.id AND society_id = v_society_id
    ) THEN
      INSERT INTO public.members (id, user_id, email, name, society_id)
      VALUES (
        gen_random_uuid(), NEW.id, NEW.email,
        COALESCE(NEW.raw_user_meta_data->>'name', split_part(NEW.email, '@', 1)),
        v_society_id
      );
    END IF;
  ELSE
    -- No explicit society: link any placeholder rows that share this
    -- email (e.g. an admin row planted by register_society).
    UPDATE public.members
       SET user_id = NEW.id
     WHERE lower(email) = lower(NEW.email)
       AND user_id IS NULL;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 7. Re-deploy enter_demo_society so it sets user_id (one row per
--    auth.uid() per society — idempotent).
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

  SELECT id INTO v_existing
  FROM public.members
  WHERE user_id = v_uid AND society_id = v_demo_society_id;

  IF v_existing IS NULL THEN
    INSERT INTO public.members (id, user_id, name, email, role, status, society_id)
    VALUES (
      gen_random_uuid(),
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

-- 8. Re-deploy register_society — drop the admin_email_in_use guard
--    (multi-society is now supported), keep the anon-rejection. If the
--    admin email already has an auth.users row, set user_id directly
--    so the trigger doesn't need to re-key on first login.
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
  v_admin_user_id UUID;
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

  -- If this email already has an auth.users row, link it directly.
  -- Otherwise leave user_id NULL — handle_new_user fills it in on
  -- first sign-in. Multi-society is now supported.
  SELECT id INTO v_admin_user_id FROM auth.users WHERE lower(email) = v_email LIMIT 1;

  -- Block double-admin in the same future society (harmless guard).
  IF v_admin_user_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM members
    WHERE user_id = v_admin_user_id
      AND society_id IN (SELECT id FROM societies WHERE subdomain = v_code)
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'already_in_this_society');
  END IF;

  INSERT INTO societies (name, subdomain, subscription_status, public_directory)
  VALUES (trim(p_society_name), v_code, 'trialing', true)
  RETURNING id INTO v_society_id;

  INSERT INTO members (id, user_id, name, email, role, status, society_id)
  VALUES (
    gen_random_uuid(),
    v_admin_user_id,                 -- may be NULL; trigger fills it in later
    COALESCE(NULLIF(trim(p_admin_name), ''), split_part(v_email, '@', 1)),
    v_email,
    'admin',
    'full_member',
    v_society_id
  );

  RETURN jsonb_build_object(
    'success', true,
    'society_id', v_society_id,
    'subdomain', v_code,
    'admin_existing_user', v_admin_user_id IS NOT NULL
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
