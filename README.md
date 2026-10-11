# AIC8800 USB WiFi Driver for Linux

An out-of-tree Linux driver for USB WiFi 6 adapters based on Aicsemi
**AIC8800** chips.

| | |
|---|---|
| Driver version | RWNX 6.4.3.0 |
| Verified on | Linux 6.1.99, ARMv7 (32-bit), Rockchip RK3506 |

**Supported chips** (detected automatically from the USB PID):
AIC8800, AIC8801, AIC8800DC, AIC8800DW, AIC8800D41, AIC8800D80 / D81,
AIC8800D81X2, AIC8800D89X2, plus several Tenda and OEM branded variants.

## Repository layout

```
.
|-- driver/aic8800/           kernel module source
|   |-- Makefile              top level entry point (make / make install)
|   |-- Kconfig
|   |-- aic_load_fw/          firmware downloader  -> aic_load_fw.ko
|   `-- aic8800_fdrv/         main WiFi driver      -> aic8800_fdrv.ko
|-- firmware/                 firmware blobs, loaded at runtime (not compiled in)
|   |-- aic8800DC/            DC / DW chips
|   `-- aic8800D80/           D80 / D81 chips
|-- tools/
|   |-- install.sh            on-target: firmware + modules + mode switch
|   |-- connect.sh            on-target: scan / connect to an access point
|   `-- aic.rules             udev rule for the U-disk mode switch (optional)
`-- README.md
```

## Requirements

The kernel must provide cfg80211 / mac80211 and USB support:

```
CONFIG_CFG80211=y          (or m)
CONFIG_MAC80211=y          (or m)
CONFIG_USB=y
CONFIG_WIRELESS_EXT=y      optional, needed for the private ioctl interface
CONFIG_WEXT_PRIV=y         optional, same
```

Note: on Rockchip kernels, enabling `CONFIG_WL_ROCKCHIP` already selects all of
the above, so no extra kernel configuration is required.

## Building

Native build against the running kernel:

```sh
make -C driver/aic8800
```

Cross compile (ARM 32-bit shown):

```sh
make -C driver/aic8800 \
     ARCH=arm \
     CROSS_COMPILE=arm-linux-gnueabihf- \
     KDIR=/path/to/linux-6.1
```

Passing `ARCH`, `CROSS_COMPILE` and `KDIR` on the command line is the supported
way to cross compile; they override whatever the Makefiles default to.

| Variable | Default | Meaning |
|---|---|---|
| `KDIR` | `/lib/modules/$(uname -r)/build` | kernel source / build directory |
| `ARCH` | host architecture (auto-detected) | target architecture |
| `CROSS_COMPILE` | empty | cross toolchain prefix, including the trailing `-` |
| `KVER` | `uname -r` | used by `make install` |
| `MODDESTDIR` | `/lib/modules/$(KVER)/kernel/drivers/net/wireless/aic8800` | `make install` destination |

Output:

```
driver/aic8800/aic_load_fw/aic_load_fw.ko
driver/aic8800/aic8800_fdrv/aic8800_fdrv.ko
```

Other targets: `make install`, `make uninstall`, `make clean`.

## Firmware

The firmware blobs are in `firmware/`. They are loaded by the driver at runtime,
not compiled in. Copy the matching subdirectory to `/lib/firmware` on the target:

```
/lib/firmware/aic8800DC/      DC / DW chips
/lib/firmware/aic8800D80/     D80 / D81 chips
```

The directory and file names are fixed: the driver looks them up by name.

The base directory is selected in `aic_load_fw/aicbluetooth.c` by the
`CONFIG_PLATFORM_UBUNTU` macro. When defined it uses `/lib/firmware`, otherwise
`/vendor/etc/firmware`. The macro name is a vendor leftover and has nothing to do
with the distribution; it is defined by default in the Makefile. If you need a
different path, change the C code rather than just deleting the flag.

## On-target helpers (`tools/`)

### tools/install.sh

Run this **on the target board** after a power cycle or replug:

```sh
cd tools
sh install.sh
```

What it does:

1. Makes the firmware visible at `/lib/firmware`. If the root filesystem is
   read-only (common on embedded squashfs images), it copies the firmware to a
   writable location (`/userdata/aic8800-fw` by default) and bind-mounts that
   over `/lib/firmware`.
2. Loads `aic_load_fw.ko` first and `aic8800_fdrv.ko` second. The order matters,
   because `aic8800_fdrv` depends on symbols exported by `aic_load_fw`.
3. Finds the adapter's block device by matching the SCSI vendor string `AIC`, so
   it will not eject an unrelated USB disk. It unmounts its partitions and runs
   `eject` to switch the adapter from U-disk mode to WiFi mode.
