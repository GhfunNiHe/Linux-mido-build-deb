#!/bin/bash
set -e
set -o pipefail

# ==========================================
# mido-rootfs-ubuntu.sh - Ubuntu rootfs 构建脚本
# ==========================================

ROOTFS_SIZE="4G"
BOOTFS_SIZE="800M"
ROOTFS_UUID="550b96c5-23d6-419f-a377-d2e446190c15"
BOOTFS_UUID="f39c8d16-64af-42a3-bdb6-8f2d3b68d375"

declare -A UBUNTU_CODENAME
UBUNTU_CODENAME[24.04]=noble
UBUNTU_CODENAME[26.04]=resolute

if [ $# -lt 2 ] || [ $# -gt 4 ]; then
    echo "用法: $0 <ubuntu_version> <kernel_version> [username] [password]"
    echo "ubuntu_version: 24.04, 26.04"
    echo "username: 默认 redmi"
    echo "password: 默认 redmi"
    echo "示例: $0 24.04 7.0.9-r0"
    echo "示例: $0 26.04 7.0.9-r0 redmi redmi"
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 请使用 root 权限运行此脚本！"
    exit 1
fi

UBUNTU_VER=$1
KERNEL_VERSION=$2
USERNAME="${3:-redmi}"
PASSWORD="${4:-redmi}"

# 从 7.0.9-r0 提取基础版本 7.0.9，用于匹配 deb 文件名
KERNEL_BASE="${KERNEL_VERSION%-*}"

CODENAME="${UBUNTU_CODENAME[$UBUNTU_VER]}"
if [ -z "$CODENAME" ]; then
    echo "❌ 不支持的 Ubuntu 版本: $UBUNTU_VER (仅支持 24.04, 26.04)"
    exit 1
fi

echo "🐧 Ubuntu ${UBUNTU_VER} (${CODENAME}) + 内核 ${KERNEL_VERSION}"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ==========================================
# 挂载点清理
# ==========================================
cleanup_mounts() {
    echo "🧹 正在卸载挂载点..."
    local RD="rootdir-ubuntu"

    # kill 进程
    if mountpoint -q "$RD" 2>/dev/null; then
        fuser -k -9 -m "$RD" 2>/dev/null || true
        sleep 0.5
    fi

    # 逆序卸载：先子挂载后父挂载
    for mp in "$RD/boot" "$RD/dev/pts" "$RD/dev" "$RD/proc" "$RD/sys"; do
        if mountpoint -q "$mp" 2>/dev/null; then
            umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
        fi
    done

    # 最后卸载 rootdir
    if mountpoint -q "$RD" 2>/dev/null; then
        umount "$RD" 2>/dev/null || umount -l "$RD" 2>/dev/null || true
    fi

    rm -rf "$RD"
}
trap cleanup_mounts EXIT ERR INT TERM

# ==========================================
# 1. 创建镜像
# ==========================================
ROOTFS_IMG="rootfs_ubuntu-${UBUNTU_VER}_${KERNEL_VERSION}_${TIMESTAMP}.img"
BOOTFS_IMG="bootfs_ubuntu-${UBUNTU_VER}_${KERNEL_VERSION}_${TIMESTAMP}.img"

echo "💾 创建 rootfs 镜像 (${ROOTFS_SIZE})..."
truncate -s $ROOTFS_SIZE "$ROOTFS_IMG"
mkfs.ext4 -O ^metadata_csum -U "$ROOTFS_UUID" "$ROOTFS_IMG"

echo "💾 创建 bootfs 镜像 (${BOOTFS_SIZE})..."
truncate -s $BOOTFS_SIZE "$BOOTFS_IMG"
mkfs.ext2 -U "$BOOTFS_UUID" "$BOOTFS_IMG"

# ==========================================
# 2. 挂载
# ==========================================
mkdir -p rootdir-ubuntu
mount -o loop "$ROOTFS_IMG" rootdir-ubuntu

echo "⬇️  正在用 debootstrap 拉取 Ubuntu ${CODENAME} 基础系统..."
debootstrap --arch=arm64 "$CODENAME" rootdir-ubuntu https://mirrors.ustc.edu.cn/ubuntu-ports/

mount -o loop "$BOOTFS_IMG" rootdir-ubuntu/boot
mount --bind /dev rootdir-ubuntu/dev
mount --make-rslave rootdir-ubuntu/dev
mount --bind /dev/pts rootdir-ubuntu/dev/pts
mount --make-rslave rootdir-ubuntu/dev/pts
mount -t proc proc rootdir-ubuntu/proc
mount -t sysfs sys rootdir-ubuntu/sys

# DNS
rm -f rootdir-ubuntu/etc/resolv.conf
echo "nameserver 8.8.8.8" > rootdir-ubuntu/etc/resolv.conf
echo "nameserver 1.1.1.1" >> rootdir-ubuntu/etc/resolv.conf
echo "nameserver 223.5.5.5" >> rootdir-ubuntu/etc/resolv.conf

# ==========================================
# 3. 配置 apt 源
# ==========================================
echo "🔧 配置 apt 源..."
cat > rootdir-ubuntu/etc/apt/sources.list <<SOURCES
deb https://mirrors.ustc.edu.cn/ubuntu-ports ${CODENAME} main universe multiverse restricted
deb https://mirrors.ustc.edu.cn/ubuntu-ports ${CODENAME}-updates main universe multiverse restricted
deb https://mirrors.ustc.edu.cn/ubuntu-ports ${CODENAME}-security main universe multiverse restricted
SOURCES

# ==========================================
# 4. 安装基础包
# ==========================================
echo "📦 安装基础环境组件..."
chroot rootdir-ubuntu bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get update && apt-get install -y --no-install-recommends \
    sudo vim wget curl \
    network-manager openssh-server wpasupplicant \
    apt-transport-https ca-certificates \
    locales console-setup \
    micro bash-completion tmux man-db \
    bluez iio-sensor-proxy polkitd pkexec \
    chrony initramfs-tools zstd \
    python3 iptables rfkill usbutils file \
    linux-firmware alsa-ucm-conf alsa-utils \
    pipewire wireplumber \
    kmscube \
    passwd"

echo "⏱️  启用 chrony NTP 时间同步..."
chroot rootdir-ubuntu systemctl enable chrony

echo "🔧 启用基础服务..."
chroot rootdir-ubuntu systemctl enable ssh
chroot rootdir-ubuntu systemctl enable NetworkManager

# ==========================================
# 4.x WiFi 自动连接 — first-boot oneshot 服务
# nmcli 直连比静态 .nmconnection 更可靠，避免 NM 内部状态冲突
# ==========================================
echo "📶 配置 WiFi 自动连接 mido-wifi..."

cat > rootdir-ubuntu/usr/local/sbin/mido-wifi-connect <<'WIFISCRIPT'
#!/bin/bash
SSID="${1:-mido-wifi}"
MAX_WAIT=30

echo "mido-wifi: waiting for wlan0..."
for i in $(seq 1 $MAX_WAIT); do
    ip link show wlan0 >/dev/null 2>&1 && break
    sleep 1
done

if ! ip link show wlan0 >/dev/null 2>&1; then
    echo "mido-wifi: wlan0 not found after ${MAX_WAIT}s, giving up"
    exit 1
fi

echo "mido-wifi: connecting to ${SSID}..."
exec nmcli dev wifi connect "${SSID}"
WIFISCRIPT
chmod +x rootdir-ubuntu/usr/local/sbin/mido-wifi-connect

cat > rootdir-ubuntu/etc/systemd/system/mido-wifi-connect.service <<SVC
[Unit]
Description=WiFi auto-connect to mido-wifi
After=NetworkManager.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mido-wifi-connect mido-wifi
Restart=on-failure
RestartSec=5
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC

chroot rootdir-ubuntu systemctl enable mido-wifi-connect

# ==========================================
# 5. 安装 .deb 包 (内核 + 固件 + ALSA)
# ==========================================
echo "📦 注入设备专属 .deb 包 (内核版本: ${KERNEL_VERSION}, base: ${KERNEL_BASE})..."
cp "${SCRIPT_DIR}"/linux-image-${KERNEL_BASE}-msm8953+_*.deb rootdir-ubuntu/tmp/ 2>/dev/null || true
cp "${SCRIPT_DIR}"/linux-libc-dev_${KERNEL_BASE}*.deb rootdir-ubuntu/tmp/ 2>/dev/null || true
cp "${SCRIPT_DIR}"/firmware-redmi-mido.deb rootdir-ubuntu/tmp/ 2>/dev/null || true
cp "${SCRIPT_DIR}"/alsa-redmi-mido.deb rootdir-ubuntu/tmp/ 2>/dev/null || true

chroot rootdir-ubuntu bash -c "export DEBIAN_FRONTEND=noninteractive PATH=/usr/local/sbin:/usr/sbin:/sbin:\$PATH && \
    dpkg -i /tmp/linux-image-${KERNEL_BASE}-msm8953+_*.deb /tmp/linux-libc-dev_${KERNEL_BASE}*.deb /tmp/firmware-redmi-mido.deb /tmp/alsa-redmi-mido.deb && \
    apt-get install -fy"
# 跳过 dbg 包

# ==========================================
# 6. 主机名 & root 密码
# ==========================================
echo "mido-ubuntu" > rootdir-ubuntu/etc/hostname
echo "127.0.0.1 mido-ubuntu" >> rootdir-ubuntu/etc/hosts
chroot rootdir-ubuntu bash -c "export PATH=/usr/local/sbin:/usr/sbin:/sbin:\$PATH && echo 'root:1234' | chpasswd"

# ==========================================
# 7. initramfs 配置
# ==========================================

# 显示/触摸模块
cat > rootdir-ubuntu/etc/initramfs-tools/modules <<'EOF'
edt_ft5x06
goodix_ts
msm
panel_xiaomi_boe_ili9885
panel_xiaomi_ebbg_r63350
panel_xiaomi_nt35532
panel_xiaomi_otm1911
panel_xiaomi_tianma_nt35596
EOF

# firmware hook
cat > rootdir-ubuntu/etc/initramfs-tools/hooks/mido-fw <<'HOOK'
#!/bin/sh
set -x
PREREQ=""
prereqs()
{
    echo "$PREREQ"
}
case $1 in
prereqs)
    prereqs
    exit 0
    ;;
