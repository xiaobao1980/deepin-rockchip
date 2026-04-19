#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# 配置
dist_version="crimson"
dist_name="deepin"

MOUNTPATH="./mountpath"
IMAGE="${dist_name}-${dist_version}-arm64.img"
ROOTFS_DIR="./rootfs/${dist_name}-${dist_version}"
BOOT_DIR="./packages/boot"

UBOOT_BIN="${UBOOT_BIN:-}"  # 允许外部传入

# 检查 rootfs
if [ ! -d "$ROOTFS_DIR" ]; then
    log_error "Rootfs directory not found: $ROOTFS_DIR"
    log_error "Please run mk-base-rootfs.sh and mk-deepinv25-rootfs.sh first"
    exit 1
fi

# 清理旧文件
cleanup() {
    if mountpoint -q "$MOUNTPATH/boot" 2>/dev/null; then
        sudo umount "$MOUNTPATH/boot" || true
    fi
    if mountpoint -q "$MOUNTPATH" 2>/dev/null; then
        sudo umount "$MOUNTPATH" || true
    fi
    if [ -n "${LOOP_DEVICE:-}" ]; then
        sudo kpartx -dv "/dev/$LOOP_DEVICE" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# 安装 Armbian 内核/U-Boot/固件包
install_boot_packages() {
    if [ ! -d "$BOOT_DIR" ]; then
        log_error "Boot packages directory not found: $BOOT_DIR"
        exit 1
    fi
    
    log_info "Installing Armbian boot packages..."
    
    # 查找所有 deb 文件
    local debs=()
    while IFS= read -r -d '' deb; do
        debs+=("$deb")
    done < <(find "$BOOT_DIR" -maxdepth 1 -name "*.deb" -print0 2>/dev/null)
    
    if [ ${#debs[@]} -eq 0 ]; then
        log_error "No .deb packages found in $BOOT_DIR"
        exit 1
    fi
    
    log_info "Found ${#debs[@]} packages"
    
    # 按优先级排序：firmware -> headers -> image -> dtb -> u-boot
    local sorted_debs=()
    for pattern in "firmware" "headers" "image" "dtb" "u-boot"; do
        for deb in "${debs[@]}"; do
            if [[ "$(basename "$deb")" == *"$pattern"* ]] && [[ ! " ${sorted_debs[*]} " =~ " $deb " ]]; then
                sorted_debs+=("$deb")
            fi
        done
    done
    # 添加剩余的
    for deb in "${debs[@]}"; do
        if [[ ! " ${sorted_debs[*]} " =~ " $deb " ]]; then
            sorted_debs+=("$deb")
        fi
    done
    
    # 提取所有包到 rootfs
    for deb in "${sorted_debs[@]}"; do
        log_info "Extracting: $(basename "$deb")"
        if ! dpkg-deb -x "$deb" "$ROOTFS_DIR/"; then
            log_warn "Failed to extract: $deb"
        fi
    done
    
    # 查找内核版本
    local kernel_img
    kernel_img=$(find "$ROOTFS_DIR/boot" -name "vmlinuz-*" -type f | head -1)
    
    if [ -z "$kernel_img" ]; then
        log_error "Kernel image not found in $ROOTFS_DIR/boot"
        exit 1
    fi
    
    local kernel_version
    kernel_version=$(basename "$kernel_img" | sed 's/vmlinuz-//')
    log_info "Kernel version: $kernel_version"
    
    # 创建标准链接
    sudo ln -sf "vmlinuz-$kernel_version" "$ROOTFS_DIR/boot/Image"
    sudo ln -sf "initrd.img-$kernel_version" "$ROOTFS_DIR/boot/initrd.img" 2>/dev/null || true
    
    # 查找 initramfs，如果不存在则尝试创建标记
    if [ ! -f "$ROOTFS_DIR/boot/initrd.img-$kernel_version" ]; then
        log_warn "Initramfs not found, creating empty marker"
        sudo touch "$ROOTFS_DIR/boot/initrd.img-$kernel_version"
    fi
    
    # 自动查找 U-Boot
    if [ -z "$UBOOT_BIN" ] || [ ! -f "$UBOOT_BIN" ]; then
        log_info "Searching for U-Boot binary..."
        
        # 在 packages/boot 中查找
        local uboot_candidates=(
            "$BOOT_DIR/u-boot.bin"
            "$BOOT_DIR/u-boot-rockchip.bin"
            "$BOOT_DIR/rk3588-u-boot.bin"
            "$BOOT_DIR/rk3568-u-boot.bin"
        )
        
        for candidate in "${uboot_candidates[@]}"; do
            if [ -f "$candidate" ]; then
                UBOOT_BIN="$candidate"
                break
            fi
        done
        
        # 从 u-boot deb 包中提取
        if [ -z "$UBOOT_BIN" ] || [ ! -f "$UBOOT_BIN" ]; then
            local uboot_pkg
            uboot_pkg=$(find "$BOOT_DIR" -name "*u-boot*.deb" | head -1)
            if [ -n "$uboot_pkg" ]; then
                log_info "Extracting U-Boot from: $(basename "$uboot_pkg")"
                local temp_dir
                temp_dir=$(mktemp -d)
                dpkg-deb -x "$uboot_pkg" "$temp_dir"
                
                UBOOT_BIN=$(find "$temp_dir" -name "u-boot*.bin" -type f | grep -v "trust" | head -1)
                
                if [ -n "$UBOOT_BIN" ]; then
                    cp "$UBOOT_BIN" "./u-boot-extracted.bin"
                    UBOOT_BIN="./u-boot-extracted.bin"
                fi
                rm -rf "$temp_dir"
            fi
        fi
    fi
    
    if [ -z "$UBOOT_BIN" ] || [ ! -f "$UBOOT_BIN" ]; then
        log_error "U-Boot binary not found!"
        exit 1
    fi
    
    log_info "Using U-Boot: $UBOOT_BIN"
}

# 复制 overlay
copy_overlay() {
    if [ -d "./overlay" ]; then
        log_info "Copying overlay files..."
        sudo cp -rpf ./overlay/* "$ROOTFS_DIR/" || log_warn "Some overlay files failed to copy"
    else
        log_warn "Overlay directory not found, skipping"
    fi
}

# 计算镜像大小
calculate_size() {
    local rootfs_size
    rootfs_size=$(sudo du -sb "$ROOTFS_DIR" | cut -f1)
    # 转换为 MB，增加 20% 余量 + 512M boot 分区
    local size_mb=$(( (rootfs_size / 1024 / 1024) * 120 / 100 + 512 + 64 ))
    echo "$size_mb"
}

# 创建镜像
create_image() {
    local size_mb=$1
    
    log_info "Creating image: $IMAGE (${size_mb}MB)"
    
    rm -f "$IMAGE"
    dd if=/dev/zero of="$IMAGE" bs=1M count=0 seek="$size_mb" status=progress
}

# 写入 U-Boot
write_uboot() {
    log_info "Writing U-Boot to image..."
    
    # Rockchip 标准偏移：32KB (sector 64)
    dd if="$UBOOT_BIN" of="$IMAGE" bs=512 seek=64 conv=notrunc,fsync status=progress
    
    sync
}

# 创建分区
create_partitions() {
    log_info "Creating partition table..."
    
    parted --script "$IMAGE" \
        mklabel gpt \
        mkpart primary ext4 16M 528M \
        mkpart primary ext4 528M 100%
    
    sync
    sleep 1
}

# 设置 loop 设备和文件系统
setup_loop() {
    log_info "Setting up loop device..."
    
    sudo kpartx -av "$IMAGE"
    sleep 2
    
    LOOP_DEVICE=$(losetup -j "$IMAGE" | cut -d: -f1 | xargs basename)
    
    if [ -z "$LOOP_DEVICE" ]; then
        log_error "Failed to setup loop device"
        exit 1
    fi
    
    log_info "Loop device: $LOOP_DEVICE"
    
    # 生成 UUID
    BOOT_UUID=$(uuidgen)
    ROOT_UUID=$(uuidgen)
    
    log_info "Creating filesystems..."
    sudo mkfs.ext4 -F -U "$BOOT_UUID" -L "boot" "/dev/mapper/${LOOP_DEVICE}p1"
    sudo mkfs.ext4 -F -U "$ROOT_UUID" -L "root" "/dev/mapper/${LOOP_DEVICE}p2"
}

# 复制 rootfs
copy_rootfs() {
    log_info "Mounting partitions..."
    sudo mkdir -p "$MOUNTPATH"
    sudo mount "/dev/mapper/${LOOP_DEVICE}p2" "$MOUNTPATH"
    sudo mkdir -p "$MOUNTPATH/boot"
    sudo mount "/dev/mapper/${LOOP_DEVICE}p1" "$MOUNTPATH/boot"
    
    log_info "Copying rootfs (this may take a while)..."
    sudo rsync -aH --info=progress2 "$ROOTFS_DIR/" "$MOUNTPATH/"
    
    # 创建 fstab
    log_info "Creating fstab..."
    sudo tee "$MOUNTPATH/etc/fstab" > /dev/null << EOF
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
UUID=$BOOT_UUID  /boot           ext4    defaults        0       2
UUID=$ROOT_UUID  /               ext4    defaults,noatime 0       1
EOF
    
    # 创建 extlinux.conf（用于 U-Boot 引导）
    log_info "Creating boot configuration..."
    sudo mkdir -p "$MOUNTPATH/boot/extlinux"
    
    local kernel_img
    kernel_img=$(find "$MOUNTPATH/boot" -name "vmlinuz-*" | head -1 | xargs basename)
    local initrd_img
    initrd_img=$(find "$MOUNTPATH/boot" -name "initrd.img-*" | head -1 | xargs basename)
    local dtb_file
    dtb_file=$(find "$MOUNTPATH/boot/dtbs" -name "*.dtb" | head -1 | xargs basename 2>/dev/null || echo "")
    
    local fdt_line=""
    [ -n "$dtb_file" ] && fdt_line="  fdt /boot/dtbs/$dtb_file"
    
    sudo tee "$MOUNTPATH/boot/extlinux/extlinux.conf" > /dev/null << EOF
label Deepin
  kernel /boot/$kernel_img
  initrd /boot/$initrd_img
$fdt_line
  append root=UUID=$ROOT_UUID rw rootwait console=ttyS2,1500000 console=tty1 panic=10
EOF
    
    sync
}

# 卸载
unmount_all() {
    log_info "Unmounting..."
    sync
    sudo umount "$MOUNTPATH/boot" 2>/dev/null || true
    sudo umount "$MOUNTPATH" 2>/dev/null || true
    sudo kpartx -dv "/dev/$LOOP_DEVICE" 2>/dev/null || true
}

# 主流程
main() {
    log_info "Starting image creation for ${dist_name}-${dist_version}"
    
    install_boot_packages
    copy_overlay
    
    local size_mb
    size_mb=$(calculate_size)
    log_info "Calculated image size: ${size_mb}MB"
    
    create_image "$size_mb"
    write_uboot
    create_partitions
    setup_loop
    copy_rootfs
    unmount_all
    
    log_info "Image created successfully: $IMAGE"
    ls -lh "$IMAGE"
}

main "$@"
