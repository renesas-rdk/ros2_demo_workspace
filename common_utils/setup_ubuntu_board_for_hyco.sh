#!/bin/bash
# =============================================================================
# setup_ubuntu_board_for_hyco.sh — prepare an Ubuntu 24.04 V4H2 board so that REACTION's
# `action: app` works with a original SDK
#
# Run FROM THE HOST:  ./setup_ubuntu_board_for_hyco.sh <board-ip> [user] [password]
# Idempotent — safe to re-run, and required after every rootfs rollback.
#
# It does two things:
#   1. symlink /home/root -> /home/<user>   (the SDK hardcodes /home/root/app_temp)
#   2. stage the aarch64 libraries Ubuntu lacks, in two layers:
#        ~/app_temp/          <- on the SDK's own LD_LIBRARY_PATH; WINS; full poky chain
#        /opt/rcar-app-libs/  <- via ld.so.conf.d; fallback when app_temp is wiped
# =============================================================================

# Target board: R-Car/V4H

set -euo pipefail

HOST="${1:?Usage: $0 <board-ip> [user] [password]}"
USER_="${2:-ubuntu}"
PASS="${3:-ubuntu}"

XOS_ROOT="${RCAR_XOS_PATH:-/opt/rcar-xos}"
IMAGE_REPO="reaction/tvm-app-linux-v4h2-cpu"
STAGE="/tmp/rcar-app-libs"

SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# --- Resolve the SDK version -------------------------------------------------
# The SDK always installs under /opt/rcar-xos/<version>. Pick the newest install
[ -d "$XOS_ROOT" ] || { echo "ERROR: $XOS_ROOT does not exist. Please install the xOS SDK1 first." >&2; exit 1; }

if [ -n "${XOS_VERSION:-}" ]; then
    VER="$XOS_VERSION"
else
    VER=$(
        shopt -s nullglob
        for d in "$XOS_ROOT"/*/; do
            [ -d "$d/tools/toolchains/poky/sysroots/cortexa76-poky-linux" ] && basename "$d"
        done | sort -V | tail -1
    )
fi
[ -n "$VER" ] || { echo "ERROR: no R-Car XOS install with a poky sysroot under $XOS_ROOT" >&2; exit 1; }

XOS="$XOS_ROOT/$VER"
POKY="$XOS/tools/toolchains/poky/sysroots/cortexa76-poky-linux/usr/lib"
[ -d "$POKY" ] || { echo "ERROR: poky sysroot not found: $POKY" >&2; exit 1; }

# The REACTION docker image is tagged with the same version (docker.py builds the
# tag as <repo>-<device>-<compute>:<version><user>, so match on the prefix).
IMAGE=$(docker images --format '{{.Repository}}:{{.Tag}}' \
        | grep "^${IMAGE_REPO}:${VER}" | head -1 || true)
if [ -z "$IMAGE" ]; then
    IMAGE=$(docker images --format '{{.Repository}}:{{.Tag}}' \
            | grep "^${IMAGE_REPO}:" | sort -V | tail -1 || true)
    [ -n "$IMAGE" ] || { echo "ERROR: no $IMAGE_REPO image found; build REACTION first" >&2; exit 1; }
    echo "    WARNING: no image tagged $VER — falling back to $IMAGE"
fi

echo "==> SDK $VER   ($XOS)"
echo "    image $IMAGE"

echo "==> [0/3] Collecting aarch64 libraries on the host"
rm -rf "$STAGE"; mkdir -p "$STAGE"

# OpenCV 4.9 (SONAME .409) comes from REACTION's own app docker image.
trap 'docker rm -f "rcarlibs_$$" >/dev/null 2>&1 || true' EXIT
docker create --name "rcarlibs_$$" "$IMAGE" >/dev/null
for l in libopencv_imgcodecs libopencv_imgproc libopencv_core; do
    docker cp "rcarlibs_$$:/opt/cross-compile-lib/$l.so.4.9.0" "$STAGE/"
    ln -sf "$l.so.4.9.0" "$STAGE/$l.so.409"
done
docker rm "rcarlibs_$$" >/dev/null
trap - EXIT

# OpenCV's dependency chain, from the poky sysroot.
for l in libjpeg.so.62 libtbb.so.12 libtiff.so.6 libwebp.so.7 libpng16.so.16 \
         libz.so.1 liblzma.so.5 libzstd.so.1 libsharpyuv.so.0; do
    real=$(readlink -f "$POKY/$l" 2>/dev/null) || continue
    [ -f "$real" ] || continue
    cp -n "$real" "$STAGE/" 2>/dev/null || true
    ln -sf "$(basename "$real")" "$STAGE/$l"
done
echo "    $(ls "$STAGE" | wc -l) files, $(du -sh "$STAGE" | cut -f1)"

echo "==> [1/3] Uploading libraries to $USER_@$HOST"
# Transfer with libs with tar
tar -C "$(dirname "$STAGE")" -czf - "$(basename "$STAGE")" \
  | $SSH "$USER_@$HOST" 'rm -rf /tmp/rcar-app-libs && tar -C /tmp -xzf -'

echo "==> [2/3] Configuring the board"
$SSH "$USER_@$HOST" "PASS='$PASS' bash -s" <<'REMOTE'
set -euo pipefail
U=$(whoami); H="/home/$U"
sudo_() { echo "$PASS" | sudo -S "$@" 2>/dev/null; }

# --- 1. symlink /home/root -> $H
# The SDK mixes two path styles in one deploy: mkdir and `cd app_temp` are
# RELATIVE to the SSH user's home, while sftp.put and chmod are ABSOLUTE
# /home/root/... The symlink makes both resolve to the same directory. It also
# covers reaction/artihelper_app/utils.py (/home/root/artihelper_app_temp).
if [ ! -e /home/root ]; then sudo_ ln -s "$H" /home/root; fi
echo "    /home/root -> $(readlink -f /home/root)"

# --- 2a. primary layer: ~/app_temp (the SDK exports LD_LIBRARY_PATH here, so it WINS)
mkdir -p "$H/app_temp"
cp -a /tmp/rcar-app-libs/. "$H/app_temp/"

# --- 2b. fallback layer: /opt/rcar-app-libs via ld.so.conf.d
# NOTE: ld.so.conf.d only FILLS GAPS — it never overrides a system library.
# (Measured: libtbb.so.12 still resolves to /lib/aarch64-linux-gnu.) So this is
# only a safety net for a wiped app_temp; it cannot replace layer 2a.
sudo_ rm -rf /opt/rcar-app-libs
sudo_ cp -a /tmp/rcar-app-libs /opt/rcar-app-libs
sudo_ bash -c 'echo /opt/rcar-app-libs > /etc/ld.so.conf.d/rcar-app.conf; ldconfig'
echo "    app_temp: $(ls "$H/app_temp" | wc -l) files | ldconfig: $(ldconfig -p | grep -c 'rcar-app-libs') entries"
REMOTE

echo "==> [3/3] Checking"
$SSH "$USER_@$HOST" '
  ok=1
  [ -L /home/root ] || { echo "    FAIL: /home/root symlink missing"; ok=0; }
  [ -f /opt/rcar-app-libs/libopencv_core.so.409 ] || { echo "    FAIL: fallback libraries missing"; ok=0; }
  [ -f ~/app_temp/libopencv_core.so.409 ] || { echo "    FAIL: libraries missing from app_temp"; ok=0; }
  [ $ok = 1 ] && echo "    OK — board is ready for action: app"'
