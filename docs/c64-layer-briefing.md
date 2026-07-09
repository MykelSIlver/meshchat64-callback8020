# Briefing: C64 retro-styling layer for MeshChat
## Knowledge transfer for the "Commodore Callback 8020 MeshChat64 App" repository

> **Purpose of this document.** This briefing captures everything developed in a
> long working session about giving a self-hosted MeshChat instance a Commodore 64
> look-and-feel, making it survive automated upstream updates, and making it run
> on the Gecko 91 WebView of the Commodore Callback 8020 (SailfishOS). It is meant
> to be merged with the SailfishOS app knowledge from a separate session into one
> coherent GitHub repository.

---

## 0. Attribution — read this first

**All MeshChat application code is authored by saint-cc.**
Upstream repository: **https://github.com/saint-cc/meshchat**

This includes, without exception: `server.py`, `script.js` (the entire chat/crypto/
relay client), `statemachine.js`, `sw.js`, `index.html`, the original `style.css`,
and the MeshChat protocol design (encrypted relay chat, the
`encKey.signKey.base64(wssRelayURL)` shareable-key format, cross-relay delivery).

The work described in this briefing is strictly a **presentation and compatibility
layer on top of saint-cc's code**. It deliberately never forks or modifies his
source. Everything is applied at deploy time, on a mirror of his `main` branch.
The new repository MUST state this attribution prominently (README top section
and/or NOTICE file), and should link to the upstream repo.

What *is* original work from this session (the deployable layer):
- `c64-theme.css` — the standalone C64 overlay stylesheet (palette, pixel font,
  CRT effects, pixel icon set, small-screen polish)
- `polyfills.js` — Gecko 91 compatibility shims (see §6; specified in a companion
  session, integrated & deployed here)
- `meshchat_update.sh` (v3.x) — the update/deploy pipeline that overlays the
  theme onto pristine upstream on every build
- The three self-hosted vendor files in `/c64/vendor/` are third-party open
  source (see §7 for exact provenance) — not ours and not saint-cc's.

---

## 1. Architecture in one paragraph

The production instance (https://meshchat.example.com/, Raspberry Pi, nginx →
Flask in a hardened Docker container) mirrors saint-cc's `main` exactly via
`git reset --hard origin/main` — **no local commits, so merge conflicts are
impossible**. After every reset, an overlay step (`apply_theme` in
`meshchat_update.sh`) re-applies the C64 layer: it **appends** `c64-theme.css`
after upstream's untouched `style.css`, copies our own assets (PWA icons,
manifest, docs page), copies `polyfills.js` + three vendor libraries into
`static/c64/`, and performs two **idempotent, anchor-checked text injections**
into upstream's `index.html` (a polyfill `<script>` tag, and three CDN→local
script swaps). The container is then rebuilt; a smoke test gates the rollout with
automatic rollback to the previous image and ntfy push notifications on any
failure. Result: upstream updates flow through untouched, the retro layer is
re-applied fresh every build, and the app runs fully offline/LAN-only.

Key principle learned the hard way: **never keep a frozen copy of upstream files**.
An earlier iteration shipped a full copy of `style.css` with the theme baked in;
when saint-cc added `white-space: pre-wrap` to `.message` upstream, the frozen
copy silently overwrote his fix on every deploy. The overlay-append architecture
replaced it and is the single most important design decision in this project.

---

## 2. The C64 theme (`c64-theme.css`) — contents & rationale

A single standalone stylesheet, appended **after** upstream `style.css` at build
time. Because CSS cascade favors later rules at equal specificity, the layer
overrides only what it names and inherits everything else from upstream.

### 2.1 VIC-II color palette (overrides upstream `:root`)
Upstream uses the same CSS custom properties with dark values; redefining them
re-skins every component automatically:

