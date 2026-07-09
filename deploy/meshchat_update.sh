#!/bin/bash
# meshchat_update.sh — v3.4: review gate (HEAD-based) + rollback + smoke test + ntfy
#                       + theme-aware trigger + standalone C64 overlay (append, not overwrite)
#
# CONFIGURATION — every path below can be overridden without editing this file,
# either via environment variables (MESHCHAT_*) or via the config file ($CONF,
# sourced early, so it may override any of these as well). Defaults assume a
# layout under $HOME; adjust to taste.
#
# Cron example (paths resolve against the cron user's $HOME):
#   0 */2 * * * $HOME/bin/meshchat_update.sh >> $HOME/meshchat/update.log 2>&1
# Manual apply after reviewing a HOLD or a failed commit:
#   meshchat_update.sh --force
#
# Changes vs v2:
#  - The gate diffs HEAD..origin/main (what actually runs vs upstream), no
#    longer fetch-before..fetch-after. Closes the piggyback gap: a "clean"
#    follow-up commit can no longer smuggle in a held change, and an open
#    HOLD stays visible on every run.
#  - meshchat:prev is tagged before every build; smoke test after start-up;
#    on failure automatic rollback to prev + git tree restored (tree =
#    running code) + marker so the same commit is not retried silently.
#  - build and up are split: a failed build never touches the running container.
#  - ntfy notifications (config in $CONF, chmod 600): HOLD (deduplicated),
#    successful update, failed build, rollback, rollback failure (max prio),
#    and the script.js-without-sw.js warning (stale-client risk).
#
# Changes vs v3 (v3.1):
#  - Theme-aware trigger: because the static files are baked into the Docker
#    image, a purely local theme change (stylesheet etc. in the theme dir)
#    must also trigger a rebuild — not just an upstream delta. The early
#    "nothing to do" exit now only fires when HEAD == origin/main AND the
#    theme is unchanged since the last successful build. Tracked via the
#    stamp file $STATE/theme_built, compared with -nt.
#  - The stamp is refreshed on the success path (after a green smoke test).
#
# Changes vs v3.1 (v3.2):
#  - style.css is NO longer overwritten with a frozen copy. apply_theme now
#    appends a standalone overlay ($THEME/c64-theme.css) AFTER the pristine
#    upstream style.css. Result: upstream styling stays authoritative and
#    keeps receiving its updates (e.g. .message white-space) automatically;
#    our C64 layer (palette, font, CRT, icons) overrides only what it names.
#    No divergence any more.
#  - Theme detection now watches c64-theme.css instead of style.css.
#  - A frozen style.css copy in the theme dir is obsolete (may remain, it is
#    no longer read).
set -uo pipefail

# --- paths (override via environment or $CONF) ---
CONF="${MESHCHAT_CONF:-$HOME/.config/meshchat_update.conf}"
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"   # provides NTFY_URL; may also override the paths below

REPO="${MESHCHAT_REPO:-$HOME/meshchat}"                                  # upstream checkout
THEME="${MESHCHAT_THEME:-$HOME/c64-layer}"                               # theme source of truth
COMPOSE="${MESHCHAT_COMPOSE:-$HOME/meshchat-docker/docker-compose.yml}"  # compose file
STATE="${MESHCHAT_STATE:-$HOME/meshchat-docker/state}"                   # markers/stamps
SMOKE="${MESHCHAT_SMOKE:-$HOME/bin/meshchat_smoke.sh}"                   # smoke-test script
THEME_STAMP="$STATE/theme_built"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

mkdir -p "$STATE"

notify() {
    # notify <prio: min|low|default|high|urgent|max> <title> <body>
    # Must never break the update flow: failures are only logged.
    [ -n "${NTFY_URL:-}" ] || return 0
    curl -fsS -m 10 \
        -H "Title: $2" -H "Priority: $1" -H "Tags: satellite" \
        -d "$3" "$NTFY_URL" >/dev/null 2>&1 \
        || echo "⚠️  ntfy notification failed: $2"
}

