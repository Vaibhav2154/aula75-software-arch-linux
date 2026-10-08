#!/usr/bin/env bash
#
# One-shot setup for the AULA F75 Windows configurator on Arch Linux
# using Bottles Flatpak + Wine 11.12 + HID fixes.
#
# Put this script in the same folder as:
#   - aula-hidfix.c
#   - 70-aula-f75.rules
#
# Optional offline installer:
#   AULA F75 Setup v2.0 20240509.exe
#
# Run:
#   chmod +x setup-arch.sh
#   ./setup-arch.sh
#
# The script is idempotent and can safely be re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BOTTLE="AULA-F75"
PROGRAM_NAME="AULA F75"

RUNNER="wine-11.12-amd64"
RUNNER_URL="https://github.com/Kron4ek/Wine-Builds/releases/download/11.12/${RUNNER}.tar.xz"

INSTALLER_NAME="AULA F75 Setup v2.0 20240509.exe"
INSTALLER="$SCRIPT_DIR/$INSTALLER_NAME"

INSTALLER_PAGE="https://aulagear.com/blogs/software/aula-f75-driver-windows-only"

INSTALLER_SHA256="83c8bad03add55ef583668dd7e84890135cdfa707f3a5ffc7ee399c1ef6e05a3"

SHIM_SRC="$SCRIPT_DIR/aula-hidfix.c"
UDEV_RULE="$SCRIPT_DIR/70-aula-f75.rules"

# Bottles Flatpak paths
BOTTLES_DATA="$HOME/.var/app/com.usebottles.bottles/data"
BOTTLE_DIR="$BOTTLES_DATA/bottles/bottles/$BOTTLE"
RUNNERS_DIR="$BOTTLES_DATA/bottles/runners"

INSTALLER_CACHE="$BOTTLES_DATA/aula-f75-setup.exe"
SHIM_SO="$BOTTLES_DATA/aula-hidfix.so"

APP_DIR="$BOTTLE_DIR/drive_c/Program Files (x86)/AULA/F75"
APP_EXE_HOST="$APP_DIR/OemDrv.exe"
APP_EXE_WIN='C:\Program Files (x86)\AULA\F75\OemDrv.exe'


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

