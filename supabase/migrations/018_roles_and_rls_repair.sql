-- ============================================================
-- Migration 018: roles & permissions (Phase A) + repair stale RLS
-- ============================================================
-- Two related changes:
--
-- 1. Expand members.role from {'member','admin'} to a richer set:
--    'member' | 'vice_captain' | 'captain' | 'treasurer' | 'admin' | 'sponsor'.
--    Adds a flexible has_role_in(society_id, roles[]) helper that the
--    RLS policies use, so the role logic lives in one place.
--
-- 2. Repair the events / messages / results / signups admin policies
--    that were left referencing members.id = auth.uid() — stale since
--    migration 011 split the membership PK from the auth user id.
--    For societies other than the default '0…001', register_society
--    now creates members with id = gen_random_uuid() and user_id =
--    auth.uid(); the old policies couldn't ever pass for those rows,
--    so admins of newly-registered societies couldn't write events
--    at all. This rebuild fixes that AND extends write permission to
--    captain + vice_captain (and treasurer for messages).
-- ============================================================

-- 1. Widen the role allowlist.
ALTER TABLE members DROP CONSTRAINT IF EXISTS members_role_check;
ALTER TABLE members ADD CONSTRAINT members_role_check
  CHECK (role IN ('member', 'vice_captain', 'captain', 'treasurer', 'admin', 'sponsor'));

-- 2. Generic role-check helper. SECURITY DEFINER so it bypasses RLS
--    and avoids the recursion risk we hit in migration 003.
CREATE OR REPLACE FUNCTION public.has_role_in(check_society_id UUID, allowed_roles TEXT[])
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.members
    WHERE user_id = auth.uid()
      AND society_id = check_society_id
      AND role = ANY(allowed_roles)
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

REVOKE ALL ON FUNCTION public.has_role_in(UUID, TEXT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.has_role_in(UUID, TEXT[]) TO anon, authenticated;

-- 3. Keep is_admin_of working (existing call sites don't need to change).
CREATE OR REPLACE FUNCTION public.is_admin_of(check_society_id UUID)
RETURNS BOOLEAN AS $$
  SELECT public.has_role_in(check_society_id, ARRAY['admin']);
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- ===========================
-- 4. Rebuild stale RLS policies — use user_id and accept event-running
--    roles (admin / captain / vice_captain). Treasurer also gets to
--    post messages so they can send finance broadcasts.
-- ===========================

-- events: admin/captain/vice_captain can manage. Anyone in the society
-- can SELECT (existing events_select_same_society stays).
DROP POLICY IF EXISTS "events_admin_all" ON events;
CREATE POLICY "events_admin_all" ON events
  FOR ALL USING (
    public.has_role_in(society_id, ARRAY['admin','captain','vice_captain'])
  );

-- messages: same write set + treasurer.
DROP POLICY IF EXISTS "messages_admin_all" ON messages;
CREATE POLICY "messages_admin_all" ON messages
  FOR ALL USING (
    public.has_role_in(society_id, ARRAY['admin','captain','vice_captain','treasurer'])
  );

-- results: scope through events.society_id.
DROP POLICY IF EXISTS "results_admin_all" ON results;
CREATE POLICY "results_admin_all" ON results
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM events e
      WHERE e.id = results.event_id
        AND public.has_role_in(e.society_id, ARRAY['admin','captain','vice_captain'])
    )
  );

-- signups: same — admins/captains/VCs can edit any member's signup
-- (e.g. mark paid). Members keep their own delete + select policies.
DROP POLICY IF EXISTS "signups_admin_all" ON signups;
CREATE POLICY "signups_admin_all" ON signups
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM events e
      WHERE e.id = signups.event_id
        AND public.has_role_in(e.society_id, ARRAY['admin','captain','vice_captain'])
    )
  );

-- ===========================
-- 5. signups_insert_own: today this policy has no WITH CHECK
--    expression (NULL), which silently allows any authenticated insert.
--    Repair it to match the table's actual semantics: a member can
--    only sign UP themselves, scoped to a member row whose user_id is
--    auth.uid().
-- ===========================
DROP POLICY IF EXISTS "signups_insert_own" ON signups;
CREATE POLICY "signups_insert_own" ON signups
  FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM members m
      WHERE m.id = signups.member_id
        AND m.user_id = auth.uid()
    )
  );

-- ===========================
-- 6. course_rates_admin_all already uses is_admin_of (which we kept
--    backward-compatible above), so it remains admin-only by design.
--    Captain doesn't negotiate green-fee rates with the courses; that's
--    an admin/treasurer concern. Extending to treasurer is a separate
--    decision and held for a future migration.
-- ===========================
