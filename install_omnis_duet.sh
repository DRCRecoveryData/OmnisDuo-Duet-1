#!/bin/bash
#
# install_omnis_duet.sh
# Run AlphaTheta OMNIS-DUO (EP148) firmware on Lenovo Duet 1 (MT8183)
# running postmarketOS (Alpine/musl).
#
# Result: EP148 runs natively (aarch64, no QEMU) in a Debian chroot,
# displayed on the Duet's DSI panel via a bare X server + matchbox WM.
#
set -e

# ========================================================================
# CONFIGURATION
# ========================================================================
WORKDIR="$HOME/omnis_extract"
CHROOT="/srv/omnis-chroot"
UPD_FILE="$HOME/OMNISDUOv200.UPD"
UPD_ZIP="$HOME/OMNISDUOv200.zip"
UPD_URL="https://downloads.support.alphatheta.com/firmwares/all-in-one-dj-systems/OMNIS-DUO/OMNISDUOv200.zip"
LUKS_DEV="omnisduo"
LUKS_MNT="/mnt/omnisduo"
KEYFILE="/tmp/omnis_key.bin"
LIBDIR="$CHROOT/opt/omnis-libs"

# LUKS passphrase (90-byte ASCII from xxd -r -p, trailing newline included)
DEFAULT_FIRMWARE_KEY_HEX='3131566e6a596d6c4d4f66753341627a783561335a737357495862555239334b34424a42564f4c354b4366417a657a784f4e7979726c4e76615074643768334e0a796c2b785348744653766a705a4f474d51694d316b773d3d0a'

