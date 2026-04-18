// SocieteeGolf — Society Configuration
// Default config used as fallback for localhost / unknown subdomains.
// In production, loadSocietyConfig() queries the societies table and
// deep-merges the society's config JSONB over these defaults.

const SOCIETY_CONFIG = {
  // Set by loadSocietyConfig()
  _loaded: false,
  _societyId: null,

  // Branding
  name: 'SocieteeGolf',
  brandHtml: 'Societee<span>Golf</span>',
  tagline: 'Great Golf. No Fees. No Fuss.',
  description: 'A friendly golf society playing the best courses in the region. All abilities welcome.',
  websiteUrl: 'https://societeegolf.app',
  contactEmail: 'info@societeegolf.app',
  contactReply: 'We usually reply within 24 hours',

  // Terminology (customise per society)
  terms: {
    booking: 'Tee Time',
    bookings: 'Tee Times',
    event: 'Event',
    events: 'Events',
    venue: 'Course',
    venues: 'Courses',
  },

  // Hero stats shown on visitor landing
  heroStats: [
    [
      { value: '13', label: 'Courses' },
      { value: 'All', label: 'Abilities Welcome' },
    ],
    [
      { value: 'Green Fees', label: '+ €5/game for prizes', valueStyle: 'font-size:16px;' },
      { value: '€0', label: 'Joining Fee' },
    ],
  ],

  // "What We're About" card
  aboutCard: {
    title: 'Golf Without the Club Fees',
    body: 'We rotate across the best courses in the area — from championship layouts to shorter 9-hole challenges. No joining fees, no share schemes. Just great golf and good company.',
  },

  // "Why Join Us?" features
  features: [
    { icon: '💰', bg: '#D1FAE5', title: 'Simple & Affordable', description: 'No joining fee, no share scheme. Green fees at discounted society rates.' },
    { icon: '🏌️', bg: '#E0E7FF', title: 'Great Courses', description: 'Rotate across 13 courses — championship layouts, coastal gems, and mountain backdrops.' },
    { icon: '🏆', bg: 'var(--gold-light)', title: 'Competitions & Trophies', description: 'Stableford, Medal, Texas Scramble, Better Ball — varied formats plus four prestigious annual trophies.' },
    { icon: '✈️', bg: '#DBEAFE', title: 'Away Trips', description: 'Bi-annual trips to premier golf courses and stay at all-inclusive hotels. Lots of fun and top class golf.' },
    { icon: '🍻', bg: '#FEE2E2', title: 'More Than Golf', description: 'Friendships, banter, away days, and social events. A community, not just a club.' },
  ],

  // Testimonials
  testimonials: [
    'I joined not knowing many people and within weeks I had a group of friends I will have for life. The golf is great but the friendships are even better.',
    'Everything a golf society should be — competitive enough to keep you sharp, friendly enough to keep you coming back.',
    'What I really like is the variety — Texas Scramble, Better Ball, Reverse Waltz, Individual Stableford. The organisers really mix things up.',
  ],

  // Trophy / competition calendar
  competitions: [
    { icon: '🏅', title: 'Francis McNeil Memorial', description: 'Our most cherished competition — a tribute to a much-missed member.' },
    { icon: '🧳', title: 'Away Days Trophies', description: 'Twice a year the society hits the road — two trophies across the best regional courses.' },
    { icon: '🎖️', title: "Captain's Trophy", description: 'One of the most prestigious events in the society year. Every member wants this one.' },
    { icon: '🆕', title: 'Society Trophy [New 2026]', description: 'Brand new — who will be the inaugural winner?' },
  ],

  // Pricing
  pricing: {
    quarterly: '€25',
    quarterlyLabel: 'per quarter — covers prizes & pre-pays booking fees',
    comp: '+ €5',
    compLabel: 'comp prizes contribution (on trophy events only)',
    greenFee: '+ green fee at <strong>discounted society rates</strong>',
    tagline: 'No joining fee. No share scheme. Ever.',
  },

  // "How to Join" steps
  joinSteps: [
    { num: '1', icon: '📝', title: 'Register Your Interest', description: 'Contact us via email or the main website form.' },
    { num: '2', icon: '⛳', title: 'Play 3 Rounds', description: "Join us for 3 games — a chance for you and us to decide if it's a good fit." },
    { num: '3', icon: '🎉', title: 'Play & Pay', description: '€25 quarterly membership + €5 comp prizes contribution. That\'s it.' },
  ],

  // Member status config
  statuses: {
    applied: { label: 'Application Pending', badge: 'badge-yellow' },
    probation: { label: 'Probation', badge: 'badge-blue' },
    full_member: { label: 'Full Member', badge: 'badge-green' },
    suspended: { label: 'Suspended', badge: 'badge-red' },
  },

  // Probation
  probation: {
    gamesRequired: 3,
    completeMessage: 'All 3 games complete! Please submit your membership payment below.',
    progressMessage: (played, total) => `${played} of ${total} probation games played`,
    remainingMessage: (remaining) => `Play ${remaining} more game${remaining !== 1 ? 's' : ''} to complete probation.`,
  },

  // Payment
  payment: {
    amount: '€25',
    period: 'quarterly',
    proofPlaceholder: 'Paste payment reference, URL, or description',
    requestTitle: 'Membership Payment Required',
    requestBody: 'Congratulations on completing your 3 probation games! To become a full member, please pay the membership fee.\n\nOnce paid, go to your Profile and submit your proof of payment.\n\nThe committee will review and confirm your membership.',
    approvedTitle: 'Welcome — Full Member!',
    approvedBody: 'Congratulations! Your payment has been confirmed and you are now a full member.',
    rejectedTitle: 'Payment Proof Rejected',
    rejectedBody: 'Your payment proof could not be verified. Please resubmit your proof of payment in your Profile.',
  },
};

