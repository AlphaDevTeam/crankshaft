#!/bin/bash

# CREDIT TO THESE TUTORIALS:
# petr.io/en/blog/2015/11/09/read-only-raspberry-pi-with-jessie
# hallard.me/raspberry-pi-read-only
# k3a.me/how-to-make-raspberrypi-truly-read-only-reliable-and-trouble-free

if [ $(id -u) -ne 0 ]; then
	echo "Installer must be run as root."
	echo "Try 'sudo bash $0'"
	exit 1
fi


# FEATURE PROMPTS ----------------------------------------------------------
# Installation doesn't begin until after all user input is taken.

INSTALL_HALT=0
SYS_TYPES=(Pi\ 3\ /\ Pi\ Zero\ W All\ other\ models)
WATCHDOG_MODULES=(bcm2835_wdog bcm2708_wdog)
OPTION_NAMES=(NO YES)

INSTALL_RW_JUMPER=1
RW_PIN=4
#invert LCD pin
INVERT_PIN=21

INSTALL_WATCHDOG=1
WD_TARGET=1

# VERIFY SELECTIONS BEFORE CONTINUING --------------------------------------

echo
if [ $INSTALL_RW_JUMPER -eq 1 ]; then
	echo "Boot-time R/W jumper: YES (GPIO$RW_PIN)"
else
	echo "Boot-time R/W jumper: NO"
fi
if [ $INSTALL_HALT -eq 1 ]; then
	echo "Install GPIO-halt: YES (GPIO$HALT_PIN)"
else
	echo "Install GPIO-halt: NO"
fi
if [ $INSTALL_WATCHDOG -eq 1 ]; then
	echo "Enable watchdog: YES (${SYS_TYPES[WD_TARGET-1]})"
else
	echo "Enable watchdog: NO"
fi
echo

# START INSTALL ------------------------------------------------------------
# All selections have been validated at this point...

# Given a filename, a regex pattern to match and a replacement string:
# Replace string if found, else no change.
# (# $1 = filename, $2 = pattern to match, $3 = replacement)
replace() {
	grep $2 $1 >/dev/null
	if [ $? -eq 0 ]; then
		# Pattern found; replace in file
		sed -i "s/$2/$3/g" $1 >/dev/null
	fi
}

# Given a filename, a regex pattern to match and a replacement string:
# If found, perform replacement, else append file w/replacement on new line.
replaceAppend() {
	grep $2 $1 >/dev/null
	if [ $? -eq 0 ]; then
		# Pattern found; replace in file
		sed -i "s/$2/$3/g" $1 >/dev/null
	else
		# Not found; append on new line (silently)
		echo $3 | sudo tee -a $1 >/dev/null
	fi
}

# Given a filename, a regex pattern to match and a string:
# If found, no change, else append file with string on new line.
append1() {
	grep $2 $1 >/dev/null
	if [ $? -ne 0 ]; then
		# Not found; append on new line (silently)
		echo $3 | sudo tee -a $1 >/dev/null
	fi
}

# Given a filename, a regex pattern to match and a string:
# If found, no change, else append space + string to last line --
# this is used for the single-line /boot/cmdline.txt file.
append2() {
	grep $2 $1 >/dev/null
	if [ $? -ne 0 ]; then
		# Not found; insert in file before EOF
		sed -i "s/\'/ $3/g" $1 >/dev/null
	fi
}

echo
echo "Starting installation..."

echo "Removing unwanted packages..."
#apt-get remove -y --force-yes --purge triggerhappy cron logrotate dbus \
# dphys-swapfile xserver-common lightdm fake-hwclock
# Let's keep dbus...that includes avahi-daemon, a la 'raspberrypi.local',
# also keeping xserver & lightdm for GUI login (WIP, not working yet)
apt-get remove -y --force-yes --purge triggerhappy cron logrotate \
 dphys-swapfile fake-hwclock
apt-get -y --force-yes autoremove --purge

# Replace log management with busybox (use logread if needed)
echo "Installing busybox-syslogd..."
apt-get -y --force-yes install busybox-syslogd; dpkg --purge rsyslog

echo "Configuring system..."

# Install boot-time R/W jumper test if requested
if [ $INSTALL_RW_JUMPER -ne 0 ]; then
	apt-get install -y --force-yes wiringpi
	# Check if already present in rc.local:
	cat <<EOF > /etc/rc.local
#!/bin/bash

gpio -g mode $RW_PIN up
gpio -g mode $INVERT_PIN up

