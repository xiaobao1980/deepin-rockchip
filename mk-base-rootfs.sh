#!/bin/bash

# 严格模式
set -euo pipefail
IFS=$'\n\t'

# 调试输出
set -x

# 环境设置
export DEBIAN_FRONTEND=noninteractive

# 变量定义（加引号防空格问题）
dist_version="crimson"
dist_name="deepin"
arch="arm64"
SOURCES_FILE="config/apt/sources.list"
PACKAGES_FILE="config/packages.list/packages.list"
OUT_DIR="rootfs"
ROOTFS="$OUT_DIR/${dist_name}-${dist_version}"
OUTPUT_TAR="${dist_name}-${dist_version}-rootfs-${arch}.tar.gz"

# 检查必需文件
[[ -f "$SOURCES_FILE" ]] || { echo "错误: $SOURCES_FILE 不存在"; exit 1; }
[[ -f "$PACKAGES_FILE" ]] || { echo "错误: $PACKAGES_FILE 不存在"; exit 1; }

# 读取仓库列表
readarray -t REPOS < "$SOURCES_FILE"

# 处理包列表（排除注释和空行）
PACKAGES=$(grep -v '^[[:space:]]*-' "$PACKAGES_FILE" | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | xargs | tr ' ' ',')

# 创建输出目录
mkdir -p "$OUT_DIR" "$ROOTFS"

# 安装构建依赖
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    curl git mmdebstrap qemu-user-static binfmt-support systemd-container

# 添加 Deepin 密钥（关键：在 mmdebstrap 之前）
echo "添加 Deepin 仓库密钥..."
# 方法1: 使用官方密钥文件
curl -fsSL "https://community-packages.deepin.com/beige/dists/beige/Release.gpg" | sudo apt-key add - || \
# 方法2: 备用密钥服务器
sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 1D27208A56B5E302 || \
sudo apt-key adv --keyserver hkp://pgp.mit.edu:80 --recv-keys 1D27208A56B5E302

# 启用异架构支持
sudo systemctl restart systemd-binfmt || true
sudo systemctl enable systemd-binfmt || true

# 确保 hook 可执行
[[ -x "./config/hooks.chroot/second-stage" ]] || chmod +x "./config/hooks.chroot/second-stage"

# 清理函数
cleanup() {
    local exit_code=$?
    if [[ -d "$ROOTFS" ]] && [[ "${KEEP_ROOTFS:-0}" != "1" ]]; then
        echo "清理临时目录: $ROOTFS"
        sudo rm -rf "$ROOTFS"
    fi
    exit $exit_code
}
trap cleanup EXIT

# 构建根文件系统
echo "开始构建 ${arch} 架构的根文件系统..."
sudo mmdebstrap \
    --hook-dir=/usr/share/mmdebstrap/hooks/merged-usr \
    --include="$PACKAGES" \
    --components="main,commercial,community" \
    --variant=minbase \
    --architecture="$arch" \
    --customize="./config/hooks.chroot/second-stage" \
    "$dist_version" \
    "$ROOTFS" \
    "${REPOS[@]}"

# 生成压缩包
echo "生成压缩包: $OUTPUT_TAR"
[[ -f "$OUTPUT_TAR" ]] && sudo rm -f "$OUTPUT_TAR"
sudo tar -czf "$OUTPUT_TAR" -C "$ROOTFS" .

echo "构建完成: $OUTPUT_TAR"
echo "大小: $(du -h "$OUTPUT_TAR" | cut -f1)"

# 可选: 保留根文件系统用于调试
# export KEEP_ROOTFS=1  # 取消注释以保留
