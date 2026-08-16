#!/usr/bin/env bash
# =============================================================================
# Build ASSella.AppImage — reproduces niwia's official release packaging.
#
# Reverse-engineered from:
#   - .agents/AGENTS.md  ->  ARCH=x86_64 ./appimagetool --no-appstream
#                            squashfs-root ASSella.AppImage
#   - ASSella-v2.6.0-linux-source.tar.gz  ->  bin/{src,run.sh,requirements.txt,icon.png}
#   - ASSella-v2.6.0.AppImage internals  ->  AppRun, ACCELA.desktop, .DirIcon
#     and the bundled interpreter: python-build-standalone CPython (relocatable)
#     installed as `bin/.venv` (NOT a real venv — no pyvenv.cfg; full stdlib
#     lives at bin/.venv/lib/python3.13/).
#
# Requirements (Linux x86_64):
#   bash, curl, jq, tar, file
#   (Ubuntu/Debian: sudo apt install curl jq; RHEL: sudo dnf install curl jq)
#
# Usage:
#   ./scripts/build-appimage.sh [OUT_NAME]     (OUT_NAME default: ASSella.AppImage)
#
# Env:
#   WORK=<dir>       cache/build dir (default: /tmp/assella_build)
#   PY_VERSION       CPython minor version (default: 3.13)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VERSION="$(tr -d '[:space:]' < src/res/version)"
OUT_NAME="${1:-ASSella.AppImage}"
PY_VERSION="${PY_VERSION:-3.13}"
WORK="${WORK:-/tmp/assella_build}"
APP_DIR="$WORK/squashfs-root"
PYTHON_TGZ="$WORK/python-build-standalone.tar.gz"
TOOL_DIR="$WORK/appimagetool"

require() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found (install it first)"; exit 1; }; }
require curl; require jq; require tar; require file

echo "==> ASSella v$VERSION AppImage build"
echo "    out:   $REPO_ROOT/$OUT_NAME"
echo "    work:  $WORK"

mkdir -p "$WORK"

# ---------------------------------------------------------------------------
# 1. Relocatable CPython (python-build-standalone) -> bin/.venv
# ---------------------------------------------------------------------------
if [ ! -x "$APP_DIR/bin/.venv/bin/python$PY_VERSION" ]; then
    if [ ! -f "$PYTHON_TGZ" ]; then
        echo "==> Downloading relocatable CPython $PY_VERSION (python-build-standalone)..."
        # Asset URLs are percent-encoded (e.g. cpython-3.13.15%2B20260814-...)
        RE="cpython-${PY_VERSION//./\\.}\.[0-9]+%2B[0-9]+-x86_64-unknown-linux-gnu-install_only\.tar\.gz"
        PY_URL=""
        # 1) pinned known-good release (deterministic — avoids GitHub API rate
        #    limits on shared CI runner IPs). Verified HEAD 302 on 2026-08-16.
        PINNED="https://github.com/astral-sh/python-build-standalone/releases/download/20260814/cpython-3.13.15%2B20260814-x86_64-unknown-linux-gnu-install_only.tar.gz"
        if curl -fsI -o /dev/null "$PINNED" 2>/dev/null; then
            PY_URL="$PINNED"
        else
            echo "    (pinned release gone — resolving via GitHub API...)"
        fi
        # 2) latest release via API (retry a few times against rate limits)
        if [ -z "$PY_URL" ]; then
            for i in 1 2 3; do
                PY_URL="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
                    https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest \
                    | jq -r '.assets[].browser_download_url' 2>/dev/null \
                    | grep -E "$RE" | head -n 1)"
                [ -n "$PY_URL" ] && break
                sleep 2
            done
        fi
        # 3) fallback: search the 10 most recent releases
        if [ -z "$PY_URL" ]; then
            echo "    (latest release miss — searching recent releases...)"
            PY_URL="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
                https://api.github.com/repos/astral-sh/python-build-standalone/releases?per_page=10 \
                | jq -r '.[].assets[].browser_download_url' 2>/dev/null \
                | grep -E "$RE" | head -n 1)"
        fi
        if [ -z "$PY_URL" ]; then
            echo "ERROR: no python-build-standalone $PY_VERSION x86_64 asset found"
            echo "  (regex: $RE)"
            exit 1
        fi
        echo "    resolved: $PY_URL"
        # Runner CDN egress is flaky: retry ALL errors (incl. mid-transfer resets
        # which plain --retry ignores), resume partial files, and verify the gzip
        # after downloading. -sS keeps the log clean (no \r meter noise) so any
        # real error is clearly visible in CI annotations.
        for attempt in 1 2 3 4 5; do
            if curl -fsSL --retry 3 --retry-all-errors --retry-delay 2 -C - -sS \
                -o "$PYTHON_TGZ" "$PY_URL"; then
                break
            fi
            rc=$?
            echo "    download attempt $attempt failed (curl exit $rc) — retrying..."
            sleep 3
        done
        if ! gzip -t "$PYTHON_TGZ" 2>/dev/null; then
            echo "ERROR: python-build-standalone tarball is missing or corrupt: $PYTHON_TGZ"
            exit 1
        fi
        mkdir -p "$APP_DIR/bin/.venv"
        tar -xzf "$PYTHON_TGZ" -C "$APP_DIR/bin/.venv" --strip-components=1
    fi