# Host display size (Lenovo Duet 1 panel)
PANEL_W=1920
PANEL_H=1200

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
step() { echo -e "\n${BLUE}===== $1 =====${NC}"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

# ========================================================================
# PHASE 0 — Sanity
# ========================================================================
step "Phase 0: Sanity checks"
[ "$(uname -m)" = "aarch64" ] || fail "Requires aarch64."
[ -c /dev/pts/ptmx ] && [ -w /dev/pts/ptmx ] || warn "/dev/pts/ptmx may be unusable."
[ -e /dev/mapper/control ] || fail "dm_crypt not available."
ok "Environment OK."

# ========================================================================
# PHASE 1 — Host packages (postmarketOS / Alpine)
# ========================================================================
step "Phase 1: Host packages (apk)"
sudo apk update
sudo apk add --no-cache \
    wget curl ca-certificates \
    cryptsetup p7zip unzip xxd \
    dtc patchelf file \
    debootstrap gcc make musl-dev \
    xorg-server xf86-input-libinput \
    xdotool xhost \
    matchbox-window-manager \
    mawk
ok "Host packages installed."

# ========================================================================
# PHASE 2 — Download + decrypt firmware
# ========================================================================
step "Phase 2: Downloading and extracting firmware"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

if [ ! -f OMNISDUOv200.UPD ]; then
    if [ ! -f OMNISDUOv200.zip ]; then
        if [ -f "$UPD_ZIP" ]; then cp "$UPD_ZIP" .
        elif [ -f "$UPD_FILE" ]; then cp "$UPD_FILE" .
        else
            echo "Downloading firmware (~172 MB)..."
            wget --show-progress -O OMNISDUOv200.zip "$UPD_URL"
        fi
    fi
    [ -f OMNISDUOv200.zip ] && unzip -o OMNISDUOv200.zip
fi
[ -f OMNISDUOv200.UPD ] || fail "OMNISDUOv200.UPD missing."
ok "Firmware present: $(du -h OMNISDUOv200.UPD | cut -f1)"

# LUKS passphrase
if [ ! -f "$KEYFILE" ]; then
    HEX="${FIRMWARE_KEY_HEX:-$DEFAULT_FIRMWARE_KEY_HEX}"
    echo "$HEX" | xxd -r -p > "$KEYFILE"
    ok "LUKS passphrase written ($(wc -c < "$KEYFILE") bytes)"
fi

sudo cryptsetup open OMNISDUOv200.UPD "$LUKS_DEV" --key-file "$KEYFILE" 2>/dev/null || \
    warn "LUKS may already be open."
sudo mkdir -p "$LUKS_MNT"
mountpoint -q "$LUKS_MNT" || sudo mount -o ro "/dev/mapper/$LUKS_DEV" "$LUKS_MNT"

# Extract ramdisk from FIT
mkdir -p "$WORKDIR/boot"
cd "$WORKDIR/boot"
[ -f ramdisk.img ] || sudo dumpimage -T flat_dt -p 2 -o ramdisk.img "$LUKS_MNT/images/boot.img" 2>/dev/null || {
    warn "dumpimage missing; install u-boot-tools"
    sudo apk add --no-cache u-boot-tools
    sudo dumpimage -T flat_dt -p 2 -o ramdisk.img "$LUKS_MNT/images/boot.img"
}
sudo chown "$(id -u):$(id -g)" ramdisk.img
ok "ramdisk.img ($(du -h ramdisk.img | cut -f1))"

# Unpack cpio → rootfs
if [ ! -d "$WORKDIR/rootfs/usr" ]; then
    mkdir -p "$WORKDIR/rootfs"
    cd "$WORKDIR/rootfs"
    zcat "$WORKDIR/boot/ramdisk.img" | cpio -idmv 2>&1 | tail -3
fi
ok "rootfs extracted."

sudo umount "$LUKS_MNT" 2>/dev/null || true
sudo cryptsetup luksClose "$LUKS_DEV" 2>/dev/null || true

# ========================================================================
# PHASE 3 — Build Debian trixie arm64 chroot
# ========================================================================
step "Phase 3: Building Debian trixie arm64 chroot"
sudo mkdir -p "$CHROOT"
if [ ! -f "$CHROOT/.debootstrap_complete" ]; then
    sudo debootstrap --arch=arm64 --variant=minbase \
        trixie "$CHROOT" http://deb.debian.org/debian/
    sudo touch "$CHROOT/.debootstrap_complete"
fi
ok "Chroot base installed."

# ========================================================================
# PHASE 4 — Mounts + runtime packages
# ========================================================================
step "Phase 4: Chroot mounts + runtime packages"

mount_chroot() {
    mountpoint -q "$CHROOT/dev"  || sudo mount --bind /dev  "$CHROOT/dev"
    mountpoint -q "$CHROOT/sys"  || sudo mount --bind /sys  "$CHROOT/sys"
    mountpoint -q "$CHROOT/proc" || sudo mount --bind /proc "$CHROOT/proc"
    sudo mkdir -p "$CHROOT/dev/pts"
    mountpoint -q "$CHROOT/dev/pts" || \
        sudo mount -t devpts devpts "$CHROOT/dev/pts" \
            -o newinstance,ptmxmode=0666,mode=0620,gid=5
    [ -L "$CHROOT/dev/ptmx" ] || sudo ln -sf pts/ptmx "$CHROOT/dev/ptmx"
    if [ ! -e "$CHROOT/dev/snd/seq" ]; then
        sudo mkdir -p "$CHROOT/dev/snd"
        sudo mount --bind /dev/snd "$CHROOT/dev/snd"
    fi
}
mount_chroot

sudo chroot "$CHROOT" bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        libx11-6 libxext6 libxinerama1 libxrandr2 libxfixes3 \
        libasound2t64 libfreetype6 libdrm2 libjemalloc2 \
        libmpg123-0t64 libjpeg62-turbo libcurl4t64 \
        libegl1 libgles2 libssl3t64 zlib1g libmbedtls21 \
        libstdc++6 libatomic1 libgcc-s1 \
        gcc make
'
ok "Runtime packages installed."

# ========================================================================
# PHASE 5 — Copy app + libs + helpers
# ========================================================================
step "Phase 5: Copying application into chroot"
SRC="$WORKDIR/rootfs"
sudo mkdir -p "$CHROOT/home/root" "$LIBDIR"

for d in pdj gui scripts; do
    [ -d "$SRC/home/root/$d" ] && sudo cp -av "$SRC/home/root/$d" "$CHROOT/home/root/"
done
for b in setting Startup checkBattery check_sig checklang.sh check_powersw.sh \
         decrypt_update.sh gui_image network_downloader poweroff cabhash; do
    [ -f "$SRC/home/root/$b" ] && sudo cp -av "$SRC/home/root/$b" "$CHROOT/home/root/"
done
sudo chmod +x "$CHROOT/home/root/"* 2>/dev/null || true

for lib in libsqlcipher.so libfdk-aac.so libclatc.so libbt-vendor.so \
           libanwbtsdk.so libanwbtphonebook.so libanwbtprofile.so \
           libanwbtaac.so libanwbtestack.so libanwbthcit.so libanwbtattach.so \
           libmbedtls.so libmbedx509.so libmbedcrypto.so libjpeg.so.8 \
           libeverest.so libp256m.so; do
    sudo cp -av "$SRC/usr/lib/${lib}"* "$LIBDIR/" 2>/dev/null || true
done

sudo mkdir -p "$CHROOT/usr/share/fonts/ttf"
sudo cp -av "$SRC/usr/share/fonts/ttf/"* "$CHROOT/usr/share/fonts/ttf/" 2>/dev/null || true

sudo mkdir -p "$CHROOT/home/root/settings"
for f in bluetooth_debug.json bluetooth_snk.json bluetooth_src.json wifi.json; do
    [ -f "$CHROOT/home/root/settings/$f" ] || \
        echo '{}' | sudo tee "$CHROOT/home/root/settings/$f" >/dev/null
done

echo off | sudo tee "$CHROOT/tmp/testmode" >/dev/null
ok "Application copied."

# ========================================================================
# PHASE 6 — Patch EP148 (drop libclatc.so → avoids SIGILL)
# ========================================================================
step "Phase 6: Patching EP148"
EP148="$CHROOT/home/root/pdj/EP148"
sudo cp -n "$EP148" "$EP148.orig"
sudo patchelf --remove-needed libclatc.so "$EP148"
sudo patchelf --print-needed "$EP148" | grep -q libclatc && fail "Patch failed."
ok "EP148 patched (ARMv8.2 SIGILL bypassed)."

# ========================================================================
# PHASE 7 — fw_printenv shim
# ========================================================================
step "Phase 7: fw_printenv shim"
sudo mkdir -p "$CHROOT/usr/local/bin"
sudo tee "$CHROOT/usr/local/bin/fw_printenv" << 'EOF'
#!/bin/sh
key=""
while [ $# -gt 0 ]; do
    case "$1" in
        -n) shift; key="$1" ;;
        *)  key="$1" ;;
    esac
    shift