```css
:root {
  --bg:       #40318d;   /* C64 screen blue        */
  --surface:  #4838a4;   /* panels                 */
  --surface2: #5a4cc0;   /* hover / active         */
  --border:   #7d70d4;   /* light-blue bezel/lines */
  --muted:    #7a6fc9;
  --dim:      #9b91ea;
  --text:     #c8c1ff;   /* light-blue text        */
  --accent:   #74e0d6;   /* C64 cyan               */
  --online:   #6fce6f;   /* C64 green              */
  --mine:     #2f2480;   /* own message bubble     */
  --theirs:   #4a3bb0;   /* their message bubble   */
  --danger:   #d97c80;   /* C64 light red          */
}
```

### 2.2 Self-hosted pixel font
- Built from the public-domain **dhepper/font8x8** bitmap font
  (https://github.com/dhepper/font8x8), compiled to a ~1.9 kB WOFF2 with
  fontTools, embedded as a base64 `@font-face` named **"PixelChat C64"**.
- 96 glyphs / full printable ASCII. Fully offline-safe (no font CDN).
- Applied via `body { font-family: 'PixelChat C64', 'Courier New', monospace; }`
  plus explicit overrides for upstream elements that hardcode a font stack.
- **Gotcha that drove a whole feature:** the font has *only* ASCII. Any emoji or
  non-ASCII glyph in the UI renders as an empty box ("tofu"). See §3.

### 2.3 CRT presentation layer
- **TV bezel:** `body::before`, `position: fixed; inset: 0`, 13px solid border in
  `--border` with an inset shadow (`#2a2080` inner line + soft vignette),
  `pointer-events: none`, `z-index: 40`.
- **Scanlines + flicker:** `body::after`, repeating-linear-gradient (1px dark line
  every 3px), 5s stepped opacity animation (`crtFlicker`).
- Square corners everywhere (`border-radius: 0 !important` on status dots,
  badges, images) — the C64 has no rounded rects.
- Uppercase labels on headings/buttons (PETSCII was upper-case), cyan
  `text-shadow` glow on titles, and a **blinking block cursor** (`content:"\2588"`,
  1s steps animation) after the login title and empty-chat text.
- `caret-color` and `::selection` in C64 cyan; `image-rendering: pixelated` on
  QR codes so they stay crisp.

### 2.4 Pixel icon set (the "tofu" fixes)
Upstream uses emoji as button glyphs. The pixel font can't render them, so each
was replaced by a hand-drawn 16×16 pixel-art SVG (VIC-II colors,
`shape-rendering='crispEdges'`), embedded as URL-encoded `data:` URIs directly in
the CSS — **zero JS/HTML changes, zero extra requests**.

Icons: floppy disk (backup/export), microphone (record), camera (send image),
three menu dots (contact menu), reply arrow (react), monitor+phone (known
devices button, replacing a plain `+`).

Two replacement techniques, chosen per button — this distinction matters:

1. **`::before` pseudo-element icon** — hide the emoji with `font-size: 0` on the
   button, draw the icon as a sized `::before` with the SVG as background.
   Works when the button has room for a pseudo-element.
2. **Background-image on the button itself** — for buttons where technique 1
   fails. Two real cases:
   - `#exportBtn` also carries upstream's `.chat-action-btn` class whose
     `padding: 0 14px` collapses the content box of the 28px-wide button to
     0 → the `::before` gets clipped away. A background paints the whole button
     regardless of padding.
   - `#audioBtn` / `#imageBtn` are stacked in a narrow flex column; on small
     phone screens the `::before` was squeezed to invisibility. Background +
     `min-height: 26px` + `!important` on background properties (upstream's
     `:hover` sets the `background` shorthand, which would otherwise wipe the
     icon) made them robust on every screen size.

Selector notes: the backup-stored indicator is
`.contactName span[title="backup stored"]`; the devices button is a **class**
(`.deviceInfoBtn`), not an id. Icons that sit inline in message text (e.g.
"🎤 audio message" labels) can NOT be fixed with pure CSS — a glyph in the middle
of a text node isn't targetable. Those were consciously left as-is (candidates
for an upstream `<span class>` wrapper suggestion to saint-cc).

