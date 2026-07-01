# Tier 1 — Google-authenticated PDF previews

**Date:** 2026-07-01
**Status:** Approved, implementation pending
**Depends on:** Tier 0 (shipped, commit `a33f845`)

## Goal

When the user is signed into Google, pressing Space on an exportable Google
Workspace file (`doc` / `sheet` / `slides` / `drawing`) shows the **real
rendered document** — the first pages of a PDF exported from Drive — instead of
the offline card.

Everything degrades gracefully: Forms, Sites, un-authenticated state, network
failure, timeout → the existing Tier 0 `StubCardView`. The preview is never
blank and never hangs.

## Non-goals

- No custom multi-page paging UI — Quick Look's native PDF view scrolls.
- No token auto-refresh timer — refresh lazily on HTTP 401 only.
- No cache eviction policy yet (`// ponytail:` note; add LRU if the folder grows).
- No `client_secret` at runtime — PKCE desktop flow doesn't need it.
- No thumbnailLink path — we go straight to PDF export (higher fidelity, chosen).

## Architecture

Two sandboxed processes:

- **App** — does the interactive OAuth login, writes tokens, shows sign-in UI.
- **Extension** — on Space-press, reads the token and fetches/renders the PDF
  itself. It already has `network.client`, so no background daemon, no
  "open the app first", no app↔extension round-trip. Works even if the app
  isn't running.

### Data flow

```
Space on .gdoc
  → extension: parse stub → TokenStore.load()
      ├─ no token OR type not exportable → StubCardView (Tier 0)
      └─ token present:
           PreviewCache hit (fresh)? → render cached PDF
           miss → DriveClient.exportPDF (≤ ~2s timeout)
                    → cache + render PDF
                    └─ any failure / timeout → StubCardView (Tier 0)
```

## Components

### 1. `GoogleAuth` (app target only)

Loopback OAuth 2.0 with PKCE (desktop client type; redirect `http://localhost`).

- Generate PKCE verifier + `S256` challenge.
- Start a one-shot local `NWListener` / minimal HTTP server on `127.0.0.1:<ephemeral port>`.
- Open the system browser to Google's auth URL (scope
  `https://www.googleapis.com/auth/drive.readonly` + `userinfo.email`).
- Catch the redirect `GET /?code=…`, respond with a "you can close this tab" page.
- Exchange code → access token + refresh token at `https://oauth2.googleapis.com/token`.
- Fetch the signed-in email (`userinfo`) for display.
- Hand tokens to `TokenStore.save`.

Lives in the app; the extension never runs the interactive dance.

### 2. `TokenStore` (DrivePeakKit, shared)

Reads/writes tokens to a **shared Keychain access group**
(`$(DEVELOPMENT_TEAM).com.drivepeak.shared`). Refresh token is a long-lived
credential → Keychain (encrypted at rest, OS-managed), not a plaintext file.

```
struct Tokens { accessToken; refreshToken; expiry: Date; email: String? }
func save(_:) throws
func load() -> Tokens?
func clear() throws
```

Both app (writes) and extension (reads) link DrivePeakKit and thus this type.

### 3. `DriveClient` (DrivePeakKit, shared)

Given a valid access token + docID + type:

- `exportPDF(docID:type:) async throws -> Data`
  → `GET https://www.googleapis.com/drive/v3/files/{id}/export?mimeType=application/pdf`
- `metadata(docID:) async throws -> (name, modifiedTime)`
  → `GET …/files/{id}?fields=name,modifiedTime` (for cache staleness + title).
- **Refresh-on-401:** if the access token is expired/rejected, use the refresh
  token to mint a new access token (persist via `TokenStore`), retry the call
  once. If refresh also fails → throw → caller falls back to Tier 0.

Injectable `URLSession` so unit tests can stub via `URLProtocol`.

### 4. `PreviewCache` (DrivePeakKit, shared)

