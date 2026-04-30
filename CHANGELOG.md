# SocieteeGolf — Changelog

## Phase 5: Self-Serve SaaS — Chooser Entry, Demo, Subscriptions, Course Rates (2026-04-27 → 2026-05-01)

A working multi-tenant B2B SaaS shape on top of the Phase 4 multi-society
foundation. Single-host pivot, anonymous-auth demo, Stripe billing,
society directory, regional course library with negotiated rate cards.

### Architecture pivot
- **Single-host model.** Subdomain routing (the dormant `f7a3383`
  resolver) parked in favour of one app entry at
  `app.societeegolf.app`, tenant identified post-login by email. Same
  shape as Linear / Notion / Vercel. Removes the wildcard-SSL +
  Netlify-Pro-support-ticket dependency. Subdomain code stays for the
  day a customer wants a custom domain (CNAME → one alias).
- **Three-action chooser** at the visitor entry: Join my society /
  Register a new society / Try the demo. The 120-line per-society
  visitor view replaced with a 40-line intent picker.

### Auth
- Magic-link only (typed-OTP path removed in `5da38d4`).
- `mailer_autoconfirm = true` on the project — new admins receive the
  friendly magic-link template instead of the spam-prone "Confirm Your
  Signup" template.
- Anonymous sign-ins enabled (project setting) for the demo path.
- `_demoEntryInProgress` flag in `onAuthStateChange` prevents the
  SIGNED_IN handler from racing the demo flow's own login work.
- `logout()` clears local state synchronously *before* `signOut()`
  call so the SIGNED_OUT echo doesn't loop through the handler
  (`e0239b3` fixes a Safari-freeze bug).
- `loginWithSession` no-membership fallback: signs out + bounces to
  the chooser instead of leaving a stranded session.

### Schema
- **Migration 004** — `events_anon_select` policy dropped; replaced
  with `events_for_society_slug` and `society_for_slug` SECURITY
  DEFINER RPCs. Tenant-scoped public reads.
- **Migration 005** — `handle_new_user` no longer silently buckets
  email-only signups into the seed default society; requires
  explicit `society_id` metadata or matches an existing member by
  email.
- **Migration 006** — `society_directory()` + `register_society()`
  RPCs, `societies.is_demo` + `societies.public_directory` flags,
  seeded demo society (`subdomain='demo'`, id `0…002`).
- **Migration 007** — `enter_demo_society()` RPC for the
  anonymous-auth demo path; `register_society` rejects anon JWTs;
  `cleanup_demo_anon_users()` helper.
- **Migration 008** — pg_cron job `demo-anon-cleanup-nightly` at
  03:15 UTC purges anonymous demo accounts older than 24h plus
  their orphan member rows.
- **Migration 009** — `register_society` blocks already-known
  emails (the `members` PK was just `id`, so multi-society wasn't
  possible without 011).
- **Migration 010** — pricing tables: `plans`, `plan_prices`,
  society billing columns (`plan_id`, `billing_currency`,
  `billing_interval`, `trial_ends_at`, `current_period_end`,
  `cancel_at_period_end`, `is_billable`). 4 plans × 3 currencies
  × 2 intervals = 24 prices. RLS world-readable on the catalog.
