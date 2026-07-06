# Spyglass Landing Page — Design

Date: 2026-07-04

## Purpose

Turn the plain OAuth-compliance page at `magicelklabs.com/spyglass/` into a
real sales landing page with a Gumroad Buy button, while preserving every
element Google's OAuth verification requires (the page is under active review).

## Constraints

- **Superset rule.** Every current OAuth-required element must survive:
  app name, functionality description, data-use / "why Google access"
  section, privacy-policy link, contact email. The new page adds to these,
  never removes them. This keeps the reviewed URL compliant mid-verification.
- Single static HTML file. Tailwind CDN + custom design tokens. No build step.
- Auto light/dark.

## Look and feel

Spyglass brand palette (the current page's colors), Viaduct LP's structure and
polish:

- Colors: teal gradient `#0B3D3A` → `#072826`, brass `#B8945F`, ink `#1A1C26`,
  system canvas/surface ladder for light+dark.
- System font stack (SF Pro). No custom typeface.
- Viaduct-style depth: surface ladder, subtle glass cards, brass/teal crown
  glow on hero, scroll-reveal on sections. No heavy drop shadows.

## Sections (top to bottom)

1. **Hero** — app icon, headline "Press Space. See the document.", tagline
   subline, primary CTA **Buy · $9** (Gumroad overlay), secondary **Download
   free** (GitHub releases). Crown glow.
2. **The problem** — before/after: raw JSON blob vs rendered preview. Names the
   six stub types.
3. **What it does** — Quick Look integration, the two tiers introduced.
4. **Free vs Paid** — comparison table. Free = info card, all six types,
   offline, no sign-in. Paid $9 one-time = rendered previews for Docs, Sheets,
   Slides, Drawings, delivered via license key.
5. **Why Spyglass needs Google access** *(OAuth-required)* — read-only scope,
   used only to render previews, stays on device, no server, email only for
   account label, revocable on sign-out.
6. **How the license works** — buy on Gumroad, receive key, paste in app,
   unlock rendered previews.
7. **Specs** — macOS 14+, $9 one-time, no subscription.
8. **FAQ** — includes a data/privacy question linking the privacy policy.
9. **Closing CTA + footer** *(OAuth-required)* — privacy-policy link, contact
   email, source link.

## Buy button

Gumroad overlay embed: load `https://gumroad.com/js/gumroad.js`, link
`https://magicelk235.gumroad.com/l/spyglass?wanted=true` with
`class="gumroad-button"`. Opens checkout in an overlay without leaving the page.

Price note: Gumroad base currency must be set to USD $9 (currently shows local
ILS ₪26.99 to the owner). That is a Gumroad dashboard setting, not a page change.

## Files

- Rebuild `docs/spyglass/index.html` in the `magicelk235.github.io` repo (served
  at `magicelklabs.com/spyglass/`).
- `privacy.html` unchanged. `assets/` icons reused.

## Out of scope

Analytics, A/B variants, video embed, multi-language. Add if needed later.
