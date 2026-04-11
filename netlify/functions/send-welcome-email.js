// Netlify Function: Send welcome/acknowledgement email via Resend
// Triggered when someone submits the Join Us form

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

  const { name, email, phone, notifyBy } = body;
  if (!name || !email) {
    return { statusCode: 400, body: JSON.stringify({ error: 'Name and email required' }) };
  }

  // Send acknowledgement email to the person who registered
  const emailHtml = `
    <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; max-width: 560px; margin: 0 auto; padding: 20px;">
      <div style="background: linear-gradient(135deg, #152847 0%, #1B4D3E 100%); border-radius: 12px; padding: 28px; text-align: center; margin-bottom: 24px;">
        <h1 style="color: #C9A84C; margin: 0; font-size: 24px; letter-spacing: 1px;">JPGS</h1>
        <p style="color: rgba(255,255,255,0.85); margin: 6px 0 0; font-size: 14px;">Javea Port Golf Society</p>
      </div>

      <h2 style="color: #152847; font-size: 20px; margin-bottom: 8px;">Thank you, ${name}!</h2>

      <p style="color: #333; font-size: 15px; line-height: 1.6;">
        We've received your interest in joining Javea Port Golf Society. A member of our committee will be in touch shortly to arrange your first round with us.
      </p>

      <div style="background: #F7F8FA; border-radius: 10px; padding: 18px; margin: 20px 0;">
        <h3 style="color: #152847; font-size: 15px; margin: 0 0 10px;">How it works:</h3>
        <ol style="color: #555; font-size: 14px; line-height: 1.8; margin: 0; padding-left: 20px;">
          <li>Play 3 rounds with us — a chance for you and us to decide if it's a good fit</li>
          <li>Once approved, membership is just <strong>&euro;25 per quarter</strong></li>
          <li>Sign up for any event, play the best courses on the Costa Blanca</li>
        </ol>
      </div>

      <p style="color: #333; font-size: 15px; line-height: 1.6;">
        We play courses across the northern Costa Blanca — from championship layouts to shorter 9-hole challenges. No joining fees, no share schemes. All abilities and nationalities welcome.
      </p>

      <div style="text-align: center; margin: 24px 0;">
        <a href="https://javeagolf.netlify.app" style="display: inline-block; background: #C9A84C; color: #152847; text-decoration: none; padding: 12px 28px; border-radius: 8px; font-weight: 600; font-size: 14px;">Visit Our Website</a>
      </div>

      <hr style="border: none; border-top: 1px solid #E5E7EB; margin: 24px 0;">

      <p style="color: #999; font-size: 12px; text-align: center; line-height: 1.5;">
        Javea Port Golf Society<br>
        Costa Blanca, Spain<br>
        <a href="mailto:javeaportgolfsociety@gmail.com" style="color: #C9A84C;">javeaportgolfsociety@gmail.com</a>
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
        from: process.env.RESEND_FROM || 'Javea Port Golf Society <noreply@apoyar.eu>',
        to: [email],
        subject: `Welcome to JPGS, ${name}!`,
        html: emailHtml
      })
    });

    const result = await response.json();

    if (!response.ok) {
      console.error('Resend error:', result);
      return { statusCode: 500, body: JSON.stringify({ error: result.message || 'Email send failed' }) };
    }

    return {
      statusCode: 200,
      body: JSON.stringify({ success: true, id: result.id })
    };
  } catch (err) {
    console.error('Email error:', err);
    return { statusCode: 500, body: JSON.stringify({ error: err.message }) };
  }
};
