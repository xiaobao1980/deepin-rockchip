#!/bin/bash -e

# 检查是否以 root 运行
if [ "$(id -u)" -ne 0 ]; then 
    echo "Error: This script must be run as root!"
    echo "Current user: $(whoami), UID: $(id -u)"
    echo "Please run: sudo ./mk-deepinv25-rootfs.sh"
    exit 1
fi

dist_version="crimson"
dist_name="deepin"

TARGET_ROOTFS_DIR=./rootfs/$dist_name-$dist_version

# 检查 rootfs 目录是否存在
if [ ! -d "$TARGET_ROOTFS_DIR" ]; then
    echo "Error: $TARGET_ROOTFS_DIR does not exist!"
    echo "Please run mk-base-rootfs.sh first to create the base rootfs."
    exit 1
fi

# 检查 packages 目录是否存在
if [ ! -d "./packages" ]; then
    echo "Warning: ./packages directory does not exist!"
    echo "Creating empty packages directory..."
    mkdir -p ./packages/boot ./packages/rga2 ./packages/mpp ./packages/gst-rkmpp
fi

cp -b /etc/resolv.conf $TARGET_ROOTFS_DIR/etc/resolv.conf
cp -b /usr/bin/qemu-aarch64-static $TARGET_ROOTFS_DIR/usr/bin/
cp -rpf ./packages $TARGET_ROOTFS_DIR/

echo "Change root...................."

mount -t proc /proc $TARGET_ROOTFS_DIR/proc
mount -t sysfs /sys $TARGET_ROOTFS_DIR/sys
mount -o bind /dev $TARGET_ROOTFS_DIR/dev
mount -o bind /dev/pts $TARGET_ROOTFS_DIR/dev/pts

# 创建必要的运行时目录
mkdir -p $TARGET_ROOTFS_DIR/run/dbus
mkdir -p $TARGET_ROOTFS_DIR/run/systemd

cleanup() {
    echo "Cleaning up mounts..."
    umount $TARGET_ROOTFS_DIR/proc 2>/dev/null || umount -l $TARGET_ROOTFS_DIR/proc 2>/dev/null || true
    umount $TARGET_ROOTFS_DIR/sys 2>/dev/null || umount -l $TARGET_ROOTFS_DIR/sys 2>/dev/null || true
    umount $TARGET_ROOTFS_DIR/dev/pts 2>/dev/null || umount -l $TARGET_ROOTFS_DIR/dev/pts 2>/dev/null || true
    umount $TARGET_ROOTFS_DIR/dev 2>/dev/null || umount -l $TARGET_ROOTFS_DIR/dev 2>/dev/null || true
}

# 设置 trap，确保脚本退出时清理挂载点
trap cleanup EXIT

cat <<'CHROOT_EOF' | chroot $TARGET_ROOTFS_DIR/

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

apt -y update

APT_INSTALL="apt install -fy --allow-downgrades --no-install-recommends"

# 安装 spark-store 的依赖（Qt5 相关）
echo "Installing Qt5 dependencies for spark-store..."
$APT_INSTALL libqt5concurrent5 libqt5core5a libqt5gui5 libqt5network5 libqt5widgets5 || true

# 安装 packages 根目录下的所有 deb 包（Armbian 内核、固件等）
if [ -d "/packages" ]; then
    # 检查是否有 deb 文件
    has_debs=0
    for f in /packages/*.deb; do
        [ -f "$f" ] && has_debs=1 && break
    done

    if [ "$has_debs" -eq 1 ]; then
        echo "Installing Armbian packages from /packages..."
        for pkg in /packages/*.deb; do
            [ -f "$pkg" ] || continue

            # 跳过与 linux-firmware 冲突的 armbian-firmware
            case "$pkg" in
                *armbian-firmware*)
                    echo "Skipping $pkg (conflicts with linux-firmware)"
                    continue
                    ;;
            esac

            echo "Installing: $pkg"
            dpkg -i "$pkg" 2>&1 | grep -v "Failed to connect to bus" || true
        done
        # 修复依赖问题
        $APT_INSTALL || true
    else
        echo "Warning: No .deb packages found in /packages, skipping..."
    fi
else
    echo "Warning: /packages directory does not exist, skipping..."
fi

# 安装 DDE 桌面环境
$APT_INSTALL deepin-desktop-environment-core         deepin-desktop-environment-base         deepin-desktop-environment-cli         deepin-desktop-environment-extras         firefox         fastfetch         gparted || true

systemctl enable lightdm || true

# 安装子目录下的本地包（如果存在）
install_local_packages() {
    pkg_dir=$1
    if [ -d "$pkg_dir" ]; then
        # 检查是否有 deb 文件
        has_debs=0
        for f in $pkg_dir/*.deb; do
            [ -f "$f" ] && has_debs=1 && break
        done

        if [ "$has_debs" -eq 1 ]; then
            echo "Installing packages from $pkg_dir..."
            for pkg in $pkg_dir/*.deb; do
                [ -f "$pkg" ] || continue
                echo "Installing: $pkg"
                dpkg -i "$pkg" 2>&1 | grep -v "Failed to connect to bus" || true
            done
            $APT_INSTALL || true
        else
            echo "Warning: No packages found in $pkg_dir, skipping..."
        fi
    fi
}

install_local_packages "/packages/rga2"
install_local_packages "/packages/mpp"
install_local_packages "/packages/gst-rkmpp"

HOST=darkmoon

# Create User
if ! id "darkmoon" >/dev/null 2>&1; then
    useradd -G sudo -m -s /bin/bash darkmoon
    passwd darkmoon <<EOF
darkmoon
darkmoon
EOF
    gpasswd -a darkmoon video
    gpasswd -a darkmoon audio
else
    echo "User darkmoon already exists, skipping creation..."
fi

passwd root <<EOF
root
root
EOF

# 检查 sudoers 中是否已存在 darkmoon 条目
if ! grep -q "darkmoon  ALL=(ALL:ALL) ALL" /etc/sudoers; then
    echo "darkmoon  ALL=(ALL:ALL) ALL" >> /etc/sudoers
fi

# hostname
echo darkmoon > /etc/hostname

# set localtime
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

# 配置 locale
locale-gen C.UTF-8 zh_CN.UTF-8 en_US.UTF-8 || true
dpkg-reconfigure locales || true

apt-get clean
rm -rf /packages/

history -c

CHROOT_EOF

# 正常卸载
cleanup

echo "Rootfs build completed successfully!"
