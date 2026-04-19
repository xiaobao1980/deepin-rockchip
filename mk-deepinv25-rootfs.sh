#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 检查是否以 root 运行
if [ "$(id -u)" -ne 0 ]; then 
    log_error "This script must be run as root!"
    log_error "Current user: $(whoami), UID: $(id -u)"
    log_error "Please run: sudo $0"
    exit 1
fi

# 可配置变量
dist_version="crimson"
dist_name="deepin"
TARGET_USER="darkmoon"  # 统一使用变量，避免硬编码
TARGET_HOSTNAME="darkmoon"

TARGET_ROOTFS_DIR="./rootfs/${dist_name}-${dist_version}"

# 检查 rootfs 目录
if [ ! -d "$TARGET_ROOTFS_DIR" ]; then
    log_error "$TARGET_ROOTFS_DIR does not exist!"
    log_error "Please run mk-base-rootfs.sh first to create the base rootfs."
    exit 1
fi

# 检查并创建 packages 目录
if [ ! -d "./packages" ]; then
    log_warn "./packages directory does not exist!"
    log_info "Creating empty packages directory..."
    mkdir -p ./packages/boot ./packages/rga2 ./packages/mpp ./packages/gst-rkmpp
fi

# 复制必要文件
log_info "Copying essential files..."
[ -f "/etc/resolv.conf" ] && cp -L /etc/resolv.conf "$TARGET_ROOTFS_DIR/etc/resolv.conf"
[ -f "/usr/bin/qemu-aarch64-static" ] && cp /usr/bin/qemu-aarch64-static "$TARGET_ROOTFS_DIR/usr/bin/"
cp -rpf ./packages "$TARGET_ROOTFS_DIR/"

# 安全挂载函数
safe_mount() {
    local src=$1 dst=$2 type=${3:-} opts=${4:-}
    
    if mountpoint -q "$dst" 2>/dev/null; then
        log_warn "Already mounted: $dst"
        return 0
    fi
    
    if [ -n "$type" ]; then
        mount -t "$type" "$src" "$dst"
    elif [ -n "$opts" ]; then
        mount -o "$opts" "$src" "$dst"
    else
        mount "$src" "$dst"
    fi
    log_info "Mounted: $dst"
}

log_info "Setting up chroot environment..."

safe_mount proc "$TARGET_ROOTFS_DIR/proc" proc ""
safe_mount sysfs "$TARGET_ROOTFS_DIR/sys" sysfs ""
safe_mount /dev "$TARGET_ROOTFS_DIR/dev" "" "bind"
safe_mount /dev/pts "$TARGET_ROOTFS_DIR/dev/pts" "" "bind"

# 创建必要的运行时目录
mkdir -p "$TARGET_ROOTFS_DIR/run/dbus"
mkdir -p "$TARGET_ROOTFS_DIR/run/systemd"

# 清理函数
cleanup() {
    local exit_code=$?
    log_info "Cleaning up mounts..."
    
    # 逆序卸载
    local mounts=("$TARGET_ROOTFS_DIR/dev/pts" "$TARGET_ROOTFS_DIR/dev" "$TARGET_ROOTFS_DIR/sys" "$TARGET_ROOTFS_DIR/proc")
    for mp in "${mounts[@]}"; do
        if mountpoint -q "$mp" 2>/dev/null; then
            umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || log_warn "Failed to unmount $mp"
        fi
    done
    
    exit $exit_code
}

trap cleanup EXIT

log_info "Entering chroot..."

# 传递变量到 chroot
export TARGET_USER TARGET_HOSTNAME

cat <<'CHROOT_EOF' | chroot "$TARGET_ROOTFS_DIR" /bin/bash

set -e

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export TARGET_USER="${TARGET_USER:-darkmoon}"
export TARGET_HOSTNAME="${TARGET_HOSTNAME:-darkmoon}"

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }

log_info "Updating package lists..."
apt-get -y update

APT_INSTALL="apt-get install -fy --allow-downgrades --no-install-recommends"

# 安装 Qt5 依赖
log_info "Installing Qt5 dependencies..."
$APT_INSTALL libqt5concurrent5 libqt5core5a libqt5gui5 libqt5network5 libqt5widgets5 || true

