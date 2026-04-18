# SocieteeGolf — Changelog

## Phase 3: Subdomain Routing (2026-04-18)

### Dynamic Society Config Loading
- `society-config.js` now includes `loadSocietyConfig()` — extracts subdomain from hostname, queries Supabase `societies` table via REST API, deep-merges the society's `config` JSONB over static defaults
- `getSubdomain()` parses hostname for `*.societeegolf.app` pattern
- Unknown subdomains redirect to `societeegolf.app`
- Localhost uses static defaults as fallback
- `init()` calls `loadSocietyConfig()` before rendering

### Society-Scoped Data Access
- `getEvents()` and `getMessages()` now filter by `society_id` for proper multi-tenant data isolation
- Default society config JSONB seeded in database

### Wildcard DNS
- `*.societeegolf.app` CNAME → `sociteegolfapp.netlify.app`
- Any subdomain resolves to the app, config loaded dynamically per society

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
