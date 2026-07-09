# c64-layer — the server-side overlay

Applied onto a pristine upstream MeshChat checkout by
`deploy/meshchat_update.sh` (`apply_theme`). Nothing here modifies upstream
source; the theme CSS is APPENDED after upstream's style.css and two
anchor-checked injections touch index.html. Full design rationale:
../docs/c64-layer-briefing.md

Contents:
- `c64-theme.css`  — VIC-II palette, embedded pixel font (public-domain
  font8x8), CRT bezel + scanlines, pixel icon set, 480x640 polish
- `polyfills.js`   — built artifact; `polyfills-src.js` is the readable
  source with the build command in its header — Gecko 91 shims: crypto.randomUUID, real-gzip
  Compression/DecompressionStream (fflate bundled; hand-rolled writable side
  because Gecko 91 lacks WritableStream), MediaRecorder mimeType guard
- `vendor/`        — self-hosted CDN replacements (see vendor/README.md)

Also deployed from the production theme directory but not committed here
(instance-specific): `manifest.json`, `icon-192.png`, `icon-512.png`,
`doc-index.html`. PWA note: icons must be exactly >=192px and the manifest
paths case-correct — a 189px icon and an `icon.png` vs `Icon.png` mismatch
silently kill installability.
