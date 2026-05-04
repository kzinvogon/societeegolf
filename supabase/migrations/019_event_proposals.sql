-- ============================================================
-- Migration 019: Interest Sounder — pre-event proposals + votes
-- ============================================================
-- Captain workflow: instead of booking blind, post 2–4 candidate
-- (course × date × approximate price) options. Members tap "I'd play"
-- on each option they're up for. Captain reads the tally and promotes
-- the winner to a real events row.
--
-- Three tables:
--   event_proposals          — header (society, title, status, close-by)
--   event_proposal_options   — N candidate (course, date, price) rows
--   event_proposal_votes     — one row per (option, member) where the
--                              member said they'd play
--
-- RLS:
--   - Proposals + options readable by same-society members.
--   - Proposals + options writable by event-running roles
--     (admin / captain / vice_captain).
--   - Votes: members read their own + aggregate counts via the tally
--     RPC; members write their own; admins/captains can read raw votes
--     for the captain's tally screen.
-- ============================================================

-- ===========================
-- 1. event_proposals
-- ===========================
CREATE TABLE IF NOT EXISTS event_proposals (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  society_id UUID NOT NULL REFERENCES societies(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  notes TEXT,
  created_by UUID REFERENCES members(id) ON DELETE SET NULL,
  status TEXT NOT NULL DEFAULT 'open'
    CHECK (status IN ('open','closed','promoted','cancelled')),
  voting_closes_at TIMESTAMPTZ,
  promoted_event_id INT REFERENCES events(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_event_proposals_society ON event_proposals(society_id, status);

-- ===========================
-- 2. event_proposal_options
-- ===========================
CREATE TABLE IF NOT EXISTS event_proposal_options (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  proposal_id UUID NOT NULL REFERENCES event_proposals(id) ON DELETE CASCADE,
  -- Either an external_courses ref OR a free-text course name when
  -- the captain is sounding interest in a course not yet in the library.
  external_course_id UUID REFERENCES external_courses(id) ON DELETE SET NULL,
  course_name TEXT NOT NULL,
  course_location TEXT,
  candidate_date DATE NOT NULL,
  approx_price_cents INT,
  approx_price_currency TEXT NOT NULL DEFAULT 'EUR'
    CHECK (approx_price_currency IN ('EUR','GBP','USD')),
  notes TEXT,
  sort_order INT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_event_proposal_options_proposal ON event_proposal_options(proposal_id, sort_order);

-- ===========================
-- 3. event_proposal_votes
-- ===========================
CREATE TABLE IF NOT EXISTS event_proposal_votes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  proposal_id UUID NOT NULL REFERENCES event_proposals(id) ON DELETE CASCADE,
  option_id UUID NOT NULL REFERENCES event_proposal_options(id) ON DELETE CASCADE,
  member_id UUID NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  -- Always true at the moment — voting model is "tap to opt in,
  -- untap to opt out". Keeping the column for future expansion
  -- (maybe/probably-yes etc).
  would_play BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (option_id, member_id)
);

CREATE INDEX IF NOT EXISTS idx_proposal_votes_option ON event_proposal_votes(option_id);
CREATE INDEX IF NOT EXISTS idx_proposal_votes_member ON event_proposal_votes(member_id);

-- ===========================
-- 4. RLS
-- ===========================
ALTER TABLE event_proposals ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_proposal_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE event_proposal_votes ENABLE ROW LEVEL SECURITY;

-- Proposals: same-society SELECT, event-running roles ALL.
DROP POLICY IF EXISTS "proposals_select_same_society" ON event_proposals;
CREATE POLICY "proposals_select_same_society" ON event_proposals
  FOR SELECT USING (
    society_id = public.get_society_id()
    OR EXISTS (SELECT 1 FROM members WHERE user_id = auth.uid() AND society_id = event_proposals.society_id)
  );

DROP POLICY IF EXISTS "proposals_admin_all" ON event_proposals;
CREATE POLICY "proposals_admin_all" ON event_proposals
  FOR ALL USING (public.has_role_in(society_id, ARRAY['admin','captain','vice_captain']));

-- Options: same scope as the parent proposal. Use the proposal row
-- via EXISTS subquery (society_id is on the parent).
DROP POLICY IF EXISTS "proposal_options_select_same_society" ON event_proposal_options;
CREATE POLICY "proposal_options_select_same_society" ON event_proposal_options
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM event_proposals p
      WHERE p.id = event_proposal_options.proposal_id
        AND (
          p.society_id = public.get_society_id()
          OR EXISTS (SELECT 1 FROM members m WHERE m.user_id = auth.uid() AND m.society_id = p.society_id)
        )
    )
  );

DROP POLICY IF EXISTS "proposal_options_admin_all" ON event_proposal_options;
CREATE POLICY "proposal_options_admin_all" ON event_proposal_options
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM event_proposals p
      WHERE p.id = event_proposal_options.proposal_id
        AND public.has_role_in(p.society_id, ARRAY['admin','captain','vice_captain'])
    )
  );