esac
. /usr/share/initramfs-tools/hook-functions
add_firmware qcom/msm8953/xiaomi/mido/a506_zap.mdt
add_firmware qcom/msm8953/xiaomi/mido/a506_zap.elf
add_firmware qcom/msm8953/xiaomi/mido/a506_zap.b00
add_firmware qcom/msm8953/xiaomi/mido/a506_zap.b01
add_firmware qcom/msm8953/xiaomi/mido/a506_zap.b02
# Adreno A530 GPU firmware (Ubuntu 的 linux-firmware 用 .zst 压缩)
# 内核 5.19+ firmware loader 自动解压，直接引用 .zst 即可
# a530_zap.mdt.zst 是 symlink → apq8096/a530_zap.mbn.zst，两个都要加
add_firmware qcom/a530_pm4.fw.zst
add_firmware qcom/a530_pfp.fw.zst
add_firmware qcom/apq8096/a530_zap.mbn.zst
add_firmware qcom/a530_zap.mdt.zst
HOOK
chmod +x rootdir-ubuntu/etc/initramfs-tools/hooks/mido-fw

echo "🔨 更新 initramfs..."
chroot rootdir-ubuntu env PATH=/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin /usr/sbin/update-initramfs -u

# ==========================================
# 8. extlinux 启动配置
# ==========================================

