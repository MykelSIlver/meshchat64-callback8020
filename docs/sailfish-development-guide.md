# SailfishOS Development Guide — MeshChat64 / Callback 8020

Everything learned building this app, written down so nobody has to learn it
twice. Companion to [c64-layer-briefing.md](c64-layer-briefing.md), which covers
the server-side layer.

Target device: **Commodore Callback 8020 "Starlight"** — 480×640 portrait,
SailfishOS 5.0.0.62, Gecko 91 WebView. Development host: Ubuntu + Sailfish SDK
(VirtualBox-based Build Engine + emulator).

---

## 1. The one-line fix that cost a day: Sailjail permissions

The SailfishOS app template ships a `.desktop` file with an **empty**
`Permissions=` line under `[X-Sailjail]`. A sandboxed app then has *no* network
access. The symptom is maximally misleading: the WebView shows **"Server not
found"** while `curl` from the same device works fine (SSH sessions are not
sandboxed), and **nothing logs an error anywhere** — an empty permission set is
a valid configuration, not a failure.

Required for this app:

```ini
[X-Sailjail]
OrganizationName=org.example
ApplicationName=MeshChat64
Permissions=Internet;WebView;Microphone
```

- `Internet` — network access. `WebView` — the Gecko engine and its cache paths.
- `Microphone` — voice messages / calls (verified working on the emulator).
- Add `Pictures` or `UserDirs` if the image file picker misbehaves.
- The smoking gun in `journalctl` when sandboxing is the problem:
  `invoker: warning: enforcing sandboxing for '/usr/bin/MeshChat64'`.

`OrganizationName` also determines **where app data lives**:
`~/.cache/<OrganizationName>/<ApplicationName>/` — that is where the Gecko
profile (cookies, localStorage, and therefore your **chat identity**) is stored.
Relevant when clearing a corrupt profile:

```
sfdk emulator exec rm -rf .cache/org.example .local/share/org.example
```

A corrupt profile (e.g. a zero-byte `ua-update.json` left behind by a crashed
session) can segfault a Gecko worker thread and produce endless "Server not
found" with a perfectly healthy network.

## 2. WebView packages: install into the target AND its snapshot

`Sailfish.WebView` is not in the build targets by default. Install it into the
target **and** its `.default` snapshot — the snapshot is what Qt Creator's code
model and the compiler sysroot actually read, and it does **not** reliably
auto-sync from the parent target:

```
sfdk tools package-install SailfishOS-5.0.0.62-i486 sailfish-components-webview-qt5
sfdk tools package-install SailfishOS-5.0.0.62-i486.default sailfish-components-webview-qt5
```

The second command ends with `Synchronising target to host... Sync completed` —
that sync is what makes the QML module visible under
`~/SailfishOS/mersdk/targets/<target>.default/usr/lib/qt5/qml/Sailfish/WebView`
and clears the "QML module not found" editor error. `sfdk tools update` does
NOT do this (it is a distro upgrade, not a snapshot reset). Repeat both
commands for every target you build against (aarch64 for the real device).

At **runtime** the engine comes in via the spec:

```
Requires: sailfish-components-webview-qt5
Requires: sailfish-components-webview-qt5-popups   # JS dialogs, auth, permission prompts
Requires: sailfish-components-webview-qt5-pickers  # file pickers (image upload)
```

The popups package is also what surfaces the getUserMedia permission prompt.

## 3. Reliable build & deploy: use the CLI

Qt Creator's "Deploy By Copying Binaries" fails silently (it only overlays
binaries onto an *already installed* app and needs a live SSH connection at the
right moment). The dependable cycle is:

```
mkdir build && cd build                     # out-of-source keeps the source tree clean
sfdk config --global target=SailfishOS-5.0.0.62-i486
sfdk config --global device="Sailfish OS Emulator 5.1.0.11"
sfdk build ../app && sfdk deploy --sdk
```

Notes:
- `sfdk config` without `--global` is **session-scoped** — it evaporates with
  the terminal. Use `--global` once and forget about it.
- All builds run inside the **Build Engine VM** (started on demand). Never
  manage that VM through the VirtualBox GUI; use `sfdk engine` commands.
- Verify a deploy actually landed (the habit that solved everything here):
  ```
  sfdk emulator exec grep url /usr/share/MeshChat64/qml/MeshChat64.qml
  ```
- If an install seems ignored, remember RPM considers same version+release
  "already installed". During development either bump `Release:` or remove
  first: `sfdk emulator exec sudo pkcon -y remove MeshChat64` (the `-y` matters:
  non-interactive sessions cannot answer the confirmation prompt, and without
  root you get "Failed to obtain authentication").

