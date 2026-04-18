-- ============================================================
-- Migration 002: Row Level Security — society-scoped access
-- ============================================================
-- Replaces all existing RLS policies with society-scoped versions.
-- Users can only access rows matching their society_id.
-- Admin role grants management within their own society.
-- ============================================================

-- Helper function: get the current user's society_id from their member record
CREATE OR REPLACE FUNCTION public.get_society_id()
RETURNS UUID AS $$
  SELECT society_id FROM public.members WHERE id = auth.uid() LIMIT 1;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- ===========================
-- SOCIETIES
-- ===========================
ALTER TABLE societies ENABLE ROW LEVEL SECURITY;

-- Anyone can read societies (needed for subdomain lookup on login)
CREATE POLICY "Anyone can view societies" ON societies
  FOR SELECT USING (true);

-- Only superadmins (future) can manage societies
-- For now, managed via direct DB access

-- ===========================
-- MEMBERS — drop old policies, add society-scoped
-- ===========================

-- Drop existing policies
DROP POLICY IF EXISTS "Public can view active members" ON members;
DROP POLICY IF EXISTS "Anyone can view members" ON members;
DROP POLICY IF EXISTS "Users can view own profile" ON members;
DROP POLICY IF EXISTS "Users can update own profile" ON members;
DROP POLICY IF EXISTS "Admins can manage members" ON members;

-- Members can view other members in their society
CREATE POLICY "members_select_same_society" ON members
  FOR SELECT USING (
    society_id = public.get_society_id()
    OR society_id = (SELECT society_id FROM members WHERE id = auth.uid())
  );

-- Users can update their own profile
CREATE POLICY "members_update_own" ON members
  FOR UPDATE USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- Admins can manage all members in their society
CREATE POLICY "members_admin_all" ON members
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM members
      WHERE id = auth.uid()
        AND role = 'admin'
        AND society_id = members.society_id
    )
  );

-- Allow insert for the trigger (admin-created members)
CREATE POLICY "members_insert_service" ON members
  FOR INSERT WITH CHECK (true);

-- ===========================
-- EVENTS — society-scoped
-- ===========================

DROP POLICY IF EXISTS "Anyone can view events" ON events;
DROP POLICY IF EXISTS "Admins can manage events" ON events;

-- Anyone in the society can view events
CREATE POLICY "events_select_same_society" ON events
  FOR SELECT USING (
    society_id = public.get_society_id()
    OR society_id IN (SELECT society_id FROM members WHERE id = auth.uid())
  );

-- Admins can manage events in their society
CREATE POLICY "events_admin_all" ON events
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM members
      WHERE id = auth.uid()
        AND role = 'admin'
        AND society_id = events.society_id
    )
  );

-- Allow anonymous read for visitor view (events are public)
CREATE POLICY "events_anon_select" ON events
  FOR SELECT USING (true);

-- ===========================
-- SIGNUPS — scoped through event's society
-- ===========================

DROP POLICY IF EXISTS "Authenticated can view signups" ON signups;
DROP POLICY IF EXISTS "Members can sign up" ON signups;
DROP POLICY IF EXISTS "Members can withdraw own signup" ON signups;
DROP POLICY IF EXISTS "Admins can manage signups" ON signups;

-- Authenticated users can view signups for events in their society
CREATE POLICY "signups_select_same_society" ON signups
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM events
      WHERE events.id = signups.event_id
        AND events.society_id = public.get_society_id()
    )
  );

-- Members can sign up for events in their society
CREATE POLICY "signups_insert_own" ON signups
  FOR INSERT WITH CHECK (
    auth.uid() = member_id
    AND EXISTS (
      SELECT 1 FROM events
      WHERE events.id = signups.event_id
        AND events.society_id = public.get_society_id()
    )
  );

-- Members can withdraw their own signup
CREATE POLICY "signups_delete_own" ON signups
  FOR DELETE USING (auth.uid() = member_id);

-- Admins can manage signups in their society
CREATE POLICY "signups_admin_all" ON signups
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM events e
      JOIN members m ON m.id = auth.uid()
      WHERE e.id = signups.event_id
        AND m.role = 'admin'
        AND m.society_id = e.society_id
    )
  );

-- ===========================
-- RESULTS — scoped through event's society
-- ===========================

DROP POLICY IF EXISTS "Anyone can view results" ON results;
DROP POLICY IF EXISTS "Admins can manage results" ON results;

-- Anyone can view results (public leaderboards)
CREATE POLICY "results_select_public" ON results
  FOR SELECT USING (true);

-- Admins can manage results in their society
CREATE POLICY "results_admin_all" ON results
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM events e
      JOIN members m ON m.id = auth.uid()
      WHERE e.id = results.event_id
        AND m.role = 'admin'
        AND m.society_id = e.society_id
    )
  );

-- ===========================
-- MESSAGES — society-scoped
-- ===========================

DROP POLICY IF EXISTS "Authenticated can view messages" ON messages;
DROP POLICY IF EXISTS "Admins can manage messages" ON messages;

-- Authenticated members can view messages in their society
CREATE POLICY "messages_select_same_society" ON messages
  FOR SELECT USING (
    society_id = public.get_society_id()
  );

-- Admins can manage messages in their society
CREATE POLICY "messages_admin_all" ON messages
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM members
      WHERE id = auth.uid()
        AND role = 'admin'
        AND society_id = messages.society_id
    )
  );

-- ===========================
-- COURSES — society-scoped
-- ===========================

ALTER TABLE courses ENABLE ROW LEVEL SECURITY;

-- Anyone can view courses (public for visitor view)
CREATE POLICY "courses_select_public" ON courses
  FOR SELECT USING (true);

-- Admins can manage courses in their society
CREATE POLICY "courses_admin_all" ON courses
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM members
      WHERE id = auth.uid()
        AND role = 'admin'
        AND society_id = courses.society_id
    )
  );

-- ===========================
-- JOIN_REQUESTS — society-scoped
-- ===========================

DROP POLICY IF EXISTS "Admins can manage join requests" ON join_requests;
DROP POLICY IF EXISTS "Anyone can submit join request" ON join_requests;

-- Anyone can submit a join request (public form)
CREATE POLICY "join_requests_insert_public" ON join_requests
  FOR INSERT WITH CHECK (true);

-- Admins can view/manage join requests for their society
CREATE POLICY "join_requests_admin_all" ON join_requests
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM members
      WHERE id = auth.uid()
        AND role = 'admin'
        AND society_id = join_requests.society_id
    )
  );