### 2.5 Small-screen polish (Callback 8020 is 480×640)
- `@media (max-height: 720px)`: `#loginScreen` becomes `align-items: flex-start;
  overflow-y: auto;` so a login box taller than the viewport scrolls instead of
  clipping (upstream `body` is `overflow: hidden`). The scrollbar is hidden
  (`scrollbar-width: none` + `::-webkit-scrollbar { width:0 }`) because it
  painted over the right bezel.
- `@media (max-width: 600px)`: bezel thins from 13px to 7px (proportionality on
  a 480px screen), lighter vignette, input-row inset reduced accordingly.
- Input row clearance: `#chatInputContainer { margin-right/bottom: 15px }`
  (9px on small screens) keeps the send/media buttons out from under the fixed
  bezel. **Must be margin, not padding** — padding steals interior height and
  crushed the stacked media buttons on phones.
- `#chatInput { min-width: 0 }` — a textarea's intrinsic min-width otherwise
  makes the flex row overflow, pushing the media buttons under the right bezel.

---

## 3. Update pipeline (`meshchat_update.sh` v3.4) — how the layer survives

Cron: `0 */2 * * * $HOME/bin/meshchat_update.sh >> .../update.log 2>&1`.
Manual: `--force` (also used to apply local theme changes immediately).

Per run:
1. `git fetch`; if `HEAD == origin/main` **and** no theme file changed **and**
   no `--force` → exit (theme changes are detected via an `-nt` comparison
   against a `state/theme_built` stamp touched after each green deploy).
2. **Review gate:** diff `HEAD..origin/main`; anything outside
   `static/*.{html,js,css,png,jpg,svg,ico,json,webmanifest,woff2}` → HOLD +
   ntfy notification, wait for human review (`--force` after review).
   The gate diffs against HEAD (what actually runs), not fetch-before/after —
   an earlier design allowed a held change to be smuggled in by a later
   "clean" commit.
3. `docker tag meshchat:local meshchat:prev` (rollback anchor),
   `git reset --hard origin/main` (pristine upstream),
   then **apply_theme** (see §4), `docker compose build` + `up -d`.
4. Smoke test; on failure: automatic rollback to `prev`, git tree restored to
   match the running image, failed commit marked (no silent retry), ntfy at
   escalating priorities. On success: stamp theme, clear markers, notify.

---

## 4. `apply_theme` — the overlay step in detail

```
mkdir -p static/doc static/c64
cat  $THEME/c64-theme.css            >> static/style.css        # APPEND, never overwrite
cp   $THEME/doc-index.html            static/doc/index.html     # our docs page
cp   $THEME/icon-192.png icon-512.png static/                   # our PWA icons
cp   $THEME/manifest.json             static/                   # our manifest
cp   $THEME/polyfills.js              static/c64/               # §6
cp   $THEME/vendor/*.js               static/c64/               # §7
# + two guarded injections into static/index.html (§5)
```

`$THEME` = the theme directory (e.g. `$HOME/c64-layer/`) — the single source of truth. Edits go
there; the pipeline detects the change and rebuilds. Idempotency is guaranteed
because `git reset --hard` restores pristine files *before* every apply.

Deliberate exception, agreed with saint-cc: his `index.html` is never replaced
by a themed copy (early attempts caused rebase conflicts when he edited it).
Only the two surgical injections below touch it.

PWA note: our `manifest.json` + icons fixed installability (upstream referenced
`./icon.png` while the file was `Icon.png` — case-sensitive server → 404 → no
install prompt; icon was also 189px < required 192).

---

## 5. Guarded injections into upstream `index.html`

Both injections are **anchor-checked and idempotent**; if the anchor pattern is
missing (upstream restructured), the step is skipped and a high-priority ntfy
warning fires ("polyfill injection failed" / "CDN swap incomplete") instead of
blind sed-ing. This "never inject blindly, always alert" pattern is the reason
the pipeline can be trusted unattended.

