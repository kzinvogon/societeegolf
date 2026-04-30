// Netlify Function: send-society-welcome
//
// Called immediately after register_society succeeds. Generates a
// one-shot magic-link URL via the Supabase admin API and embeds it
// in a richer HTML welcome email containing society, plan, and
// trial details — instead of relying on the bare-bones default
// magic-link template which says nothing about what was set up.
//
// Required env vars (Netlify dashboard → Site settings → Env vars):
//   RESEND_API_KEY            — already set for the join-form welcome email
//   SUPABASE_URL              — https://<project-ref>.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY — bypasses RLS for admin user creation
//
// The function is anon-callable; the only data it accepts comes from
// the client's register flow. To prevent abuse, it requires the
// society_id to exist with subscription_status='trialing' AND match
// the email passed in (i.e. admin email is on the members row).
// That keeps a malicious caller from spamming arbitrary addresses.

const RESEND_API = 'https://api.resend.com/emails';

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: 'Method not allowed' };
  }

  const RESEND_API_KEY = process.env.RESEND_API_KEY;
  const SUPABASE_URL = process.env.SUPABASE_URL;
  const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!RESEND_API_KEY || !SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    return { statusCode: 500, body: JSON.stringify({ error: 'server_misconfigured' }) };
  }

  let body;
  try { body = JSON.parse(event.body || '{}'); }
  catch { return { statusCode: 400, body: JSON.stringify({ error: 'invalid_json' }) }; }

  const { society_id, society_name, society_code, admin_name, admin_email, plan_name, plan_member_cap, currency, billing_interval, trial_ends_at, price_display } = body;
  if (!society_id || !admin_email || !society_name) {
    return { statusCode: 400, body: JSON.stringify({ error: 'missing_required_fields' }) };
  }

  const supaHeaders = {
    'apikey': SUPABASE_SERVICE_ROLE_KEY,
    'Authorization': 'Bearer ' + SUPABASE_SERVICE_ROLE_KEY,
    'Content-Type': 'application/json',
  };

  // Anti-spam check: confirm the society + admin combo is real and
  // recently created. Society must exist with subscription_status
  // 'trialing' AND the admin email must be on a members row in that
  // society. Both conditions are set by register_society.
  try {
    const sRes = await fetch(`${SUPABASE_URL}/rest/v1/societies?id=eq.${society_id}&select=id,name,subscription_status`, { headers: supaHeaders });
    const sRows = await sRes.json();
    if (!sRows.length) return { statusCode: 404, body: JSON.stringify({ error: 'society_not_found' }) };
    if (sRows[0].subscription_status !== 'trialing') {
      return { statusCode: 400, body: JSON.stringify({ error: 'society_not_in_trial' }) };
    }

    const mRes = await fetch(`${SUPABASE_URL}/rest/v1/members?society_id=eq.${society_id}&email=eq.${encodeURIComponent(admin_email.toLowerCase())}&role=eq.admin&select=id`, { headers: supaHeaders });
    const mRows = await mRes.json();
    if (!mRows.length) return { statusCode: 403, body: JSON.stringify({ error: 'admin_not_on_society' }) };
  } catch (e) {
    return { statusCode: 500, body: JSON.stringify({ error: 'preflight_failed', detail: String(e) }) };
  }

  // Generate a magic link via the admin API. type='magiclink' for
  // existing users; if the user doesn't yet exist in auth.users,
  // we fall through to type='invite' which creates them.
  const origin = event.headers.origin || 'https://app.societeegolf.app';
  const redirectTo = `${origin}/`;

  let actionLink = null;
  for (const linkType of ['magiclink', 'invite']) {
    try {
      const r = await fetch(`${SUPABASE_URL}/auth/v1/admin/generate_link`, {
        method: 'POST',
        headers: supaHeaders,
        body: JSON.stringify({
          type: linkType,
          email: admin_email,
          options: { redirect_to: redirectTo },
          // Only relevant on type='invite' — passes through to handle_new_user.
          data: { society_id, name: admin_name },
        }),
      });
      const out = await r.json();
      if (r.ok && out?.properties?.action_link) {
        actionLink = out.properties.action_link;
        break;
      }
      // If magiclink failed because user doesn't exist, fall through to invite.
      if (linkType === 'magiclink' && (out?.error_code === 'user_not_found' || out?.msg?.includes('not found') || r.status === 422)) {
        continue;
      }
      // Otherwise stop on other errors.
      console.warn('[society-welcome] generate_link', linkType, r.status, out);
    } catch (e) {
      console.warn('[society-welcome] generate_link exception', linkType, e);
    }
  }

  if (!actionLink) {
    return { statusCode: 502, body: JSON.stringify({ error: 'magic_link_failed' }) };
  }

  // Build the HTML email.
  const trialEnds = trial_ends_at ? new Date(trial_ends_at) : null;
  const trialDate = trialEnds ? trialEnds.toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric' }) : 'in 30 days';
  const planLine = plan_name
    ? `<strong>${escapeHtml(plan_name)}</strong>${plan_member_cap ? ` — up to ${plan_member_cap} members` : ''}`
    : 'Standard plan';
  const priceLine = price_display
    ? `${escapeHtml(price_display)} per ${billing_interval === 'year' ? 'year' : 'month'}`
    : '';
  const safeName = escapeHtml(admin_name || 'there');
  const safeSociety = escapeHtml(society_name);
  const safeCode = escapeHtml(society_code || '');

  const html = `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Welcome to SocieteeGolf</title></head>
<body style="margin:0;padding:0;background:#F5F5F4;font-family:-apple-system,Segoe UI,Roboto,sans-serif;color:#1F2937;">
  <div style="max-width:560px;margin:0 auto;padding:24px;">
    <div style="background:#1B4D3E;color:#F5F5F4;padding:24px;border-radius:12px 12px 0 0;">
      <div style="font-size:14px;letter-spacing:1px;opacity:0.7;">SOCIETEEGOLF</div>
      <h1 style="margin:8px 0 0 0;font-size:24px;">Welcome, ${safeName}.</h1>
      <p style="margin:8px 0 0 0;font-size:15px;opacity:0.9;">
        <strong>${safeSociety}</strong> is set up and ready.
      </p>
    </div>

    <div style="background:#FFFFFF;padding:24px;border-radius:0 0 12px 12px;border:1px solid #E5E7EB;border-top:none;">
      <p style="font-size:15px;line-height:1.55;">
        Click the button below to sign in for the first time. The link expires in 1 hour.
      </p>
      <p style="text-align:center;margin:24px 0;">
        <a href="${actionLink}"
           style="display:inline-block;background:#C9A961;color:#1B4D3E;text-decoration:none;
                  padding:14px 28px;border-radius:8px;font-weight:700;font-size:16px;">
          Sign in to ${safeSociety}
        </a>
      </p>

      <h2 style="font-size:16px;margin:24px 0 8px 0;color:#1B4D3E;">Your society</h2>
      <table style="width:100%;border-collapse:collapse;font-size:14px;">
        <tr><td style="padding:6px 0;color:#6B7280;width:140px;">Name</td><td>${safeSociety}</td></tr>
        ${safeCode ? `<tr><td style="padding:6px 0;color:#6B7280;">Code</td><td><code>${safeCode}</code></td></tr>` : ''}
        <tr><td style="padding:6px 0;color:#6B7280;">Plan</td><td>${planLine}</td></tr>
        ${priceLine ? `<tr><td style="padding:6px 0;color:#6B7280;">Price</td><td>${priceLine}</td></tr>` : ''}
      </table>

      <h2 style="font-size:16px;margin:24px 0 8px 0;color:#1B4D3E;">Your free trial</h2>
      <p style="font-size:14px;line-height:1.55;margin:0;">
        You have <strong>30 days free</strong> — no charge until <strong>${trialDate}</strong>.
        After that the plan above bills automatically. You can cancel any time
        before then from your admin area and you won't be charged.
      </p>

      <h2 style="font-size:16px;margin:24px 0 8px 0;color:#1B4D3E;">What to do first</h2>
      <ol style="padding-left:20px;margin:0;font-size:14px;line-height:1.7;">
        <li>Sign in using the button above.</li>
        <li>Add a few members from the <strong>Admin</strong> tab (or share your join link).</li>
        <li>Browse the regional course library and confirm the rates for the venues you play.</li>
        <li>Create your first event — the cost auto-fills from your rate card.</li>
      </ol>

      <p style="margin:32px 0 0 0;font-size:13px;color:#6B7280;border-top:1px solid #E5E7EB;padding-top:16px;">
        Questions? Just reply to this email.
        <br>This sign-in link expires in 1 hour and can only be used once.
      </p>
    </div>

    <p style="text-align:center;font-size:12px;color:#9CA3AF;margin-top:16px;">
      SocieteeGolf · societeegolf.app
    </p>
  </div>
</body>
</html>`;

  // Send via Resend.
  try {
    const r = await fetch(RESEND_API, {
      method: 'POST',
      headers: {
        'Authorization': 'Bearer ' + RESEND_API_KEY,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: 'SocieteeGolf <noreply@societeegolf.app>',
        to: [admin_email],
        subject: `Welcome to SocieteeGolf — ${society_name} is live`,
        html,
        // Plain-text fallback so spam filters relax.
        text: [
          `Hi ${admin_name || 'there'},`,
          ``,
          `${society_name} is set up on SocieteeGolf.`,
          `Plan: ${plan_name || 'Standard'}${plan_member_cap ? ' (up to ' + plan_member_cap + ' members)' : ''}.`,
          `Free trial — no charge until ${trialDate}.`,
          ``,
          `Sign in here (expires in 1 hour):`,
          actionLink,
          ``,
          `Reply to this email if you need a hand.`,
          `SocieteeGolf · societeegolf.app`,
        ].join('\n'),
      }),
    });
    const out = await r.json();
    if (!r.ok) {
      console.warn('[society-welcome] resend error', r.status, out);
      return { statusCode: 502, body: JSON.stringify({ error: 'resend_failed', detail: out }) };
    }
    return { statusCode: 200, body: JSON.stringify({ ok: true, id: out.id }) };
  } catch (e) {
    return { statusCode: 502, body: JSON.stringify({ error: 'resend_unreachable', detail: String(e) }) };
  }
};

function escapeHtml(s) {
  return String(s || '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
