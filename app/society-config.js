// SocieteeGolf — Society Configuration
// All society-specific content in one place. Edit this file to rebrand for any society.

const SOCIETY_CONFIG = {
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

// ===== Society hydration =====

const ACTIVE_SOCIETY_KEY = 'sg_active_society_id';

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
 * Hydrate SOCIETY_CONFIG from a society row's config JSONB.
 * Stores the active society_id for data scoping.
 */
function hydrateSocietyConfig(society) {
  SOCIETY_CONFIG._societyId = society.id;
  SOCIETY_CONFIG._societyName = society.name;
  SOCIETY_CONFIG._societySubdomain = society.subdomain;
  if (society.config && typeof society.config === 'object') {
    deepMerge(SOCIETY_CONFIG, society.config);
  }
  // Auto-generate brandHtml from name if not set in config
  if (society.config?.name && !society.config?.brandHtml) {
    SOCIETY_CONFIG.name = society.config.name;
    SOCIETY_CONFIG.brandHtml = society.config.name;
  }
  // Persist selection
  try { localStorage.setItem(ACTIVE_SOCIETY_KEY, society.id); } catch(e) {}
}

/**
 * Get the persisted active society_id from localStorage.
 */
function getActiveSocietyId() {
  try { return localStorage.getItem(ACTIVE_SOCIETY_KEY); } catch(e) { return null; }
}

/**
 * Extract a tenant slug from the current hostname.
 *   jpgs.societeegolf.app  → "jpgs"
 *   app.societeegolf.app   → null (reserved, legacy default-host)
 *   societeegolf.app       → null (apex, marketing site)
 *   localhost / *.netlify.app → null (dev / preview)
 */
const RESERVED_SUBDOMAINS = new Set(['app','www','api','admin','mail','staging','preview','dev']);
function resolveTenantSlugFromHost() {
  const host = (typeof window !== 'undefined' && window.location && window.location.hostname) || '';
  if (!host) return null;
  if (host === 'localhost' || host === '127.0.0.1' || host.startsWith('192.168.') || host.endsWith('.local')) return null;
  if (host.endsWith('.netlify.app')) return null;
  const parts = host.split('.');
  if (parts.length < 3) return null;            // apex domain — no subdomain
  const slug = parts[0].toLowerCase();
  if (RESERVED_SUBDOMAINS.has(slug)) return null;
  return slug;
}

/**
 * Clear the persisted active society on logout.
 */
function clearActiveSociety() {
  try { localStorage.removeItem(ACTIVE_SOCIETY_KEY); } catch(e) {}
  SOCIETY_CONFIG._societyId = null;
  SOCIETY_CONFIG._societyName = null;
  SOCIETY_CONFIG._societySubdomain = null;
}

/**
 * Apply the current SOCIETY_CONFIG to DOM elements.
 */
function applySocietyConfigToDOM() {
  document.title = SOCIETY_CONFIG.name;
  const brand = document.querySelector('.header-brand');
  if (brand) {
    brand.innerHTML = SOCIETY_CONFIG.brandHtml;
    brand.href = SOCIETY_CONFIG.websiteUrl;
  }
  const teeLabel = document.querySelector('.tab-label-tee');
  if (teeLabel) teeLabel.textContent = SOCIETY_CONFIG.terms.bookings;
  const teeHeading = document.querySelector('.tab-heading-tee');
  if (teeHeading) teeHeading.textContent = 'Your ' + SOCIETY_CONFIG.terms.bookings;
}
