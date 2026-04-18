-- ============================================================
-- Migration 001: Multitenancy — societies table + society_id FKs
-- ============================================================
-- Adds a societies table and links all existing tables to it
-- via a society_id column. Existing data gets assigned to a
-- default society created during migration.
-- ============================================================

-- 1. Create societies table
CREATE TABLE IF NOT EXISTS societies (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  subdomain TEXT UNIQUE NOT NULL,
  config JSONB DEFAULT '{}',
  subscription_status TEXT NOT NULL DEFAULT 'trial'
    CHECK (subscription_status IN ('trial', 'active', 'past_due', 'cancelled', 'free')),
  stripe_customer_id TEXT,
  stripe_subscription_id TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Add index on subdomain for fast lookups
CREATE INDEX IF NOT EXISTS idx_societies_subdomain ON societies(subdomain);

-- 2. Create a default society for existing data
INSERT INTO societies (id, name, subdomain, subscription_status)
VALUES (
  '00000000-0000-0000-0000-000000000001',
  'SocieteeGolf',
  'default',
  'free'
) ON CONFLICT (id) DO NOTHING;

-- 3. Add society_id to members
ALTER TABLE members ADD COLUMN IF NOT EXISTS society_id UUID
  REFERENCES societies(id) ON DELETE CASCADE;
UPDATE members SET society_id = '00000000-0000-0000-0000-000000000001'
  WHERE society_id IS NULL;
ALTER TABLE members ALTER COLUMN society_id SET NOT NULL;
ALTER TABLE members ALTER COLUMN society_id SET DEFAULT '00000000-0000-0000-0000-000000000001';

-- Drop the global email unique constraint and replace with per-society unique
ALTER TABLE members DROP CONSTRAINT IF EXISTS members_email_key;
ALTER TABLE members ADD CONSTRAINT members_email_society_unique UNIQUE (email, society_id);

-- 4. Add society_id to events
ALTER TABLE events ADD COLUMN IF NOT EXISTS society_id UUID
  REFERENCES societies(id) ON DELETE CASCADE;
UPDATE events SET society_id = '00000000-0000-0000-0000-000000000001'
  WHERE society_id IS NULL;
ALTER TABLE events ALTER COLUMN society_id SET NOT NULL;
ALTER TABLE events ALTER COLUMN society_id SET DEFAULT '00000000-0000-0000-0000-000000000001';

-- 5. Add society_id to messages
ALTER TABLE messages ADD COLUMN IF NOT EXISTS society_id UUID
  REFERENCES societies(id) ON DELETE CASCADE;
UPDATE messages SET society_id = '00000000-0000-0000-0000-000000000001'
  WHERE society_id IS NULL;
ALTER TABLE messages ALTER COLUMN society_id SET NOT NULL;
ALTER TABLE messages ALTER COLUMN society_id SET DEFAULT '00000000-0000-0000-0000-000000000001';

-- 6. Add society_id to join_requests
ALTER TABLE join_requests ADD COLUMN IF NOT EXISTS society_id UUID
  REFERENCES societies(id) ON DELETE CASCADE;
UPDATE join_requests SET society_id = '00000000-0000-0000-0000-000000000001'
  WHERE society_id IS NULL;
ALTER TABLE join_requests ALTER COLUMN society_id SET NOT NULL;
ALTER TABLE join_requests ALTER COLUMN society_id SET DEFAULT '00000000-0000-0000-0000-000000000001';

-- 7. Add society_id to courses
ALTER TABLE courses ADD COLUMN IF NOT EXISTS society_id UUID
  REFERENCES societies(id) ON DELETE CASCADE;
UPDATE courses SET society_id = '00000000-0000-0000-0000-000000000001'
  WHERE society_id IS NULL;
ALTER TABLE courses ALTER COLUMN society_id SET NOT NULL;
ALTER TABLE courses ALTER COLUMN society_id SET DEFAULT '00000000-0000-0000-0000-000000000001';

-- 8. signups and results inherit society through their event/member FKs
--    No society_id needed — they're scoped by event_id which is scoped by society_id

-- 9. Create indexes for fast filtering
CREATE INDEX IF NOT EXISTS idx_members_society ON members(society_id);
CREATE INDEX IF NOT EXISTS idx_events_society ON events(society_id);
CREATE INDEX IF NOT EXISTS idx_messages_society ON messages(society_id);
CREATE INDEX IF NOT EXISTS idx_join_requests_society ON join_requests(society_id);
CREATE INDEX IF NOT EXISTS idx_courses_society ON courses(society_id);

-- 10. Update handle_new_user trigger to include society_id from auth metadata
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
  existing_id UUID;
  v_society_id UUID;
BEGIN
  -- Get society_id from auth metadata, default to the default society
  v_society_id := COALESCE(
    (NEW.raw_user_meta_data->>'society_id')::UUID,
    '00000000-0000-0000-0000-000000000001'
  );

  -- Check if a member with this email already exists in this society
  SELECT id INTO existing_id FROM public.members
    WHERE email = NEW.email AND society_id = v_society_id LIMIT 1;

  IF existing_id IS NOT NULL THEN
    -- Re-key the existing member row to match the new auth user's id
    UPDATE public.members SET id = NEW.id WHERE email = NEW.email AND society_id = v_society_id;
  ELSE
    -- New user: insert with default 'applied' status
    INSERT INTO public.members (id, email, name, society_id)
    VALUES (
      NEW.id,
      NEW.email,
      COALESCE(NEW.raw_user_meta_data->>'name', split_part(NEW.email, '@', 1)),
      v_society_id
    );
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
