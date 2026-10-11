#!/bin/sh
# AIC8800 最后一步：固件就位 -> eject 切模式 -> 等驱动自动绑定 -> 报告
#
# 关键: 固件必须在 eject 之前就位!
#       模块最好也已经加载(已在运行的模块会在设备切到 2604:xxxx 时自动绑定)
#
# 用法: 板子上 sh install.sh

FW_DST=/lib/firmware
FW_WORK=/userdata/aic8800-fw
HERE="$(cd "$(dirname "$0")" && pwd)"

# 找到部署包根目录 (兼容脚本与 firmware/ ko/ 不在同一层的情况)
BASE="$HERE"
if [ ! -d "$BASE/firmware" ] && [ ! -d "$BASE/ko" ]; then
	for c in "$HERE/.." /userdata/MyLinuxDrivers/aic8800-deploy \
	         /userdata/aic8800-deploy /root/aic8800-deploy; do
		[ -d "$c" ] || continue
		if [ -d "$c/firmware" ] || [ -d "$c/ko" ]; then
			BASE="$(cd "$c" && pwd)"
			break
		fi
	done
fi
echo "部署包根目录: $BASE"
[ -d "$BASE/firmware" ] && echo "  firmware/ 找到" || echo "  !! firmware/ 未找到"
[ -d "$BASE/ko" ]       && echo "  ko/ 找到"       || echo "  !! ko/ 未找到"

DISK_PIDS="5721 5723 5725 5726 5727 572a 5730"
WIFI_PIDS="8800 8801 88dc 88dd 8d41 8d81 8d91 8d99 88df 88e0 88e1 88e2 88e3 88e5 8d80 8d40 8d90 0013 0014 001f 0020 0023 0024"

pid_mode() {
	for p in $DISK_PIDS; do [ "$1" = "$p" ] && { echo disk; return; }; done
	for p in $WIFI_PIDS; do [ "$1" = "$p" ] && { echo wifi; return; }; done
	echo unknown
}

