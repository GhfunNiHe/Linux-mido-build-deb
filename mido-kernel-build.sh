#!/bin/bash
set -e
set -o pipefail

# ==========================================
# 1. 参数
# ==========================================
if [ $# -lt 1 ]; then
    echo "用法: $0 <kernel_version>"
    echo "示例: $0 7.0.9-r0"
    exit 1
fi

KERNEL_VERSION="$1"
KERNEL_TAG="v${KERNEL_VERSION}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "🔧 内核版本: ${KERNEL_VERSION} (标签: ${KERNEL_TAG})"

# ==========================================
# 2. 工具链配置
# ==========================================
export CCACHE_DIR="$HOME/.ccache"
export CCACHE_MAXSIZE="10G"
export CCACHE_SLOPPINESS="file_macro,locale,time_macros"
export CCACHE_NOHASHDIR="true"
mkdir -p "$CCACHE_DIR"

export ARCH="arm64"
export CC="ccache clang"
export LLVM=1
# ==========================================
# 3. 内核配置文件
# ==========================================
KCONFIG="${SCRIPT_DIR}/config-msm8953-${KERNEL_VERSION}.aarch64"
if [ ! -f "${KCONFIG}" ]; then
    echo "❌ 未找到内核配置文件: ${KCONFIG}"
    exit 1
fi
echo "📋 内核配置: ${KCONFIG}"

# ==========================================
# 4. 拉取内核源码
# ==========================================
echo "📥 克隆内核源码 (标签: ${KERNEL_TAG})..."
git clone https://github.com/msm8953-mainline/linux.git --branch "${KERNEL_TAG}" --depth 1 "${SCRIPT_DIR}/linux"
cd "${SCRIPT_DIR}/linux"

# ==========================================
# 5. 配置
# ==========================================
cp "${KCONFIG}" .config
./scripts/config --disable LTO_NONE --enable LTO_CLANG_THIN
make ARCH=arm64 olddefconfig
echo "✅ 配置补全完成"

# ==========================================
# 6. 编译 & 生成 deb 包
# ==========================================
# linux 6.12 起需要 libssl-dev:arm64 构建 kernel-headers，通过
# DEB_BUILD_PROFILES=nokernelheaders 跳过 headers 规避（ref: e2c3182）
# DPKG_FLAGS=-d 跳过构建依赖检查，兼容非 Debian 发行版（Arch/CachyOS 等）
_kernel_version="$(make kernelrelease -s)"
echo "📦 编译并生成 deb 包..."
make -j"$(nproc)" CC="ccache clang" LLVM=1 DEB_BUILD_PROFILES=pkg.linux-upstream.nokernelheaders DPKG_FLAGS="-d" bindeb-pkg

cd "${SCRIPT_DIR}"

# ==========================================
# 7. 编译 lk2nd
# ==========================================

echo "📥 克隆 lk2nd 源码..."
git clone https://github.com/msm8916-mainline/lk2nd.git --depth 1 "${SCRIPT_DIR}/lk2nd"
cd "${SCRIPT_DIR}/lk2nd"

# --- EDT 版本 (默认触摸屏) ---
echo "🔨 编译 lk2nd (EDT 触摸屏)..."
make TOOLCHAIN_PREFIX=arm-none-eabi- lk2nd-msm8953
mv build-lk2nd-msm8953/lk2nd.img "${SCRIPT_DIR}/lk2nd-edt.img"
echo "✅ lk2nd-edt.img"

# --- Goodix 版本 ---
echo "🔨 编译 lk2nd (Goodix 触摸屏)..."
sed -i 's/touchscreen-compatible = "edt,edt-ft5406";/touchscreen-compatible = "goodix,gt917d";/g' lk2nd/device/dts/msm8953/msm8953-xiaomi-common.dts
make TOOLCHAIN_PREFIX=arm-none-eabi- lk2nd-msm8953
mv build-lk2nd-msm8953/lk2nd.img "${SCRIPT_DIR}/lk2nd-goodix.img"
echo "✅ lk2nd-goodix.img"

cd "${SCRIPT_DIR}"

# ==========================================
# 8. 打包固件
# ==========================================
echo "📦 打包固件..."
dpkg-deb --build --root-owner-group -Zzstd -z10 "${SCRIPT_DIR}/firmware-redmi-mido"
dpkg-deb --build --root-owner-group -Zzstd -z10 "${SCRIPT_DIR}/alsa-redmi-mido"

echo "🎉 构建完成"
