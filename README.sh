
# ----------------------
# On: host machine
# ----------------------

# Flash
#   http://ppa.linuxfactory.or.kr/images/raw/arm64/jammy/ubuntu-22.04-server-odroidn2plus-20221115.img.xz
# using Balena Etcher

# Disable journaling on root fs
umount /media/$USER/rootfs
sudo tune2fs -O ^has_journal /dev/mmcblk0p2
sudo mkdir -p /media/$USER/rootfs
sudo mount /dev/mmcblk0p2 /media/$USER/rootfs

# ----------------------
# On: Odroid N2+
# ----------------------

# sudo shutdown

# ----------------------
# On: host machine
# ----------------------

# Start docker build container
docker run -it -v /media/$USER/rootfs:/media/$USER/rootfs -v  /media/$USER/BOOT:/media/$USER/BOOT --name linuxcnc ubuntu:22.04
# or restart an existing one if you already built the kernel
# docker start linuxcnc
# docker exec -it linuxcnc bash

# ----------------------
# On: docker container
# ----------------------

USER=alangibson
# LINARO_VERSION=gcc-linaro-7.4.1-2019.02-x86_64_aarch64-linux-gnu
LINARO_VERSION=gcc-linaro-12.2.1-2023.01-x86_64_aarch64-linux-gnu

# Set up cross compile environment
dpkg --add-architecture arm64
sed -i 's/deb /deb [arch=amd64] /' /etc/apt/sources.list
cat >> /etc/apt/sources.list << EOF
deb [arch=arm64] http://ports.ubuntu.com/ jammy main restricted
deb [arch=arm64] http://ports.ubuntu.com/ jammy-updates main restricted
deb [arch=arm64] http://ports.ubuntu.com/ jammy universe
deb [arch=arm64] http://ports.ubuntu.com/ jammy-updates universe
deb [arch=arm64] http://ports.ubuntu.com/ jammy multiverse
deb [arch=arm64] http://ports.ubuntu.com/ jammy-updates multiverse
deb [arch=arm64] http://ports.ubuntu.com/ jammy-backports main restricted universe multiverse
EOF
apt update

apt -y install build-essential git python3
# apt -y install crossbuild-essential-arm64

# Install Linaro cross compile toolchain
apt -y install curl xz-utils
# curl -L -O https://snapshots.linaro.org/gnu-toolchain/12.2-2023.01-1/aarch64-linux-gnu/$LINARO_VERSION.tar.xz
curl -L -O https://releases.linaro.org/components/toolchain/binaries/7.4-2019.02/aarch64-linux-gnu/$LINARO_VERSION.tar.xz
mkdir /toolchains
pushd /toolchains
tar Jxvf ../$LINARO_VERSION.tar.xz
# mv $LINARO_VERSION/aarch64-linux-gnu/bin/as $LINARO_VERSION/aarch64-linux-gnu/bin/as.off
popd

# Prevent `make` error "as: unrecognized option '--64'"
# mv $(which as) $(which as).off

# PATH=/usr/aarch64-linux-gnu/bin:$PATH
# PATH=/toolchains/$LINARO_VERSION/bin/:/toolchains/$LINARO_VERSION/aarch64-linux-gnu/bin/:$PATH
export ARCH=arm64 \
    CC=aarch64-linux-gnu-gcc \
    CXX=aarch64-linux-gnu-g++ \
    PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig \
    CROSS_COMPILE=aarch64-linux-gnu- \
    DEB_HOST_MULTIARCH=aarch64-linux-gnu \
    PATH=/toolchains/$LINARO_VERSION/bin:$PATH

# Verify Linaro toolchain is correctly installed
$CC -v
$CXX -v
ld -v

# 
# Cross compile linux kernel
# 

apt -y install build-essential bison flex libncurses-dev libssl-dev libelf-dev git bc rsync cpio kmod git

# Get linux Linux kernel
git clone --depth 1 -b odroid-5.10.y-rt https://github.com/tobetter/linux.git
pushd linux

# make odroidg12_defconfig
cp /media/$USER/BOOT/config-5.15.0-odroid-arm64 .config
echo 'CONFIG_PREEMPT_RT=y' >> .config
echo 'CONFIG_PREEMPT_RT_FULL=y' >> .config
echo 'CONFIG_VIRTUALIZATION=n' >> .config
echo 'CONFIG_ARCH_SUPPORTS_RT=y' >> .config
echo 'CONFIG_LOCALVERSION_AUTO=y' >> .config
yes "" | make oldconfig
echo "-odroid-arm64" > .scmversion

# Cross compile kernel
make -j$(expr $(nproc) + 1)
make modules
make Image

# Install onto SD card
# cp arch/arm64/boot/Image.gz arch/arm64/boot/dts/amlogic/meson64_odroid*.dtb /media/alangibson/BOOT
make install INSTALL_PATH=/media/$USER/BOOT
make modules_install INSTALL_MOD_PATH=/media/$USER/rootfs
make headers_install INSTALL_HDR_PATH=/media/$USER/rootfs/usr/src/linux-headers-5.10.18-rt32-odroid-arm64

sed -i "s/^force=.*$/force=\"yes\"/g" /media/$USER/rootfs/usr/share/flash-kernel/functions
cp -R arch/arm64/boot/dts /media/$USER/rootfs/usr/lib/linux-image-$(cat include/config/kernel.release)
cp arch/arm64/boot/dts/amlogic/meson64_odroidn2_plus.dtb /media/$USER/rootfs/etc/flash-kernel/dtbs

