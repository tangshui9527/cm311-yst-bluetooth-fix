#!/bin/bash
# bt-recover.sh — CM311-1a-YST (RTL8761BTV on /dev/ttyAML1) H5 链路假死自救
# 症状：hciconfig 显示 hci0 UP RUNNING，但任何扫描都收不到设备。
# 用法：直接跑 ./bt-recover.sh；需要 root。详见仓库 README 第三节。
set -u

TTY="ttyAML1"
LOG="/var/log/rtk_hciattach.log"

echo "==> [1/4] 停掉旧 attach 进程"
killall rtk_hciattach 2>/dev/null
sleep 1

echo "==> [2/4] GPIO82 复位脉冲（拉低 1 秒 → 拉高）"
gpioset -s 1 -m time 0 82=0 || { echo "gpioset 失败：请确认已安装 gpiod"; exit 1; }
gpioset 0 82=1
sleep 1

echo "==> [3/4] 重新 attach（H5, 起始波特率 115200）"
nohup /usr/bin/rtk_hciattach -n -s 115200 "$TTY" rtk_h5 >"$LOG" 2>&1 &
echo "    等待初始化（约 15 秒）..."
sleep 15

echo "==> [4/4] 验证"
if hciconfig hci0 2>/dev/null | grep -q "UP RUNNING"; then
    ADDR=$(hciconfig hci0 | grep 'BD Address' | awk '{print $3}')
    echo "✅ 蓝牙已恢复：hci0 UP RUNNING, $ADDR"
    exit 0
else
    echo "❌ 恢复失败。排查线索："
    echo "   - attach 日志: tail -30 $LOG"
    echo "   - 内核日志:   dmesg | grep -iE 'hci0|rtk' | tail -20"
    echo "   - 若日志报 retransmission exhausts，检查 rtl8761b_config 软链是否指向 rtl8761bt_config（81 字节版）"
    exit 1
fi
