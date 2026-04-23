-- ============================================================
-- Migration 003: Fix RLS infinite recursion on members / join_requests
-- ============================================================
-- The members_select_same_society / members_admin_all / join_requests_admin_all
-- policies contained subqueries on the members table. PostgreSQL re-evaluates
-- the RLS policy for each row scanned in the subquery, which recurses back
-- into the same policy and aborts with 500.
--
-- Fix: wrap the "is the current user an admin of X" check in a SECURITY
-- DEFINER function (which bypasses RLS). Simplify members_select_same_society
-- by relying only on the existing SECURITY DEFINER helper get_society_id()
-- plus a direct auth.uid() comparison so users can always read their own row.
-- ============================================================

-- Helper: is the current user an admin in the given society?
CREATE OR REPLACE FUNCTION public.is_admin_of(check_society_id UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.members
    WHERE id = auth.uid()
      AND role = 'admin'
      AND society_id = check_society_id
  );
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- ===========================
-- MEMBERS — rebuild policies without recursion
-- ===========================
DROP POLICY IF EXISTS "members_select_same_society" ON members;
DROP POLICY IF EXISTS "members_admin_all" ON members;

-- SELECT: user can read their own row, plus other members of the same society.
-- Both branches rely on auth.uid() directly or the SECURITY DEFINER helper.
CREATE POLICY "members_select_same_society" ON members
  FOR SELECT USING (
    id = auth.uid()
    OR society_id = public.get_society_id()
  );

-- Admin: manage all members in the same society, via SECURITY DEFINER helper.
CREATE POLICY "members_admin_all" ON members
  FOR ALL USING (public.is_admin_of(society_id));

-- ===========================
-- JOIN_REQUESTS — rebuild admin policy without recursion
-- ===========================
DROP POLICY IF EXISTS "join_requests_admin_all" ON join_requests;

CREATE POLICY "join_requests_admin_all" ON join_requests
  FOR ALL USING (public.is_admin_of(society_id));

-- Also allow a just-logged-in user to read their own approved join_request,
-- so the app can auto-create the members row on first login.
-- Use auth.jwt() to read the email claim directly — the `authenticated`
-- role doesn't have SELECT on auth.users.
DROP POLICY IF EXISTS "join_requests_self_select" ON join_requests;
CREATE POLICY "join_requests_self_select" ON join_requests
  FOR SELECT USING (
    email = (auth.jwt() ->> 'email')::text
  );
