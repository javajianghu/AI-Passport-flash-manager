#!/usr/bin/env python3
"""
ESP32-C3 固件管理命令行工具

提供纯命令行方式的固件导出、导入功能。

Usage:
    python3 esp32_firmware_cli.py list                    # 列出已连接设备
    python3 esp32_firmware_cli.py export [OPTIONS]        # 导出固件
    python3 esp32_firmware_cli.py import <firmware> [OPTIONS]  # 导入固件

Options:
    -p, --port PORT       指定串口设备路径
    -o, --output DIR      导出时指定输出目录 (默认: ~/Desktop)
    -y, --yes             跳过确认提示
    -h, --help            显示帮助信息
"""

import argparse
import os
import sys
import subprocess
import re
import glob
from datetime import datetime
from pathlib import Path

# esptool 路径 (优先使用系统安装的)
ESPTOOL_PATHS = [
    "/Users/tang/miniconda3/bin/esptool",  # miniconda
    "/usr/local/bin/esptool",              # homebrew
    "/opt/homebrew/bin/esptool",           # homebrew ARM
    "esptool",                             # PATH 中的 esptool
]

# 默认固件大小 (8MB for ESP32-C3)
DEFAULT_FLASH_SIZE = 0x800000


def find_esptool():
    """查找可用的 esptool 路径"""
    for path in ESPTOOL_PATHS:
        if os.path.exists(path):
            return path
        # 检查 PATH 中是否存在
        result = subprocess.run(["which", path.replace("'", "")], capture_output=True, text=True)
        if result.returncode == 0:
            return result.stdout.strip()
    return "esptool"  # 最后尝试 PATH


def find_connected_devices():
    """查找已连接的 ESP32 设备"""
    devices = []
    dev_dir = "/dev"

    if not os.path.exists(dev_dir):
        return devices

    try:
        for item in os.listdir(dev_dir):
            if item.startswith("cu.usbmodem"):
                devices.append(f"/dev/{item}")
    except OSError:
        pass

    return sorted(devices)


def get_device_info(port):
    """获取设备信息"""
    esptool = find_esptool()

    try:
        # 读取 flash_id
        result = subprocess.run(
            [esptool, "--port", port, "flash_id"],
            capture_output=True,
            text=True,
            timeout=10
        )

        info = {
            "port": port,
            "chip_type": "Unknown",
            "flash_size": "Unknown",
            "mac_address": "Unknown",
        }

        if result.returncode == 0:
            for line in result.stdout.split("\n"):
                if "Chip type:" in line:
                    match = re.search(r"Chip type:\s*(.+?)(?:\s*\(|$)", line)
                    if match:
                        info["chip_type"] = match.group(1).strip()
                elif "Flash size:" in line:
                    match = re.search(r"Flash size:\s*(\d+[A-Z]+)", line)
                    if match:
                        info["flash_size"] = match.group(1).strip()

        # 读取 MAC 地址
        mac_result = subprocess.run(
            [esptool, "--port", port, "read_mac"],
            capture_output=True,
            text=True,
            timeout=10
        )

        if mac_result.returncode == 0:
            for line in mac_result.stdout.split("\n"):
                if "MAC:" in line:
                    match = re.search(r"MAC:\s*([0-9a-f:]+)", line)
                    if match:
                        info["mac_address"] = match.group(1).strip()

        return info

    except subprocess.TimeoutExpired:
        print(f"错误: 读取设备信息超时 (端口: {port})", file=sys.stderr)
        return None
    except Exception as e:
        print(f"错误: 读取设备信息失败 ({e})", file=sys.stderr)
        return None


def export_firmware(port, output_dir, skip_confirm=False):
    """导出固件到指定目录"""
    esptool = find_esptool()

    # 获取设备信息
    print(f"正在连接设备 {port}...")
    device_info = get_device_info(port)

    if not device_info:
        return False

    mac = device_info["mac_address"].replace(":", "").lower()
    chip_type = device_info["chip_type"]

    print(f"设备信息:")
    print(f"  芯片类型: {chip_type}")
    print(f"  MAC 地址: {device_info['mac_address']}")
    print(f"  闪存大小: {device_info['flash_size']}")

    # 生成文件名
    timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
    filename = f"{mac}_{timestamp}.bin"
    output_path = os.path.join(os.path.expanduser(output_dir), filename)

    # 确保输出目录存在
    os.makedirs(os.path.expanduser(output_dir), exist_ok=True)

    # 确认
    if not skip_confirm:
        print(f"\n固件将保存到: {output_path}")
        response = input("确认导出? (y/n): ").strip().lower()
        if response != 'y':
            print("已取消")
            return False

    print(f"\n正在读取固件 ({DEFAULT_FLASH_SIZE // (1024*1024)}MB)...")

    try:
        result = subprocess.run(
            [esptool, "--port", port, "read_flash", "0x0", hex(DEFAULT_FLASH_SIZE), output_path],
            capture_output=True,
            text=True
        )

        if result.returncode == 0:
            file_size = os.path.getsize(output_path)
            print(f"\n导出成功!")
            print(f"文件: {output_path}")
            print(f"大小: {file_size / (1024*1024):.2f} MB")
            return True
        else:
            print(f"\n导出失败: {result.stderr}", file=sys.stderr)
            # 清理可能生成的不完整文件
            if os.path.exists(output_path):
                os.remove(output_path)
            return False

    except KeyboardInterrupt:
        print("\n\n已中断导出")
        if os.path.exists(output_path):
            os.remove(output_path)
        return False
    except Exception as e:
        print(f"\n导出失败: {e}", file=sys.stderr)
        return False


