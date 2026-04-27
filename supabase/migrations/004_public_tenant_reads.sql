-- ============================================================
-- Migration 004: Scoped public reads for tenant landing pages
-- ============================================================
-- The previous events_anon_select policy allowed any anonymous user
-- to read every society's events globally. For societegolf.app/[code]
-- public landing pages we want anonymous users to see only the events
-- of the resolved society.
--
-- Approach: drop the lax anonymous policy and expose tenant data via
-- SECURITY DEFINER RPCs that take a society slug. The function bypasses
-- RLS internally but only ever returns rows for the requested society,
-- so the slug becomes the access boundary.
-- ============================================================

-- Drop the over-permissive policy
DROP POLICY IF EXISTS "events_anon_select" ON events;

-- Public RPC: events for a given society subdomain (slug).
-- Used by anonymous tenant landing pages.
CREATE OR REPLACE FUNCTION public.events_for_society_slug(slug TEXT)
RETURNS SETOF events AS $$
  SELECT e.*
  FROM events e
  JOIN societies s ON s.id = e.society_id
  WHERE s.subdomain = slug;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

REVOKE ALL ON FUNCTION public.events_for_society_slug(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.events_for_society_slug(TEXT) TO anon, authenticated;

-- Public RPC: society summary (name + config) for a slug, used to
-- hydrate branding on the public landing page before login.
CREATE OR REPLACE FUNCTION public.society_for_slug(slug TEXT)
RETURNS TABLE (id UUID, name TEXT, subdomain TEXT, config JSONB) AS $$
  SELECT id, name, subdomain, config
  FROM societies
  WHERE subdomain = slug;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

REVOKE ALL ON FUNCTION public.society_for_slug(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.society_for_slug(TEXT) TO anon, authenticated;