# 安装本地 deb 包函数
install_local_debs() {
    local dir=$1
    local name=${2:-$dir}
    
    if [ ! -d "$dir" ]; then
        log_warn "Directory $dir not found"
        return 0
    fi
    
    local debs=()
    for f in "$dir"/*.deb; do
        [ -f "$f" ] && debs+=("$f")
    done
    
    [ ${#debs[@]} -eq 0 ] && { log_warn "No .deb files in $dir"; return 0; }
    
    log_info "Installing ${#debs[@]} packages from $name..."
    
    # 跳过 armbian-firmware
    local install_debs=()
    for deb in "${debs[@]}"; do
        case "$deb" in
            *armbian-firmware*)
                log_warn "Skipping $deb (conflicts with linux-firmware)"
                ;;
            *) install_debs+=("$deb") ;;
        esac
    done
    
    [ ${#install_debs[@]} -gt 0 ] && dpkg -i "${install_debs[@]}" 2>&1 | grep -v "Failed to connect to bus" || true
    $APT_INSTALL || true
}

# 安装 packages 下的 deb 包
install_local_debs "/packages" "main packages"

# 安装 DDE 桌面环境
log_info "Installing DDE desktop environment..."
$APT_INSTALL \
    deepin-desktop-environment-core \
    deepin-desktop-environment-base \
    deepin-desktop-environment-cli \
    deepin-desktop-environment-extras \
    firefox \
    fastfetch \
    gparted || true

# 启用显示管理器
systemctl enable lightdm 2>/dev/null || log_warn "Failed to enable lightdm"

# 安装 Rockchip 相关包
install_local_debs "/packages/rga2" "RGA2"
install_local_debs "/packages/mpp" "MPP"
install_local_debs "/packages/gst-rkmpp" "GStreamer MPP"

# 创建用户
if ! id "$TARGET_USER" >/dev/null 2>&1; then
    log_info "Creating user: $TARGET_USER"
    
    # 确保 sudo 组存在
    getent group sudo >/dev/null || groupadd sudo
    
    useradd -G sudo -m -s /bin/bash "$TARGET_USER"
    
    # 设置密码（交互式更安全，但这里保持自动）
    echo "$TARGET_USER:$TARGET_USER" | chpasswd
    
    # 添加到常用组
    usermod -aG video,audio,plugdev,users "$TARGET_USER" 2>/dev/null || true
else
    log_warn "User $TARGET_USER already exists"
fi

# 设置 root 密码
echo "root:root" | chpasswd

# 配置 sudo（安全方式）
if [ -d "/etc/sudoers.d" ]; then
    echo "$TARGET_USER ALL=(ALL:ALL) NOPASSWD: ALL" > "/etc/sudoers.d/99-$TARGET_USER"
    chmod 440 "/etc/sudoers.d/99-$TARGET_USER"
else
    # 确保 /etc/sudoers 以换行结束
    [ -n "$(tail -c1 /etc/sudoers)" ] && echo "" >> /etc/sudoers
    echo "$TARGET_USER ALL=(ALL:ALL) ALL" >> /etc/sudoers
fi

# 设置主机名
echo "$TARGET_HOSTNAME" > /etc/hostname

# 配置 hosts
cat > /etc/hosts << EOF
127.0.0.1   localhost
127.0.1.1   $TARGET_HOSTNAME

# The following lines are desirable for IPv6 capable hosts
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

# 设置时区
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

# 配置 locale
if command -v locale-gen >/dev/null 2>&1; then
    locale-gen C.UTF-8 zh_CN.UTF-8 en_US.UTF-8 || true
else
    log_warn "locale-gen not found, installing locales..."
    apt-get install -y locales || true
    locale-gen C.UTF-8 zh_CN.UTF-8 en_US.UTF-8 || true
fi

dpkg-reconfigure -f noninteractive locales 2>/dev/null || true

# 清理
log_info "Cleaning up..."

# 禁用历史记录
cat > /etc/profile.d/disable-history.sh << 'EOF'
# Disable bash history for privacy
export HISTSIZE=0
export HISTFILESIZE=0
export HISTCONTROL=ignoreboth
EOF

# 清理文件
rm -f /root/.bash_history /home/*/.bash_history 2>/dev/null || true
rm -rf /packages/ /tmp/* /var/tmp/* /root/.cache /home/*/.cache 2>/dev/null || true
find /var/log -type f -exec sh -c '> {}' \; 2>/dev/null || true

apt-get autoremove -y 2>/dev/null || true
apt-get clean

log_info "Chroot configuration completed!"

CHROOT_EOF

log_info "Rootfs build completed successfully!"
log_info "Output: $TARGET_ROOTFS_DIR"