// ===== Subdomain routing & config loading =====

const PLATFORM_DOMAIN = 'societeegolf.app';
const PLATFORM_URL = 'https://societeegolf.app';
const DEFAULT_SOCIETY_ID = '00000000-0000-0000-0000-000000000001';

/**
 * Extract society slug from subdomain.
 * Pattern: {slug}.societeegolf.app
 * Examples:
 *   "testgolf.societeegolf.app"   → "testgolf"
 *   "societeegolf.app"            → null (marketing site)
 *   "www.societeegolf.app"        → null (marketing site)
 *   "localhost"                   → null (dev fallback)
 */
function getSocietySlug() {
  const host = window.location.hostname;
  // Localhost / dev — use default
  if (host === 'localhost' || host === '127.0.0.1') return null;
  // Must be under the platform domain
  if (!host.endsWith('.' + PLATFORM_DOMAIN)) return null;
  const sub = host.replace('.' + PLATFORM_DOMAIN, '');
  // www and empty are not society slugs
  if (!sub || sub === 'www' || sub === 'app') return null;
  return sub;
}

/**
 * Deep merge source into target. Arrays are replaced, not merged.
 * Functions in target are kept if source doesn't override them.
 */
function deepMerge(target, source) {
  if (!source || typeof source !== 'object') return;
  for (const key of Object.keys(source)) {
    if (source[key] && typeof source[key] === 'object' && !Array.isArray(source[key]) && typeof target[key] === 'object' && !Array.isArray(target[key])) {
      deepMerge(target[key], source[key]);
    } else if (source[key] !== undefined && source[key] !== null) {
      target[key] = source[key];
    }
  }
}

/**
 * Load society config from Supabase via REST API.
 * Uses path-based routing: /s/{slug}/...
 *
 * URL examples:
 *   app.societeegolf.app/              → default society
 *   app.societeegolf.app/s/mygolf/     → society with subdomain "mygolf"
 *   app.societeegolf.app/s/unknown/    → redirect to societeegolf.app
 *   localhost:8080/                     → default society (static fallback)
 */
async function loadSocietyConfig() {
  const slug = getSocietySlug();

  // No slug — use default society
  if (!slug) {
    SOCIETY_CONFIG._loaded = true;
    SOCIETY_CONFIG._societyId = DEFAULT_SOCIETY_ID;
    SOCIETY_CONFIG._slug = null;
    return;
  }

  try {
    const res = await fetch(
      SUPABASE_URL + '/rest/v1/societies?subdomain=eq.' + encodeURIComponent(slug) + '&select=id,name,subdomain,config',
      {
        headers: {
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': 'Bearer ' + SUPABASE_ANON_KEY,
        }
      }
    );

    if (!res.ok) {
      console.warn('Failed to load society config:', res.status);
      SOCIETY_CONFIG._loaded = true;
      SOCIETY_CONFIG._societyId = DEFAULT_SOCIETY_ID;
      SOCIETY_CONFIG._slug = null;
      return;
    }

    const data = await res.json();

    if (!data || data.length === 0) {
      // Unknown slug — redirect to main site
      console.warn('Unknown society slug:', slug);
      window.location.href = PLATFORM_URL;
      return;
    }

    const society = data[0];
    SOCIETY_CONFIG._societyId = society.id;
    SOCIETY_CONFIG._loaded = true;
    SOCIETY_CONFIG._slug = slug;

    // Deep merge the society's config JSONB over the defaults
    if (society.config && typeof society.config === 'object') {
      deepMerge(SOCIETY_CONFIG, society.config);
    }

    // If the society has a name but no brandHtml, auto-generate it
    if (society.config?.name && !society.config?.brandHtml) {
      SOCIETY_CONFIG.name = society.config.name;
      SOCIETY_CONFIG.brandHtml = society.config.name;
    }

    console.log('Society loaded:', society.name, '(id:', society.id, ', slug:', slug + ')');

  } catch (err) {
    console.warn('Error loading society config:', err);
    SOCIETY_CONFIG._loaded = true;
    SOCIETY_CONFIG._societyId = DEFAULT_SOCIETY_ID;
    SOCIETY_CONFIG._slug = null;
  }
}
