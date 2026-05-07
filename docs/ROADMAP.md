# SocieteeGolf — 5-phase roadmap (A → F)

The "captain loop" is a 7-block flow: Course Intelligence → Interest Sounder → Event Sign-up → Play Schedule → Results → Roles → Sponsorship. The current code covered ~35–40% of that loop before this plan started. Each phase below ships standalone — usable on its own without the next.

## Status at a glance

| # | Phase | Status | Migration | Headline commit |
|---|---|---|---|---|
| A | Roles & permissions | ✅ shipped | 018 | `fccb4d8` |
| B | Interest Sounder | ✅ shipped | 019 | `3af29b7` |
| C | Format library + team generator | ✅ shipped | 020 | `92e795f` |
| D | Results + push to members | ✅ shipped | 022 | — |
| F | Sponsor (parallel-able with D/E) | ← **next** | — | — |
| E | Course intelligence (automation) | deferred | — | — |

**Order in practice:** A → B → C → D → **F** → E. E is last because it depends on partner integrations and is the riskiest; A–D + F are pure UX wins.

---

## Architectural decisions baked in

- Phase A's `has_role_in(society_id, roles[])` SECURITY DEFINER helper is the **gate for every Phase C+ admin write**. Don't bypass it with new RLS — extend it.
- "Captain ≠ Admin": captains run events but don't do member CRUD or rate negotiation. Phase C generator-publish is `userCanRunEvents`, not `userIsAdmin`. Phase D scoring should follow the same rule.
- Sponsor role is **content-only**; never gate functional permissions on it.
- The format library has a "custom" fallback path so captains aren't blocked when their event is unusual; the entry gets promoted to the library after captain confirms.
- `societies.subscription_status` carries both legacy `'trial'` and Stripe-canonical `'trialing'` — any new filter must allow both, plus `'past_due'` for retry hiccups (see migration 021).

---

## Phase A — Roles & permissions ✅ shipped (2026-05-04, `fccb4d8`)

Six roles instead of two: `member` / `vice_captain` / `captain` / `treasurer` / `admin` / `sponsor`. Schema-side enforcement via `has_role_in(society_id, roles[])`.

- Migration 018 expanded the role check, added `has_role_in`, and repaired four RLS policies that were left referencing `members.id = auth.uid()` (stale since migration 011 split the membership PK from the auth user id).
- Client: `MANAGE_ROLES` / `EVENT_ROLES` constants + `userIsAdmin` / `userCanManage` / `userCanRunEvents` / `userIsTreasurer` helpers. Tab visibility, Quick Actions, member edit form gating.
- Sponsor acts as Member for permissions in v1; the soft-role content slot is Phase F.

---

## Phase B — Interest Sounder ✅ shipped (2026-05-04, `3af29b7`)

Pre-event "let members register interest before we book" flow. Captain floats 2–4 candidate options (course × date × approx €), members tap "I'd play", captain promotes the winner to a real event.

- Migration 019: `event_proposals` (status open/closed/promoted/cancelled), `event_proposal_options` (free-text course-name fallback alongside `external_courses` ref), `event_proposal_votes` (UNIQUE(option, member)).
- RPCs: `proposal_tally(proposal_id)` aggregates votes; `promote_proposal_to_event(proposal_id, option_id, …)` creates the real event row, marks proposal `'promoted'`, links `proposal.promoted_event_id`.
- UI: Captain "Sound out next event" form + tally view (`showAdminProposalTally`); admin events page shows "Open proposals" panel; member Home gets `#openProposalsCard` with vote toggles.

---

## Phase C — Format library + team generator ✅ shipped (2026-05-06, `92e795f`)

The single biggest captain time-saver in the loop.

- **Migration 020** — `event_formats` (society_id-nullable globals + per-society customs; team_size_min/max 1–4; scoring_method enum: stableford / medal / scramble / better_ball / matchplay / custom). Seeded with **9 globals**: Individual Stableford, Medal (Stroke Play), Individual Matchplay, Pairs Matchplay, Better Ball (4BBB), Greensomes, Foursomes, Texas Scramble, Reverse Waltz. `events.format_id` FK with best-effort backfill from text `format`. `events.tee_time_interval_minutes` (5–30). `event_teams` (team_number, member_ids UUID[], tee_time, status draft/published, published_at via trigger).
- **RLS** — globals readable by any authenticated user; society formats readable same-society and writable by `admin`/`captain`/`vice_captain`. `event_teams` readable when published OR by event-running roles, writable by event-running roles.
- **Client** — Format dropdown in event create with "+ Custom format..." path that inserts into `event_formats` for the society on submit. Team generator (`openTeamGenerator`): snake-draft by handicap (alternating direction per round → balanced totals without optimization), team-size + start-time + interval controls, per-team cards with up/down nudge that reshuffles into adjacent team, live HCP totals. Save draft / Save + Publish / Publish / Unpublish / Clear lineup. Members see published teams in event detail.
- **Departed from spec:** drag-drop deferred — up/down nudge buttons cover the same need with no library dependency.