apply_theme() {
    # Apply the C64 layer: copy/append + one targeted injection.
    #  - style.css: append our standalone overlay AFTER the pristine upstream
    #    css (no freezing; upstream styling keeps its updates, our layer
    #    overrides).
    #  - doc/icons/manifest: our own assets, plain copies.
    #  - index.html: NO full copy (upstream stays authoritative), but ONE
    #    idempotent injection of the polyfills tag for the Commodore/SailfishOS
    #    WebView (Gecko 91), before script.js.
    # Safely idempotent: git reset --hard restores static/ to pristine
    # upstream before apply_theme runs on every pass, so never doubled.
    mkdir -p static/doc static/c64
    cat "$THEME/c64-theme.css" >> static/style.css
    cp -f "$THEME/doc-index.html" static/doc/index.html
    cp -f "$THEME/icon-192.png"   static/icon-192.png
    cp -f "$THEME/icon-512.png"   static/icon-512.png
    cp -f "$THEME/manifest.json"  static/manifest.json
    echo "✅ C64 overlay appended after upstream css + icons/manifest applied"

    # --- polyfills for the Gecko 91 WebView: file + <script> injection before script.js ---
    if [ -f "$THEME/polyfills.js" ]; then
        cp -f "$THEME/polyfills.js" static/c64/polyfills.js
        if grep -q '/c64/polyfills.js' static/index.html; then
            echo "ℹ️  polyfills already present in index.html (index.html not pristine?)"
        elif grep -q 'src="script\.js"' static/index.html; then
            sed -i '\#src="script\.js"#i <script src="/c64/polyfills.js"></script>' static/index.html
            echo "✅ polyfills.js injected before script.js"
        else
            echo "⚠️  anchor src=\"script.js\" not found in index.html — polyfill NOT injected (upstream changed?)"
            notify high "MeshChat: polyfill injection failed" \
                "Anchor script.js not found in index.html; Commodore WebView is missing its polyfills. Check upstream."
        fi
    else
        echo "ℹ️  no $THEME/polyfills.js — polyfill step skipped"
    fi

    # --- CDN independence: self-host qrcode / html5-qrcode / ed25519 ---
    # Replace the three external CDN scripts with local copies in /c64/, so
    # MeshChat starts fully without internet (LAN / Commodore device).
    # The ed25519 bundle is critical: without that module there is no crypto
    # identity and the app cannot log in.
    if [ -f "$THEME/vendor/qrcode.min.js" ] && [ -f "$THEME/vendor/html5-qrcode.min.js" ] \
       && [ -f "$THEME/vendor/ed25519.bundle.min.js" ]; then
        cp -f "$THEME/vendor/qrcode.min.js"          static/c64/qrcode.min.js
        cp -f "$THEME/vendor/html5-qrcode.min.js"    static/c64/html5-qrcode.min.js
        cp -f "$THEME/vendor/ed25519.bundle.min.js"  static/c64/ed25519.bundle.min.js

        # 1) qrcodejs: cdnjs URL -> local
        if grep -q 'cdnjs.cloudflare.com/ajax/libs/qrcodejs' static/index.html; then
            sed -i 's#https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/[^"]*#/c64/qrcode.min.js#' static/index.html
        fi
        # 2) html5-qrcode: unpkg URL -> local
        if grep -q 'unpkg.com/html5-qrcode' static/index.html; then
            sed -i 's#https://unpkg.com/html5-qrcode[^"]*#/c64/html5-qrcode.min.js#' static/index.html
        fi
        # 3) ed25519: replace the inline module script (import from esm.sh)
        #    with one plain script tag; the bundle sets window.ed25519 itself.
        if grep -q 'esm.sh/@noble/curves' static/index.html; then
            python3 - <<'PYEOF'
import re
p = "static/index.html"
h = open(p).read()
pat = re.compile(r'<script type="module">\s*import \{ ed25519 \} from \'https://esm\.sh/@noble/curves[^\']*\';\s*window\.ed25519 = ed25519;\s*</script>')
new = '<script src="/c64/ed25519.bundle.min.js"></script>'
h2, n = pat.subn(new, h)
open(p, "w").write(h2 if n else h)
print(f"ed25519 swap: {n} replacement(s)")
PYEOF
        fi

        # verification: no external CDN references left?
        LEFT=$(grep -cE 'cdnjs.cloudflare.com|unpkg.com|esm.sh' static/index.html || true)
        if [ "$LEFT" = "0" ]; then
            echo "✅ CDN-free: qrcode, html5-qrcode and ed25519 served locally from /c64/"
        else
            echo "⚠️  $LEFT external CDN reference(s) still in index.html — swap incomplete (upstream changed?)"
            notify high "MeshChat: CDN swap incomplete" \
                "index.html still contains external CDN references; offline start not guaranteed. Check upstream."
        fi
    else
        echo "ℹ️  vendor files incomplete in $THEME/vendor/ — CDN swap skipped"
    fi
}