def import_firmware(port, firmware_path, skip_confirm=False):
    """导入固件到设备"""
    esptool = find_esptool()

    # 检查固件文件
    firmware_path = os.path.expanduser(firmware_path)
    if not os.path.exists(firmware_path):
        print(f"错误: 固件文件不存在: {firmware_path}", file=sys.stderr)
        return False

    # 获取设备信息
    print(f"正在连接设备 {port}...")
    device_info = get_device_info(port)

    if not device_info:
        return False

    chip_type = device_info["chip_type"]
    file_size = os.path.getsize(firmware_path)

    print(f"设备信息:")
    print(f"  芯片类型: {chip_type}")
    print(f"  MAC 地址: {device_info['mac_address']}")

    # 确认
    if not skip_confirm:
        print(f"\n将要刷入的固件:")
        print(f"  文件: {firmware_path}")
        print(f"  大小: {file_size / (1024*1024):.2f} MB")
        response = input("\n警告: 此操作将覆盖设备现有固件! 确认继续? (y/n): ").strip().lower()
        if response != 'y':
            print("已取消")
            return False

    print(f"\n正在写入固件 ({file_size / (1024*1024):.2f} MB)...")

    try:
        result = subprocess.run(
            [esptool, "--port", port, "write_flash", "0x0", firmware_path],
            capture_output=True,
            text=True
        )

        if result.returncode == 0:
            print("\n导入成功!")
            return True
        else:
            print(f"\n导入失败: {result.stderr}", file=sys.stderr)
            return False

    except KeyboardInterrupt:
        print("\n\n已中断导入")
        return False
    except Exception as e:
        print(f"\n导入失败: {e}", file=sys.stderr)
        return False


def list_devices():
    """列出已连接设备"""
    devices = find_connected_devices()

    if not devices:
        print("未检测到已连接的 ESP32 设备")
        print("请确保设备已通过 USB 连接")
        return

    print(f"检测到 {len(devices)} 个设备:\n")

    for port in devices:
        info = get_device_info(port)
        if info:
            print(f"端口: {port}")
            print(f"  芯片: {info['chip_type']}")
            print(f"  MAC:  {info['mac_address']}")
            print(f"  闪存: {info['flash_size']}")
        else:
            print(f"端口: {port} (无法读取信息)")
        print()


def main():
    parser = argparse.ArgumentParser(
        description="ESP32-C3 固件管理命令行工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  %(prog)s list                                    # 列出已连接设备
  %(prog)s export                                 # 导出固件 (需指定端口)
  %(prog)s export -p /dev/cu.usbmodem101          # 导出到默认目录
  %(prog)s export -p /dev/cu.usbmodem101 -o ~/fw  # 导出到指定目录
  %(prog)s import ./firmware.bin                   # 导入固件 (需指定端口)
  %(prog)s import ./firmware.bin -p /dev/cu.usbmodem101  # 指定端口导入
        """
    )

    subparsers = parser.add_subparsers(dest="command", help="可用命令")

    # list 命令
    list_parser = subparsers.add_parser("list", help="列出已连接的设备")

    # export 命令
    export_parser = subparsers.add_parser("export", help="导出设备固件")
    export_parser.add_argument("-p", "--port", help="指定串口设备路径")
    export_parser.add_argument("-o", "--output", default="~/Desktop", help="输出目录 (默认: ~/Desktop)")
    export_parser.add_argument("-y", "--yes", action="store_true", help="跳过确认提示")

    # import 命令
    import_parser = subparsers.add_parser("import", help="导入固件到设备")
    import_parser.add_argument("firmware", help="固件文件路径")
    import_parser.add_argument("-p", "--port", help="指定串口设备路径")
    import_parser.add_argument("-y", "--yes", action="store_true", help="跳过确认提示")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return 0

    if args.command == "list":
        list_devices()
        return 0

    # 获取端口
    port = getattr(args, "port", None)
    if not port:
        devices = find_connected_devices()
        if not devices:
            print("错误: 未检测到设备，请使用 -p 指定端口", file=sys.stderr)
            return 1
        if len(devices) == 1:
            port = devices[0]
        else:
            print("错误: 检测到多个设备，请使用 -p 指定端口:", file=sys.stderr)
            for d in devices:
                print(f"  {d}", file=sys.stderr)
            return 1

    # 验证端口是否存在
    if not os.path.exists(port):
        print(f"错误: 端口不存在: {port}", file=sys.stderr)
        return 1

    if args.command == "export":
        success = export_firmware(port, args.output, args.yes)
        return 0 if success else 1

    elif args.command == "import":
        success = import_firmware(port, args.firmware, args.yes)
        return 0 if success else 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
