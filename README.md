# ESP32-C3 固件管理工具

一款 macOS 原生应用，用于 ESP32-C3 设备的固件导出、导入和备份管理。

## 功能特性

- **固件导出**: 读取设备完整固件（按探测到的实际 flash 容量，默认 8MB）并保存为镜像文件
- **固件导入**: 将固件镜像刷入设备；文件超过设备 flash 容量时，若超出部分全为擦除态（0xFF）则自动截断后写入，否则拒绝写入以保证安全
- **固件管理**: 展示已导出固件列表，支持导入和删除
- **固件广场**: 内嵌网页访问固件下载
- **网页版工具**: 浏览器中直接刷写固件，无需安装 Python（见下文「网页版」）

## 系统要求

- macOS 13.0 (Ventura) 或更高版本
- Python 3.x
- esptool.py (`pip3 install esptool`)

## 安装

1. 确保已安装 XcodeGen:
   ```bash
   brew install xcodegen
   ```

2. 安装 Python 依赖:
   ```bash
   pip3 install esptool
   ```

3. 生成 Xcode 项目:
   ```bash
   cd ESP32Firmware
   xcodegen generate
   ```

4. 用 Xcode 打开 `ESP32Firmware.xcodeproj`，编译运行

## 使用说明

### 连接设备

使用 USB 线连接 ESP32-C3 设备到 Mac。应用会自动检测并显示设备信息。

### 图形界面操作

#### 导出固件

1. 确保设备已连接
2. 点击「导出当前固件」按钮
3. 固件将保存到备份目录，文件名为 `{MAC}_{时间戳}.bin`

#### 导入固件

1. 从固件列表中选择要导入的固件
2. 点击「导入」按钮
3. 根据提示选择是否先备份当前固件
4. 等待固件写入完成

### 命令行操作

本工具也提供纯命令行接口，适合自动化脚本或远程操作：

```bash
# 列出已连接的设备
python3 esp32_firmware_cli.py list

# 导出固件 (自动检测单设备)
python3 esp32_firmware_cli.py export -p /dev/cu.usbmodem101

# 导出固件到指定目录
python3 esp32_firmware_cli.py export -p /dev/cu.usbmodem101 -o ~/firmware

# 跳过确认提示
python3 esp32_firmware_cli.py export -p /dev/cu.usbmodem101 -y

# 导入固件
python3 esp32_firmware_cli.py import ./firmware.bin -p /dev/cu.usbmodem101

# 导入固件 (跳过确认)
python3 esp32_firmware_cli.py import ./firmware.bin -p /dev/cu.usbmodem101 -y
```

**参数说明：**
- `-p, --port PORT` - 指定串口设备路径
- `-o, --output DIR` - 导出时指定输出目录 (默认: ~/Desktop)
- `-y, --yes` - 跳过所有确认提示

**命令行模式会自动检测 esptool 安装位置，支持：**
- miniconda 安装路径
- homebrew 安装路径
- 系统 PATH 中的 esptool

### flash 容量自适应与安全截断

工具不再固定读写 8MB，而是通过 `esptool flash-id` 探测设备真实 flash 容量：

- **导出**：按探测到的实际容量读取；探测失败时退回 8MB 并给出警告。
  固定读 8MB 会在小容量设备上读到地址回卷的无效数据。
- **导入**：固件文件超过设备真实容量时，检查超出部分是否全为 0xFF（擦除态）：
  - 全为 0xFF：截断为设备容量后写入（避免 esptool 的
    "doesn't fit in the available flash" 报错）；
  - 含非 0xFF 数据：拒绝写入，提示确认固件与设备是否匹配。

### 网页版工具

`esp32_firmware_web.html` 是一个零依赖的单文件网页，基于 Web Serial API
在浏览器内完成 ESP32 固件的擦除、写入与读取，无需安装 Python 或 esptool。

使用方法：用 Chrome/Edge 打开该文件，点击连接设备，授权串口访问后即可操作。
（要求浏览器支持 Web Serial，macOS 上 Chrome/Edge 均可。）

### 设备独占

ESP32 串口同一时刻只能被一个 esptool 进程独占。App 与命令行工具共用同一把跨进程锁
（`~/Library/Caches/cn.folotoy.ESP32Firmware/locks/`），因此：

- App 正在导出/导入时，命令行工具会提示「设备正忙」并退出，不会破坏正在进行的操作；
- 命令行工具正在操作时，App 的按钮会自动禁用；
- 导入前的备份与固件写入在同一次独占内完成，中途不会被其它进程插入。

App 与 CLI 同时操作同一台设备是安全的，无需手动协调。

### 固件广场

访问固件广场下载其他固件版本（需要设备连接）。

## 配置

在「设置」页面可以修改：
- 备份目录位置
- 导入时是否提示备份

## 文件命名

导出的固件文件名格式: `{MAC}_{时间戳}.bin`

例如: `4c11ae308664_20261020120000.bin`

- MAC 地址去除冒号并转为小写
- 时间戳格式: `yyyyMMddHHmmss`

## 技术栈

- SwiftUI - 界面框架
- Python + esptool.py - 设备通信
- XcodeGen - 项目生成
- Swift Package Manager - 依赖管理

## 目录结构

```
ESP32-manager/
├── docs/                      # 设计文档
├── ESP32Firmware/             # Swift 应用
│   ├── Sources/
│   │   ├── App/               # 应用入口
│   │   ├── Views/             # 界面
│   │   ├── ViewModels/        # 视图模型
│   │   ├── Services/          # 服务层
│   │   └── Models/            # 数据模型
│   ├── Resources/             # 资源文件
│   └── project.yml            # XcodeGen 配置
├── esp32_firmware_cli.py      # 命令行工具
├── esp32_firmware_web.html    # 网页版刷写工具 (Web Serial)
└── README.md
```

## License

MIT
