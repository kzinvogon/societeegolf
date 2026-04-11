-- JPGS Mobile App — Supabase Database Schema
-- Paste this into the Supabase SQL Editor (https://supabase.com/dashboard → SQL Editor → New query)

-- 1. Members table (linked to Supabase Auth)
CREATE TABLE members (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  email TEXT UNIQUE NOT NULL,
  handicap DECIMAL,
  status TEXT NOT NULL DEFAULT 'applied' CHECK (status IN ('applied', 'probation', 'full_member', 'suspended')),
  joined_date DATE DEFAULT CURRENT_DATE,
  phone TEXT,
  role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('member', 'admin')),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. Events / Fixtures
CREATE TABLE events (
  id SERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  date DATE NOT NULL,
  course TEXT NOT NULL,
  location TEXT,
  format TEXT,
  cost DECIMAL,
  payment_link TEXT,
  signup_limit INT,
  signup_cutoff DATE,
  tee_time_start TIME,
  tee_interval INT DEFAULT 10,
  notes TEXT,
  created_by UUID REFERENCES members(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 3. Event Signups
CREATE TABLE signups (
  id SERIAL PRIMARY KEY,
  event_id INT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  member_id UUID NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  handicap_at_signup DECIMAL,
  paid BOOLEAN DEFAULT FALSE,
  signed_up_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(event_id, member_id)
);

-- 4. Results
CREATE TABLE results (
  id SERIAL PRIMARY KEY,
  event_id INT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
  member_id UUID NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  score INT,
  points INT,
  position INT,
  notes TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 5. Messages / Announcements
CREATE TABLE messages (
  id SERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  body TEXT NOT NULL,
  priority TEXT NOT NULL DEFAULT 'normal' CHECK (priority IN ('normal', 'important', 'urgent')),
  created_by UUID REFERENCES members(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ===========================
-- Row Level Security Policies
-- ===========================

-- Enable RLS on all tables
ALTER TABLE members ENABLE ROW LEVEL SECURITY;
ALTER TABLE events ENABLE ROW LEVEL SECURITY;
ALTER TABLE signups ENABLE ROW LEVEL SECURITY;
ALTER TABLE results ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;

-- Members: anyone can read active members, users can update their own profile
CREATE POLICY "Public can view active members" ON members
  FOR SELECT USING (status IN ('probation', 'full_member'));

CREATE POLICY "Users can view own profile" ON members
  FOR SELECT USING (auth.uid() = id);

CREATE POLICY "Users can update own profile" ON members
  FOR UPDATE USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

CREATE POLICY "Admins can manage members" ON members
  FOR ALL USING (
    EXISTS (SELECT 1 FROM members WHERE id = auth.uid() AND role = 'admin')
  );

-- Events: public read, admin write
CREATE POLICY "Anyone can view events" ON events
  FOR SELECT USING (true);

CREATE POLICY "Admins can manage events" ON events
  FOR ALL USING (
    EXISTS (SELECT 1 FROM members WHERE id = auth.uid() AND role = 'admin')
  );

-- Signups: members can read all, manage own
CREATE POLICY "Authenticated can view signups" ON signups
  FOR SELECT USING (auth.role() = 'authenticated');

CREATE POLICY "Members can sign up" ON signups
  FOR INSERT WITH CHECK (auth.uid() = member_id);

CREATE POLICY "Members can withdraw own signup" ON signups
  FOR DELETE USING (auth.uid() = member_id);

CREATE POLICY "Admins can manage signups" ON signups
  FOR ALL USING (
    EXISTS (SELECT 1 FROM members WHERE id = auth.uid() AND role = 'admin')
  );

-- Results: public read, admin write
CREATE POLICY "Anyone can view results" ON results
  FOR SELECT USING (true);

CREATE POLICY "Admins can manage results" ON results
  FOR ALL USING (
    EXISTS (SELECT 1 FROM members WHERE id = auth.uid() AND role = 'admin')
  );

-- Messages: authenticated read, admin write
CREATE POLICY "Authenticated can view messages" ON messages
  FOR SELECT USING (auth.role() = 'authenticated');

CREATE POLICY "Admins can manage messages" ON messages
  FOR ALL USING (
    EXISTS (SELECT 1 FROM members WHERE id = auth.uid() AND role = 'admin')
  );

-- ===========================
-- Helper: auto-create member profile on signup
-- ===========================
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.members (id, email, name)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'name', split_part(NEW.email, '@', 1))
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ===========================
-- Additional: country code and join requests
-- ===========================

ALTER TABLE members ADD COLUMN IF NOT EXISTS country_code TEXT DEFAULT '+34';

-- Join requests (visitor sign-up form)
CREATE TABLE IF NOT EXISTS join_requests (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  email TEXT NOT NULL,
  phone TEXT,
  notify_by TEXT DEFAULT 'email',
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'contacted', 'approved', 'rejected')),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE join_requests ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins can manage join requests" ON join_requests
  FOR ALL USING (
    EXISTS (SELECT 1 FROM members WHERE id = auth.uid() AND role = 'admin')
  );

CREATE POLICY "Anyone can submit join request" ON join_requests
  FOR INSERT WITH CHECK (true);