fi
PYTHON="$APP_DIR/bin/.venv/bin/python$PY_VERSION"
echo "==> Interpreter: $("$PYTHON" -V 2>&1) ($PYTHON)"

# ---------------------------------------------------------------------------
# 2. Payload (fresh copy of the codebase)
# ---------------------------------------------------------------------------
rm -rf "$APP_DIR/bin/src"
cp -r src "$APP_DIR/bin/src"
find "$APP_DIR/bin/src" -type d -name '__pycache__' -prune -exec rm -rf {} +
cp requirements.txt "$APP_DIR/bin/requirements.txt"

# ---------------------------------------------------------------------------
# 3. run.sh — canonical launcher (verbatim from the ASSella release archive)
# ---------------------------------------------------------------------------
cat > "$APP_DIR/bin/run.sh" <<'RUNSH'
#!/usr/bin/env bash
cd "$(dirname "$(realpath "$0")")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

set +eu
IS_APPIMAGE=$APPIMAGE

# Check if notify-send exists globally
command -v notify-send &> /dev/null
NOTIFY_SEND_AVAILABLE=$?
set -eu

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
    set +eu
    if [ "$NOTIFY_SEND_AVAILABLE" -eq 0 ]; then
        notify-send -t 5000 "INFO" "$1" 2>/dev/null
    fi
    set -eu
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    set +eu
    if [ "$NOTIFY_SEND_AVAILABLE" -eq 0 ]; then
        notify-send -t 5000 -u normal "WARNING" "$1" 2>/dev/null
    fi
    set -eu
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    set +eu
    if [ "$NOTIFY_SEND_AVAILABLE" -eq 0 ]; then
        notify-send -t 5000 -u critical "ERROR" "$1" 2>/dev/null
    fi
    set -eu
}

# Parse command line arguments
SETUP_VENV=false
PYTHON_ARGS=()

for arg in "$@"; do
    if [ "$arg" = "--venv" ]; then
        SETUP_VENV=true
    else
        PYTHON_ARGS+=("$arg")
    fi
done

setup_venv() {
    # Create virtual environment
    python3 -m venv .venv

    # Activate virtual environment
    source .venv/bin/activate

    # Install requirements
    if [ -f "requirements.txt" ]; then
        pip install -r requirements.txt
    else
        log_warn "requirements.txt not found, skipping pip install"
    fi
}

# Check if we're running inside an AppImage
if [ -n "$IS_APPIMAGE" ]; then
    # We are using the bundled standalone python
    PYTHON_EXEC=".venv/bin/python3"

    if [ -f "$PYTHON_EXEC" ]; then
        exec "$PYTHON_EXEC" src/main.py "${PYTHON_ARGS[@]}"
    else
        log_error "Bundled Python environment not found in AppImage"
        exit 1
    fi
