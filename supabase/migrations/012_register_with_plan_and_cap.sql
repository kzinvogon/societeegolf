-- ============================================================
-- Migration 012: register_society with plan params + cap-enforced
--                join_request approval RPC
-- ============================================================
-- Builds on 010 (plans + plan_prices + societies billing columns) and
-- 011 (multi-society membership).
--
-- 1. register_society now accepts plan_code + billing_currency +
--    billing_interval and stamps trial_ends_at = now() + 30 days.
--    Stripe IDs stay null — they'll be filled by the Checkout flow
--    once the secret key lands.
--
-- 2. approve_join_request RPC: only an admin of the society can call
--    it; rejects when society_at_member_cap() is true. The client
--    can no longer just UPDATE join_requests directly because RLS now
--    blocks join_requests writes from non-admins, and the cap check
--    needs to live somewhere atomic with the approval.
-- ============================================================

-- ===========================
-- register_society: plan-aware
-- ===========================
CREATE OR REPLACE FUNCTION public.register_society(
  p_society_name TEXT,
  p_society_code TEXT,
  p_admin_name TEXT,
  p_admin_email TEXT,
  p_plan_code TEXT DEFAULT 'starter',
  p_billing_currency TEXT DEFAULT 'EUR',
  p_billing_interval TEXT DEFAULT 'month'
) RETURNS JSONB AS $$
DECLARE
  v_society_id UUID;
  v_code TEXT;
  v_email TEXT;
  v_admin_user_id UUID;
  v_plan_id UUID;
  v_trial_ends TIMESTAMPTZ;
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

  -- Plan + currency + interval validation
  SELECT id INTO v_plan_id FROM plans
   WHERE code = lower(trim(p_plan_code)) AND active = true;
  IF v_plan_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_plan');
  END IF;

  IF p_billing_currency NOT IN ('EUR','GBP','USD') THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_currency');
  END IF;
  IF p_billing_interval NOT IN ('month','year') THEN
    RETURN jsonb_build_object('success', false, 'error', 'invalid_interval');
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM plan_prices
     WHERE plan_id = v_plan_id
       AND currency = p_billing_currency
       AND interval = p_billing_interval
       AND active = true
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'plan_price_unavailable');
  END IF;

  -- Existing-user lookup + already-in-this-society guard.
  SELECT id INTO v_admin_user_id FROM auth.users WHERE lower(email) = v_email LIMIT 1;
  IF v_admin_user_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM members
    WHERE user_id = v_admin_user_id
      AND society_id IN (SELECT id FROM societies WHERE subdomain = v_code)
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'already_in_this_society');
  END IF;

  v_trial_ends := NOW() + INTERVAL '30 days';

  INSERT INTO societies (
    name, subdomain, subscription_status, public_directory,
    plan_id, billing_currency, billing_interval, trial_ends_at, is_billable
  )
  VALUES (
    trim(p_society_name), v_code, 'trialing', true,
    v_plan_id, p_billing_currency, p_billing_interval, v_trial_ends, true
  )
  RETURNING id INTO v_society_id;

  INSERT INTO members (id, user_id, name, email, role, status, society_id)
  VALUES (
    gen_random_uuid(),
    v_admin_user_id,
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
    'plan_code', p_plan_code,
    'billing_currency', p_billing_currency,
    'billing_interval', p_billing_interval,
    'trial_ends_at', v_trial_ends,
    'admin_existing_user', v_admin_user_id IS NOT NULL
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE ALL ON FUNCTION public.register_society(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.register_society(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT) TO anon, authenticated;

-- ===========================
-- approve_join_request: cap-enforced
-- ===========================
CREATE OR REPLACE FUNCTION public.approve_join_request(p_request_id INTEGER)
RETURNS JSONB AS $$
DECLARE
  v_request RECORD;
  v_uid UUID := auth.uid();
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_authenticated');
  END IF;

  SELECT * INTO v_request FROM join_requests WHERE id = p_request_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'request_not_found');
  END IF;

  IF NOT public.is_admin_of(v_request.society_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'not_admin');
  END IF;

  IF v_request.status <> 'pending' THEN
    RETURN jsonb_build_object('success', false, 'error', 'already_processed', 'status', v_request.status);
  END IF;

  IF public.society_at_member_cap(v_request.society_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'plan_member_limit_reached');
  END IF;

  UPDATE join_requests
     SET status = 'approved'
   WHERE id = p_request_id;

  RETURN jsonb_build_object('success', true, 'request_id', p_request_id);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE ALL ON FUNCTION public.approve_join_request(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.approve_join_request(INTEGER) TO authenticated;