- **Migration 011** — multi-society membership unblocked.
  `members.user_id` added (was `id == auth.uid()` for everyone, so
  the same auth user couldn't appear in two member rows).
  Existing rows backfilled. `members.id` now per-membership PK,
  `user_id` is the auth link. RLS + helpers + trigger + RPCs all
  updated to filter on `user_id`.
- **Migration 012** — `register_society` accepts plan/currency/
  interval params and stamps a 30-day trial. New
  `approve_join_request(integer)` RPC enforces the plan member cap
  on approval.
- **Migration 013** — pricing v2: switched from per-member to
  flat-rate per society after pricing-vs-society-economics
  analysis. €5/€10/€20 per month for ≤50/100/200 members; Society+
  is "contact us" (`is_contact_only`). Annual = 11 × monthly.
- **Migration 014** — `external_courses` shared catalog (32
  Costa Blanca + Murcia courses seeded from JPGS data + wanderlog
  cross-reference). `search_external_courses` RPC.
- **Migration 015** — `course_rates` per-society negotiated rate
  rows. JSONB `date_ranges` for queryable matching plus the
  original label string. 35 rate rows seeded from JPGS's
  "Societies 2026 V3" rate card. `rates_for_course(course_id,
  players, on_date)` RPC returns active-today + matches-player-count
  flags computed server-side. Splits Villaitana into Levante/
  Poniente courses (different rates).
- **Migration 016** — broader Spain coverage: 38 more
  society-friendly courses across Costa del Sol, Mallorca, Costa
  Brava, Catalonia, Madrid, Tenerife. Total now 73 courses across
  9 regions.

### Stripe billing
- 4 products + 24 prices bootstrapped in test mode via the Stripe
  REST API. `plans.stripe_product_id` + `plan_prices.stripe_price_id`
  persisted. Repriced in pricing v2 — old per-member prices archived,
  18 new flat-rate prices created.
- `netlify/functions/create-checkout-session.js` — verifies caller's
  Supabase JWT, looks up the right price via service role, builds a
  Stripe Checkout session in subscription mode with
  `trial_period_days=30` and `quantity=1`.
- `netlify/functions/stripe-webhook.js` — HMAC-SHA256 signature
  verification (no Stripe SDK, fetch + crypto only). Handles
  `checkout.session.completed`,
  `customer.subscription.{created,updated,deleted}`,
  `invoice.payment_{succeeded,failed}` → updates society
  subscription columns.
- Admin home Subscription card pulls plan name, interval, currency,
  trial-end + days-left, status. "Set up billing" CTA opens
  Checkout when `stripe_subscription_id` is null.
- Post-Checkout return (`?billing=success`/`cancelled`) shows a
  toast and cleans the query string.
- **Pending:** `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`,
  `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` env vars on Netlify
  + webhook endpoint registration in Stripe dashboard.

### Visitor / member UX
- Demo path: `signInAnonymously` → `enter_demo_society` RPC →
  full member view of the demo society. Yellow banner pinned under
  the header with a one-click "Register your society" jump that
  ends the demo session and drops the user on the register form.
- `endAnonSessionIfAny()` helper called at the top of
  `showRegisterSocietyView` and `showJoinSocietyView` so a lingering
  demo session doesn't trip the `is_anonymous` guard on
  `register_society`.
- Member-cap enforcement: 80% / 100% capacity banners on the admin
  home; `approve_join_request` rejects when at cap.
- Currency picker on register form auto-defaults from
  `navigator.language` (EUR / GBP / USD).
- Plan picker on register form pulls live from `plans` +
  `plan_prices`. Society+ shows "Contact us" mailto instead of
  price + radio.
- Course library search panel in admin event creation. "Rates" /
  "Use" action buttons per result. Rates panel: season/date/GF/
  buggy/min/captain table with active-today highlighted, 12-player
  default calculator (captain-freebie aware).
- Admin "Manage Course Rates" screen — full CRUD on the society's
  rate rows via direct PostgREST writes (gated by
  `course_rates_admin_all` RLS).
- Auto-fill event cost: when admin picks a course + date in the
  Create Event form, the cost field pre-fills from the matching
  rate, with a hint showing season + buggy treatment + captain
  freebie. Manual cost overrides stick.

### Layout / UX fixes
- `e0239b3` — Safari freeze on logout (signOut/SIGNED_OUT loop).
- `6f0de94` — tab bar pinned to viewport bottom on tall windows
  was leaving a gap on desktop. Replaced with `position: sticky`
  on a naturally-flowing document — bar sits inline at end of
  short content, sticks while scrolling on long content.
- `7c190e9` — fresh login lands on Home; page refreshes restore
  last-tab. `localStorage.jpgs_last_tab` cleared on logout so it
  doesn't follow the user to a new session.
- `f4ade44` / `e8c77f9` — fixed an `_demoEntryInProgress` race
  where the SIGNED_IN handler ran `loginWithSession` which signed
  the brand-new anon user out before the demo member row existed.

### Cleanup
- Repo root swept: `deploy/`, `deploy_javeagolf/`, `deploy_go_javea/`,
  legacy `jpgs_*.html` review packs, JPGS strategy docs all moved
  to `_archive/`. `.gitignore` covers `node_modules`, `_archive`,
  `.env*`, OS junk. `package.json` tracked.

### Outstanding (parked, not blocked)
- Apex marketing site (`index.html`) still has JPGS-pitched-to-
  golfers content. Needs SaaS-pitched-to-organisers rewrite.
- Stripe end-to-end verification waiting on Netlify env vars +
  Stripe webhook endpoint registration.
- `app/index.html` is now ~4,300 lines with module-style sections
  but no actual modules. Refactor candidate before subdomain
  routing comes back online.
- `external_courses` covers Spain only. Add UK / Portugal / etc.
  when the customer base demands.

---

## Phase 4: Society Selection on Login (2026-04-19)

### Society Selector
- After magic link login, app queries all societies the user belongs to
- Single society: auto-selects and proceeds to member view
- Multiple societies: shows a picker screen with society name and membership status
- Selected society persisted in localStorage (`sg_active_society_id`), restored on next visit
- Cleared on logout

### Config Hydration
- `hydrateSocietyConfig(society)` deep-merges the society's `config` JSONB over defaults
- `applySocietyConfigToDOM()` updates title, header brand, tab labels from config
- `selectSocietyAndLogin()` handles the full flow: hydrate → set user → render
- Cache invalidated on society switch to ensure fresh data

### Society-Scoped Data
- `getEvents()` and `getMessages()` filter by `SOCIETY_CONFIG._societyId`
- Ensures members only see data for their active society

### Auth
- Magic link redirects to `https://app.societeegolf.app/` (single domain, no wildcards)
- No subdomain routing needed — society resolved after login from DB

### RLS Fix
- Fixed infinite recursion in members policies (self-referencing subqueries)
- Rebuilt all members policies: anon select (for email check), auth select (society-scoped via SECURITY DEFINER function), admin all, update own, insert open
- `get_society_id()` function recreated as SECURITY DEFINER to bypass RLS safely

---

## Phase 3: Tenant Routing — REVERTED (2026-04-19)

Subdomain and path-based routing were implemented but reverted.
Subdomain approach requires wildcard DNS (Netlify free tier doesn't support it).
New approach TBD — considering Vercel migration or alternative routing.

Phase 2 multitenancy DB (societies table, society_id, RLS) remains in place.

---

## Phase 2: Multitenancy Foundation

### Migration 001 — Multitenancy (2026-04-18)
- Created `societies` table: id, name, subdomain, config (JSONB), subscription_status, stripe_customer_id, stripe_subscription_id, created_at
- Added `society_id` FK to: members, events, messages, join_requests, courses
- All existing data assigned to default society (id: `00000000-...-000001`, name: "SocieteeGolf", subdomain: "default")
- Email uniqueness changed from global to per-society (`members_email_society_unique`)
- `handle_new_user()` trigger updated to read `society_id` from auth user metadata
- File: `supabase/migrations/001_multitenancy.sql`

### Migration 002 — Row Level Security (2026-04-18)
- Created `public.get_society_id()` helper function for RLS policy checks
- Dropped all legacy RLS policies, replaced with 20 society-scoped policies
- Members: can only view/interact within their own society
- Admins: can manage members, events, messages, courses, join_requests within their society
- Events, courses, results: publicly readable (visitor view)
- Join requests: publicly insertable (registration form)
- File: `supabase/migrations/002_rls.sql`

---

## Phase 1: Society Config Extraction (2026-04-18)

### society-config.js
- Extracted all society-specific content into `app/society-config.js`
- Config object `SOCIETY_CONFIG` contains: name, brandHtml, tagline, description, websiteUrl, contactEmail, terms, heroStats, aboutCard, features, testimonials, competitions, pricing, joinSteps, statuses, probation, payment
- Visitor view refactored to render entirely from config via `renderVisitorView()`
- Member UI labels (title, header brand, Tee Times tab, dashboard) read from config
- To rebrand for any society: edit only `society-config.js`

---

## Rebrand: JPGS → SocieteeGolf (2026-04-17)

### Domain Setup
- GitHub repo renamed from `kzinvogon/jpgs` to `kzinvogon/societeegolf`
- Main website: `https://societeegolf.app` (Netlify site: `enchanting-custard-51941b`)
- Member app: `https://app.societeegolf.app` (Netlify site: `sociteegolfapp`, base dir: `app/`)
- Magic link redirect: `https://app.societeegolf.app/`
- Supabase redirect URLs: `https://societeegolf.app/**`, `https://app.societeegolf.app/**`

### Content
- All "JPGS" and "Javea Port Golf Society" references replaced with "SocieteeGolf"
- All Javea, Costa Blanca, and location-specific content removed/genericised
- Contact email: `info@societeegolf.app`
- Hardcoded courses replaced with generic placeholders (real data from Supabase)
- Welcome email rebranded in `netlify/functions/send-welcome-email.js`

---

## UX Polish (2026-04-15)

### Login Form
- Inline email validation with green/red border
- Spinner animation on send button
- "Check your inbox" sent state with Gmail/Outlook shortcuts
- 30-second resend cooldown timer
- Auto-focus email input on auth view

### Session & Toast
- Personalised "Welcome, {firstName}" toast on first login (once per member per browser)
- Last visited tab saved to localStorage and restored on login

### Bottom Nav
- Active pip dot under active tab
- Icon bounce animation on active
- Tap scale feedback (0.92x)
- Unread messages badge (red, based on last-seen timestamp)

### Mode Toggle
- Sliding white pill animation between Visitor/Member

### Email Restriction
- Magic link restricted to registered emails only
- Unknown emails shown "Email not found. Please apply via Join Us first." with link

---

## Member Lifecycle (2026-04-11 → 2026-04-12)

### Status System
- Four statuses: Applied → Probation → Full Member → Suspended
- DB CHECK constraint updated from old `active` values
- CSS badge classes: yellow (applied), blue (probation), green (full_member), red (suspended)
- `approveMember()` now sets probation (or full_member for admins)

### Probation Tracking
- Admin members table shows X/3 progress for probation members (amber < 3, green >= 3)
- Member profile shows progress bar on both web and app
- App dashboard shows probation alert card

### Payment Flow
- DB columns added: `payment_proof`, `payment_proof_submitted_at`, `payment_due_sent_at`
- "Send Payment Link" button for admin when probation member has 3+ games
- Payment proof input on member profile (both web and app)
- "Pending Payment Reviews" section in admin — approve promotes to Full Member, reject clears proof
- Congratulatory message sent on approval, rejection notification on reject

### Join Request → Member
- Approving a join request now creates member record immediately (FK to auth.users dropped)
- Admin can set initial member status before approving (Applied/Probation/Full Member)
- "Add Member" creates directly in members table with selectable status (defaults to Full Member)
- Auto-create on magic link login still works as fallback

### Admin Roles
- Any admin can promote other members to admin via Edit Member form
- Admins skip probation — approved straight to Full Member
- App admin shows edit member screen with role and status controls

---

## Context-Sensitive Help (2026-04-12)

### Member App
- ? button in header, always visible
- Help content adapts to current context: visitor, home, events, tee times, messages, profile, admin, create event, edit member
- Includes member lifecycle reference

### Main Website
- ? button in My Account modal and Admin Panel header
- Help content for each admin tab
- Includes member lifecycle and payment flow documentation

---

## Admin Panel Improvements (2026-04-11 → 2026-04-12)

### Event Signups View
- Event details (date, course, location, cost, tee time, etc.) shown above signups table

### Members Table
- Replaced Email/Phone columns with Played, Pending, Last Played
- Capacity check added to app signup (prevents overbooking)
- Reject member now sets status to suspended instead of deleting record

### App Admin
- All stat cards clickable (scroll to section)
- Members list with status badges and probation game count
- Join Requests section with status dropdowns
- Edit member screen with role/status controls
- "New Applications" combined count
- Payment Reviews and Ready for Payment sections

### Bug Fixes
- Missing `badge-blue` and `badge-yellow` CSS classes added
- Signup capacity check and member status check in app
- Duplicate signup error handled with user-friendly message
- `handle_new_user` trigger fixed to handle existing email gracefully (re-keys member ID)
