#!/bin/bash
# ESP32Firmware DMG 构建脚本
# 用法: ./build-dmg.sh [Debug|Release]

set -e

# 配置
SCHEME="ESP32Firmware"
APP_NAME="ESP32固件管理"
CONFIGURATION="${1:-Release}"
XCODEGEN_CMD="xcodegen"
DMG_FILENAME="ESP32固件管理.dmg"
BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)/build"
SRC_DIR="$BUILD_DIR/dmg_src"
TEMP_DMG="$BUILD_DIR/temp.dmg"
FINAL_DMG="$BUILD_DIR/$DMG_FILENAME"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查 XcodeGen
if ! command -v $XCODEGEN_CMD &> /dev/null; then
    log_error "XcodeGen 未安装，请先运行: brew install xcodegen"
    exit 1
fi

# 检查 Xcode 开发者目录
if ! xcodebuild -version &> /dev/null; then
    log_error "Xcode 未正确配置，请运行: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
fi

# 进入项目目录
cd "$(dirname "$0")/.."

# 创建 build 目录
mkdir -p "$BUILD_DIR"

# 生成 Xcode 项目（如需要）
if [ ! -f "ESP32Firmware.xcodeproj" ] || [ "project.yml" -nt "ESP32Firmware.xcodeproj" ]; then
    log_info "生成 Xcode 项目..."
    $XCODEGEN_CMD generate
fi

# 清理旧构建
log_info "清理旧构建..."
xcodebuild clean -scheme "$SCHEME" -configuration "$CONFIGURATION" > /dev/null 2>&1 || true

# 构建项目
log_info "构建项目 ($CONFIGURATION)..."
xcodebuild -scheme "$SCHEME" -configuration "$CONFIGURATION" build

# 查找构建产物
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/"$SCHEME"-*/Build/Products/"$CONFIGURATION" -name "*.app" -type d 2>/dev/null | head -1)

if [ -z "$APP_PATH" ]; then
    log_error "未找到构建产物"
    exit 1
fi

log_info "构建产物: $APP_PATH"

# 创建 DMG 源码目录
log_info "创建 DMG 结构..."
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"

# 复制 app 到 DMG 源目录
cp -R "$APP_PATH" "$SRC_DIR/"

# 创建 Applications 符号链接
ln -sf /Applications "$SRC_DIR/Applications"

# 创建 DMG
log_info "创建 DMG 安装包..."
rm -f "$TEMP_DMG" "$FINAL_DMG"

# 使用 UDZO 格式创建压缩 DMG
hdiutil create -volname "$APP_NAME" -srcfolder "$SRC_DIR" -ov -format UDZO -quiet "$TEMP_DMG"

# 移动到最终位置
mv "$TEMP_DMG" "$FINAL_DMG"

# 清理
rm -rf "$SRC_DIR"

# 完成
DMG_SIZE=$(ls -lh "$FINAL_DMG" | awk '{print $5}')
log_info "完成！"
echo ""
echo "========================================"
echo " DMG 安装包: $FINAL_DMG"
echo " 大小: $DMG_SIZE"
echo "========================================"
echo ""
echo "安装步骤:"
echo "  1. 双击打开 DMG 文件"
echo "  2. 将 $APP_NAME 拖拽到 Applications 文件夹"
echo "  3. 首次运行在系统设置中允许运行"