else
    # Normal source execution
    if [ "$SETUP_VENV" = true ]; then
        log_info "Setting up virtual environment and installing dependencies"
        setup_venv
    else
        # Check if virtual environment already exists and activate it if it does
        if [ -d ".venv" ] && [ -f ".venv/bin/activate" ]; then
            source .venv/bin/activate
        else
            log_warn "No virtual environment found, creating"
            setup_venv
        fi
    fi

    # Run the main script with preserved environment
    # This ensures DISPLAY, WAYLAND_DISPLAY, PATH, etc. are preserved
    # which is needed for Qt GUI and Wine
    # Pass all remaining command-line arguments through to the Python script
    exec python src/main.py "${PYTHON_ARGS[@]}"
fi
RUNSH
chmod +x "$APP_DIR/bin/run.sh"

# ---------------------------------------------------------------------------
# 4. Install dependencies into the bundled interpreter
# ---------------------------------------------------------------------------
echo "==> Installing Python dependencies (this can take a few minutes)..."
"$PYTHON" -m pip install --upgrade pip -q
"$PYTHON" -m pip install -r requirements.txt -q

# Optional extras shipped in niwia's release (Steam Deck Decky support, etc.):
#   "$PYTHON" -m pip install decky_loader==3.2.6 numpy -q

# ---------------------------------------------------------------------------
# 5. AppImage metadata (mirrors the official AppImage exactly)
# ---------------------------------------------------------------------------
cat > "$APP_DIR/AppRun" <<'RUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
cd "$HERE/bin"
export APPIMAGE=1
exec "./run.sh" "$@"
RUN
chmod +x "$APP_DIR/AppRun"

cat > "$APP_DIR/ACCELA.desktop" <<'DESK'
[Desktop Entry]
Name=ASSella
Comment=god is in the ass
Exec=run.sh
Icon=accela
Terminal=false
Type=Application
Categories=Utility;Game;
MimeType=x-scheme-handler/accela;
DESK

cp src/res/logo/accela.png "$APP_DIR/accela.png"
ln -sf accela.png "$APP_DIR/.DirIcon"

# ---------------------------------------------------------------------------
# 6. appimagetool
# ---------------------------------------------------------------------------
if [ ! -x "$TOOL_DIR/usr/bin/appimagetool" ]; then
    echo "==> Fetching appimagetool (continuous)..."
    rm -f "$WORK/appimagetool.AppImage"
    for attempt in 1 2 3 4 5; do
        if curl -fsSL --retry 3 --retry-all-errors --retry-delay 2 -C - -sS \
            -o "$WORK/appimagetool.AppImage" \
            https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage; then
            break
        fi
        rc=$?
        echo "    appimagetool download attempt $attempt failed (curl exit $rc) — retrying..."
        sleep 3
    done
    chmod +x "$WORK/appimagetool.AppImage"
    if ! file "$WORK/appimagetool.AppImage" | grep -q ELF; then
        echo "ERROR: appimagetool download is not an ELF binary"
        exit 1
    fi
    # Extract into a scratch subdir: --appimage-extract unpacks to ./squashfs-root,
    # which MUST NOT collide with our AppDir (APP_DIR is also $WORK/squashfs-root).
    SCRATCH="$WORK/appimagetool-x"
    rm -rf "$SCRATCH"
    mkdir -p "$SCRATCH"
    ( cd "$SCRATCH" && ../appimagetool.AppImage --appimage-extract >/dev/null )
    rm -rf "$TOOL_DIR"
    mv "$SCRATCH/squashfs-root" "$TOOL_DIR"
    rm -rf "$SCRATCH"
fi
TOOL="$TOOL_DIR/usr/bin/appimagetool"

# ---------------------------------------------------------------------------
# 7. Build the AppImage
# ---------------------------------------------------------------------------
echo "==> Building $OUT_NAME ..."
rm -f "$REPO_ROOT/$OUT_NAME"
ARCH=x86_64 "$TOOL" --no-appstream "$APP_DIR" "$REPO_ROOT/$OUT_NAME"
chmod +x "$REPO_ROOT/$OUT_NAME"

echo "==> DONE: $REPO_ROOT/$OUT_NAME"
file "$REPO_ROOT/$OUT_NAME"
ls -lh "$REPO_ROOT/$OUT_NAME"
