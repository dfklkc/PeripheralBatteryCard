# 外设电量卡片 (PeripheralBatteryCard)

在 macOS 桌面和菜单栏查看支持的鼠标、键盘、耳机、手柄与电源设备的电量。

## 下载与安装

下载 `PeripheralBatteryCard-v1.0.1-macOS-universal.zip`，解压后将「外设电量卡片」拖入「应用程序」。从 v1.0.0 升级时退出旧版，再替换应用。 [GitHub Releases](https://github.com/dfklkc/PeripheralBatteryCard/releases/latest)

- 支持 macOS 14 及更高版本、Apple Silicon 与 Intel。
- 发行包使用临时本地签名，Apple 公证状态为未公证。`SHA256SUMS.txt` 用于验证下载文件。
- 部分 USB 或 2.4GHz 外设的电量读取需要 macOS「输入监控」权限。升级后如显示「需授权」，可从卡片打开系统设置，为当前版本重新开启权限。

## 支持的外设与协议

- **Apple 及标准蓝牙外设**：Magic Mouse / Keyboard / Trackpad、蓝牙鼠标/键盘/手柄（通过 `IOKit HID` 与 `SPBluetoothDataType`）
- **蓝牙音频与 TWS 耳机**：AirPods / AirPods Pro / Beats 等（支持左耳、右耳、充电盒独立电量显示）及单电量蓝牙耳机、音箱
- **BLE 低功耗外设**：支持标准 GATT Battery Service (`0x180F` / `0x2A19`)，包含 ZMK/QMK 蓝牙分体键盘多部件电量
- **标准 HID Power 设备 & UPS 电源**：支持 USB/HID Power Usage Page (`0x06` / `0x85`) 与 `IOPowerSources` 外接 UPS / 配件电源
- **多品牌 USB / 2.4GHz 接收器私有 HID 协议**：
  - **EVision / Telink** (`0x320F` / `0x0C45` / `0x258A` / `0x3151` 等)：VXE V87、VGN V87/V98/S99、ATK、Wobkey Rainy75、Ajazz、Akko、CHERRY 等
  - **YJX-CHIP** (`0xA8A5:0x2255` / `0xA8A4:0x2255`)：迈从 MCHOSE G7 与采用同一协议的无线鼠标。 [协议记录](https://github.com/ryan-mant/AreYouLowBattery/blob/main/docs/protocol-yjx-a8a5.md)
  - **Compx** (`0x373B` / `0x3554` / `0x248A` / `0x1915` / `0x3553` / `0x3837` 等)：VXE R1、蜻蜓 F1、Pulsar、Lamzu、Darmoshark 等
  - **Logitech HID++ 2.0** (`0x046D`)：Unifying / Logi Bolt / Lightspeed 接收器（支持多通道 `1...6`）及直连键鼠
  - **Razer 雷蛇** (`0x1532`)：90 字节 Feature Report 协议
  - **Sony PlayStation** (`0x054C`)：DualSense / DualShock 4（USB 与蓝牙被动监听）
  - **SteelSeries 赛睿** (`0x1038`)：无线鼠标与 Arctis / Nova 无线耳机
  - **Corsair 美商海盗船** (`0x1B1C`)：Bragi / Slipstream 无线协议
  - **自定义 JSON 规则**：支持在 `~/Library/Application Support/PeripheralBatteryCard/custom_protocols.json` 中免编译扩展任意新型外设

## 主要功能

- **两种桌面卡片视图**：列表卡片视图、Apple 风格圆形进度环网格视图
- **窗口层级切换**：可选择「贴靠桌面层」或「置顶悬浮」，支持毛玻璃深色/浅色主题、透明度调节、位置拖动持久化与锁定
- **最近一次读数**：每台设备显示实际电量采样时间。设备休眠或读数待确认时，最多保留 30 分钟内的上次电量。
- **设备管理与诊断**：支持右键重命名、隐藏指定设备、低电量提醒和登录时启动。诊断窗口按设备归组，展开可查看协议和接口详情。复制的诊断 JSON 采用匿名设备编号，并包含排查所需的协议字段和读数状态。

## 构建与运行

构建需要 macOS、Swift 6 和 Xcode 命令行工具。构建产物位于 `dist/`，包括通用 `.app`、ZIP 和 SHA-256 校验文件。

```bash
# 构建 .app 捆绑包
./scripts/build-app.sh

# 运行单元测试
./scripts/test.sh

# 在本机调试时输出原始 JSON 快照（含设备识别信息）
"dist/外设电量卡片.app/Contents/MacOS/PeripheralBatteryCard" --dump-json

# 启动桌面卡片应用
open "dist/外设电量卡片.app"
```

如需安装到系统 `/Applications` 目录：

```bash
./scripts/install-to-applications.sh
```