1. **Polyfills:** insert `<script src="/c64/polyfills.js"></script>` immediately
   **before** the `src="script.js"` tag (polyfills must patch globals before the
   app reads them). Guard: skip if already present; warn if anchor missing.
2. **CDN → local swaps** (three):
   - `https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/...` → `/c64/qrcode.min.js`
   - `https://unpkg.com/html5-qrcode@2.3.8/...` → `/c64/html5-qrcode.min.js`
   - The whole inline module script
     `<script type="module">import { ed25519 } from 'https://esm.sh/@noble/curves@1.4.0/ed25519'; window.ed25519 = ed25519;</script>`
     is replaced by one plain `<script src="/c64/ed25519.bundle.min.js"></script>`
     (the bundle sets `window.ed25519` itself).
   - Post-check: `grep -cE 'cdnjs|unpkg|esm.sh'` must be 0, else ntfy warning.

Escaping war story: a generated version of the script shipped `script\\.js`
(double backslash) in the grep/sed patterns; the anchor never matched and the
injection silently skipped. Symptom: `grep -c "/c64/polyfills.js"` on the served
page returned 0. When porting these patterns, verify the *file on disk* contains
single backslashes, and test the grep+sed against a real upstream `index.html`.

---

## 6. Gecko 91 compatibility (`polyfills.js`, ~15.8 kB, self-contained IIFE)

The Callback 8020's SailfishOS WebView runs **Gecko 91** (Firefox ESR 91, 2021).
Audit of upstream `script.js` found exactly two hard breaks and one silent trap:

- **`crypto.randomUUID`** (Firefox 95+; used for messages/images/calls) —
  polyfilled as RFC 4122 v4 over `crypto.getRandomValues`.
- **`CompressionStream`/`DecompressionStream`** (Firefox 113+) — the critical
  one: compression lives **inside `encryptObject`/`decryptObject`**, i.e. inside
  the encryption protocol, so it had to be real gzip (fflate is bundled into the
  polyfill; no CDN). Extra trap: Gecko 91 has `ReadableStream` but **no
  `WritableStream`/`TransformStream`**, so off-the-shelf npm polyfills would
  themselves crash — the writable side is implemented by hand, serving exactly
  upstream's `writer.write → close → new Response(readable)` usage pattern.
- **`MediaRecorder` with `mimeType: "audio/webm"`** — Gecko 91 records
  ogg/Opus and throws `NotSupportedError` on an unsupported mimeType. The
  constructor is wrapped to silently drop an unsupported mimeType. Caveat: the
  blob keeps its "audio/webm" label while containing ogg — receivers generally
  content-sniff and play it, but test one voice message Callback → desktop.

Verified fine on Gecko 91 (no action needed): `crypto.subtle` (AES-GCM, HMAC),
`getRandomValues`, WebSocket, localStorage, createImageBitmap+canvas,
`navigator.clipboard.writeText` (already has a .catch), optional chaining,
async/await, BigInt (needed by noble-curves), the pass-through service worker.

Not polyfillable (device/stack-dependent, test on hardware): `getUserMedia`
(microphone) and `RTCPeerConnection` (audio calls). Upstream already falls back
to a synthetic silent track on mic refusal, but a *missing* RTCPeerConnection
would still throw — recommended: hide the call button in the C64 layer when
`typeof RTCPeerConnection === "undefined"`.

SailfishOS packaging notes (belongs with the app repo): Sailjail permissions —
`Permissions=Internet;WebView;Microphone` (Microphone required for voice/calls;
`Pictures`/`UserDirs` if the image file picker misbehaves). The Sailfish WebView
historically mishandles `width=device-width` (fixed devicePixelRatio); the known
workaround is injecting a viewport meta with
`width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no` via
`runJavaScript` after load. A ~1–2px layout-viewport overshoot (right bezel edge
just off-screen) was observed and accepted as cosmetic.

---

## 7. Self-hosted vendor libraries (`/c64/vendor/`) — provenance

Goal: the app must start with **zero external requests** (LAN-only / flaky
internet on the phone). The ed25519 module is existential — without it there is
no crypto identity and the app cannot log in.

