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
apt install -y vim nfs-common

echo "=== Step 6: 更新 内核 ==="

apt upgrade -y


echo "=== 初始化完成 ==="

