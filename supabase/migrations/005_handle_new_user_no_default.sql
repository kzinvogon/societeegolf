-- ============================================================
-- Migration 005: Harden handle_new_user — no silent default society
-- ============================================================
-- The original trigger fell back to society_id '0…001' (the seed
-- SocieteeGolf default) if raw_user_meta_data didn't carry a
-- society_id. That meant a self-serve signup from any tenant landing
-- page that forgot to set the metadata would silently enroll the
-- new user into the SocieteeGolf default society — a multi-tenant
-- correctness bug.
--
-- New behaviour:
--   1. If raw_user_meta_data->>'society_id' is set, use it.
--   2. Else, look for an existing member row by email (any society)
--      and re-key it to the new auth user's id. This handles the
--      case where an admin created the member ahead of time and the
--      member is now logging in for the first time.
--   3. Else, do not insert a member row. The application is
--      responsible for creating the member after collecting which
--      society the user wants to join (e.g. via a join_request).
-- ============================================================

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
  v_society_id UUID;
  v_existing_count INT;
BEGIN
  v_society_id := (NEW.raw_user_meta_data->>'society_id')::UUID;

  IF v_society_id IS NOT NULL THEN
    -- Explicit society — re-key existing member or insert a new one.
    UPDATE public.members
       SET id = NEW.id
     WHERE email = NEW.email
       AND society_id = v_society_id;
    GET DIAGNOSTICS v_existing_count = ROW_COUNT;

    IF v_existing_count = 0 THEN
      INSERT INTO public.members (id, email, name, society_id)
      VALUES (
        NEW.id,
        NEW.email,
        COALESCE(NEW.raw_user_meta_data->>'name', split_part(NEW.email, '@', 1)),
        v_society_id
      );
    END IF;
  ELSE
    -- No explicit society. Re-key any existing member rows with this
    -- email so the user can still log in to societies they were
    -- invited to. Do NOT insert a fallback row.
    UPDATE public.members SET id = NEW.id WHERE email = NEW.email;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
