<img width="258" height="340" alt="meshchat64" src="https://github.com/user-attachments/assets/01a85ba0-357f-42e3-90f1-23bae75f0a16" />

## MeshChat64 — Commodore Callback 8020 App

A native **SailfishOS WebView app** plus a **Commodore 64 presentation layer**
that together turn a self-hosted [MeshChat](https://github.com/saint-cc/meshchat)
instance into a retro encrypted messenger for the
**Commodore Callback 8020** phone (480×640, SailfishOS 5.x, Gecko 91 WebView).

> ## Attribution — read this first
>
> **All MeshChat application code is authored by [saint-cc](https://github.com/saint-cc).**
> Upstream repository: **https://github.com/saint-cc/meshchat**
>
> This includes, without exception: `server.py`, `script.js` (the entire
> chat/crypto/relay client), `statemachine.js`, `sw.js`, `index.html`, the
> original `style.css`, and the MeshChat protocol design (encrypted relay chat,
> the shareable-key format, cross-relay delivery).
>
> Everything in this repository is strictly a **presentation and compatibility
> layer on top of saint-cc's code**. It deliberately never forks or modifies his
> source: the deploy pipeline mirrors his `main` branch pristine and re-applies
> the overlay at build time. See [NOTICE](NOTICE).

## What is in this repository

```
meshchat64-callback8020/
├── app/               SailfishOS app: a thin WebView shell (QML, .desktop, RPM spec)
├── c64-layer/         The C64 overlay: theme CSS, Gecko 91 polyfills, PWA assets,
│   └── vendor/        self-hosted third-party libs (provenance + SHA-256 inside)
├── deploy/            meshchat_update.sh — the unattended update/overlay pipeline
├── docs/              Full knowledge base (briefing + SailfishOS development guide)
└── licenses/          Third-party license texts
```

The two halves are intentionally decoupled:

- **The app** (`app/`) is trivial on purpose — a `WebView` pointed at the
  server, portrait-locked for the 480×640 screen, with the Sailjail permissions
  that make it actually work. All complexity is server-side, so the app almost
  never needs an update.
- **The server layer** (`c64-layer/` + `deploy/`) does the heavy lifting: it
  re-skins upstream MeshChat with a VIC-II palette, pixel font, CRT bezel and
  pixel icon set, teaches the 2021-era Gecko 91 engine the modern browser APIs
  the client needs (`crypto.randomUUID`, `CompressionStream` — the latter sits
  *inside* the encryption protocol), and makes the whole page start with zero
  external requests (all CDN libraries self-hosted).

## Architecture

```
┌────────────────────────┐        ┌──────────────────────────────────────┐
│ Commodore Callback 8020│        │ Raspberry Pi                         │
│  MeshChat64 (this app) │ wss/   │  nginx ──► Docker: MeshChat (saint-cc)│
│  SailfishOS WebView    │ https  │            + C64 overlay re-applied  │
│  (Gecko 91)            ├───────►│              on every upstream update │
└────────────────────────┘  443   └──────────────────────────────────────┘
```

The pipeline (`deploy/meshchat_update.sh`) runs from cron, mirrors upstream
`main` with `git reset --hard` (no local commits → merge conflicts are
impossible), appends the theme after upstream's untouched `style.css`, performs
two anchor-checked injections into `index.html` (polyfills tag + CDN→local
swaps), rebuilds the container, smoke-tests, and rolls back automatically on
failure with ntfy push notifications. Full rationale and war stories:
[docs/c64-layer-briefing.md](docs/c64-layer-briefing.md).

## Quick start

### Server layer (Raspberry Pi or any Docker host)

1. Run saint-cc's MeshChat behind nginx per his README (HTTP on 8000, WebSocket
   on 8888 proxied at `/ws/`; set `RELAY_WSS_URL=wss://your.host/ws/`).
2. Copy `c64-layer/` to your theme directory and `deploy/meshchat_update.sh`
   to your bin. Configure via `MESHCHAT_*` environment variables or the config
   file (`~/.config/meshchat_update.conf`, chmod 600 — it also holds your
   private `NTFY_URL`); defaults live under `$HOME`.
3. Add the vendor libraries to `c64-layer/vendor/` — see
   [c64-layer/vendor/README.md](c64-layer/vendor/README.md) for exact
   provenance, build command and SHA-256 checksums.
4. Cron it: `0 */2 * * * /path/to/meshchat_update.sh >> update.log 2>&1`

### SailfishOS app

1. Point `url:` in `app/qml/MeshChat64.qml` at your instance.
2. Install the WebView components into your build target **and** its
   `.default` snapshot (yes, both — see the development guide):
   ```
   sfdk tools package-install SailfishOS-5.0.0.62-i486 sailfish-components-webview-qt5
   sfdk tools package-install SailfishOS-5.0.0.62-i486.default sailfish-components-webview-qt5
   ```
3. Build & deploy to the emulator:
   ```
   mkdir build && cd build
   sfdk config --global target=SailfishOS-5.0.0.62-i486
   sfdk build ../app && sfdk deploy --sdk
   ```
4. For the real Callback (aarch64), same recipe with
   `sfdk -c target=SailfishOS-5.0.0.62-aarch64 build ../app` — the RPM lands in
   `RPMS/` ready for sideloading.

Every hard-won lesson (the empty `Permissions=` trap, the `.default` snapshot
sync, emulator framebuffer drift, where the Gecko profile actually lives, and
more) is written down in
[docs/sailfish-development-guide.md](docs/sailfish-development-guide.md).

## Gecko 91 compatibility in one table

| API used by upstream | Native since | Status on the Callback |
|---|---|---|
| `crypto.randomUUID` | Firefox 95 | polyfilled (RFC 4122 v4 over `getRandomValues`) |
| `CompressionStream`/`DecompressionStream` | Firefox 113 | polyfilled with real gzip (fflate bundled) — required, it lives inside the encryption pipeline |
| `MediaRecorder` + `audio/webm` | — | constructor wrapped: unsupported mimeType is dropped, Gecko records ogg/Opus |
| `crypto.subtle`, WebSocket, localStorage, `createImageBitmap`, clipboard `writeText`, BigInt | ≤ FF 91 | work natively, no action |
| `getUserMedia`, `RTCPeerConnection` | — | device/stack-dependent; microphone verified working on the emulator |

## Credits

- **[saint-cc](https://github.com/saint-cc)** — MeshChat: the application,
  protocol and server. This project exists on top of his work, with his
  permission.
- Pixel font built from the public-domain
  [dhepper/font8x8](https://github.com/dhepper/font8x8) bitmap font.
- Self-hosted vendor libraries: qrcodejs (MIT), html5-qrcode (Apache-2.0),
  @noble/curves (MIT) — see [licenses/](licenses/).

## License

The original work in this repository (theme, polyfills, pipeline, app shell,
documentation) is released under the [MIT License](LICENSE). Third-party
components keep their own licenses (see [licenses/](licenses/) and
[NOTICE](NOTICE)); nothing in this repository relicenses any part of upstream
MeshChat.
