// Netlify Function: handle Stripe webhook events. Verifies the signature
// using STRIPE_WEBHOOK_SECRET and updates society billing fields based on
// the events we care about.
//
// Required env vars:
//   STRIPE_WEBHOOK_SECRET     whsec_… from Stripe dashboard → Webhooks
//   SUPABASE_URL              https://<project-ref>.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY service-role key for write access
//
// Events handled:
//   checkout.session.completed       — society now has stripe_customer_id
//                                      and stripe_subscription_id
//   customer.subscription.updated    — status / period / cancel flag changes
//   customer.subscription.deleted    — set status=cancelled
//   invoice.payment_failed           — set status=past_due
//   invoice.payment_succeeded        — refresh status=active

const crypto = require('crypto');

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: 'Method not allowed' };
  }

  const STRIPE_WEBHOOK_SECRET = process.env.STRIPE_WEBHOOK_SECRET;
  const SUPABASE_URL = process.env.SUPABASE_URL;
  const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!STRIPE_WEBHOOK_SECRET || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return { statusCode: 500, body: 'server_misconfigured' };
  }

  // Stripe sends the raw body — Netlify gives us event.body as a string.
  // The signature header is `Stripe-Signature: t=…,v1=…,v1=…`.
  const sigHeader = event.headers['stripe-signature'] || event.headers['Stripe-Signature'];
  const rawBody = event.body || '';
  if (!sigHeader) return { statusCode: 400, body: 'no_signature' };

  // Parse + verify the signature ourselves (avoids the stripe Node SDK
  // and its bundling weight). https://stripe.com/docs/webhooks/signatures
  const parts = Object.fromEntries(sigHeader.split(',').map(p => p.split('=')));
  const timestamp = parts.t;
  const expected = parts.v1;
  if (!timestamp || !expected) return { statusCode: 400, body: 'malformed_signature' };

  const signedPayload = `${timestamp}.${rawBody}`;
  const computed = crypto
    .createHmac('sha256', STRIPE_WEBHOOK_SECRET)
    .update(signedPayload, 'utf8')
    .digest('hex');

  // Constant-time compare.
  const a = Buffer.from(computed, 'hex');
  const b = Buffer.from(expected, 'hex');
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
    return { statusCode: 400, body: 'invalid_signature' };
  }

  // Reject events older than 5 minutes — replay attack mitigation.
  const ageSec = Math.abs(Math.floor(Date.now() / 1000) - parseInt(timestamp, 10));
  if (ageSec > 300) return { statusCode: 400, body: 'stale_event' };

  let evt;
  try { evt = JSON.parse(rawBody); }
  catch { return { statusCode: 400, body: 'invalid_json' }; }

  const supaHeaders = {
    'apikey': SUPABASE_SERVICE_ROLE_KEY,
    'Authorization': 'Bearer ' + SUPABASE_SERVICE_ROLE_KEY,
    'Content-Type': 'application/json',
    'Prefer': 'return=minimal',
  };
  const patchSociety = async (societyId, fields) => {
    if (!societyId) return;
    const r = await fetch(`${SUPABASE_URL}/rest/v1/societies?id=eq.${societyId}`, {
      method: 'PATCH', headers: supaHeaders, body: JSON.stringify(fields),
    });
    if (!r.ok) console.warn('[stripe-webhook] patchSociety failed', r.status, await r.text());
  };

  // Dispatch.
  try {
    const obj = evt.data?.object || {};
    const isoFromUnix = (n) => n ? new Date(n * 1000).toISOString() : null;

    switch (evt.type) {
      case 'checkout.session.completed': {
        const societyId = obj.client_reference_id || obj.metadata?.society_id;
        await patchSociety(societyId, {
          stripe_customer_id: obj.customer,
          stripe_subscription_id: obj.subscription,
          subscription_status: 'trialing',
        });
        break;
      }
      case 'customer.subscription.updated':
      case 'customer.subscription.created': {
        const societyId = obj.metadata?.society_id;
        const status = obj.status; // trialing / active / past_due / cancelled / unpaid …
        await patchSociety(societyId, {
          subscription_status: status,
          current_period_end: isoFromUnix(obj.current_period_end),
          cancel_at_period_end: !!obj.cancel_at_period_end,
        });
        break;
      }
      case 'customer.subscription.deleted': {
        const societyId = obj.metadata?.society_id;
        await patchSociety(societyId, {
          subscription_status: 'cancelled',
          cancel_at_period_end: false,
        });
        break;
      }
      case 'invoice.payment_failed': {
        const societyId = obj.subscription_details?.metadata?.society_id || obj.metadata?.society_id;
        await patchSociety(societyId, { subscription_status: 'past_due' });
        break;
      }
      case 'invoice.payment_succeeded': {
        const societyId = obj.subscription_details?.metadata?.society_id || obj.metadata?.society_id;
        await patchSociety(societyId, { subscription_status: 'active' });
        break;
      }
      default:
        // Ignored event type.
        break;
    }
  } catch (e) {
    console.error('[stripe-webhook] dispatch error', e);
    // Return 200 anyway so Stripe doesn't retry — log and move on.
  }

  return { statusCode: 200, body: JSON.stringify({ received: true }) };
};
