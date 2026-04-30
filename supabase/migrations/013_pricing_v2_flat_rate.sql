-- ============================================================
-- Migration 013: Pricing v2 — flat-rate per society, anchored to
-- typical society economics (~5–7% of gross revenue)
-- ============================================================
-- The per-member pricing in 010 was 5–10× too high for the actual
-- audience. Volunteer-run societies of 80 members typically charge
-- €25/year membership = €2k/year gross. SocieteeGolf at €100/mo
-- = 60% of their revenue, nonviable. Repriced to flat rates that
-- a treasurer absorbs without committee approval.
--
-- Changes:
--   - Plan names: Starter→Small, Standard→Medium, Pro→Large.
--     Codes stay (starter/standard/pro/society_plus) so client
--     references and Stripe metadata don't churn.
--   - Member caps: 25/75/200/∞ → 50/100/200/∞.
--   - Per-society flat rates replace per-member rates.
--   - Society+ has no Stripe price — it's a "contact us" tier.
--
-- The unit_amount_cents column is reused as the FLAT monthly/annual
-- rate (not per-member). The column name keeps for backward compat;
-- the UI semantics change from "/member/month" to "/month".
-- ============================================================

-- Update plan names + caps + base reference rate (per-society, not
-- per-member).
UPDATE plans SET name = 'Small',     member_cap = 50,  base_price_eur_monthly_cents = 500
  WHERE code = 'starter';
UPDATE plans SET name = 'Medium',    member_cap = 100, base_price_eur_monthly_cents = 1000
  WHERE code = 'standard';
UPDATE plans SET name = 'Large',     member_cap = 200, base_price_eur_monthly_cents = 2000
  WHERE code = 'pro';
UPDATE plans SET name = 'Society+',  member_cap = NULL, base_price_eur_monthly_cents = 0
  WHERE code = 'society_plus';

-- Wipe + reseed plan_prices for the three billable tiers. Society+
-- gets no rows — it's "contact us", surfaced in the UI as a different
-- card.
DELETE FROM plan_prices
 WHERE plan_id IN (SELECT id FROM plans WHERE code IN ('starter','standard','pro','society_plus'));

INSERT INTO plan_prices (plan_id, currency, interval, unit_amount_cents)
VALUES
  -- Small  €5 / £5 / $6 monthly · €55 / £55 / $66 annual (11×)
  ((SELECT id FROM plans WHERE code='starter'),  'EUR', 'month',  500),
  ((SELECT id FROM plans WHERE code='starter'),  'EUR', 'year',  5500),
  ((SELECT id FROM plans WHERE code='starter'),  'GBP', 'month',  500),
  ((SELECT id FROM plans WHERE code='starter'),  'GBP', 'year',  5500),
  ((SELECT id FROM plans WHERE code='starter'),  'USD', 'month',  600),
  ((SELECT id FROM plans WHERE code='starter'),  'USD', 'year',  6600),
  -- Medium €10 / £9 / $11 monthly · €110 / £99 / $121 annual
  ((SELECT id FROM plans WHERE code='standard'), 'EUR', 'month', 1000),
  ((SELECT id FROM plans WHERE code='standard'), 'EUR', 'year', 11000),
  ((SELECT id FROM plans WHERE code='standard'), 'GBP', 'month',  900),
  ((SELECT id FROM plans WHERE code='standard'), 'GBP', 'year',  9900),
  ((SELECT id FROM plans WHERE code='standard'), 'USD', 'month', 1100),
  ((SELECT id FROM plans WHERE code='standard'), 'USD', 'year', 12100),
  -- Large  €20 / £18 / $22 monthly · €220 / £198 / $242 annual
  ((SELECT id FROM plans WHERE code='pro'),      'EUR', 'month', 2000),
  ((SELECT id FROM plans WHERE code='pro'),      'EUR', 'year', 22000),
  ((SELECT id FROM plans WHERE code='pro'),      'GBP', 'month', 1800),
  ((SELECT id FROM plans WHERE code='pro'),      'GBP', 'year', 19800),
  ((SELECT id FROM plans WHERE code='pro'),      'USD', 'month', 2200),
  ((SELECT id FROM plans WHERE code='pro'),      'USD', 'year', 24200);

-- Mark Society+ as contact-only via a flag on plans.
ALTER TABLE plans ADD COLUMN IF NOT EXISTS is_contact_only BOOLEAN NOT NULL DEFAULT false;
UPDATE plans SET is_contact_only = true  WHERE code = 'society_plus';
UPDATE plans SET is_contact_only = false WHERE code <> 'society_plus';
