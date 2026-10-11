#!/bin/sh
# AIC8800 wlan0 连接 WiFi 脚本
# 用法: sh connect.sh "SSID" "密码"
#       只想扫描不连接:  sh connect.sh --scan
#
# 说明: 板子上没装 iw, 所以用 wpa_cli 扫描

IF=wlan0

if [ "$1" = "--scan" ]; then
	echo "=== 扫描周边 WiFi (约 8 秒) ==="
	[ -e /sys/class/net/$IF ] || { echo "  !! $IF 不存在, 驱动没起来"; exit 1; }
	rfkill unblock wifi 2>/dev/null
	ifconfig $IF up 2>/dev/null
	killall wpa_supplicant 2>/dev/null
	sleep 1
	wpa_supplicant -Dnl80211 -i$IF -B 2>/dev/null
	sleep 3
	wpa_cli -i$IF scan 2>/dev/null
	sleep 8
	echo
	echo "=== 扫描结果 (SSID / 信号) ==="
	wpa_cli -i$IF scan_results 2>/dev/null
	exit 0
fi

SSID="$1"
PASS="$2"

if [ -z "$SSID" ]; then
	echo "用法: sh $0 \"SSID\" \"密码\""
	echo "      sh $0 --scan"
	exit 1
fi

echo "=============================================="
echo " 1. 检查 wlan0"
echo "=============================================="
if [ ! -e /sys/class/net/$IF ]; then
	echo "  !! $IF 不存在。请先: sh install.sh"
	exit 1
fi
echo "  $IF 存在"

echo
echo "=============================================="
echo " 2. rfkill 解锁 + 拉起接口"
echo "=============================================="
rfkill list 2>/dev/null | head -10
rfkill unblock wifi 2>/dev/null && echo "  rfkill unblock wifi"
rfkill unblock all  2>/dev/null
ifconfig $IF up 2>/dev/null && echo "  ifconfig $IF up"

echo
echo "=============================================="
echo " 3. 生成配置并启动 wpa_supplicant"
echo "=============================================="
CONF=/userdata/wpa.conf
wpa_passphrase "$SSID" "$PASS" > "$CONF" 2>/dev/null
if [ ! -s "$CONF" ]; then
	echo "  !! wpa_passphrase 不可用, 手写配置"
	cat > "$CONF" <<EOF
network={
	ssid="$SSID"
	psk="$PASS"
}
EOF
fi
echo "  配置: $CONF"

killall wpa_supplicant 2>/dev/null
sleep 1
wpa_supplicant -Dnl80211 -i$IF -c "$CONF" -B
if [ $? -ne 0 ]; then
	echo "  !! wpa_supplicant 启动失败"
	exit 1
fi
echo "  wpa_supplicant 已启动"

echo
echo "=============================================="
echo " 4. 等待关联 (最多 30 秒)"
echo "=============================================="
i=0
while [ $i -lt 30 ]; do
	i=$((i+1))
	ST=$(wpa_cli -i$IF status 2>/dev/null | sed -n 's/^wpa_state=//p')
	case "$ST" in
		COMPLETED)
			echo "  [${i}s] 关联成功 (wpa_state=COMPLETED)"
			break
			;;
		*)
			[ $((i % 5)) -eq 0 ] && echo "  [${i}s] wpa_state=$ST"
			;;
	esac
	sleep 1
done

echo
echo "--- wpa_cli status ---"
wpa_cli -i$IF status 2>/dev/null

echo
echo "=============================================="
echo " 5. 获取 IP (udhcpc)"
echo "=============================================="
udhcpc -i $IF -n -q -t 8 2>/dev/null
echo

echo "--- ifconfig $IF ---"
ifconfig $IF 2>/dev/null

echo
echo "=============================================="
echo " 6. 连通性测试"
echo "=============================================="
GW=$(ip route 2>/dev/null | sed -n 's/^default via \([0-9.]*\).*/\1/p' | head -1)
[ -z "$GW" ] && GW=$(route -n 2>/dev/null | sed -n 's/^0\.0\.0\.0  *\([0-9.]*\).*/\1/p' | head -1)
echo "  默认网关: ${GW:-未获取到}"

if [ -n "$GW" ]; then
	echo "  ping 网关:"
	ping -c 3 -W 2 "$GW" 2>/dev/null | tail -4
fi

echo "  ping 8.8.8.8:"
ping -c 3 -W 2 8.8.8.8 2>/dev/null | tail -4

echo
echo "=============================================="
if ifconfig $IF 2>/dev/null | grep -q "inet addr\|inet "; then
	echo " 完成! wlan0 已获得 IP"
else
	echo " 还没拿到 IP, 请把以上输出贴回"
fi
echo "=============================================="
