#######################################
# On: host machine
#######################################

# Save space on hard drive
xz PREEMPT_RT/images/Armbian_23.02.0-trunk_Odroidn2_bookworm_edge_6.2.0_xfce_desktop.img

# Write image to sd card
xzcat PREEMPT_RT/images/Armbian_23.02.0-trunk_Odroidn2_bookworm_edge_6.2.0_xfce_desktop.img.xz | sudo dd bs=4M of=/dev/mmcblk0

# Disable journaling on root fs
sudo tune2fs -O ^has_journal /dev/mmcblk0p2

# Copy debs to sd card
udisksctl mount -b /dev/mmcblk0p1
sudo cp PREEMPT_RT/debs/*.deb /media/$USER/armbi_root/
udisksctl unmount -b /dev/mmcblk0p1

#######################################
# On: Odroid N2+
#######################################

# -------------------------------------
# Set up OS
# -------------------------------------

dpkg -i /linux*.deb

# Run CPU at max frequency
echo 'performance' > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

# Set kernel command line
cp /boot/armbianEnv.txt /boot/armbianEnv.txt.bak
echo 'extraargs=isolcpus=2,3,4,5 processor.max_cstate=1 idle=poll' >> /boot/armbianEnv.txt

# Stop unnecessary services, sockets, timers, etc.
systemctl disable --now \
  rsyslog.service systemd-journald.service cron.service cron.service cups.service\
  wpa_supplicant.service packagekit.service unattended-upgrades.service \
  chrony.service upower.service NetworkManager.service \
  systemd-journald-dev-log.socket systemd-journald.socket systemd-journald-audit.socket \
  syslog.socket

reboot

# -------------------------------------
# Install LinuxCNC
# -------------------------------------

alias run='taskset -c 2-5'

# Install LinuxCNC
run apt update
run apt install -y linuxcnc-uspace

# Install suggested packages
run apt install -y librsvg2-dev python3-pil \
    python3-pil.imagetk python3-pyqt5 python3-pyqt5.* python3-opencv \
    python3-dbus python3-espeak python3-dbus.mainloop.pyqt5 espeak-ng \
    pyqt5-dev-tools gstreamer1.0-tools espeak sound-theme-freedesktop \
    python3-poppler-qt5

# Run everything on isolated cpus
sed -i 's/Exec=/Exec=taskset -c 2-5 /' /usr/share/applications/linuxcnc-*.desktop

# -------------------------------------
# Test performance
# -------------------------------------

alias run='taskset -c 2-5'

run apt install -y rt-tests stress-ng schedtool

# Find best-case latency numbers
run cyclictest --mlockall --smp --priority=99 --interval=200 --distance=0
# taskset -c 2-5 cyclictest --mlockall --smp --priority=99 --interval=200 --distance=0

# Run a stress-ng CPU stressor on each reserved CPU
seq 2 5 | xargs -i -P 4 taskset -c {} stress-ng --cpu 1 --cpu-method all -t 10m &
# then find worst-case latency numbers
run cyclictest --mlockall --smp --priority=99 --interval=200 --distance=0
