#!/bin/bash

# === 检查参数 ===
if [ "$EUID" -ne 0 ]; then
  echo "请以 root 身份运行此脚本"
  exit 1
fi

if [ -z "$1" ]; then
  echo "用法: sudo $0 <new-root-password>"
  exit 1
fi

ROOT_PASSWORD="$1"

echo "=== Step 1: 更新软件包索引（不升级） ==="
apt update

echo "=== Step 2: 安装 ntpdate 和 hwclock，并设置时间 ==="
apt install -y ntpdate util-linux-extra
ntpdate ntp.aliyun.com
hwclock -w

echo "=== Step 3: 安装 OpenSSH Server，并启用 root 密码登录 ==="
apt install -y openssh-server

# 修改sshd_config：允许root密码登录
SSHD_CONFIG="/etc/ssh/sshd_config"
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' "$SSHD_CONFIG"
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' "$SSHD_CONFIG"
systemctl enable ssh
systemctl restart ssh

echo "=== Step 4: 修改 root 密码 ==="
echo "root:$ROOT_PASSWORD" | chpasswd

echo "=== Step 5: 安装 vim ==="
apt install -y vim

echo "锁定内核为6.11"
echo "🔍 正在检查当前内核版本..."
CURRENT_KERNEL=$(uname -r)
echo "当前内核: $CURRENT_KERNEL"

echo "🔒 锁定当前内核版本 $CURRENT_KERNEL..."
apt-mark hold "linux-image-$CURRENT_KERNEL-generic" "linux-headers-$CURRENT_KERNEL" || true
apt-mark hold linux-image-generic linux-headers-generic || true

echo "✅ 更新 grub 引导项..."
update-grub

echo "=== 初始化完成 ==="

