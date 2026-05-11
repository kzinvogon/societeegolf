// Netlify Function: Send member status change notification via Resend
// Called when a member's status changes (approved, probation, full_member, suspended)

exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: 'Method not allowed' };
  }

  const RESEND_API_KEY = process.env.RESEND_API_KEY;
  if (!RESEND_API_KEY) {
    return { statusCode: 500, body: JSON.stringify({ error: 'RESEND_API_KEY not configured' }) };
  }

  let body;
  try {
    body = JSON.parse(event.body);
  } catch {
    return { statusCode: 400, body: JSON.stringify({ error: 'Invalid JSON' }) };
  }

  const { name, email, society_name, new_status, message } = body;
  if (!name || !email || !new_status) {
    return { statusCode: 400, body: JSON.stringify({ error: 'name, email, and new_status required' }) };
  }

  const statusMessages = {
    probation: {
      subject: `Welcome to ${society_name || 'SocieteeGolf'} — you're in!`,
      heading: 'Application Approved',
      body: `Great news — your application has been approved! You're now a probation member of <strong>${society_name || 'SocieteeGolf'}</strong>.`,
      detail: 'Play 3 rounds with us and you\'ll be eligible for full membership. You can sign up for events right away.',
      cta: 'View Events',
    },
    full_member: {
      subject: `Congratulations — you're a full member of ${society_name || 'SocieteeGolf'}!`,
      heading: 'Full Membership Confirmed',
      body: `Congratulations, ${name}! You are now a <strong>full member</strong> of <strong>${society_name || 'SocieteeGolf'}</strong>.`,
      detail: 'Your payment has been confirmed and your membership is active. See you on the course!',
      cta: 'Open the App',
    },
    suspended: {
      subject: `${society_name || 'SocieteeGolf'} — membership update`,
      heading: 'Membership Suspended',
      body: `Hi ${name}, your membership at <strong>${society_name || 'SocieteeGolf'}</strong> has been suspended.`,
      detail: message || 'Please contact your society admin for more information.',
      cta: null,
    },
    applied: {
      subject: `${society_name || 'SocieteeGolf'} — application received`,
      heading: 'Application Received',
      body: `Thanks for your interest in <strong>${society_name || 'SocieteeGolf'}</strong>, ${name}!`,
      detail: 'Your application is being reviewed by the committee. You\'ll receive an email when it\'s been processed.',
      cta: null,
    },
  };

  const tmpl = statusMessages[new_status] || {
    subject: `${society_name || 'SocieteeGolf'} — status update`,
    heading: 'Status Update',
    body: `Hi ${name}, your membership status at <strong>${society_name || 'SocieteeGolf'}</strong> has been updated to <strong>${new_status}</strong>.`,
    detail: message || '',
    cta: 'Open the App',
  };

  const ctaHtml = tmpl.cta ? `
    <div style="text-align: center; margin: 24px 0;">
      <a href="https://app.societeegolf.app" style="display: inline-block; background: #2ecc71; color: white; text-decoration: none; padding: 12px 28px; border-radius: 8px; font-weight: 600; font-size: 14px;">${tmpl.cta}</a>
    </div>
  ` : '';

  const emailHtml = `
    <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; max-width: 560px; margin: 0 auto; padding: 20px;">
      <div style="background: linear-gradient(135deg, #0f172a 0%, #1e293b 100%); border-radius: 12px; padding: 28px; text-align: center; margin-bottom: 24px;">
        <h1 style="color: #2ecc71; margin: 0; font-size: 24px; letter-spacing: 1px;">SocieteeGolf</h1>
        <p style="color: rgba(255,255,255,0.7); margin: 6px 0 0; font-size: 14px;">${society_name || 'Golf Society Management'}</p>
      </div>

      <h2 style="color: #0f172a; font-size: 20px; margin-bottom: 12px;">${tmpl.heading}</h2>

      <p style="color: #333; font-size: 15px; line-height: 1.6;">${tmpl.body}</p>

      <div style="background: #F0FDF4; border-radius: 10px; padding: 18px; margin: 20px 0; border-left: 4px solid #2ecc71;">
        <p style="color: #333; font-size: 14px; line-height: 1.6; margin: 0;">${tmpl.detail}</p>
      </div>

      ${ctaHtml}

      <hr style="border: none; border-top: 1px solid #E5E7EB; margin: 24px 0;">

      <p style="color: #999; font-size: 12px; text-align: center; line-height: 1.5;">
        ${society_name || 'SocieteeGolf'}<br>
        <a href="https://app.societeegolf.app" style="color: #2ecc71;">app.societeegolf.app</a>
      </p>
    </div>
  `;

  try {
    const response = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${RESEND_API_KEY}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        from: process.env.RESEND_FROM || 'SocieteeGolf <noreply@apoyar.eu>',
        to: [email],
        subject: tmpl.subject,
        html: emailHtml
      })
    });

    const result = await response.json();
    if (!response.ok) {
      console.error('Resend error:', result);
      return { statusCode: 500, body: JSON.stringify({ error: result.message || 'Email send failed' }) };
    }

    return { statusCode: 200, body: JSON.stringify({ success: true, id: result.id }) };
  } catch (err) {
    console.error('Email error:', err);
    return { statusCode: 500, body: JSON.stringify({ error: err.message }) };
  }
};