For the real Callback (aarch64), one-shot override that leaves the global
config alone:

```
sfdk -c target=SailfishOS-5.0.0.62-aarch64 build ../app
```

The RPM lands in `RPMS/MeshChat64-0.1-1.aarch64.rpm`. Deployment to a real
device is SSH via Developer Mode (Settings → Developer Tools), or low-tech:
transfer the RPM and `pkcon install-local`.

## 4. Emulator setup for the Callback form factor

Create a custom device model (480×640 px, 50×66 mm, pixel ratio 1.0,
portrait) and select it **with the emulator stopped**:

```
sfdk emulator stop
sfdk emulator set device-model="Commodore Callback 8020"
sfdk emulator set downscale=no          # downscale is for high-res models only
sfdk emulator start
```

**Framebuffer drift** — the lesson that explains every "misaligned lock
screen": VirtualBox Guest Additions resize the guest framebuffer to whatever
fits the host window, while lipstick (the compositor) keeps the device-model
resolution from `/var/lib/environment/compositor/*.conf`. Result: UI laid out
for one size, rendered on another → everything off-center and clipped. Checks:

```
sfdk emulator exec cat /sys/class/graphics/fb0/virtual_size    # actual framebuffer
VBoxManage getextradata "SailfishOS-5.1.0.11" enumerate | grep -i video
```

Fixes: keep **View → Auto-resize Guest Display OFF**, don't drag the window
edges, and do clean stop/start cycles after model changes. A residual 472×637
vs 480×640 (window decorations eat a few pixels) is cosmetic — the compositor
follows along and everything centers correctly.

Emulator/target version mismatch is fine: build against 5.0.0.62 (matches the
phone), run on the 5.1.0.11 emulator — Sailfish is backwards compatible.

## 5. Networking from the emulator

The emulator sits behind VirtualBox NAT. Everything is **outbound** — no port
forwarding is ever needed for this app (the phone is a client; ports 8000/8888
live behind nginx on the server and are never contacted directly).

Two NAT gotchas:

1. **DNS is flaky after restarts**, and LAN-only hostnames (e.g. a hosts-file
   entry for your server, the standard workaround for ISP NAT-hairpinning)
   don't resolve at all. Fix once, with the VM powered off:
   ```
   VBoxManage modifyvm "SailfishOS-5.1.0.11" --natdnshostresolver1 on
   ```
   The VM then uses the *host's* resolver — including `/etc/hosts`.
2. `10.0.2.2` is the host as seen from the VM — handy for DNS-bypass tests.

Debug from outside the sandbox:

```
sfdk emulator exec curl -sI https://your.host/          # network truth
sfdk emulator exec sudo journalctl --since "-3 min" --no-pager   # app + Gecko logs
```

JavaScript errors from the WebView appear in journalctl — that is how the
Gecko 91 API gaps (see the polyfills) were found. Note the emulator journal is
volatile: it resets on every VM restart, so capture logs immediately.

`connmanctl` is not shipped in the emulator image; query connman over D-Bus
instead:

```
sfdk emulator exec sudo dbus-send --system --print-reply \
  --dest=net.connman / net.connman.Manager.GetProperties
```

Gecko refuses network I/O while connman reports offline, independent of actual
connectivity — worth checking when curl works but the WebView doesn't.

## 6. MeshChat-specific: identity is deterministic

MeshChat has no accounts. **Identity = keypair derived from
username+passphrase.** A typo on the phone's keyboard silently creates a brand
new, empty identity — no "wrong password" error is possible. Symptoms: no
contacts, no sync, messages reach nobody, zero errors anywhere. The server log
makes it visible instantly: compare the `AUTH OK id=...` of the new device with
your other devices. Same credentials → same id → the relay buffer flushes and
everything syncs on first connect.

## 7. Misc facts worth remembering

- Sailfish uses **Qt 5.6.3** everywhere (licensing); no Qt 5.7+ QML features.
- App icons are plain PNGs at 86/108/128/172 px, installed to
  `/usr/share/icons/hicolor/<size>/apps/`; nothing is masked — round your own
  corners. `Name[xx]=` lines in the .desktop are optional per-locale overrides;
  the bare `Name=` is the fallback for every language.
- The `NOKEY` RPM signature warnings during `package-install` are normal for
  SDK targets.
- Closing an app: swipe **top-to-bottom**. Long-press + ✕ on the app grid
  **uninstalls** (ask how we know).
- Commodore's published policy blocks browsers and social media at system
  level; email/work apps are merely excluded from the Commostore but
  sideloadable. Native Sailfish RPM sideloading and Developer Mode status on
  the Callback are unconfirmed until hardware ships — this app's fallback is
  the Commostore whitelist request form.
