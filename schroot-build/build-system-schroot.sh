#!/bin/sh -x

RELEASE=$1
ARCH=$2
VGNAME=$3
LVNAME=$4
LVSIZE=$5
LVTYPE=$6
PREPARE=$7
MIRROR=http://ftp.debian.org/debian

[ -z "$PREPARE" ] && {
  echo "Usage: $0 release arch vgname lvname lvsize fstype prepare-script"
  exit 1
}

if ! which schroot; then
  aptitude update && aptitude -y install schroot debootstrap
fi

[ -z "$(aptitude show deborphan | grep '^State: installed')" ] && {
  aptitude install -y deborphan unattended-upgrades && {
    cat > /etc/apt/apt.conf.d/02periodic <<EOF
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "1";
APT::Periodic::Verbose "0";
EOF
  } && {
    aptitude -y purge $(deborphan -n --guess-all)
    aptitude -f install
    aptitude -y purge $(deborphan -n --guess-all)
    aptitude -f install
    apt-get autoremove
    apt-get autoclean
    apt-get clean
  }
}

[ ! -e /etc/schroot/server ] && {
  cp -a /etc/schroot/minimal /etc/schroot/server
  cat > /etc/schroot/server/nssdatabases <<EOF
networks
hosts
EOF
  cat > /etc/schroot/server/fstab <<EOF
/proc           /proc           none    rw,bind         0       0
/sys            /sys            none    rw,bind         0       0
/dev            /dev            none    rw,bind         0       0
/dev/pts        /dev/pts        none    rw,bind         0       0
/dev/shm        /dev/shm        none    rw,bind         0       0
EOF
}

[ -e /dev/$VGNAME/$LVNAME ] && {
  echo "Logical volume /dev/$VGNAME/$LVNAME already exists."
  echo
  echo "If your choice is to continue the volume will be destroyed."
  echo
  read -r -p "Are you sure to continue? [y/N] " response
  case $response in
    [yY][eE][sS]|[yY]) 
        umount /dev/$VGNAME/$LVNAME
        lvremove -f /dev/$VGNAME/$LVNAME
        ;;
    *)
        echo "aborted"
        exit 1
        ;;
  esac
}

lvcreate -n $LVNAME -L$LVSIZE $VGNAME && \
	mkfs.$LVTYPE -f /dev/$VGNAME/$LVNAME && \
	mkdir -p /var/lib/container/$LVNAME && \
	mount -t $LVTYPE /dev/$VGNAME/$LVNAME /var/lib/container/$LVNAME && \
	debootstrap --include aptitude,deborphan,locales,unattended-upgrades \
		    --exclude tasksel,tasksel-data,nano \
		    --variant=minbase --arch=$ARCH $RELEASE \
		    /var/lib/container/$LVNAME || exit 1

cat > /var/lib/container/$LVNAME/etc/apt/apt.conf.d/02periodic <<EOF
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "1";
APT::Periodic::Verbose "0";
EOF

case "$RELEASE" in
  jessie|stable)
    cat > /var/lib/container/$LVNAME/etc/apt/sources.list <<EOF
deb $MIRROR $RELEASE main non-free contrib
deb http://security.debian.org/ ${RELEASE}/updates main contrib non-free
deb $MIRROR ${RELEASE}-updates main non-free contrib
deb $MIRROR ${RELEASE}-proposed-updates main non-free contrib
deb $MIRROR ${RELEASE}-backports main non-free contrib
EOF
  ;;
  sid|unstable|experimental)
    cat > /var/lib/container/$LVNAME/etc/apt/sources.list <<EOF
deb $MIRROR $RELEASE main non-free contrib
EOF
  ;;
  *)
    cat > /var/lib/container/$LVNAME/etc/apt/sources.list <<EOF
deb $MIRROR $RELEASE main non-free contrib
deb http://security.debian.org/ ${RELEASE}/updates main contrib non-free
deb $MIRROR ${RELEASE}-updates main non-free contrib
deb $MIRROR ${RELEASE}-proposed-updates main non-free contrib
EOF
  ;;
esac

[ -z "$(grep $LVNAME /etc/schroot/schroot.conf)" ] && {
  cat >> /etc/schroot/schroot.conf <<EOF

[$LVNAME]
description=$LVNAME container
type=lvm-snapshot
device=/dev/$VGNAME/$LVNAME
lvm-snapshot-options=--size 1G
users=operador
root-groups=root
source-root-groups=root
personality=linux
profile=server
preserve-environment=false
EOF
}

$(realpath $PREPARE) /var/lib/container/$LVNAME $RELEASE && \
	mount --bind /dev/pts /var/lib/container/$LVNAME/dev/pts && \
	chroot /var/lib/container/$LVNAME /bin/bash -c "
		aptitude update
		aptitude -y install sysvinit-core sysvinit-utils
		cp /usr/share/sysvinit/inittab /etc/inittab
		apt-get -y remove --purge --auto-remove systemd
		#aptitude -y install systemd-shim
		echo -e 'Package: systemd\nPin: origin \"\"\nPin-Priority: -1' > /etc/apt/preferences.d/systemd
		echo -e '\n\nPackage: *systemd*\nPin: origin \"\"\nPin-Priority: -1' >> /etc/apt/preferences.d/systemd" && \
	umount /var/lib/container/$LVNAME/dev/pts && \
	umount /var/lib/container/$LVNAME && \
	schroot -c source:$LVNAME -u root --directory /root -- sh /root/install && \
	schroot -c source:$LVNAME -u root --directory /root -- bash -c "
		aptitude -f install
		aptitude -y purge \$(deborphan -n --guess-all)
		apt-get autoremove
		apt-get autoclean
		apt-get clean
		rm -rf /usr/src/*
		rm -f /etc/ssh_host_*
		rm -rf /var/tmp /tmp/*
		ln -s /tmp /var/tmp
		rm -f /var/log/wtmp /var/log/btmp
		rm -rf /var/lib/apt/lists/*
		rm -rf /var/lib/apt/lists/partial/*
		history -c" || exit 1

BACKUP="/var/backups/${LVNAME}_$(date +%F_%T).cpio.xz"
read -r -p "Build backup? [y/N] " response
case $response in
    [yY][eE][sS]|[yY]) 
	aptitude -y install cpio xz-utils
	mount -t $LVTYPE /dev/$VGNAME/$LVNAME /var/lib/container/$LVNAME && \
	cd /var/lib/container/$LVNAME && \
		find . -depth -print \
		| cpio --create --format=crc \
		| xz -v -6 -Csha256 > $BACKUP && \
	umount /var/lib/container/$LVNAME && \
	ls -lh $BACKUP
        ;;
esac

schroot -b -n $LVNAME -c source:$LVNAME -u root --directory /root -- sh /root/init && {
  sed -i -e '/^exit 0$/d' /etc/rc.local
  echo "schroot -b -n $LVNAME -c source:$LVNAME -u root --directory /root" >> /etc/rc.local
  [ -e /var/lib/container/$LVNAME/root/init ] && {
    echo "sleep 1\nschroot -r -c $LVNAME -u root --directory /root -- sh /root/init" >> /etc/rc.local
  }
  echo "\nexit 0" >> /etc/rc.local
}