restore_tree() {
    # Restore the git tree to the given commit + theme, so the checkout
    # matches the running image again. Prevents a later --force/theme rebuild
    # from silently rebuilding broken code.
    git reset --hard "$1" >/dev/null
    apply_theme
    echo "↩️  git tree back on ${1:0:7} (= running code)"
}

cd "$REPO" || exit 1
echo "=== MeshChat Auto Update - $(date) ==="

if ! git fetch origin main; then
    echo "❌ git fetch failed (network/GitHub?) — nothing changed"
    exit 1
fi

HEAD_=$(git rev-parse HEAD)
TARGET=$(git rev-parse origin/main)
H7=${HEAD_:0:7}; T7=${TARGET:0:7}

# --- has the theme changed since the last successful build? ---
# (static files are baked into the image, so a local theme change requires a
#  rebuild — even without an upstream delta.)
theme_changed=0
for f in c64-theme.css doc-index.html icon-192.png icon-512.png manifest.json polyfills.js \
         vendor/qrcode.min.js vendor/html5-qrcode.min.js vendor/ed25519.bundle.min.js; do
    [ "$THEME/$f" -nt "$THEME_STAMP" ] && theme_changed=1
done

# --- nothing to do? (no upstream delta, no --force, and theme unchanged) ---
if [ "$HEAD_" = "$TARGET" ] && [ "$FORCE" != "1" ] && [ "$theme_changed" = "0" ]; then
    echo "— HEAD ($H7) equals origin/main, theme unchanged —"
    exit 0
fi
[ "$theme_changed" = "1" ] && echo "🎨 theme change detected in theme dir"

if [ "$HEAD_" != "$TARGET" ]; then
    echo "🔔 Pending delta: $H7 → $T7"
    git diff --stat "$HEAD_" "$TARGET" 2>/dev/null

    # --- previously-failed-commit marker (no automatic retry) ---
    if [ "$FORCE" != "1" ] && [ -f "$STATE/failed_commit" ] \
       && [ "$(cat "$STATE/failed_commit")" = "$TARGET" ]; then
        echo "⛔ commit $T7 previously failed build/smoke test — waiting for review (--force) or a new upstream commit"
        exit 0
    fi

    # --- REVIEW GATE (allowlist), diffed from HEAD ---
    CHANGED=$(git diff --name-only "$HEAD_" "$TARGET")
    UNSAFE=$(echo "$CHANGED" | grep -vE '^static/.*\.(html|js|css|png|jpg|svg|ico|json|webmanifest|woff2?)$' || true)

    if [ -n "$UNSAFE" ] && [ "$FORCE" != "1" ]; then
        echo "⛔ HOLD — non-browser files changed, manual review required:"
        echo "$UNSAFE" | sed 's/^/      /'
        echo "   Review:  git diff HEAD origin/main"
        echo "   Then:    meshchat_update.sh --force"
        if [ "$(cat "$STATE/hold_notified" 2>/dev/null)" != "$TARGET" ]; then
            notify high "MeshChat HOLD ($T7)" \
                "Review required: $(echo "$UNSAFE" | head -5 | tr '\n' ' ')"
            echo "$TARGET" > "$STATE/hold_notified"
        else
            echo "   (notification for $T7 already sent earlier)"
        fi
        exit 0
    fi
    [ "$FORCE" = "1" ] && [ -n "$UNSAFE" ] && echo "🔧 --force: gate overruled after review"

    # --- stale-client warning: script.js changed without an sw.js bump ---
    if echo "$CHANGED" | grep -q '^static/script\.js$' \
       && ! echo "$CHANGED" | grep -q '^static/sw\.js$'; then
        echo "⚠️  script.js changed without sw.js — existing clients stay on old code (SW cache)"
        notify default "MeshChat: script.js without sw.js bump ($T7)" \
            "Possibly a breaking client change; existing clients will not refresh by themselves."
    fi
