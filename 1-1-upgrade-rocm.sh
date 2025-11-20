#!/usr/bin/env bash
set -euo pipefail

TMP="/tmp/upgrade-kernel-6.14"
mkdir -p "$TMP"

if [ "$EUID" -ne 0 ]; then
  echo "请以 root 运行此脚本。"
  exit 1
fi


echo "=== Step 1: 卸载 ROCm 相关包 ==="
# 常见 rocm 元包、驱动包
apt-get purge -y "rocm*" "hip*" "hsa*" "comgr*" "opencl*" "amdgpu*" || true

# 清理残留依赖
apt-get autoremove -y
apt-get clean

echo "当前内核: $(uname -r)"
echo "准备安装 Linux kernel $REQUIRED_KERNEL ..."

# 1) 记录当前 holds 并解除它们（备份）
dpkg --get-selections | grep hold || true
echo "备份当前 apt-mark hold 列表到 /root/apt-hold-backup.txt"
comm -23 <(apt-mark showhold | sort) <(printf "%s\n" | sort) > /root/apt-hold-backup.txt || true

# 解除常见内核相关 hold（安全：如果没有对应包会忽略）
echo "解除已锁定内核包（如果有）..."
apt-mark unhold linux-image-* || true
apt-mark unhold linux-headers-* || true
apt update
apt upgrade -y


sudo apt install --reinstall ubuntu-desktop
sudo apt install --reinstall gnome-shell
sudo systemctl restart gdm3

echo
echo "内核安装完成（包已安装）。请手动重启以使用新内核："
echo "  sudo reboot"
echo
echo "重启后请登录并用 'uname -r' 确认正在运行的版本号。"
echo "当确认运行新内核后，再运行 ROCm 升级脚本 "