scan_aic() {
	for d in /sys/bus/usb/devices/*/; do
		[ -f "$d/idVendor" ] || continue
		V=$(cat "$d/idVendor" 2>/dev/null)
		case "$V" in
			a69c|2604|368b) ;;
			*) continue ;;
		esac
		echo "$V $(cat "$d/idProduct" 2>/dev/null) $(basename "$d")"
	done
}

# 列出所有 sd 块设备身份, 避免误 eject 硬盘盒/U盘
list_sd() {
	for b in /sys/block/sd*; do
		[ -e "$b" ] || continue
		printf "    /dev/%-5s vendor=%-10s model=%s\n" "$(basename "$b")" \
			"$(cat "$b/device/vendor" 2>/dev/null)" \
			"$(cat "$b/device/model" 2>/dev/null)"
	done
}

# 找出 AIC 网卡对应的块设备 (靠 SCSI vendor 字符串)
find_aic_blockdev() {
	for b in /sys/block/sd*; do
		[ -e "$b" ] || continue
		V=$(cat "$b/device/vendor" 2>/dev/null)
		case "$V" in
			*AIC*|*aic*) echo "/dev/$(basename "$b")"; return ;;
		esac
	done
}

# ---------------- 1. 固件 ----------------
echo "=============================================="
echo " 1. 固件检查"
echo "=============================================="
if [ ! -d "$FW_DST/aic8800DC" ] && [ ! -d "$FW_DST/aic8800D80" ]; then
	if [ -d "$FW_WORK/aic8800DC" ]; then
		echo "  bind mount $FW_WORK -> $FW_DST"
		mount --bind "$FW_WORK" "$FW_DST" 2>/dev/null || \
			mount -o bind "$FW_WORK" "$FW_DST" 2>/dev/null
	else
		echo "  在 $FW_DST 下准备固件..."
		mkdir -p "$FW_WORK" 2>/dev/null
		if [ -d "$BASE/firmware" ]; then
			cp -r "$BASE/firmware/aic8800DC" "$FW_WORK/" 2>/dev/null
			cp -r "$BASE/firmware/aic8800D80" "$FW_WORK/" 2>/dev/null
			mount --bind "$FW_WORK" "$FW_DST" 2>/dev/null || \
				mount -o bind "$FW_WORK" "$FW_DST" 2>/dev/null
		else
			echo "  !! 找不到固件, 请手动:"
			echo "     mkdir -p $FW_WORK"
			echo "     cp -r <deploy>/firmware/aic8800DC $FW_WORK/"
			echo "     mount --bind $FW_WORK $FW_DST"
			exit 1
		fi
	fi
fi
for c in aic8800DC aic8800D80; do
	[ -d "$FW_DST/$c" ] && echo "  OK   $FW_DST/$c ($(ls "$FW_DST/$c" | wc -l) 个文件)" \
	                    || echo "  缺失 $FW_DST/$c"
done

# ---------------- 2. 模块 ----------------
echo
echo "=============================================="
echo " 2. 驱动模块"
echo "=============================================="
if grep -q "^aic_load_fw" /proc/modules 2>/dev/null; then
	echo "  aic_load_fw   已加载"
else
	echo "  aic_load_fw   未加载, 现在加载"
	insmod "$BASE/ko/aic_load_fw.ko" 2>/dev/null || \
		insmod /userdata/MyLinuxDrivers/aic8800-deploy/ko/aic_load_fw.ko
fi
if grep -q "^aic8800_fdrv" /proc/modules 2>/dev/null; then
	echo "  aic8800_fdrv  已加载"
else
	echo "  aic8800_fdrv  未加载, 现在加载"
	insmod "$BASE/ko/aic8800_fdrv.ko" 2>/dev/null || \
		insmod /userdata/MyLinuxDrivers/aic8800-deploy/ko/aic8800_fdrv.ko
fi

# ---------------- 3. 当前状态 ----------------
echo
echo "=============================================="
echo " 3. 网卡当前状态"
echo "=============================================="
INFO=$(scan_aic)
if [ -z "$INFO" ]; then
	echo "  没有发现 AIC 网卡 (vid a69c/2604/368b)"
	echo "  请把网卡插到板子 USB-A 口后重跑本脚本"
	exit 1
fi
echo "$INFO" | while read V P B; do
	echo "  $B : $V:$P  ->  $(pid_mode $P) 模式"
done

CURPID=$(echo "$INFO" | head -1 | awk '{print $2}')
CURMODE=$(pid_mode "$CURPID")

# ---------------- 4. eject ----------------
echo
echo "=============================================="
echo " 4. 模式切换"
echo "=============================================="
if [ "$CURMODE" = "disk" ]; then
	echo "  当前块设备:"
	list_sd

	AICDEV=$(find_aic_blockdev)
	if [ -n "$AICDEV" ]; then
		echo "  -> AIC 网卡对应的块设备: $AICDEV"
	else
		echo "  -> !! 没找到 vendor=AIC 的块设备"
		echo "     如果你的网卡就是 U盘模式, 请手动指定, 例如: eject /dev/sdX"
		exit 1
	fi

	# 卸载该设备的所有分区
	for part in "$AICDEV" "$AICDEV"1 "$AICDEV"2 "$AICDEV"3; do
		[ -b "$part" ] || continue
		mount 2>/dev/null | grep -q "$part" && { echo "  umount $part"; umount "$part" 2>/dev/null; }
	done

	if eject "$AICDEV" 2>/dev/null; then
		echo "  eject $AICDEV 成功"
	else
		# 整盘不行就试分区
		OK=0
		for part in "$AICDEV"1 "$AICDEV"2; do
			[ -b "$part" ] || continue
			if eject "$part" 2>/dev/null; then
				echo "  eject $part 成功"
				OK=1
				break
			fi
		done
		[ "$OK" = "0" ] && { echo "  !! eject 失败"; exit 1; }
	fi
	echo "  等待切换 + 驱动绑定 + 固件下载..."
else
	echo "  已经是 $CURMODE 模式, 不需要 eject"
fi

# ---------------- 5. 等待并观察 ----------------
echo
echo "=============================================="
echo " 5. 监控 70 秒"
echo "=============================================="
i=0
while [ $i -lt 70 ]; do
	i=$((i+1))
	if [ -e /sys/class/net/wlan0 ]; then
		echo "  [${i}s] >>> wlan0 出现了!"
		break
	fi
	if [ $((i % 10)) -eq 0 ]; then
		N=$(scan_aic)
		echo "  [${i}s] AIC 设备: ${N:-（暂时不在总线上）}"
	fi
	sleep 1
done

# ---------------- 6. 报告 ----------------
echo
echo "=============================================="
echo " 6. 结果"
echo "=============================================="
echo "--- 模块绑定 ---"
for drv in aic_load_fw aic8800_fdrv; do
	n=$(ls -l /sys/bus/usb/drivers/$drv/ 2>/dev/null | grep -c "^l")
	echo "  $drv: 绑定 $n 个接口"
done
echo
echo "--- 网卡 ---"
scan_aic | while read V P B; do echo "  $B : $V:$P ($(pid_mode $P))"; done
echo
echo "--- /sys/class/net ---"
ls /sys/class/net/
echo
echo "--- ifconfig -a ---"
ifconfig -a 2>/dev/null | grep -E "^[a-zA-Z]|ether|HWaddr"
echo
echo "--- dmesg (aic/rwnx/固件) ---"
dmesg 2>/dev/null | grep -i -E "aic|rwnx|firmware|wrong size|request" | tail -30
echo
echo "--- dmesg 最后 20 行 ---"
dmesg 2>/dev/null | tail -20

echo
if [ -e /sys/class/net/wlan0 ]; then
	echo "##############################################"
	echo " 成功! wlan0 已创建"
	echo "##############################################"
	echo " 连接 WiFi:"
	echo "   wpa_passphrase \"SSID\" \"密码\" > /tmp/wpa.conf"
	echo "   wpa_supplicant -Dnl80211 -iwlan0 -c /tmp/wpa.conf -B"
	echo "   udhcpc -i wlan0"
else
	echo "##############################################"
	echo " 还没有 wlan0, 请把以上输出贴回"
	echo "##############################################"
fi
