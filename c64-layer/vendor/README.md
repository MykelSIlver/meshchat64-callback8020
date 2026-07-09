# Self-hosted vendor libraries

Goal: the app must start with **zero external requests** (LAN-only usage, and
the phone's internet may be filtered). The ed25519 module is existential —
without it there is no crypto identity and the app cannot log in.

These three files are NOT committed here (build/fetch them yourself, verify
the hashes) — or commit them if you prefer a batteries-included repo:

| File | Origin | License |
|---|---|---|
| `qrcode.min.js` | davidshimjs/qrcodejs (GitHub; same source cdnjs serves) | MIT |
| `html5-qrcode.min.js` | official npm tarball `html5-qrcode@2.3.8` (byte-identical to unpkg) | Apache-2.0 |
| `ed25519.bundle.min.js` | built from npm `@noble/curves@1.4.0` | MIT |

Build the ed25519 bundle (sets `window.ed25519`, exactly like upstream's
inline esm.sh module did):

```
npm install @noble/curves@1.4.0 esbuild
cat > ed25519-entry.js << 'JS'
import { ed25519 } from '@noble/curves/ed25519';
window.ed25519 = ed25519;
JS
npx esbuild ed25519-entry.js --bundle --minify --format=iife \
    --target=firefox91 --outfile=ed25519.bundle.min.js
```

The `firefox91` target guarantees no post-2021 syntax — safer for the Gecko 91
WebView than esm.sh's modern output. Functional check: keygen gives a 32-byte
public key, sign gives a 64-byte signature, verify returns true (and false on
a tampered message).

SHA-256 of the artifacts in production (for integrity when re-hosting):

```
212e21685ac1bb52459d6b817b6da4cbd217ad659232ee1583f5625d9455edf2  ed25519.bundle.min.js
660b12437b1d747e3e68b8be0685c08cb728140110ad213f167b14b66f8b1d8e  html5-qrcode.min.js
c541ef06327885a8415bca8df6071e14189b4855336def4f36db54bde8484f36  qrcode.min.js
```

Versions are intentionally pinned (they are pinned upstream too). If upstream
ever bumps `@noble/curves`, the CDN-swap regex in `deploy/meshchat_update.sh`
stops matching and its ntfy warning fires — rebuild the bundle against the new
version then.
