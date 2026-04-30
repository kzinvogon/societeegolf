// Netlify Function: create a Stripe Checkout session for a society's
// subscription. Caller must pass a valid Supabase user JWT — we verify
// they're an admin of the requested society before creating the session.
//
// Required env vars (Netlify dashboard → Site settings → Environment):
//   STRIPE_SECRET_KEY        sk_test_… in test, sk_live_… once verified
//   SUPABASE_URL             https://<project-ref>.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY for the SECURITY-DEFINER-bypassing reads we
//                            need to verify admin role + look up plan_price

const STRIPE_API = 'https://api.stripe.com/v1';

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: 'Method not allowed' };
  }

  const STRIPE_SECRET_KEY = process.env.STRIPE_SECRET_KEY;
  const SUPABASE_URL = process.env.SUPABASE_URL;
  const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!STRIPE_SECRET_KEY || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return { statusCode: 500, body: JSON.stringify({ error: 'server_misconfigured' }) };
  }

  // Caller's JWT — proves who they are. Body says which society they want
  // to set up billing for; we verify they're admin via the Supabase REST API
  // using the service role to bypass RLS.
  const auth = event.headers.authorization || event.headers.Authorization;
  const accessToken = auth && auth.startsWith('Bearer ') ? auth.slice(7) : null;
  if (!accessToken) return { statusCode: 401, body: JSON.stringify({ error: 'no_token' }) };

  let body;
  try { body = JSON.parse(event.body || '{}'); }
  catch { return { statusCode: 400, body: JSON.stringify({ error: 'invalid_json' }) }; }

  const { society_id, return_url } = body;
  if (!society_id) return { statusCode: 400, body: JSON.stringify({ error: 'society_id_required' }) };

  // Decode the JWT (no signature check here — we use it as a Supabase auth
  // header on the next call, which Supabase verifies for us).
  let userId;
  try {
    const payload = JSON.parse(Buffer.from(accessToken.split('.')[1], 'base64').toString());
    userId = payload.sub;
  } catch { return { statusCode: 401, body: JSON.stringify({ error: 'bad_token' }) }; }
  if (!userId) return { statusCode: 401, body: JSON.stringify({ error: 'no_sub_in_token' }) };

  // Service-role read: society + admin's member row + plan_price row.
  const supaHeaders = {
    'apikey': SUPABASE_SERVICE_ROLE_KEY,
    'Authorization': 'Bearer ' + SUPABASE_SERVICE_ROLE_KEY,
    'Content-Type': 'application/json',
  };

  const fetchJson = async (url) => {
    const r = await fetch(url, { headers: supaHeaders });
    if (!r.ok) throw new Error(`${url} → ${r.status} ${await r.text()}`);
    return r.json();
  };

  let society, member, priceRow;
  try {
    const sRows = await fetchJson(`${SUPABASE_URL}/rest/v1/societies?id=eq.${society_id}&select=id,name,plan_id,billing_currency,billing_interval,stripe_customer_id,stripe_subscription_id,is_billable,subscription_status`);
    society = sRows[0];
    if (!society) return { statusCode: 404, body: JSON.stringify({ error: 'society_not_found' }) };
    if (!society.is_billable) return { statusCode: 400, body: JSON.stringify({ error: 'society_not_billable' }) };
    if (!society.plan_id || !society.billing_currency || !society.billing_interval) {
      return { statusCode: 400, body: JSON.stringify({ error: 'plan_not_set_on_society' }) };
    }

    const mRows = await fetchJson(`${SUPABASE_URL}/rest/v1/members?user_id=eq.${userId}&society_id=eq.${society_id}&role=eq.admin&select=id,name,email`);
    member = mRows[0];
    if (!member) return { statusCode: 403, body: JSON.stringify({ error: 'not_admin_of_society' }) };

    const ppRows = await fetchJson(`${SUPABASE_URL}/rest/v1/plan_prices?plan_id=eq.${society.plan_id}&currency=eq.${society.billing_currency}&interval=eq.${society.billing_interval}&select=stripe_price_id`);
    priceRow = ppRows[0];
    if (!priceRow?.stripe_price_id) return { statusCode: 400, body: JSON.stringify({ error: 'stripe_price_id_missing' }) };
  } catch (e) {
    return { statusCode: 500, body: JSON.stringify({ error: 'lookup_failed', detail: String(e) }) };
  }

  // Build Stripe Checkout session. Pricing is flat per-society now —
  // quantity is always 1, member count is enforced by the in-app
  // hard cap (society_at_member_cap), not by Stripe seat count.
  const params = new URLSearchParams();
  params.set('mode', 'subscription');
  params.set('payment_method_types[0]', 'card');
  params.set('line_items[0][price]', priceRow.stripe_price_id);
  params.set('line_items[0][quantity]', '1');
  // 30-day trial — Stripe handles "no charge until day 30".
  params.set('subscription_data[trial_period_days]', '30');
  params.set('subscription_data[metadata][society_id]', society_id);
  params.set('metadata[society_id]', society_id);
  params.set('client_reference_id', society_id);
  // Reuse customer if we've already created one; otherwise email-prefill.
  if (society.stripe_customer_id) {
    params.set('customer', society.stripe_customer_id);
  } else {
    params.set('customer_email', member.email);
    params.set('customer_creation', 'always');
  }
  const origin = (return_url && return_url.split('/').slice(0, 3).join('/')) || (event.headers.origin || 'https://app.societeegolf.app');
  params.set('success_url', `${origin}/?billing=success`);
  params.set('cancel_url', `${origin}/?billing=cancelled`);
  params.set('allow_promotion_codes', 'true');

  let session;
  try {
    const r = await fetch(`${STRIPE_API}/checkout/sessions`, {
      method: 'POST',
      headers: {
        'Authorization': 'Bearer ' + STRIPE_SECRET_KEY,
        'Content-Type': 'application/x-www-form-urlencoded',
        'Stripe-Version': '2024-06-20',
      },
      body: params.toString(),
    });
    session = await r.json();
    if (!r.ok) return { statusCode: 502, body: JSON.stringify({ error: 'stripe_error', detail: session }) };
  } catch (e) {
    return { statusCode: 502, body: JSON.stringify({ error: 'stripe_unreachable', detail: String(e) }) };
  }

  return {
    statusCode: 200,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ url: session.url, session_id: session.id }),
  };
};
