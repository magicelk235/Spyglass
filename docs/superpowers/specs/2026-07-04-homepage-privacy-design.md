# Spyglass Homepage + Privacy Policy — Design

Date: 2026-07-04

## Purpose

Provide the app homepage and privacy policy required for Google OAuth
verification of the Spyglass macOS app (Drive `drive.readonly` scope). The
homepage must identify the app, describe its function, explain why user data is
requested, be public (no login), and link to a matching privacy policy.

## Hosting

GitHub Pages, source = `main` branch `/docs` folder. Served at
`https://magicelk235.github.io/Spyglass/`.

Known risk: `*.github.io` is a shared third-party subdomain. Google's "verified
domain you own" rule may reject it. Accepted for now to get a live public link;
pages are built domain-agnostic (relative links) so a custom domain later needs
only a `CNAME` file, no HTML edits.

## Deliverables

Two self-contained static HTML files, no framework, no build step, no JS:

1. `docs/index.html` — homepage
   - Hero: inline SVG spyglass mark in a gold circle, app name, one-line pitch.
   - "What it does": Tier 0 offline card + Tier 1 rendered PDF preview.
   - "Why Spyglass needs Google access": plain-English data-use section — the
     OAuth reviewer's target. Read-only Drive, used only to export docs as PDF
     for local preview, cached locally, never sent to any server, sign-out
     revokes the grant.
   - Links: GitHub repo, download (DMG/releases), privacy policy, contact email.

2. `docs/privacy.html` — privacy policy
   - Data accessed: Drive files (read-only, `drive.readonly`), account email.
   - How used: PDF export fetched, rendered, cached in the local App Group
     container. No servers, no analytics, no third parties, no selling/sharing.
   - Retention/deletion: cache is local; sign-out clears tokens and revokes the
     grant server-side at Google.
   - Contact: yehonatan.2350@gmail.com.
   - "Last updated" date.

3. `docs/.nojekyll` — serve raw HTML untouched.

## Styling

Match the existing OAuth loopback success page (`App/GoogleAuth.swift`): system
font stack, accent `#B8945F`, `color-scheme: light dark`, single inline
`<style>` per page, `clamp()` responsive type. Relative link between the two
pages.

## Out of scope (YAGNI)

Build tooling, analytics, cookie banner (no cookies set), JS, multi-page nav,
blog. Add if a real need appears.
