# CM311-1a-YST（Armbian）蓝牙修复：RTL8761BTV 全套方案

> 硬件：CM311-1a-YST 盒子（Amlogic S905L3a），蓝牙芯片 **Realtek RTL8761BTV**（BT-only，走 UART，无 WiFi——该批次出厂就没焊 WiFi 模块）。
> 2026-09-14 首次在 .231 实测成功；2026-09-26 在 .230（生产机）复刻成功。两台盒子同配方双活。
> 配套视频盒用途：.230 跑 ScreenPhantom（scrcpy→HA 面板），.231 为实验机。

## 硬件底层事实（先懂原理再动手）

| 项目 | 内容 |
|---|---|
| 芯片 | Realtek RTL8761BTV，蓝牙 5.0，BT-only |
| 挂载方式 | 串口 `/dev/ttyAML1`（DT 的 `uart_A` = serial@24000，带 RTS/CTS），**不是 SDIO/USB** |
| 供电/复位 | GPIO **gpiochip0 line 82** 为复位脚；芯片平时断电，上电后必须先做复位脉冲才可初始化 |
| 协议 | H5 三线 UART（Realtek 私有初始化流程） |
| 固件 | `/lib/firmware/rtlbt/`，其中 `rtl8761b_fw` + `rtl8761b_config`（config 有版本坑，见下） |
| MAC | 同前缀 `2C:B0:FD:`，每颗芯片地址不同（.231=`…62:57:07`，.230=`…67:49:3C`） |

## 一、全新修复步骤（从零到 hci0 UP）

### 1. 装依赖

```bash
apt update && apt install -y bluez gpiod
```

### 2. 放固件并建软链

Armbian 的 `linux-firmware` 包自带 `/lib/firmware/rtl_bt/rtl8761b_fw.bin` 和 `rtl8761b_config.bin`，但 **rtk_hciattach 找的是 `/lib/firmware/rtlbt/`（无点号目录），且 config 必须用 `rtl8761bt_config`（81 字节那个，注意多个 t）**：

```bash
ls -la /lib/firmware/rtlbt/ | grep 8761b     # 看目录里已有什么
ls -la /lib/firmware/rtl_bt/ | grep 8761b    # 确认 linux-firmware 里有 fw

# 关键两个软链（缺一不可）：
ln -sf ../rtl_bt/rtl8761b_fw.bin /lib/firmware/rtlbt/rtl8761b_fw
ln -sf /lib/firmware/rtlbt/rtl8761bt_config /lib/firmware/rtlbt/rtl8761b_config
```

> ⚠️ **坑：config 指向 `rtl8761b_config.bin`（25 字节）时，H5 能同步、波特率能切到 1.5M，但 patch 下载中途 `retransmission exhausts` 失败。必须指 `rtl8761bt_config`（81 字节）。**

### 3. 装 rtk_hciattach

bluez 自带的 `hciattach` **不行**（会建出 hci0 但所有命令超时），必须用 Realtek 家的 rtk_hciattach：

