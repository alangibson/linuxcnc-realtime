#
# Install LinuxCNC on Debian Bullseye on 6.0 PREEMPT_RT kernel
#
# Thansk to
#   https://forum.odroid.com/viewtopic.php?f=179&t=43719&start=200
#   https://forum.linuxcnc.org/18-computer/48113-odroid-as-raplacement-for-raspberry-pi
#

#######################################
# On: host machine
#######################################

# Download image
curl -O -L https://oph.mdrjr.net/meveric/images/Bullseye/Debian-Bullseye64-1.5-20221220-N2.img.xz

# and write it to sd card
xzcat Debian-Bullseye64-1.5-20221220-N2.img.xz | sudo dd bs=4M of=/dev/mmcblk0

# Disable journaling on root fs
sudo tune2fs -O ^has_journal /dev/mmcblk0p2

#######################################
# On: Odroid N2+
# login = root/odroid
#######################################

# Create a new host key and start sshd
ssh-keygen -A
systemctl restart sshd

# Upgrade everything we can
apt update && apt upgrade && apt dist-upgrade

# Set a timezone
dpkg-reconfigure tzdata

# Fix locale message
echo 'LC_ALL="en_US.UTF-8"' /etc/default/locale
echo 'export LC_ALL="en_US.UTF-8"' >> .basrc
source .basrc

# Install latest PREEMPT_RT kernel
# apt-cache policy linux-image-rt-arm64
OLD_KERNEL=$(uname -r)
apt remove linux-image-arm64-odroid linux-headers-arm64-odroid
cp -av /usr/lib/linux-image-${OLD_KERNEL}/amlogic/meson64* /etc/flash-kernel/dtbs/
apt install -t bullseye-backports linux-image-rt-arm64 linux-headers-rt-arm64
# dpkg --list | grep linux-image
NEW_KERNEL="6.0.0-0.deb11.6-rt-arm64"
flash-kernel --force ${NEW_KERNEL}
echo "fk_kvers=\"${NEW_KERNEL}\"" >> /boot/config.ini

# Run CPU at max frequency
echo 'performance' > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 

# Set kernel command line
cp /boot/boot.scr /boot/boot.scr.bak
dd if=/boot/boot.scr of=boot.txt bs=72 skip=1
sed -i 's/no_console_suspend/no_console_suspend processor.max_cstate=1 isolcpus=2,3,4,5 workqueue.power_efficient=0/' boot.txt
mkimage -A arm -T script -C none -n "Ubuntu boot script" -d boot.txt /boot/boot.scr

# Install graphical interface
apt install -y task-xfce-desktop

# Stop useless services, sockets, timers, etc.
systemctl disable --now \
  rsyslog.service systemd-timesyncd.service systemd-journald.service cron.service \
  wpa_supplicant.service packagekit.service unattended-upgrades.service snapd.service \
  multipathd.service \
  systemd-journald-dev-log.socket systemd-journald.socket systemd-journald-audit.socket \
  snapd.socket syslog.socket multipathd.socket

# Clean up an unneeded packages
apt -y autoremove

# Reboot into new kernel
reboot

# -------------------------------------
# Build LinuxCNC
# -------------------------------------

# Install build dependencies
apt install -y build-essential git python3 \
    dpkg-dev fakeroot dh-python debhelper python3-tk \
    docbook-xsl asciidoc ghostscript imagemagick \
    asciidoc-dblatex desktop-file-utils intltool po4a \
    python3-xlib tclx yapps2 netcat bwidget psmisc \
    libudev-dev libboost-python-dev libepoxy-dev \
    tcl8.6-dev libgl1-mesa-dev libglu1-mesa-dev \
    libgtk2.0-dev libgtk-3-dev libmodbus-dev \
    libeditreadline-dev libtirpc-dev libusb-1.0-0-dev \
    libxmu-dev tk8.6-dev libudev-dev python3-dev

# Get source code
git clone -b 2.9 --depth 1 https://github.com/LinuxCNC/linuxcnc.git build

# Create Debian package
pushd build
./debian/configure no-docs
dpkg-buildpackage --build=binary --unsigned-changes 
popd

# Install required dependencies
apt install -y mesa-utils python3-numpy python3-cairo python3-gi-cairo \
    python3-opengl libgtksourceview-3.0-dev tclreadline python3-pyqt5 dblatex \
    texlive-extra-utils texlive-fonts-recommended texlive-latex-recommended \
    texlive-xetex xsltproc 
# Install suggested packages
apt install -y librsvg2-dev python3-pil \
    python3-pil.imagetk python3-pyqt5 python3-pyqt5.* python3-opencv \
    python3-dbus python3-espeak python3-dbus.mainloop.pyqt5 espeak-ng \
    pyqt5-dev-tools gstreamer1.0-tools espeak sound-theme-freedesktop \
    python3-poppler-qt5
# Install LinuxCNC package
dpkg -i ./linuxcnc-*.deb

# -------------------------------------
# Configure LinuxCNC
# -------------------------------------

# Configure notification service
apt install -y notification-daemon
cat | tee /usr/share/dbus-1/services/org.freedesktop.Notifications.service <<EOF
[D-BUS Service]
Name=org.freedesktop.Notifications
Exec=/usr/lib/notification-daemon/notification-daemon
EOF

# Install Qt Designer
# Select option 3
sudo sed -i 's/x86_64-linux-gnu/aarch64-linux-gnu/' /usr/lib/python3/dist-packages/qtvcp/designer/install_script
/usr/lib/python3/dist-packages/qtvcp/designer/install_script

# Fix virtual keyboard
apt -y install python3-pip onboard
pip install pygst
sed -i 's/stderr=subprocess.PIPE,/stderr=subprocess.PIPE, text=True,/' /usr/lib/python3/dist-packages/gladevcp/hal_filechooser.py

# Create a user
useradd -m linuxcnc
passwd linuxcnc

# -------------------------------------
# Latency testing
# -------------------------------------

# Find best-case latency numbers
apt install rt-tests
schedtool -a 2-5 -e nice -n 99 cyclictest --mlockall --smp --priority=99 --interval=200 --distance=0

# Run LinuxCNC latency test
apt install -y stress-ng
# Start LinucCNC latency histogram
DISPLAY=:0 schedtool -a 2-5 -e nice -n99 latency-histogram >/dev/null 2>&1 &
# then un a stress-ng CPU stressor on each reserved CPU
seq 2 5 | xargs -i -P 4 taskset -c {} stress-ng --cpu 1 --cpu-method all -t 10m &
# OR run 7 instances of glxgears
seq 1 7 | DISPLAY=:0 xargs -i -P 7 schedtool -a 2-5 -e nice -n99 glxgears >/dev/null 2>&1 &