step() {
    printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

ok() {
    printf '\033[1;32m    ok:\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m warning:\033[0m %s\n' "$*" >&2
}

die() {
    printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

bcli() {
    flatpak run --command=bottles-cli com.usebottles.bottles "$@"
}

bsh() {
    flatpak run --command=sh com.usebottles.bottles -c "$1"
}

hash_file() {
    sha256sum "$1" | awk '{print $1}'
}

verify_installer() {
    local file="$1"
    local actual

    actual="$(hash_file "$file")"

    if [[ "$actual" != "$INSTALLER_SHA256" ]]; then
        die "installer checksum mismatch

File:     $file
Got:      $actual
Expected: $INSTALLER_SHA256"
    fi

    ok "installer SHA-256 verified"
}


# ---------------------------------------------------------------------------
# Download official AULA installer
# ---------------------------------------------------------------------------

download_installer()
{
    local dest="$1"
    local page_tmp
    local url

    page_tmp=$(mktemp)

    step "Downloading AULA driver page"

    curl -L \
        --fail \
        --silent \
        --show-error \
        -o "$page_tmp" \
        "$INSTALLER_PAGE"

    # Find the href associated with the actual Windows driver link.
    #
    # The AULA page currently contains:
    #   Download software ver. - Windows
    #
    # followed by the Shopify CDN download URL.
    url=$(
        python - "$page_tmp" <<'PY'
import re
import sys
from html import unescape

page = open(sys.argv[1], encoding="utf-8", errors="ignore").read()

# Find an anchor containing the Windows download text.
patterns = [
    r'<a[^>]+href=["\']([^"\']+)["\'][^>]*>[^<]*Download software ver\.\s*-\s*Windows',
    r'<a[^>]*>[^<]*Download software ver\.\s*-\s*Windows[^<]*</a>',
]

m = re.search(patterns[0], page, re.I | re.S)

if m:
    print(unescape(m.group(1)))
    raise SystemExit

# More tolerant fallback: find a Shopify CDN URL near the Windows
# download text.
m = re.search(
    r'Download software ver\.\s*-\s*Windows.*?'
    r'(https?://cdn\.shopify\.com/[^"\'>\s]+)',
    page,
    re.I | re.S
)

if m:
    print(unescape(m.group(1)))
    raise SystemExit

# Last fallback: search for a Shopify CDN href containing likely
# executable/archive names.
for m in re.finditer(
    r'href=["\']([^"\']*cdn\.shopify\.com[^"\']+)["\']',
    page,
    re.I
):
    candidate = unescape(m.group(1))

    if re.search(
        r'\.(exe|zip|rar|7z)(?:\?|$)',
        candidate,
        re.I
    ):
        print(candidate)
        raise SystemExit

raise SystemExit("NO_DRIVER_URL")
PY
    )

    rm -f "$page_tmp"

    [[ -n "$url" ]] ||
        die "could not find the AULA F75 driver download link"

    case "$url" in
        //*)
            url="https:$url"
            ;;
        http://*|https://*)
            ;;
        *)
            die "unexpected AULA driver download URL: $url"
            ;;
    esac

    step "Driver URL found:"
    echo "    $url"

    step "Downloading AULA F75 installer"

    curl \
        -L \
        --fail \
        --progress-bar \
        -o "$dest" \
        "$url"

    # IMPORTANT: make sure we actually received an executable.
    if ! file "$dest" | grep -qiE 'PE32|PE32\+|MS Windows'; then
        echo
        file "$dest"
        echo
        head -c 200 "$dest" 2>/dev/null || true
        echo

        die "downloaded file is not a Windows executable; refusing to install"
    fi

    verify_installer "$dest"
}
# ---------------------------------------------------------------------------
# Arch Linux prerequisites
# ---------------------------------------------------------------------------

step "Checking Arch Linux prerequisites"

if [[ ! -f /etc/arch-release ]]; then
    die "This script is intended for Arch Linux."
fi

command -v pacman >/dev/null ||
    die "pacman was not found."

# Install required native packages.
#
# flatpak       -> Bottles
# curl          -> installer download
# tar/xz        -> Wine runner extraction
# gcc           -> HID shim
# imagemagick   -> optional icon extraction
# desktop-file-utils -> update desktop database
# usbutils      -> lsusb
#
# base-devel is not strictly required, but gcc comes from it and it is
# commonly useful for building the shim.

step "Installing Arch Linux dependencies"

sudo pacman -S --needed --noconfirm \
    flatpak \
    curl \
    tar \
    xz \
    gcc \
    imagemagick \
    desktop-file-utils \
    usbutils

ok "Arch dependencies installed"


# ---------------------------------------------------------------------------
# Validate local files
# ---------------------------------------------------------------------------

step "Checking local files"

[[ -f "$SHIM_SRC" ]] ||
    die "HID shim source not found:

$SHIM_SRC"

[[ -f "$UDEV_RULE" ]] ||
    die "udev rule not found:

$UDEV_RULE"

if [[ -f "$INSTALLER" ]]; then
    step "Verifying local AULA installer"
    verify_installer "$INSTALLER"
else
    ok "No local installer found; will download official installer"
fi


# ---------------------------------------------------------------------------
# Flatpak / Flathub / Bottles
# ---------------------------------------------------------------------------

step "Ensuring Flathub is configured"

if ! flatpak remotes --user | awk '{print $1}' | grep -qx "flathub"; then
    flatpak remote-add \
        --user \
        --if-not-exists \
        flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo
fi

ok "Flathub configured"


step "Installing Bottles"

if flatpak info com.usebottles.bottles >/dev/null 2>&1; then
    ok "Bottles already installed"
else
    flatpak install \
        --user \
        -y \
        flathub \
        com.usebottles.bottles

    ok "Bottles installed"
fi


# ---------------------------------------------------------------------------
# udev rule
# ---------------------------------------------------------------------------

step "Installing udev rule for AULA F75 HID devices"

if [[ -f /etc/udev/rules.d/70-aula-f75.rules ]]; then
    ok "udev rule already installed"
else
    sudo install \
        -m 644 \
        "$UDEV_RULE" \
        /etc/udev/rules.d/70-aula-f75.rules

    sudo udevadm control --reload-rules
    sudo udevadm trigger

    ok "udev rule installed"
fi


# ---------------------------------------------------------------------------
# Create Bottles bottle
# ---------------------------------------------------------------------------

step "Creating Bottles bottle: $BOTTLE"

if bcli list bottles 2>/dev/null |
    grep -qxF -- "- $BOTTLE"; then

    ok "bottle already exists"

else
    bcli new \
        --bottle-name "$BOTTLE" \
        --environment application

    ok "bottle created"
fi


# ---------------------------------------------------------------------------
# Install custom Wine 11.12 runner
# ---------------------------------------------------------------------------

step "Installing Wine 11.12 runner"

if [[ -x "$RUNNERS_DIR/$RUNNER/bin/wine" ]]; then

    ok "Wine runner already installed"

else

    mkdir -p "$RUNNERS_DIR"

    curl \
        -L \
        --fail \
        --progress-bar \
        -o "$RUNNERS_DIR/$RUNNER.tar.xz" \
        "$RUNNER_URL"

    step "Extracting Wine runner"

    tar \
        -xf "$RUNNERS_DIR/$RUNNER.tar.xz" \
        -C "$RUNNERS_DIR"

    rm -f "$RUNNERS_DIR/$RUNNER.tar.xz"

    [[ -x "$RUNNERS_DIR/$RUNNER/bin/wine" ]] ||
        die "Wine runner extraction failed"

    ok "Wine 11.12 installed"
fi


# ---------------------------------------------------------------------------
# Switch bottle to Wine 11.12
# ---------------------------------------------------------------------------

step "Configuring bottle to use $RUNNER"

if [[ ! -f "$BOTTLE_DIR/bottle.yml" ]]; then
    die "Bottle configuration not found:

$BOTTLE_DIR/bottle.yml"
fi

if grep -q "^Runner: $RUNNER\$" "$BOTTLE_DIR/bottle.yml"; then

    ok "bottle already uses $RUNNER"

else

    bcli edit \
        -b "$BOTTLE" \
        --runner "$RUNNER" || true

    if ! grep -q "^Runner: $RUNNER\$" "$BOTTLE_DIR/bottle.yml"; then
        die "failed to switch bottle to $RUNNER"
    fi

    step "Restarting Wine prefix under new runner"

    bsh "
        export WINEPREFIX='$BOTTLE_DIR'
        export PATH='$RUNNERS_DIR/$RUNNER/bin':\$PATH

        wineserver -k >/dev/null 2>&1 || true
        sleep 2

        wineboot -u >/dev/null 2>&1 || true

        wineserver -w
    "

    ok "bottle switched to $RUNNER"
fi


# ---------------------------------------------------------------------------
# Download / install AULA software
# ---------------------------------------------------------------------------

step "Installing AULA F75 software"

if [[ -f "$APP_EXE_HOST" ]]; then

    ok "AULA F75 software already installed"

else

    if [[ -f "$INSTALLER" ]]; then

        step "Using local installer"

        cp "$INSTALLER" "$INSTALLER_CACHE"

    else

        download_installer "$INSTALLER_CACHE"

    fi

    step "Running AULA installer"

    bcli run \
        -b "$BOTTLE" \
        -e "$INSTALLER_CACHE" \
        --args "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"

    step "Waiting for AULA installation to finish"

    for _ in $(seq 1 60); do
        if [[ -f "$APP_EXE_HOST" ]]; then
            break
        fi

        sleep 2
    done

    rm -f "$INSTALLER_CACHE"

    [[ -f "$APP_EXE_HOST" ]] ||
        die "AULA installation did not produce:

$APP_EXE_HOST"

    ok "AULA F75 installed"
fi


# ---------------------------------------------------------------------------
# Build HID shim
# ---------------------------------------------------------------------------

step "Building HID GetFeature length-fix shim"

gcc \
    -shared \
    -fPIC \
    -O2 \
    -o "$SHIM_SO" \
    "$SHIM_SRC" \
    -ldl

[[ -f "$SHIM_SO" ]] ||
    die "failed to build HID shim"

ok "HID shim built"


# ---------------------------------------------------------------------------
# Configure LD_PRELOAD
# ---------------------------------------------------------------------------

step "Configuring LD_PRELOAD"

if grep -q "LD_PRELOAD: $SHIM_SO" "$BOTTLE_DIR/bottle.yml"; then

    ok "LD_PRELOAD already configured"

else

    bcli edit \
        -b "$BOTTLE" \
        --env-var "LD_PRELOAD=$SHIM_SO"

    ok "LD_PRELOAD configured"
fi


# ---------------------------------------------------------------------------
# Register AULA program with Bottles
# ---------------------------------------------------------------------------

step "Registering AULA F75 program"

if bcli programs -b "$BOTTLE" 2>/dev/null |
    grep -qxF -- "- $PROGRAM_NAME"; then

    ok "program already registered"

else

    bcli add \
        -b "$BOTTLE" \
        -n "$PROGRAM_NAME" \
        -p "$APP_EXE_HOST"

    ok "program registered"
fi


# ---------------------------------------------------------------------------
# Extract icon
# ---------------------------------------------------------------------------

step "Creating AULA F75 icon"

ICON_REF="input-keyboard"
ICON_PNG="$HOME/.local/share/icons/hicolor/128x128/apps/aula-f75.png"

ICON_FILE="$APP_DIR/appico.ico"

if [[ -f "$ICON_FILE" ]]; then

    ICON_TMP="$(mktemp -d)"

    (
        cd "$ICON_TMP"

        if command -v magick >/dev/null 2>&1; then

            magick \
                "$ICON_FILE" \
                icon.png \
                >/dev/null 2>&1 || true

        elif command -v convert >/dev/null 2>&1; then

            convert \
                "$ICON_FILE" \
                icon.png \
                >/dev/null 2>&1 || true

        fi

        BEST="$(ls -S icon*.png 2>/dev/null | head -1 || true)"

        if [[ -n "$BEST" ]]; then

            mkdir -p "$(dirname "$ICON_PNG")"

            cp "$BEST" "$ICON_PNG"

        fi
    )

    rm -rf "$ICON_TMP"
fi

if [[ -f "$ICON_PNG" ]]; then
    ICON_REF="$ICON_PNG"
    ok "AULA icon installed"
else
    ok "Using keyboard icon fallback"
fi


# ---------------------------------------------------------------------------
# Desktop launcher
# ---------------------------------------------------------------------------

step "Creating desktop launcher"

DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/aula-f75.desktop"

mkdir -p "$DESKTOP_DIR"

cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=AULA F75
Comment=AULA F75 keyboard configuration software via Bottles/Wine
Exec=flatpak run --command=bottles-cli com.usebottles.bottles run -b $BOTTLE -p "$PROGRAM_NAME"
Icon=$ICON_REF
Terminal=false
Categories=Settings;HardwareSettings;Utility;
StartupWMClass=OemDrv.exe
EOF

chmod +x "$DESKTOP_FILE"

update-desktop-database \
    "$DESKTOP_DIR" \
    >/dev/null 2>&1 || true

ok "desktop launcher installed"


# ---------------------------------------------------------------------------
# Final checks
# ---------------------------------------------------------------------------

step "Running final checks"

if command -v lsusb >/dev/null 2>&1 &&
   lsusb | grep -qi "258a:010c"; then

    echo
    echo "    Keyboard detected: 258a:010c"
    echo "    AULA F75 should be ready to configure."

else

    echo
    echo "    AULA F75 keyboard was not detected."
    echo "    Connect the keyboard using USB before launching the configurator."

fi

echo
echo "============================================================"
echo " AULA F75 setup completed"
echo "============================================================"
echo
echo "Launch from your application menu:"
echo
echo "    AULA F75"
echo
echo "Or launch from terminal:"
echo
echo "    flatpak run --command=bottles-cli \\"
echo "      com.usebottles.bottles run \\"
echo "      -b \"$BOTTLE\" \\"
echo "      -p \"$PROGRAM_NAME\""
echo
echo "Bottle:"
echo "    $BOTTLE_DIR"
echo
echo "Wine runner:"
echo "    $RUNNERS_DIR/$RUNNER"
echo
echo "HID shim:"
echo "    $SHIM_SO"
echo