# 
# Cross compile LinuxCNC
# 

git clone -b 2.9 --depth 1 https://github.com/LinuxCNC/linuxcnc.git /linuxcnc
pushd /linuxcnc

apt install -y dh-python docbook-xsl asciidoc ghostscript imagemagick \
    asciidoc-dblatex desktop-file-utils intltool po4a python3 python3-tk \
    python3-xlib tclx yapps2 netcat bwidget psmisc \
    libudev-dev:arm64 libboost-python-dev:arm64 libepoxy-dev:arm64 \
    tcl8.6-dev:arm64 libgl1-mesa-dev:arm64 libglu1-mesa-dev:arm64 \
    libgtk2.0-dev:arm64 libgtk-3-dev:arm64 libmodbus-dev:arm64 \
    libeditreadline-dev:arm64 libtirpc-dev:arm64 libusb-1.0-0-dev:arm64 \
    libxmu-dev:arm64 tk8.6-dev:arm64 libudev-dev:arm64
# python3-dev:arm64 ?
apt -y install crossbuild-essential-arm64

# TODO manually reset path
# Use correct ld
export PATH="/usr/aarch64-linux-gnu/bin:$PATH"

# Configure for Debian packaging
sed -i 's/Ubuntu-21/Ubuntu-22/' ./debian/configure
./debian/configure no-docs
# Apply hacks to support cross compile
sed -i 's/[(]void[)]//g' ./src/rtapi/rtapi_io.h
sed -i 's/\.\/configure/.\/configure --host=$(DEB_HOST_MULTIARCH) --target=$(DEB_HOST_MULTIARCH) --with-kernel-headers=\/linux\/include/' debian/rules
# dpkg-checkbuilddeps -a arm64
# apt build-dep -a arm64 .
# debuild -aarm64 -i -us -uc -b
dpkg-buildpackage --host-arch arm64 --target-arch arm64 --build=binary --unsigned-changes --no-check-builddeps

popd
cp linuxcnc-*.deb /media/$USER/rootfs

# ----------------------
# On: Odroid N2+
# ----------------------

# linux-version list
# sudo flash-kernel --force 5.10.18-rt32-odroid-arm64
# sudo reboot
sudo update-initramfs -k 5.10.18-rt32-odroid-arm64 -c

sudo cp /boot/boot.scr /boot/boot.scr.bak2
dd if=/boot/boot.scr of=boot.txt bs=72 skip=1
# sudo sed -i 's/net\.ifnames\=0/net.ifnames=0 processor.max_cstate=1 isolcpus=2,3,4,5 workqueue.power_efficient=0/' boot.txt
sudo sed -i 's/net\.ifnames\=0/net.ifnames=0 processor.max_cstate=1 isolcpus=2,3,4,5 workqueue.power_efficient=0/' boot.txt
sudo mkimage -A arm -T script -C none -n "Ubuntu boot script" -d boot.txt /boot/boot.scr

echo -n 'performance' | sudo tee /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

# Install glxgears
sudo apt install -y mesa-utils xserver-xorg xserver-xorg-input-all xterm xinit
echo 'xterm' > .xinitrc

# Stop useless services, sockets, timers, etc.
sudo systemctl disable --now \
  rsyslog.service systemd-timesyncd.service systemd-journald.service cron.service \
  wpa_supplicant.service packagekit.service unattended-upgrades.service snapd.service \
  multipathd.service \
  systemd-journald-dev-log.socket systemd-journald.socket systemd-journald-audit.socket \
  snapd.socket syslog.socket multipathd.socket

#sudo systemctl stop pulseaudio.service apache2.service cron.service snapd.service rsyslog.service wpa_supplicant.service systemd-journald.service \
#    unattended-upgrades.service multipathd.service colord.service upower.service packagekit.service systemd-timesyncd.service systemd-tmpfiles-clean.service \
#    snapd.socket syslog.socket systemd-journald.socket systemd-journald-dev-log.socket systemd-journald-audit.socket multipathd.socket
#sudo systemctl mask pulseaudio.service apache2.service cron.service snapd.service rsyslog.service wpa_supplicant.service systemd-journald.service \
#    unattended-upgrades.service multipathd.service colord.service upower.service packagekit.service systemd-timesyncd.service systemd-tmpfiles-clean.service \
#    snapd.socket syslog.socket systemd-journald.socket systemd-journald-dev-log.socket systemd-journald-audit.socket multipathd.socket

# Install LinuxCNC
sudo apt install ./*.deb

# 
# Latency testing
# 

# Find best-case latency numbers
sudo apt install rt-tests
sudo cyclictest --mlockall --smp --priority=99 --interval=200 --distance=0

apt install -y stress-ng
# Run LinuxCNC latency test
DISPLAY=:0 schedtool -a 2-5 -e nice -n99 latency-histogram >/dev/null 2>&1 &
# then un a stress-ng CPU stressor on each reserved CPU
seq 2 5 | xargs -i -P 4 taskset -c {} stress-ng --cpu 1 --cpu-method all -t 10m &
# or 
seq 1 7 | DISPLAY=:0 xargs -i -P 7 schedtool -a 2-5 -e nice -n99 glxgears >/dev/null 2>&1 &

# Find processes doing io
sudo apt install -y iotop
sudo iotop -ao

# Back up SD card
# unmount /media/$USER/*
# sudo dd bs=4M if=/dev/mmcblk0 | gzip > odroid-n2-plus_5.10.18-rt32-odroid-arm64.img.gz