4. Waits up to 70 seconds for the driver to bind and for `wlan0` to appear, then
   prints a summary (`dmesg`, interfaces, bound drivers).

The script locates `firmware/` and `ko/` either next to itself or one level up,
so the firmware in this repository is found automatically. The built modules
still have to be placed in a `ko/` directory:

```
.
|-- tools/install.sh
|-- firmware/            aic8800DC/, aic8800D80/
`-- ko/                  aic_load_fw.ko, aic8800_fdrv.ko
```

Use `sh install.sh remove` to unload the modules and drop the bind mount.

### tools/connect.sh

Run this **on the target board** once `wlan0` exists:

```sh
sh connect.sh --scan              # list nearby access points
sh connect.sh "MySSID" "MyPass"   # associate and get an IP address
```

It unblocks rfkill, brings `wlan0` up, generates a `wpa_supplicant` configuration
(written to `/userdata/wpa.conf`, since the root filesystem may be read-only),
starts `wpa_supplicant`, waits for `wpa_state=COMPLETED`, then obtains an address
with `udhcpc` and runs a connectivity check.

Target-side requirements: `wpa_supplicant`, `wpa_passphrase`, `wpa_cli`, `eject`,
and busybox `ifconfig` / `udhcpc`. There is no `iw` dependency; scanning is done
through `wpa_cli`.

## Manual equivalent

```sh
# 1. build
make -C driver/aic8800 ARCH=arm CROSS_COMPILE=<prefix> KDIR=<kernel>

# 2. copy the modules and the firmware to the board, then on the board:

# 3. firmware
mkdir -p /userdata/aic8800-fw
cp -r firmware/aic8800DC firmware/aic8800D80 /userdata/aic8800-fw/
mount --bind /userdata/aic8800-fw /lib/firmware
ls /lib/firmware/aic8800DC | head        # must list files

# 4. modules (order matters)
insmod ko/aic_load_fw.ko
insmod ko/aic8800_fdrv.ko

# 5. switch the adapter out of U-disk mode
for b in /sys/block/sd*; do
    echo "/dev/$(basename $b) vendor=$(cat $b/device/vendor)"
done
eject /dev/sdX                           # the one with vendor=AIC

# 6. connect
wpa_passphrase "MySSID" "MyPass" > /tmp/wpa.conf
rfkill unblock wifi
ifconfig wlan0 up
wpa_supplicant -Dnl80211 -iwlan0 -c /tmp/wpa.conf -B
udhcpc -i wlan0
```

## Notes and known issues

* **`CONFIG_WERROR=y` breaks the build.** `aic8800_fdrv/aicwf_usb.c:2571` has a
  `printk` with a missing argument, which the kernel turns into an error. Either
  build with `make KCFLAGS=-Wno-error ...` or fix the line by appending
  `, __func__`.
* **The Makefiles still contain vendor paths.** The `CONFIG_PLATFORM_ROCKCHIP` /
  `ALLWINNER` / `AMLOGIC` / `HI` branches hardcode paths from the original
  author's build machines, and force `ARCH=arm64` plus `-DANDROID_PLATFORM`. They
  are inactive by default; always pass `KDIR`, `ARCH` and `CROSS_COMPILE`
  explicitly.
* **U-disk mode is not persistent.** Many AIC8800 adapters enumerate first as a
  USB mass storage device (`a69c:5721`, SCSI name `AIC flash`). The `eject`
  switches them to WiFi mode for the current session only; after a power cycle or
  replug you have to do it again. Because of this, the firmware and the modules
  must already be in place *before* the eject.
* **Re-enumeration can be flaky.** `device descriptor read error -110 / -71` and
  `usb usbN-portM: attempt power cycle` are common right after the switch.
  Retrying usually succeeds.
* **`EXTRA_CFLAGS` is deprecated.** `aic8800_fdrv/Makefile` still uses it;
  switching to `ccflags-y` is recommended.
* **`CONFIG_PLATFORM_HI` does not affect `aic_load_fw`.** The source contains
  `#ifdef CONFIG_PLATFORM_HI` in `aic_load_fw`, but the Makefile never defines the
  macro for that module. This was left as-is to preserve the original behaviour.

## Verified environment

| | |
|---|---|
| Kernel | Linux 6.1.99 (Rockchip BSP) |
| Architecture | ARMv7 (32-bit), thumb2, preempt |
| Toolchain | gcc-arm-10.3-2021.07 (`arm-none-linux-gnueabihf-`) |
| Board | Rockchip RK3506 / OK3506-S, buildroot + NAND/UBI |
| Adapter | AIC8800DC (Tenda OEM), `a69c:5721` to `2604:0014` |

Result: `wlan0` created, DHCP address obtained, `ping 8.8.8.8` with 0% loss.
