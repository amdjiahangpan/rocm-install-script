#!/bin/bash

echo "This script will install 7.9.0 on AMD GFX 1151 (395) GPU. Do not use on CDNA GPUs."

echo "Step 1: Install Python and basic dependencies"

sudo apt install python3.12 python3.12-venv

echo "Step 2: Add user to video/render groups permanently"
sudo usermod -a -G video,render $LOGNAME
echo 'ADD_EXTRA_GROUPS=1' | sudo tee -a /etc/adduser.conf
echo 'EXTRA_GROUPS=video' | sudo tee -a /etc/adduser.conf
echo 'EXTRA_GROUPS=render' | sudo tee -a /etc/adduser.conf


echo "Step 3: Create virtual environment"

python3.12 -m venv .venv
source .venv/bin/activate

echo "Step 4: Install AMDGPU installer and basic dependencies"

python -m pip install --index-url https://repo.amd.com/rocm/whl/gfx1151/ "rocm[libraries,devel]"

echo "Step 5: Final reboot"
echo "Installation complete. Rebooting now..."
sudo reboot