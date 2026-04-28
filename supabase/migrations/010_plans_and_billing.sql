-- ============================================================
-- Migration 010: Plans + per-currency pricing + society billing fields
-- ============================================================
-- Schema only. Stripe Price IDs go in plan_prices once the Stripe
-- account + products are created (separate step). The application
-- layer (register flow, member-cap enforcement, webhook) is also a
-- separate step that depends on this schema.
-- ============================================================

-- ===========================
-- PLANS
-- ===========================
CREATE TABLE IF NOT EXISTS plans (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code TEXT UNIQUE NOT NULL CHECK (code ~ '^[a-z0-9_-]+$'),
  name TEXT NOT NULL,
  member_cap INTEGER,                   -- NULL = unlimited
  base_price_eur_monthly_cents INTEGER NOT NULL,  -- monthly per-member rate in EUR cents
  sort_order INTEGER NOT NULL DEFAULT 100,
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_plans_active ON plans(active, sort_order);

-- Seed the four plans. Per-member monthly rates in cents:
--   Starter   €1.00 = 100c  (cap 25)
--   Standard  €0.85 = 85c   (cap 75)
--   Pro       €0.70 = 70c   (cap 200)
--   Society+  €0.55 = 55c   (no cap)
INSERT INTO plans (code, name, member_cap, base_price_eur_monthly_cents, sort_order)
VALUES
  ('starter',  'Starter',   25,   100, 10),
  ('standard', 'Standard',  75,    85, 20),
  ('pro',      'Pro',      200,    70, 30),
  ('society_plus', 'Society+', NULL, 55, 40)
ON CONFLICT (code) DO UPDATE SET
  name = EXCLUDED.name,
  member_cap = EXCLUDED.member_cap,
  base_price_eur_monthly_cents = EXCLUDED.base_price_eur_monthly_cents,
  sort_order = EXCLUDED.sort_order;

-- ===========================
-- PLAN_PRICES — one row per (plan, currency, interval)
-- ===========================
-- stripe_price_id is filled in once products are created in Stripe.
-- Seeded prices match the table I committed to in chat.
CREATE TABLE IF NOT EXISTS plan_prices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id UUID NOT NULL REFERENCES plans(id) ON DELETE CASCADE,
  currency TEXT NOT NULL CHECK (currency IN ('EUR','GBP','USD')),
  interval TEXT NOT NULL CHECK (interval IN ('month','year')),
  unit_amount_cents INTEGER NOT NULL,          -- per-member rate in this currency, in minor units
  stripe_price_id TEXT,                        -- e.g. 'price_…' — null until set up in Stripe
  active BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (plan_id, currency, interval)
);

CREATE INDEX IF NOT EXISTS idx_plan_prices_lookup ON plan_prices(plan_id, currency, interval);

-- Seed the per-currency prices.
-- EUR base; GBP and USD chosen for clean round numbers.
-- Annual = 11 × monthly (one month free).
DO $seed$
DECLARE
  p_starter UUID; p_standard UUID; p_pro UUID; p_plus UUID;
BEGIN
  SELECT id INTO p_starter  FROM plans WHERE code = 'starter';
  SELECT id INTO p_standard FROM plans WHERE code = 'standard';
  SELECT id INTO p_pro      FROM plans WHERE code = 'pro';
  SELECT id INTO p_plus     FROM plans WHERE code = 'society_plus';

  -- Helper to upsert a price row.
  PERFORM 1;
END$seed$;

INSERT INTO plan_prices (plan_id, currency, interval, unit_amount_cents)
VALUES
  -- Starter — €1.00 / £0.85 / $1.10
  ((SELECT id FROM plans WHERE code='starter'), 'EUR', 'month', 100),
  ((SELECT id FROM plans WHERE code='starter'), 'EUR', 'year', 1100),
  ((SELECT id FROM plans WHERE code='starter'), 'GBP', 'month',  85),
  ((SELECT id FROM plans WHERE code='starter'), 'GBP', 'year',  935),
  ((SELECT id FROM plans WHERE code='starter'), 'USD', 'month', 110),
  ((SELECT id FROM plans WHERE code='starter'), 'USD', 'year', 1210),
  -- Standard — €0.85 / £0.75 / $0.95
  ((SELECT id FROM plans WHERE code='standard'), 'EUR', 'month',  85),
  ((SELECT id FROM plans WHERE code='standard'), 'EUR', 'year',  935),
  ((SELECT id FROM plans WHERE code='standard'), 'GBP', 'month',  75),
  ((SELECT id FROM plans WHERE code='standard'), 'GBP', 'year',  825),
  ((SELECT id FROM plans WHERE code='standard'), 'USD', 'month',  95),
  ((SELECT id FROM plans WHERE code='standard'), 'USD', 'year', 1045),
  -- Pro — €0.70 / £0.60 / $0.80
  ((SELECT id FROM plans WHERE code='pro'), 'EUR', 'month',  70),
  ((SELECT id FROM plans WHERE code='pro'), 'EUR', 'year',  770),
  ((SELECT id FROM plans WHERE code='pro'), 'GBP', 'month',  60),
  ((SELECT id FROM plans WHERE code='pro'), 'GBP', 'year',  660),
  ((SELECT id FROM plans WHERE code='pro'), 'USD', 'month',  80),
  ((SELECT id FROM plans WHERE code='pro'), 'USD', 'year',  880),
  -- Society+ — €0.55 / £0.50 / $0.65
  ((SELECT id FROM plans WHERE code='society_plus'), 'EUR', 'month',  55),
  ((SELECT id FROM plans WHERE code='society_plus'), 'EUR', 'year',  605),
  ((SELECT id FROM plans WHERE code='society_plus'), 'GBP', 'month',  50),
  ((SELECT id FROM plans WHERE code='society_plus'), 'GBP', 'year',  550),
  ((SELECT id FROM plans WHERE code='society_plus'), 'USD', 'month',  65),
  ((SELECT id FROM plans WHERE code='society_plus'), 'USD', 'year',  715)