# 获取实际安装的内核版本
KERNEL_RELEASE=$(chroot rootdir-ubuntu bash -c "ls /boot/vmlinuz-*" 2>/dev/null | head -1 | sed 's|/boot/vmlinuz-||')
if [ -z "$KERNEL_RELEASE" ]; then
    echo "❌ 未找到 vmlinuz，内核安装失败？"
    exit 1
fi
echo "🐧 检测到内核版本: ${KERNEL_RELEASE}"

mkdir -p rootdir-ubuntu/boot/extlinux
cat > rootdir-ubuntu/boot/extlinux/extlinux.conf <<EXTLINUX
timeout 1
default Ubuntu
menu title boot prev kernel

label Ubuntu
	kernel /vmlinuz-${KERNEL_RELEASE}
	fdtdir /
	initrd /initrd.img-${KERNEL_RELEASE}
	append console=tty0 root=UUID=${ROOTFS_UUID} rw loglevel=3 splash
EXTLINUX

# 复制 dtb
echo "📋 复制 mido 设备树..."
cp rootdir-ubuntu/usr/lib/linux-image-${KERNEL_RELEASE}/qcom/*mido* rootdir-ubuntu/boot/ 2>/dev/null || true

# kernel postinst hook — 新内核安装时自动更新 dtb 和 extlinux
mkdir -p rootdir-ubuntu/etc/kernel/postinst.d
cat > rootdir-ubuntu/etc/kernel/postinst.d/mido-update-boot <<'HOOK'
#!/bin/sh
set -e

KVER=$1
BOOTDIR=/boot
EXTLINUX=${BOOTDIR}/extlinux/extlinux.conf

if [ -z "$KVER" ]; then
    echo "mido-update-boot: no kernel version argument, skipping"
    exit 1
fi

echo "mido-update-boot: updating dtb and extlinux for kernel ${KVER}"

# 复制 mido dtb
if [ -d "/usr/lib/linux-image-${KVER}/qcom" ]; then
    cp /usr/lib/linux-image-${KVER}/qcom/*mido* ${BOOTDIR}/ 2>/dev/null || true
    echo "mido-update-boot: dtb files copied"
fi

# 更新 extlinux.conf — 只替换内核/initrd 版本，保留手动改的参数
if [ -f ${EXTLINUX} ]; then
    sed -i "s|/vmlinuz-[^ ]*|/vmlinuz-${KVER}|" ${EXTLINUX}
    sed -i "s|/initrd.img-[^ ]*|/initrd.img-${KVER}|" ${EXTLINUX}
    echo "mido-update-boot: extlinux.conf kernel/initrd updated to ${KVER}"
else
    ROOT_UUID=$(findmnt -nvo UUID /)
    cat > ${EXTLINUX} <<EOF
timeout 1
default Ubuntu
menu title boot prev kernel

label Ubuntu
	kernel /vmlinuz-${KVER}
	fdtdir /
	initrd /initrd.img-${KVER}
	append console=tty0 root=UUID=${ROOT_UUID} rw loglevel=3 splash
EOF
    echo "mido-update-boot: extlinux.conf created"
fi
HOOK
chmod +x rootdir-ubuntu/etc/kernel/postinst.d/mido-update-boot

# ==========================================
# 9. fstab
# ==========================================
cat > rootdir-ubuntu/etc/fstab <<FSTAB
UUID=${BOOTFS_UUID} /boot ext2 defaults 0 2
FSTAB

# ==========================================
# 10. g_serial USB 串口
# ==========================================
cat > rootdir-ubuntu/etc/systemd/system/serial-getty@ttyGS0.service <<'UNIT'
[Unit]
Description=Serial Console Service on ttyGS0

[Service]
ExecStart=-/usr/sbin/agetty -L 115200 ttyGS0 xterm+256color
Type=idle
Restart=always
RestartSec=0

[Install]
WantedBy=multi-user.target
UNIT
chroot rootdir-ubuntu systemctl enable serial-getty@ttyGS0.service
echo g_serial >> rootdir-ubuntu/etc/modules

# ==========================================
# 11. resizefs 自动扩容
# ==========================================
cat > rootdir-ubuntu/etc/systemd/system/resizefs.service <<'UNIT'
[Unit]
Description=Expand root filesystem to fill partition
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'exec /usr/sbin/resize2fs $(findmnt -nvo SOURCE /)'
ExecStartPost=/usr/bin/systemctl disable resizefs.service
RemainAfterExit=true

[Install]
WantedBy=default.target
UNIT
chroot rootdir-ubuntu systemctl enable resizefs.service

# ==========================================
# 12. 创建用户
# ==========================================
echo "👤 创建用户 ${USERNAME}..."
chroot rootdir-ubuntu /usr/sbin/useradd -m -s /bin/bash "$USERNAME"
chroot rootdir-ubuntu bash -c "export PATH=/usr/local/sbin:/usr/sbin:/sbin:\$PATH && echo '${USERNAME}:${PASSWORD}' | chpasswd"
chroot rootdir-ubuntu /usr/sbin/usermod -aG sudo,audio,video,input,netdev,plugdev,bluetooth,render "$USERNAME"

# ==========================================
# 13. cleanup
# ==========================================
echo "🧹 清理..."
chroot rootdir-ubuntu apt-get clean
rm -f rootdir-ubuntu/tmp/*.deb
cleanup_mounts
trap - EXIT ERR INT TERM

# ==========================================
# 14. 转换 sparse + 压缩
# ==========================================
echo "🔄 转换 sparse 镜像并压缩..."

SPARSE_ROOTFS="sparse_${ROOTFS_IMG}"
SPARSE_BOOTFS="sparse_${BOOTFS_IMG}"

img2simg "$ROOTFS_IMG" "$SPARSE_ROOTFS"
img2simg "$BOOTFS_IMG" "$SPARSE_BOOTFS"

zstd -22 --ultra -T0 --long=31 "$SPARSE_ROOTFS" -o "${ROOTFS_IMG}.zst"
zstd -22 --ultra -T0 --long=31 "$SPARSE_BOOTFS" -o "${BOOTFS_IMG}.zst"

rm -f "$ROOTFS_IMG" "$SPARSE_ROOTFS" "$BOOTFS_IMG" "$SPARSE_BOOTFS"

echo ""
echo "🎉 构建完成！"
echo "  rootfs: ${ROOTFS_IMG}.zst"
echo "  bootfs: ${BOOTFS_IMG}.zst"