- 来源：[ophub issue #471 附带社区编译版（aarch64）](https://github.com/ophub/amlogic-s9xxx-armbian/files/9278195/rtk_hciattach.zip)，源码 [radxa/rtkbt](https://github.com/radxa/rtkbt)
- 或直接从已修好的盒子拷：

```bash
scp root@另一台盒子:/usr/bin/rtk_hciattach /usr/bin/rtk_hciattach
chmod 755 /usr/bin/rtk_hciattach
```

### 4. 手动测试（时序是灵魂）

```bash
# 复位脉冲：拉低 1 秒再拉高（gpiod 1.6 语法），不做这步 H5 必 sync 超时
gpioset -s 1 -m time 0 82=0
gpioset 0 82=1
sleep 1

# 后台 attach，日志落盘
nohup /usr/bin/rtk_hciattach -n -s 115200 ttyAML1 rtk_h5 >/var/log/rtk_hciattach.log 2>&1 &

sleep 15 && hciconfig
# 期望：hci0 Type: UART, UP RUNNING, BD Address 2C:B0:FD:xx:xx:xx
```

### 5. 验证真的能收包

```bash
bluetoothctl --timeout 15 scan on
# 出现 [NEW] Device xx:xx… 名字 = 成功
```

## 二、写入开机自启

编辑 `/etc/custom_service/start_service.sh`（Armbian ophub 镜像开机经 rc.local 调它），**在文件末尾追加**（改前先 `cp -p` 备份）：

```bash
#bluetooth (RTL8761BTV on ttyAML1, added 2026-09-26, per .231 fix)
gpioset -s 1 -m time 0 82=0 2>/dev/null
gpioset 0 82=1 2>/dev/null
nohup /usr/bin/rtk_hciattach -n -s 115200 ttyAML1 rtk_h5 >/var/log/rtk_hciattach.log 2>&1 &
```

- `bluetooth.service` 本来就是 enabled，不用动；
- 断电冷启动没问题：每次开机都会复位芯片重新 attach；
- **不要写两遍**（我们第一版就手滑写过重复块，好在第二次 attach 无害，属无效动作）。

## 三、日常故障自救：H5 链路假死（实测高发！）

### 症状

- `hciconfig` 一切正常（`hci0 UP RUNNING`），`systemctl is-active bluetooth` = active；
- 但**任何扫描都空手而归**：bluetoothctl scan、`hcitool lescan`、`hcitool scan` 三路全无输出；
- `dmesg` 里有实锤：

```
Bluetooth: Controller acked invalid packet
Bluetooth: hci0: Peer device has reset
Bluetooth: hci0: Injecting HCI hardware error event
Bluetooth: hci0: hardware error 0x00
Bluetooth: hci0: sending frame failed (-49)
```

### 根因

RTL8761B 在 H5 三线链路上偶发内部复位，BlueZ 重同步后**命令能发、广播包收不回**——半开链路，只有物理复位（GPIO82 脉冲）能救。

### 自救（一条命令搞定）

```bash
curl -fsSL -o /usr/local/bin/bt-recover.sh https://raw.githubusercontent.com/tangshui9527/cm311-yst-bluetooth-fix/main/scripts/bt-recover.sh && chmod +x /usr/local/bin/bt-recover.sh
bt-recover.sh
```

或手动五连：

```bash
killall rtk_hciattach 2>/dev/null
gpioset -s 1 -m time 0 82=0      # 复位：拉低 1 秒
gpioset 0 82=1                    # 再拉高
sleep 1
nohup /usr/bin/rtk_hciattach -n -s 115200 ttyAML1 rtk_h5 >/var/log/rtk_hciattach.log 2>&1 &
sleep 15 && hciconfig             # 应恢复 UP RUNNING
```

> 2026-09-26 .231 实测：假死后用此流程 20 秒内恢复，立即扫到周围 6 台设备。

## 四、常用命令速查

```bash
# ── 扫描 ──
bluetoothctl --timeout 15 scan on      # LE+经典一把梭（推荐）
bluetoothctl devices                   # 列出发现/已配对设备
timeout 12 hcitool -i hci0 lescan      # 纯 LE 扫描（底层）
timeout 12 hcitool -i hci0 scan        # 经典蓝牙扫描（底层）

# ── 配对连接 ──
bluetoothctl pair <MAC>                # 配对
bluetoothctl trust <MAC>               # 信任（自动重连）
bluetoothctl connect <MAC>             # 连接
bluetoothctl info <MAC>                # 详情（电量/服务）
bluetoothctl disconnect <MAC>          # 断开
bluetoothctl remove <MAC>              # 删除配对

# ── 排障 ──
systemctl status bluetooth             # 守护进程
tail -30 /var/log/rtk_hciattach.log    # attach 初始化日志
btmon &                                # 抓 HCI 层原始命令/事件
dmesg | grep -iE 'hci0|rtk'            # 内核侧蓝牙日志
```

注意：两个 scan 同时开会报 `InProgress`，先 `scan off`。

## 五、两台盒子部署档案

| | .231（实验机） | .230（生产机） |
|---|---|---|
| 修复日期 | 2026-09-14 | 2026-09-26 |
| hci0 MAC | `2C:B0:FD:62:57:07` | `2C:B0:FD:67:49:3C` |
| 软链 | fw→`../rtl_bt/rtl8761b_fw.bin`；config→`rtl8761bt_config` | 同左（.230 出厂只带 rtl8761bt_config，fw 软链后补） |
| bluez | 已有 | 2026-09-26 `apt install bluez` 补装 |
| rtk_hciattach | ophub #471 包 | 从 .231 经工作站中转 scp |
| 自启 | start_service.sh（曾写重复块，09-26 已去重） | 追加至 start_service.sh 末尾（socat 注释保留在后） |
| 验证 | 扫描见 Apple 广播/ACTION III 音箱 | 扫描见 AIMA 电动车等 4 台 |
| 特别注意 | H5 假死高发，见第三节 | 生产机：不动 DTB、不折腾 WiFi |

## 六、明确不要做的事

- **别碰 WiFi**：DT 里的 `sprd,unisoc-wifi`（UWE5622）是 cm311/m401a/e900v22c 三兄弟机型共用 DT 继承来的，YST 批次根本没焊模块，SDIO 总线上无卡，实锤无硬件；
- **别用 bluez 自带 hciattach**：`hciattach ttyAML1 any 115200 flow` 会建出假 hci0，所有命令超时；
- **别省复位脉冲**：芯片上电处于未知态，直接 attach 必 `3-wire sync pattern resend: 40, H5 sync timed out`；
- **别刷其它型号固件**（触控等外设固件烧在面板里，错刷永久报废——这是整个 CM311 折腾系列的红线）。

## 许可

文档与脚本：MIT。rtk_hciattach 二进制来自 radxa/rtkbt（Apache-2.0）社区编译版。
