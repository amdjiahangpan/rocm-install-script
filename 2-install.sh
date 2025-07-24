#!/bin/bash

echo "Step 2: Install AMDGPU installer and basic dependencies"
wget https://repo.radeon.com/amdgpu-install/6.4/ubuntu/noble/amdgpu-install_6.4.60400-1_all.deb
sudo apt install -y ./amdgpu-install_6.4.60400-1_all.deb
sudo apt update
sudo apt install -y python3-setuptools python3-wheel
sudo usermod -a -G render,video $LOGNAME

echo "Step 3: Install ROCm core and kernel modules"
wget https://repo.radeon.com/amdgpu-install/6.4/ubuntu/noble/amdgpu-install_6.4.60400-1_all.deb
sudo apt install -y ./amdgpu-install_6.4.60400-1_all.deb
sudo apt update
sudo apt install -y "linux-headers-$(uname -r)" "linux-modules-extra-$(uname -r)"
sudo apt install -y amdgpu-dkms
sudo apt install -y rocm

echo "Step 4: Add user to video/render groups permanently"
sudo usermod -a -G video,render $LOGNAME
echo 'ADD_EXTRA_GROUPS=1' | sudo tee -a /etc/adduser.conf
echo 'EXTRA_GROUPS=video' | sudo tee -a /etc/adduser.conf
echo 'EXTRA_GROUPS=render' | sudo tee -a /etc/adduser.conf

echo "Step 5: Set udev rules"
sudo bash -c 'cat > /etc/udev/rules.d/70-kfd.rules' <<EOF
KERNEL=="kfd", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0666"
EOF
sudo udevadm control --reload-rules && sudo udevadm trigger

echo "Step 6: Set ROCm library paths"
sudo tee /etc/ld.so.conf.d/rocm.conf > /dev/null <<EOF
/opt/rocm/lib
/opt/rocm/lib64
EOF
sudo ldconfig

echo 'export LD_LIBRARY_PATH=/opt/rocm-6.4.1/lib:$LD_LIBRARY_PATH' >> ~/.bashrc


echo "Step 7: Final reboot"
echo "Installation complete. Rebooting now..."
sudo reboot