done
case "$key" in
    hostPcAppMode)      echo "standalone" ;;
    aplstart)           echo "on" ;;
    bootcmd)            echo "run bootcmd_mmc" ;;
    boot_type)          echo "normal" ;;
    force_update)       echo "false" ;;
    enable_core_dump)   echo "disabled" ;;
    devtype)            echo "mmc" ;;
    devnum)             echo "0" ;;
    serial_number)      echo "0000000000000" ;;
    *) exit 1 ;;
esac
EOF
sudo chmod +x "$CHROOT/usr/local/bin/fw_printenv"
sudo cp "$CHROOT/usr/local/bin/fw_printenv" "$CHROOT/usr/local/bin/fw_setenv"
ok "fw_printenv shim installed."

# ========================================================================
# PHASE 8 — Launcher (bare X + matchbox + EP148)
# ========================================================================
step "Phase 8: Installing launcher"

sudo tee /usr/local/bin/omnis-duo << LAUNCHER
#!/bin/bash
# omnis-duo — Launch EP148 fullscreen on the Duet's DSI panel.
# Uses bare X :1 + matchbox so nothing minimizes or steals focus.
set -e

WORK="$CHROOT"
DISP=":1"
PANEL_W=$PANEL_W
PANEL_H=$PANEL_H

# --- stop GNOME if it's running (frees the panel) ---
if systemctl is-active --quiet gdm 2>/dev/null; then
    echo "Stopping gdm to free the display..."
    sudo systemctl stop gdm
    sleep 2
fi

# --- chroot mounts ---
for m in dev sys proc; do
    mountpoint -q "\$WORK/\$m" || sudo mount --bind "/\$m" "\$WORK/\$m"
