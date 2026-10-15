# OMNIS-DUO on Lenovo Duet 1

Run AlphaTheta's **OMNIS-DUO v2.00** DJ application (`EP148`) on a
**Lenovo Duet 1** (MediaTek MT8183, ARM Cortex-A73/A53) running
**postmarketOS** (Alpine/musl). The DJ UI renders **natively** at full
speed — no QEMU, no emulation — inside a Debian aarch64 chroot, on a
bare X server with matchbox as the window manager.

The result is a **standalone OMNIS-DUO on tablet hardware**.

---

## Status

| Feature | State |
|---|---|
| Native aarch64 execution of EP148 | ✅ No QEMU |
| UI renders fullscreen on DSI panel | ✅ |
| Touch input | ✅ via X libinput |
| No GNOME minimize / focus steal | ✅ bare X + matchbox |
| Front-panel MCU (SubCpu / SPI) | ❌ Missing → "DISCONNECTING..." modal |
| Audio | ⚠️ ALSA can't find the 4-output card |
| Streaming (Beatport/TIDAL/Apple) | ❌ Needs certs + licence |
| Bluetooth | ❌ No Silex chip |

---

## Hardware

- **Lenovo Duet 1** (MT8183, 4 GB RAM, 64 GB eMMC)
- **postmarketOS** installed on the Duet
- 10.1" 1920×1200 panel with FT5x06-class touch (works)
- Optional: USB keyboard for shell access
- Optional: USB-C hub / Ethernet

---

## Why this works (briefly)

The OMNIS-DUO is a **Rockchip RK3566** device running a **Linux 4.19
BSP**. Its firmware cannot boot on the MT8183. But the **user
application** `EP148` is a JUCE app that only uses generic Linux APIs:

- X11 (`libX11`, `libXext`)
- ALSA (`libasound`)
- EGL/GLES2 (`libEGL`, `libGLESv2`)
- Standard C++/glibc

The **only** Rockchip-specific dependency is `libclatc.so` (castLabs
DRM) which contains ARMv8.2 LSE instructions the MT8183's Cortex-A73
cannot execute. Removing it via `patchelf --remove-needed` fixes the
SIGILL crash and the app runs natively.

The install pipeline:

1. **Decrypt** the vendor `.UPD` (LUKS1, AES-XTS-Plain64)
2. **Extract** the FIT image → ramdisk → cpio rootfs
3. **Chroot** into a clean Debian trixie aarch64 base
4. **Copy** EP148 + private libs + fonts into the chroot
5. **Patch** EP148 to drop `libclatc.so`
6. **Shim** `fw_printenv` for the U-Boot env (which doesn't exist on the Duet)
7. **Run** a bare X :1 + matchbox, launch EP148 fullscreen

---

## Requirements

- Lenovo Duet 1 running postmarketOS (any recent release)
- ~4 GB free disk space
- Internet connection (for firmware + apt/apk packages)
- **The firmware LUKS passphrase** (the hex string supplied to you)

---

## Install

```bash
chmod +x install_omnis_duet.sh
./install_omnis_duet.sh
```

Runs in ~15 minutes. What it does:

1. `apk add` all host tools (Xorg, matchbox, cryptsetup, debootstrap, etc.)
2. Download `OMNISDUOv200.zip` from AlphaTheta (~172 MB)
3. `cryptsetup luksOpen` the UPD with the built-in key
4. `dumpimage` to extract `ramdisk.img` from `boot.img`
5. `zcat | cpio` to unpack the rootfs
6. `debootstrap` a Debian trixie arm64 chroot
7. Install the runtime libs in the chroot
8. Copy EP148, its private libs, fonts, and helper scripts
9. Patch EP148 (`patchelf --remove-needed libclatc.so`)
10. Install `fw_printenv` shim
11. Install `/usr/local/bin/omnis-duo` launcher

---

## Run

```bash
omnis-duo
```

This launcher:

1. Stops `gdm` if it's running (frees the display)
2. Ensures the chroot's `/dev`, `/sys`, `/proc`, `/dev/pts`, `/dev/snd` are mounted
3. Starts **X :1** (a bare X server — no GNOME)
4. Starts **matchbox** on `:1` (maximizes everything, no minimize)
5. Launches `EP148` inside the chroot with the right env vars
6. Forces the window to 1920×1200 at position 0,0

To kill everything:

```bash
sudo pkill -9 -f EP148
sudo pkill -9 -f matchbox
sudo pkill -9 Xorg
sudo systemctl start gdm    # bring GNOME back
```

---

## What you'll see

- The OMNIS-DUO UI takes over the DSI panel — full screen.
- The "DISCONNECTING…" modal appears (SubCpu shim work is deferred).
- All errors about `SubCpu::writeData`, `VsyncTime`, and network state
  files are **non-fatal** — they flood `/tmp/ep148.log` but do not
  affect the UI.
- The app runs indefinitely; only the modal blocks the underlying
  main view.

---

## File layout

| Path | Purpose |
|---|---|
| `/srv/omnis-chroot` | Debian aarch64 chroot |
| `/srv/omnis-chroot/home/root/pdj/EP148` | The DJ application |
| `/srv/omnis-chroot/opt/omnis-libs/` | Private shared libraries |
| `/srv/omnis-chroot/tmp/ep148.log` | App log |
| `/usr/local/bin/omnis-duo` | Launcher |
| `~/omnis_extract` | Extracted firmware + rootfs |

---

## Troubleshooting

### "Cannot open display :1"

X :1 died. Restart:

```bash
sudo rm -f /tmp/.X1-lock /tmp/.X11-unix/X1
sudo /usr/bin/Xorg :1 -ac -nolisten tcp vt7 &
sleep 4
```

### EP148 window not fullscreen

GNOME's compositor may still be holding the panel. Make sure gdm is stopped:

```bash
sudo systemctl stop gdm
pgrep -a Xorg           # should show /usr/libexec/Xorg (X :1), not Xorg :0
```

### Log floods the terminal

Launch EP148 with output redirected:

```bash
... exec ./EP148 >> /tmp/ep148.log 2>&1
```

The launcher does this automatically.

### "DISCONNECTING..." modal

This is the SubCpu ship-mode signal. Fix requires an LD_PRELOAD shim
that fakes the SPI device (`/dev/subucom_spi3.0`). Same approach as
the Pi 4 port.

### Audio fails with "hw:1,0 not available"

ALSA can't find the 4-output OMNIS-DUO codec. Options:

1. Add a USB audio interface with ≥2 stereo outputs
2. Create `/srv/omnis-chroot/etc/asound.conf` routing to PulseAudio
3. Accept that audio is unavailable for now

### Reboot restores GNOME

That's intentional. Run `omnis-duo` when you want the DJ UI,
`systemctl start gdm` when you want GNOME.

---

## Uninstall

```bash
sudo rm -rf /srv/omnis-chroot
sudo rm -f /usr/local/bin/omnis-duo
sudo rm -rf ~/omnis_extract
sudo apk del matchbox-window-manager xorg-server xf86-input-libinput
```

GNOME is restored automatically the next time gdm starts.

---

## Legal

This project is for personal experimentation. The OMNIS-DUO firmware
and the `EP148` application are AlphaTheta Corporation's property.
Redistribution of the firmware or the DJ binary is prohibited.

---

## Credits

Port built iteratively from `install_omnis_duet.sh` sessions.
Special thanks to the postmarketOS community for the MT8183 support
and to the MPC-LiveXplore project for the chroot + shim approach
template.