Caches exported PDFs in the shared **App Group** container
(`group.com.drivepeak.shared`) keyed by `docID`, invalidated by `modifiedTime`.

```
<group-container>/previews/<docID>.pdf
<group-container>/previews/<docID>.meta   (stored modifiedTime)
```

- `cachedPDF(docID:, modifiedTime:) -> Data?`  (nil if missing or stale)
- `store(docID:, modifiedTime:, pdf: Data)`

Container (not Keychain) is correct here — the rendered PDF is derived output,
not a secret. Only tokens go in Keychain.

### 5. Extension changes (`PreviewViewController`)

`preparePreviewOfFile(at:)` becomes:

1. Parse stub (unchanged).
2. If `!stub.type.isExportable` OR `TokenStore.load() == nil` → `StubCardView`.
3. Else: `metadata` → `PreviewCache.cachedPDF` hit → render PDF (native
   `PDFView`/`NSHostingView`). Miss → `DriveClient.exportPDF` under a ~2s
   timeout → cache + render. Any throw/timeout → `StubCardView`.

A brief spinner covers the first (network) open; re-opens are instant from cache.

### 6. App UI (`ContentView`)

Add a sign-in row:

- Signed out → **Sign in with Google** button → runs `GoogleAuth`.
- Signed in → **Signed in as `<email>` · Sign out** (`TokenStore.clear`).
- Keep the existing live Tier 0 sample card.

## Config / secrets

- `GoogleOAuth.plist` (gitignored) holds `client_id` only. Loaded at runtime.
  README documents creating it from the downloaded
  `client_secret_*.json` (also gitignored; already ignored via `client_secret_*.json`).
- `client_secret` is **not** embedded — PKCE desktop flow doesn't require it.

## Entitlements & signing (needs the paid Apple Developer account)

- Both targets: `keychain-access-groups: [$(DEVELOPMENT_TEAM).com.drivepeak.shared]`.
- Both targets: App Group `group.com.drivepeak.shared`.
- Signing moves from ad-hoc `-` to the Developer identity once the Team ID exists.

**Build-today provision (Apple account is ~1–3 days out):** `DEVELOPMENT_TEAM`
comes from `Secrets.xcconfig` (gitignored), empty for now. Code compiles and unit
tests run under ad-hoc signing today. When the account lands, drop the Team ID
into `Secrets.xcconfig`, flip signing — no code change.

## Testing

**Unit (no network, no creds — runnable today):**

- `TokenStore` round-trip (in-memory backend under `#if TEST`, or a Keychain
  mock) — save → load → clear.
- `DriveClient` — export/metadata URL construction; refresh-retry on stubbed 401
  via `URLProtocol`; gives up after one refresh.
- `PreviewCache` — path derivation; staleness by `modifiedTime` (stale → nil).
- `GoogleAuth` — PKCE verifier/`S256` challenge correctness; auth-URL assembly.

**Manual (needs the account + real creds — deferred to when Apple approves):**

- Sign in → Space a real `.gdoc` → rendered PDF appears; re-open is instant;
  a Form still shows the Tier 0 card.

## Deliberate simplifications (ponytail)

- Native PDF scroll, no paging UI.
- Lazy 401 refresh, no timer.
- No cache eviction yet — note + upgrade path in code.
- No `client_secret` at runtime.
- Cache staleness via one cheap metadata field on a call we already make.

## Risks

- **Keychain-from-extension:** old lore says finicky; on macOS 14+ with a proper
  access group it's reliable. Mitigation: the whole path falls back to Tier 0 on
  any `TokenStore.load()` failure, so a Keychain miss is never fatal.
- **Export latency:** large docs may exceed the 2s timeout → Tier 0 shown, PDF
  lands in cache for the next open. Acceptable.
- **Cannot end-to-end test until the Apple account lands.** Unit tests cover all
  pure logic; only the signed, entitlement-gated flow waits.