Also shipped same day:
- Migration 021: `society_directory()` now accepts `('active','trial','trialing','free','past_due')` so newly-registered societies surface in the join flow.
- Admin "Invite members" card surfaces `societies.subdomain` (the join code) with copy + native-share buttons.
- Cutoff timezone fix (datetime-local → UTC ISO before insert), cutoff auto-fill fallback chain (Friday-before → evening-before → blank), logout-from-chooser fix, OTP login fallback (verify 6-digit code in-app alongside the magic link), Next-Event 5h tee-time grace, demo-mode honest error copy + Supabase CDN fallback chain.

---

## Phase D — Results + push to members ✅ shipped (2026-05-07)

Builds directly on Phase C — uses `event_teams` for team formats, `event_formats.scoring_method` to pick the right entry form.

- **Migration 022** — `results.team_id` FK to `event_teams` (nullable; per-member rows for individual formats). `events.results_published_at` timestamp gates member visibility. RLS split into `results_published_read` (same-society, published only) and `results_draft_read` (event-running roles see unpublished).
- **Format-aware results entry** — `loadResultsForm()` switches on `scoring_method`:
  - `stableford` / `medal` / `matchplay` — per-player rows with score + points (label adapts: "Points" / "Net" / "W/L"), auto-calculated position.
  - `scramble` / `better_ball` — per-team rows; score applies to all members of that team via `team_id`. Shared positions for same-score teams.
  - `custom` — free-form textarea for non-standard formats.
- **Publish gate** — "Publish results to members" / "Unpublish" buttons on the results entry form. Members only see results in event detail when `results_published_at` is set; captains see "(Draft)" label.
- **Auto-notification** — publishing inserts a broadcast `messages` row (`priority='important'`) with winner name, points, event title, and course.
- **Event detail** — results display handles individual, team (grouped by `team_id`), and custom (free text) results. Shows "Results not yet published" to members when unpublished.
- **Home tab** — "Latest Result" card with trophy icon, winner name, points, event title. Taps through to event detail.

---

## Phase F — Sponsor (~half day, parallel-able)

Light bolt-on; can be developed alongside D or E.

**Schema:**
- `society_sponsors` (society_id, name, logo_url, link_url, blurb, active_from, active_until).
- `event_sponsors` (event_id, sponsor_id, role) — `'primary'` / `'supporting'` / `'prize_donor'`.

**UI:**
- Sponsor admin page (treasurer + admin only): add/edit logos, links, blurbs.
- Event card surfaces sponsor logo: "Sponsored by Bonalba Pro Shop".
- "Our Sponsors" member-side page with logos, links, dates active.

The `sponsor` role from Phase A is the content-only soft role this delivers against — it grants visibility on the sponsor admin page, no other writes.

---

## Phase E — Course intelligence (automation, ~3–5 days, deferred)

The hardest piece because it depends on external data. Defer until A–D + F are working.

**Schema:**
- `course_availability_snapshots` (external_course_id, date, available_tee_times jsonb, last_checked_at).

**Approach:**
- Curate a small set of partner course websites + golf-travel sites manually — Costa Blanca regional set first (~15 courses for JPGS).
- Nightly Netlify scheduled function hits each partner's public availability page, parses, persists.
- Captain interface: "Find a slot" → query the snapshots → return courses with capacity for X players on date Y at price ≤ €Z.
- Where partner sites block scraping, fall back to "phone the course" with the listing's phone number.

Estimate is highly variable depending on how cooperative the partner sites are. v1 covers the JPGS-relevant 15 courses.

---

## Out of scope (not in any phase)

- Native mobile apps (single-host responsive web is sufficient for v1).
- Per-society custom domains (the multi-tenant model has the hooks but routing is dormant — see `societies.subdomain` is the join code, not a real DNS subdomain).
- Per-society branded email (single Resend SMTP for now; templates are global).
- Stripe billing UI — already shipped (Phase 5 in `CHANGELOG.md`); not part of this A–F sequence.

---

*Last updated: 2026-05-07.*