done
sudo mkdir -p "\$WORK/dev/pts"
mountpoint -q "\$WORK/dev/pts" || \
    sudo mount -t devpts devpts "\$WORK/dev/pts" \
        -o newinstance,ptmxmode=0666,mode=0620,gid=5
[ -L "\$WORK/dev/ptmx" ] || sudo ln -sf pts/ptmx "\$WORK/dev/ptmx"
[ -e "\$WORK/dev/snd/seq" ] || {
    sudo mkdir -p "\$WORK/dev/snd"
    sudo mount --bind /dev/snd "\$WORK/dev/snd"
}

# --- start X :1 ---
if ! pgrep -f "Xorg \$DISP" >/dev/null 2>&1; then
    sudo rm -f /tmp/.X1-lock /tmp/.X11-unix/X1
    sudo /usr/bin/Xorg "\$DISP" -ac -nolisten tcp vt7 &
    sleep 4
fi

# --- X socket bind ---
sudo mkdir -p "\$WORK/tmp/.X11-unix"
mountpoint -q "\$WORK/tmp/.X11-unix" || \
    sudo mount --bind /tmp/.X11-unix "\$WORK/tmp/.X11-unix"

# --- allow local X access ---
DISPLAY="\$DISP" xhost +local: 2>/dev/null || true

# --- start matchbox ---
if ! pgrep -f matchbox >/dev/null 2>&1; then
    DISPLAY="\$DISP" matchbox-window-manager -use_titlebar no &
    sleep 2
fi

# --- prep state ---
echo off | sudo tee "\$WORK/tmp/testmode" >/dev/null
sudo rm -f "\$WORK/tmp/ep148.log"

echo "Launching EP148 on \$DISP (\${PANEL_W}x\${PANEL_H})..."
echo "Log: \$WORK/tmp/ep148.log"

# --- launch EP148 ---
sudo chroot "\$WORK" bash -c "
    export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
    export DISPLAY=\$DISP
    export HOME=/home/root
    export LD_LIBRARY_PATH=/opt/omnis-libs:/usr/local/lib:/usr/lib
    cd /home/root/pdj
    exec ./EP148 >> /tmp/ep148.log 2>&1
" &
sleep 25

# --- force fullscreen (matchbox usually does this automatically) ---
for wid in \$(DISPLAY="\$DISP" xdotool search --name "EP148" 2>/dev/null); do
    DISPLAY="\$DISP" xdotool windowmap     "\$wid" 2>/dev/null || true
    DISPLAY="\$DISP" xdotool windowsize    "\$wid" "\$PANEL_W" "\$PANEL_H" 2>/dev/null || true
    DISPLAY="\$DISP" xdotool windowmove    "\$wid" 0 0 2>/dev/null || true
    DISPLAY="\$DISP" xdotool windowraise   "\$wid" 2>/dev/null || true
    echo "Fullscreen: WID=\$wid"
done
LAUNCHER
sudo chmod +x /usr/local/bin/omnis-duo
ok "Launcher installed: /usr/local/bin/omnis-duo"

# ========================================================================
# DONE
# ========================================================================
step "Installation complete"
cat << EOF
${GREEN}Core install finished.${NC}

${YELLOW}TO RUN:${NC}
  omnis-duo

  This will:
    - Stop gdm (GNOME) to free the display
    - Start X :1 (bare X server)
    - Start matchbox WM (keeps EP148 fullscreen)
    - Launch EP148 on the Duet's panel

${YELLOW}LOG:${NC}
  $CHROOT/tmp/ep148.log

${YELLOW}WHAT WORKS:${NC}
  - EP148 renders natively (aarch64, no QEMU)
  - Fullscreen on the DSI panel via matchbox
  - Touch input through X's libinput driver
  - No GNOME minimize / focus-steal issues

${YELLOW}WHAT'S MISSING:${NC}
  - Front-panel MCU (SPI shim) → the "DISCONNECTING..." modal persists
  - Audio routing → ALSA can't find the OMNIS-DUO 4-output card

${YELLOW}LAYOUT:${NC}
  Chroot:       $CHROOT
  Private libs: $LIBDIR
  Extracted:    $WORKDIR

EOF