-- Votes: members read aggregate via RPC; admins/captains can read raw
-- via the same-society policy. Members can INSERT/DELETE their own row.
DROP POLICY IF EXISTS "proposal_votes_select_same_society" ON event_proposal_votes;
CREATE POLICY "proposal_votes_select_same_society" ON event_proposal_votes
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM event_proposals p
      WHERE p.id = event_proposal_votes.proposal_id
        AND p.society_id = public.get_society_id()
    )
  );

DROP POLICY IF EXISTS "proposal_votes_insert_own" ON event_proposal_votes;
CREATE POLICY "proposal_votes_insert_own" ON event_proposal_votes
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM members m
      WHERE m.id = event_proposal_votes.member_id
        AND m.user_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "proposal_votes_delete_own" ON event_proposal_votes;
CREATE POLICY "proposal_votes_delete_own" ON event_proposal_votes
  FOR DELETE USING (
    EXISTS (
      SELECT 1 FROM members m
      WHERE m.id = event_proposal_votes.member_id
        AND m.user_id = auth.uid()
    )
  );

-- ===========================
-- 5. Tally RPC — aggregate vote counts per option for a proposal
-- ===========================
CREATE OR REPLACE FUNCTION public.proposal_tally(p_proposal_id UUID)
RETURNS TABLE (
  option_id UUID,
  course_name TEXT,
  course_location TEXT,
  candidate_date DATE,
  approx_price_cents INT,
  approx_price_currency TEXT,
  notes TEXT,
  sort_order INT,
  yes_votes INT
) AS $$
  SELECT
    o.id,
    o.course_name,
    o.course_location,
    o.candidate_date,
    o.approx_price_cents,
    o.approx_price_currency,
    o.notes,
    o.sort_order,
    COALESCE((SELECT count(*)::INT FROM event_proposal_votes v
              WHERE v.option_id = o.id AND v.would_play = true), 0)
  FROM event_proposal_options o
  WHERE o.proposal_id = p_proposal_id
  ORDER BY o.sort_order, o.candidate_date;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

REVOKE ALL ON FUNCTION public.proposal_tally(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.proposal_tally(UUID) TO authenticated;

-- ===========================
-- 6. Promote-to-event RPC — captain picks the winner, this creates
--    the real events row and marks the proposal 'promoted'.
-- ===========================
CREATE OR REPLACE FUNCTION public.promote_proposal_to_event(
  p_proposal_id UUID,
  p_option_id UUID,
  p_title TEXT DEFAULT NULL,
  p_cost_override_cents INT DEFAULT NULL,
  p_signup_limit INT DEFAULT NULL,
  p_signup_cutoff_at TIMESTAMPTZ DEFAULT NULL,
  p_tee_time_start TIME DEFAULT NULL,
  p_format TEXT DEFAULT NULL,
  p_notes TEXT DEFAULT NULL
) RETURNS JSONB AS $$
DECLARE
  v_proposal event_proposals;
  v_option event_proposal_options;
  v_event_id INT;
  v_cost NUMERIC;
BEGIN
  SELECT * INTO v_proposal FROM event_proposals WHERE id = p_proposal_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'proposal_not_found');
  END IF;

  IF NOT public.has_role_in(v_proposal.society_id, ARRAY['admin','captain','vice_captain']) THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_authorised');
  END IF;

  IF v_proposal.status NOT IN ('open','closed') THEN
    RETURN jsonb_build_object('success', false, 'error', 'already_processed', 'status', v_proposal.status);
  END IF;

  SELECT * INTO v_option FROM event_proposal_options WHERE id = p_option_id AND proposal_id = p_proposal_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'option_not_found');
  END IF;

  v_cost := CASE
    WHEN p_cost_override_cents IS NOT NULL THEN (p_cost_override_cents::numeric / 100)
    WHEN v_option.approx_price_cents IS NOT NULL THEN (v_option.approx_price_cents::numeric / 100)
    ELSE 0
  END;

  INSERT INTO events (
    title, date, course, location, format, cost, signup_limit,
    signup_cutoff, signup_cutoff_at, tee_time_start, notes,
    society_id, created_by
  ) VALUES (
    COALESCE(NULLIF(trim(p_title), ''), v_proposal.title),
    v_option.candidate_date,
    v_option.course_name,
    v_option.course_location,
    p_format,
    v_cost,
    p_signup_limit,
    CASE WHEN p_signup_cutoff_at IS NOT NULL THEN p_signup_cutoff_at::date ELSE NULL END,
    p_signup_cutoff_at,
    p_tee_time_start,
    p_notes,
    v_proposal.society_id,
    v_proposal.created_by
  )
  RETURNING id INTO v_event_id;

  UPDATE event_proposals
     SET status = 'promoted',
         promoted_event_id = v_event_id,
         updated_at = NOW()
   WHERE id = p_proposal_id;

  RETURN jsonb_build_object(
    'success', true,
    'event_id', v_event_id,
    'proposal_id', p_proposal_id
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE ALL ON FUNCTION public.promote_proposal_to_event(UUID, UUID, TEXT, INT, INT, TIMESTAMPTZ, TIME, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.promote_proposal_to_event(UUID, UUID, TEXT, INT, INT, TIMESTAMPTZ, TIME, TEXT, TEXT) TO authenticated;