else
    # no upstream delta: we got here via --force or a theme change
    if [ "$FORCE" = "1" ]; then
        echo "🔧 --force without delta: theme + rebuild (same safety-net pipeline)"
    else
        echo "🎨 theme change without upstream delta: theme + rebuild (same safety-net pipeline)"
    fi
fi

# --- apply, with safety net ---
if docker image inspect meshchat:local >/dev/null 2>&1; then
    docker tag meshchat:local meshchat:prev
    echo "🛟 meshchat:prev = current image"
else
    echo "ℹ️  no existing meshchat:local to tag as prev"
fi

git reset --hard "$TARGET"
apply_theme

if ! docker compose -f "$COMPOSE" build; then
    echo "❌ build FAILED — old container keeps running untouched"
    restore_tree "$HEAD_"
    echo "$TARGET" > "$STATE/failed_commit"
    notify urgent "MeshChat: build FAILED ($T7)" \
        "Image does not build; old container keeps running. Review required."
    exit 1
fi

if ! docker compose -f "$COMPOSE" up -d; then
    echo "❌ up -d FAILED — rolling back to prev"
else
    echo "✅ container started on $T7 — smoke test..."
    if "$SMOKE"; then
        echo "✅ UPDATE SUCCEEDED: $H7 → $T7"
        rm -f "$STATE/failed_commit" "$STATE/hold_notified"
        touch "$THEME_STAMP"   # theme is now built → no needless rebuild next run
        notify default "MeshChat: update succeeded" "$H7 → $T7, smoke test green."
        exit 0
    fi
    echo "❌ smoke test FAILED on $T7 — rolling back to prev"
fi

# --- ROLLBACK ---
if ! docker image inspect meshchat:prev >/dev/null 2>&1; then
    notify max "MeshChat BROKEN — no prev image" \
        "Update $T7 failed and there is no meshchat:prev to roll back to. Manual intervention required."
    exit 1
fi
docker tag meshchat:prev meshchat:local
docker compose -f "$COMPOSE" up -d --force-recreate
if "$SMOKE"; then
    restore_tree "$HEAD_"
    echo "$TARGET" > "$STATE/failed_commit"
    echo "↩️  ROLLBACK succeeded: prev ($H7) running again; $T7 marked as failed"
    notify urgent "MeshChat ROLLBACK performed" \
        "Commit $T7 failed the smoke test. Prev ($H7) is running again and green. Review required."
    exit 1
else
    echo "🚨 rollback failed as well — manual intervention required"
    restore_tree "$HEAD_"                      # tree = prev code (= meshchat:local after retag)
    echo "$TARGET" > "$STATE/failed_commit"    # delta stays visible, no silent retry
    notify max "MeshChat BROKEN — rollback failed" \
        "Update $T7 AND rollback to $H7 fail the smoke test. Relay presumably down. Manual intervention required."
    exit 1
fi