if [ \`gpio -g read $RW_PIN\` -eq 0 ] ; then
	mount -o remount,rw /
	mount -o remount,rw /boot
fi

if [ \`gpio -g read $INVERT_PIN\` -eq 0 ] ; then
	grep "lcd_rotate=2" /boot/config.txt >/dev/null
	if [ \$? -ne 0 ]; then
		# Not there
		mount -o remount,rw /boot
		echo "lcd_rotate=2" >> /boot/config.txt
		reboot
	fi
else
	grep "lcd_rotate=2" /boot/config.txt >/dev/null
	if [ \$? -eq 0 ]; then
		# There, need to restore
		mount -o remount,rw /boot
		sed -i 's/^lcd_rotate=2//g' /boot/config.txt
		reboot
        fi
fi
exit 0
EOF
fi

chmod +x /etc/rc.local

cat <<EOF > /etc/systemd/system/rc-local.service
[Unit]
 Description=/etc/rc.local Compatibility
 ConditionPathExists=/etc/rc.local

[Service]
 Type=forking
 ExecStart=/etc/rc.local start
 TimeoutSec=0
 StandardOutput=tty
 RemainAfterExit=yes
 SysVStartPriority=99

[Install]
 WantedBy=multi-user.target
EOF

systemctl enable rc-local


# Install watchdog if requested
if [ $INSTALL_WATCHDOG -ne 0 ]; then
	apt-get install -y --force-yes watchdog
	# $MODULE is specific watchdog module name
	MODULE=${WATCHDOG_MODULES[($WD_TARGET-1)]}
	# Add to /etc/modules, update watchdog config file
	append1 /etc/modules $MODULE $MODULE
	replace /etc/watchdog.conf "#watchdog-device" "watchdog-device"
	replace /etc/watchdog.conf "#max-load-1" "max-load-1"
	# Start watchdog at system start and start right away
	# Raspbian Stretch needs this package installed first
	apt-get install -y --force-yes insserv
	insserv watchdog
	# Additional settings needed on Jessie
	append1 /lib/systemd/system/watchdog.service "WantedBy" "WantedBy=multi-user.target"
	systemctl enable watchdog
	# Set up automatic reboot in sysctl.conf
	replaceAppend /etc/sysctl.conf "^.*kernel.panic.*$" "kernel.panic = 10"
fi

# Add fastboot, noswap and/or ro to end of /boot/cmdline.txt
append2 /boot/cmdline.txt fastboot fastboot
append2 /boot/cmdline.txt noswap noswap
append2 /boot/cmdline.txt ro^o^t ro

# Move /var/spool to /tmp
rm -rf /var/spool
ln -s /tmp /var/spool

# Voodoo stuff to get the home folder working
rm -rf /home/pi/.config
mkdir /tmpfs_home
chown pi:pi /tmpfs_home
ln -s /tmpfs_home /home/pi/.config

# Make SSH work
#replaceAppend /etc/ssh/sshd_config "^.*UsePrivilegeSeparation.*$" "UsePrivilegeSeparation no"
# bbro method (not working in Jessie?):
#rmdir /var/run/sshd
#ln -s /tmp /var/run/sshd

# Change spool permissions in var.conf (rondie/Margaret fix)
replace /usr/lib/tmpfiles.d/var.conf "spool\s*0755" "spool 1777"

# Move dhcpd.resolv.conf to tmpfs
touch /tmp/dhcpcd.resolv.conf
rm /etc/resolv.conf
ln -s /tmp/dhcpcd.resolv.conf /etc/resolv.conf

# Make edits to fstab
# make / ro
# tmpfs /var/log tmpfs nodev,nosuid 0 0
# tmpfs /var/tmp tmpfs nodev,nosuid 0 0
# tmpfs /tmp     tmpfs nodev,nosuid 0 0
replace /etc/fstab "vfat\s*defaults\s" "vfat    defaults,ro "
replace /etc/fstab "ext4\s*defaults,noatime\s" "ext4    defaults,noatime,ro "
append1 /etc/fstab "/var/log" "tmpfs /var/log tmpfs nodev,nosuid 0 0"
append1 /etc/fstab "/var/tmp" "tmpfs /var/tmp tmpfs nodev,nosuid 0 0"
append1 /etc/fstab "\s/tmp"   "tmpfs /tmp    tmpfs nodev,nosuid 0 0"
append1 /etc/fstab "\s/tmpfs_home"   "tmpfs /tmpfs_home    tmpfs nodev,nosuid 0 0"

sync
exit 0