| File | Origin | Notes |
|---|---|---|
| `qrcode.min.js` | davidshimjs/qrcodejs (GitHub, same source cdnjs serves) | ES5-era code, trivially Gecko-91-safe. MIT. |
| `html5-qrcode.min.js` | Official npm tarball `html5-qrcode@2.3.8` | Byte-identical to what unpkg served. Apache-2.0. |
| `ed25519.bundle.min.js` | Built from official npm `@noble/curves@1.4.0` with esbuild, `--bundle --minify --format=iife --target=firefox91` | Sets `window.ed25519`, exactly like upstream's inline module did. MIT. |

The firefox91 esbuild target guarantees no post-2021 syntax — arguably *safer*
than the original esm.sh delivery, which serves modern ES output with no regard
for old engines. The bundle was functionally verified (keygen 32-byte pubkey,
64-byte signature, verify true / tampered-verify false).

SHA-256 of the built artifacts (for integrity checks when re-hosting):
```
212e21685ac1bb52459d6b817b6da4cbd217ad659232ee1583f5625d9455edf2  ed25519.bundle.min.js
660b12437b1d747e3e68b8be0685c08cb728140110ad213f167b14b66f8b1d8e  html5-qrcode.min.js
c541ef06327885a8415bca8df6071e14189b4855336def4f36db54bde8484f36  qrcode.min.js
```
Versions are intentionally pinned (they were pinned upstream too). If saint-cc
ever bumps `@noble/curves`, the swap regex stops matching and the pipeline's
ntfy warning fires — rebuild the bundle against the new version then.

**Repo licensing consequence:** the new repository must carry the licenses of
these three libraries alongside its own, and must respect saint-cc's license
for anything of his that is referenced or vendored.

---

## 8. Debugging lessons worth keeping (they cost real time)

- **Docker bakes `static/` into the image.** Copying a file into the host's
  `static/` changes nothing until `docker compose build` runs. Diagnostic that
  settles it in seconds: `curl -s http://127.0.0.1:8000/style.css | grep -c <marker>`
  (container truth) vs. grepping the host file. `docker inspect <c> --format
  '{{json .Mounts}}'` shows whether a bind mount exists (here: only a data
  volume, so rebuild is the only path).
- **Three cache layers, three different fixes.** Server-side truth via curl on
  127.0.0.1; browser truth via the public URL with a cache-buster (`?x=1`);
  a stale device needs site-data clearing once. Flask now sends
  `Cache-Control: no-cache, no-store, must-revalidate`, so this is a one-time
  cleanup per device. An installed PWA has its own storage (clear app data or
  reinstall). "Incognito" only bypasses the *local* cache — reusing an open
  incognito window still shows its session cache.
- **NAT hairpinning** (seen on some consumer ISPs): curling your own public domain from inside
  the LAN hangs. Test from outside (e.g. phone hotspot) or map the domain to the
  LAN IP in /etc/hosts.
- **Verify every layer with one grep.** Every feature in this project ships with
  a one-line curl+grep acceptance check. Keep that habit in the app repo.

---

## 9. Suggested repository layout (for the merge)

```
meshchat64-callback8020/
├── README.md            # top: attribution to saint-cc + upstream link (§0)
├── app/                 # SailfishOS app (QML, .desktop, packaging) ← other session
├── c64-layer/
│   ├── c64-theme.css
│   ├── polyfills.js
│   ├── manifest.json, icon-192.png, icon-512.png, doc-index.html
│   └── vendor/ (qrcode.min.js, html5-qrcode.min.js, ed25519.bundle.min.js + licenses)
├── deploy/
│   └── meshchat_update.sh   # v3.4 pipeline (gate, overlay, injections, rollback)
└── docs/
    └── this briefing
```

The server-side layer and the SailfishOS app are intentionally decoupled: the
app is a thin WebView onto the themed instance, and everything Gecko-specific is
delivered server-side so the app itself stays trivial.

*End of briefing.*