ON CONFLICT (plan_id, currency, interval) DO UPDATE SET
  unit_amount_cents = EXCLUDED.unit_amount_cents;

-- ===========================
-- SOCIETIES — billing columns
-- ===========================

-- Allow 'trialing' as a subscription_status value.
ALTER TABLE societies DROP CONSTRAINT IF EXISTS societies_subscription_status_check;
ALTER TABLE societies ADD CONSTRAINT societies_subscription_status_check
  CHECK (subscription_status IN ('trial','trialing','active','past_due','cancelled','free'));

ALTER TABLE societies ADD COLUMN IF NOT EXISTS plan_id UUID REFERENCES plans(id);
ALTER TABLE societies ADD COLUMN IF NOT EXISTS billing_currency TEXT
  CHECK (billing_currency IN ('EUR','GBP','USD'));
ALTER TABLE societies ADD COLUMN IF NOT EXISTS billing_interval TEXT
  CHECK (billing_interval IN ('month','year'));
ALTER TABLE societies ADD COLUMN IF NOT EXISTS trial_ends_at TIMESTAMPTZ;
ALTER TABLE societies ADD COLUMN IF NOT EXISTS current_period_end TIMESTAMPTZ;
ALTER TABLE societies ADD COLUMN IF NOT EXISTS cancel_at_period_end BOOLEAN NOT NULL DEFAULT false;
-- stripe_customer_id and stripe_subscription_id already exist from migration 001.

CREATE INDEX IF NOT EXISTS idx_societies_plan ON societies(plan_id);
CREATE INDEX IF NOT EXISTS idx_societies_stripe_customer ON societies(stripe_customer_id);
CREATE INDEX IF NOT EXISTS idx_societies_stripe_subscription ON societies(stripe_subscription_id);

-- The seeded 'default' and 'demo' societies are exempt from billing.
-- Mark them so the cap enforcement / billing UI knows to skip them.
ALTER TABLE societies ADD COLUMN IF NOT EXISTS is_billable BOOLEAN NOT NULL DEFAULT true;
UPDATE societies SET is_billable = false
  WHERE id IN (
    '00000000-0000-0000-0000-000000000001',  -- default seed
    '00000000-0000-0000-0000-000000000002'   -- demo
  );

-- ===========================
-- HELPER: society_member_count(uuid)
-- ===========================
-- Used by the cap-check logic (SECURITY DEFINER so anon-callable RPCs
-- can use it without exposing members rows directly).
CREATE OR REPLACE FUNCTION public.society_member_count(p_society_id UUID)
RETURNS INTEGER AS $$
  SELECT COUNT(*)::INT FROM members WHERE society_id = p_society_id;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- ===========================
-- HELPER: society_at_member_cap(uuid) RETURNS BOOLEAN
-- ===========================
-- True when the society's current member count equals or exceeds its
-- plan's member_cap. Returns false for unlimited plans, non-billable
-- societies, and societies without a plan.
CREATE OR REPLACE FUNCTION public.society_at_member_cap(p_society_id UUID)
RETURNS BOOLEAN AS $$
  SELECT
    CASE
      WHEN s.is_billable IS FALSE THEN FALSE
      WHEN p.id IS NULL THEN FALSE
      WHEN p.member_cap IS NULL THEN FALSE
      ELSE public.society_member_count(p_society_id) >= p.member_cap
    END
  FROM societies s
  LEFT JOIN plans p ON p.id = s.plan_id
  WHERE s.id = p_society_id;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- ===========================
-- RLS: plans + plan_prices are world-readable
-- ===========================
-- These are catalog data, not tenant data. Anyone (including anon)
-- needs to read them to render plan-picker UIs.
ALTER TABLE plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE plan_prices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "plans_public_read" ON plans;
CREATE POLICY "plans_public_read" ON plans FOR SELECT USING (active = true);

DROP POLICY IF EXISTS "plan_prices_public_read" ON plan_prices;
CREATE POLICY "plan_prices_public_read" ON plan_prices FOR SELECT USING (active = true);
