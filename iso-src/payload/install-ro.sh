#!/bin/sh
# install-ro: instala Alpine com /, /boot/efi e p4 sempre em ro; Docker em /dev/shm; volumes em ZFS
# (o pool ZFS mirror e criado no 1o boot so se houver 2 discos livres de mesmo tamanho), montado
# em /mnt/zfs (RAID1 por software); Samba em \\<host>\zfs = /mnt/zfs/samba. Apps: roapp (/etc/roapps). Funciona em BIOS e UEFI. Senhas: ROOTPW, SMBPW (padrao: alpine).
# TZ (padrao America/Sao_Paulo; vale para o snapshot diario das 0h), SNAP_KEEP (snapshots mantidos, padrao 30).
# Disco de boot: rodisk=/dev/X no cmdline do kernel, variavel DISK, ou o MENOR disco interno (>= 32 GiB).
set -e
CFG=${CFG:-/usr/share/rodocker} T=/mnt
step() { echo; echo "=== $* ==="; }
uuid() { blkid $1 | sed -n 's/.* UUID="\([^"]*\)".*/\1/p'; }   # blkid do busybox ignora -s/-o
trap 'echo; echo "!!! INSTALL FALHOU !!!"' EXIT

# ---------- escolha do disco (nunca USB, nunca a midia de boot) ----------
bootmedia=$(awk '$2 ~ /^\/media\// {sub("/dev/","",$1); print $1}' /proc/mounts | sed 's/p\?[0-9]*$//' | sort -u)
candidates() {
	for s in /sys/block/sd* /sys/block/vd* /sys/block/nvme*n* /sys/block/mmcblk[0-9]; do
		[ -e "$s" ] || continue; n=${s##*/}
		[ "$(cat $s/removable)" = 0 ] && [ "$(cat $s/ro)" = 0 ] || continue
		readlink -f $s | grep -q /usb && continue
		echo " $bootmedia " | grep -q " $n " && continue
		sz=$(cat $s/size); [ $sz -ge 67108864 ] || continue      # >= 32 GiB
		echo "$sz $n"
	done
}
DISK=${DISK:-$(sed -n 's/.*rodisk=\([^ ]*\).*/\1/p' /proc/cmdline)}
[ -n "$DISK" ] || DISK=/dev/$(candidates | sort -n | awk 'NR==1{print $2}')
[ -b "$DISK" ] || { echo "nenhum disco interno >= 32 GiB encontrado"; exit 1; }
case $DISK in *nvme*|*mmcblk*) P=${DISK}p ;; *) P=$DISK ;; esac
[ -d /sys/firmware/efi ] && EFI=1 || EFI=
echo "disco de boot: $DISK ($(($(cat /sys/block/${DISK#/dev/}/size)/2097152)) GiB), firmware: $([ -n "$EFI" ] && echo UEFI || echo BIOS)"
echo "discos internos: $(candidates | awk '{printf "%s(%dG) ", $2, $1/2097152}')"

step "[1/6] rede, repositorios e particoes (bios_grub 1M | EFI 512M | root 20G | docker-store resto)"
printf 'auto lo\niface lo inet loopback\n' > /etc/network/interfaces
for i in $(ls /sys/class/net | grep -v '^lo$'); do
	[ -e /sys/class/net/$i/device ] || continue; ip link set $i up
done
sleep 10
up=
for i in $(ls /sys/class/net | grep -v '^lo$'); do
	[ "$(cat /sys/class/net/$i/carrier 2>/dev/null)" = 1 ] || continue
	udhcpc -i $i -n -q -t 5 && { up=$i; break; }
done
[ -n "$up" ] || { echo "sem rede com DHCP (a instalacao baixa pacotes)"; exit 1; }
echo "rede: $up"
V=$(cut -d. -f1,2 /etc/alpine-release) M=https://dl-cdn.alpinelinux.org/alpine
printf '%s/v%s/main\n%s/v%s/community\n' $M $V $M $V > /etc/apk/repositories
apk update && apk add sfdisk e2fsprogs dosfstools
for m in $T/dev $T/proc $T/sys $T/boot/efi $T; do umount $m 2>/dev/null || true; done
for p in $(ls /sys/block/${DISK#/dev/}/ | grep "^${DISK#/dev/}"); do umount /dev/$p 2>/dev/null || true; done
printf ',1M,21686148-6449-6E6F-744E-656564454649\n,512M,U\n,20G,L\n,,L\n' | sfdisk --wipe always --wipe-partitions always --label gpt $DISK
sleep 2; mdev -s; sleep 1
mkfs.vfat -F32 -n EFI ${P}2
mkfs.ext4 -F -q -L root ${P}3
mkfs.ext4 -F -q -L dockstore ${P}4
mount -t ext4 ${P}3 $T && mkdir -p $T/boot/efi && mount -t vfat ${P}2 $T/boot/efi

step "[2/6] setup-disk e pacotes"
echo "root:${ROOTPW:-alpine}" | chpasswd
echo alpine-ro > /etc/hostname
BOOTLOADER=grub USE_EFI=$EFI setup-disk -m sys $T
for d in dev proc sys; do mount --bind /$d $T/$d; done
[ -n "$EFI" ] && mount -t efivarfs efivarfs $T/sys/firmware/efi/efivars 2>/dev/null || true
cp /etc/resolv.conf $T/etc/
apk --root $T add docker docker-openrc zfs zfs-lts openssh grub-efi grub-bios efibootmgr \
	eudev udev-init-scripts udev-init-scripts-openrc linux-firmware intel-ucode amd-ucode \
	samba samba-server-openrc docker-cli-compose tzdata
c() { chroot $T "$@"; }
c ssh-keygen -A; c zgenhostid -f; echo "root:${ROOTPW:-alpine}" | c chpasswd

step "[3/6] fstab ro, rede e caminhos gravaveis em /run e /dev/shm"
mkdir -p $T/mnt/docker-store $T/mnt/zfs $T/var/lib/samba $T/usr/local/sbin $T/etc/docker $T/etc/udhcpc $T/root/.ssh $T/etc/roapps
cat > $T/etc/fstab <<F
UUID=$(uuid ${P}3)  /                  ext4   ro,noatime             0 1
UUID=$(uuid ${P}2)  /boot/efi          vfat   ro,noatime,umask=0077  0 2
UUID=$(uuid ${P}4)  /mnt/docker-store  ext4   ro,noatime             0 2
tmpfs  /tmp  tmpfs  nosuid,nodev,mode=1777,size=512M  0 0
F
for l in var/log:/dev/shm/log var/tmp:/tmp var/lib/docker:/dev/shm/docker \
	var/lib/containerd:/dev/shm/containerd etc/resolv.conf:/run/resolv.conf; do
	rm -rf $T/${l%%:*}; ln -s ${l#*:} $T/${l%%:*}
done
echo 'RESOLV_CONF="/run/resolv.conf"' > $T/etc/udhcpc/udhcpc.conf
# DHCP em todas as placas ethernet (nomes ethN fixados por net.ifnames=0); udhcpc em background
{ printf 'auto lo\niface lo inet loopback\n'
  n=0; for i in $(ls /sys/class/net); do
	[ -e /sys/class/net/$i/device ] && [ ! -e /sys/class/net/$i/wireless ] || continue
	printf '\nauto eth%d\niface eth%d inet dhcp\n' $n $n; n=$((n+1))
  done; } > $T/etc/network/interfaces
echo alpine-ro > $T/etc/hostname

step "[4/6] Docker, syslog, ZFS, roctl, roapp"
install -m 755 $CFG/roctl $T/usr/local/sbin/roctl
install -m 755 $CFG/roapp $T/usr/local/sbin/roapp
install -m 755 $CFG/rodockerd $T/usr/local/sbin/rodockerd
install -m 755 $CFG/rodocker $T/etc/init.d/rodocker
# logs dos containers: driver local (docker logs), 2 x 2 MiB por container; o total fica num tmpfs de
# 92 MiB (roctl logfs). Nao usar syslog + cache-max-*: o Docker 29 ignora o limite do cache (20 MiB x 5).
cat > $T/etc/docker/daemon.json <<F
{ "storage-driver": "overlay2", "log-driver": "local",
  "log-opts": { "max-size": "2m", "max-file": "2" },
  "features": { "containerd-snapshotter": false } }
F
cat > $T/etc/conf.d/docker <<'F'
DOCKER_OPTS="--data-root $(cat /run/docker-root 2>/dev/null || echo /dev/shm/docker)"
DOCKERD_BINARY="/usr/local/sbin/rodockerd"
DOCKER_LOGFILE="/dev/shm/log/docker.log"
LOGPROXY_ROTATION_SIZE=4194304
LOGPROXY_ROTATED_FILES=2
rc_after="rodocker"
F
# syslog: 20 MiB + 3 rotacoes = 80 MiB, dentro do tmpfs de 100 MiB de /dev/shm/log (roctl syslogfs)
echo 'SYSLOGD_OPTS="-t -O /dev/shm/log/messages -s 20480 -b 3"' > $T/etc/conf.d/syslog
echo "0 3 1 * * /usr/sbin/zpool scrub tank" >> $T/etc/crontabs/root
echo "0 0 * * * /usr/local/sbin/roctl snap" >> $T/etc/crontabs/root      # snapshot diario do pool
TZ=${TZ:-America/Sao_Paulo}
[ -f $T/usr/share/zoneinfo/$TZ ] || { echo "TZ invalido: $TZ; usando UTC"; TZ=UTC; }
cp $T/usr/share/zoneinfo/$TZ $T/etc/localtime && echo $TZ > $T/etc/timezone
sed -i 's/^#\?rc_cgroup_mode=.*/rc_cgroup_mode="unified"/' $T/etc/rc.conf
[ -f $CFG/authorized_keys ] && install -m 600 $CFG/authorized_keys $T/root/.ssh/authorized_keys
# VM de teste: o vm-test.sh passa a chave do usuario do host pelo fw_cfg do QEMU (em bare metal nao existe)
modprobe qemu_fw_cfg 2>/dev/null || true
FWK=/sys/firmware/qemu_fw_cfg/by_name/opt/alpine-ro/authorized_keys/raw
if [ -r $FWK ]; then cat $FWK >> $T/root/.ssh/authorized_keys; chmod 600 $T/root/.ssh/authorized_keys; echo "chave SSH do fw_cfg (vm-test.sh) adicionada"; fi
chmod 700 $T/root/.ssh

# Samba: compartilha so /mnt/zfs/samba (os dados dos apps ficam fora); usuario smb; estado em /var/lib/samba (dataset do pool)
c adduser -D -H -h /mnt/zfs/samba -s /sbin/nologin ${SMBUSER:-smb} 2>/dev/null || true
printf 'SMBUSER=%s\nSMBPW=%s\nSNAP_KEEP=%s\n' "${SMBUSER:-smb}" "${SMBPW:-alpine}" "${SNAP_KEEP:-30}" > $T/etc/rodocker.conf
chmod 600 $T/etc/rodocker.conf
mkdir -p $T/etc/samba
cat > $T/etc/samba/smb.conf <<F
[global]
   workgroup = WORKGROUP
   server string = Alpine RO
   server role = standalone server
   map to guest = never
   disable netbios = yes
   smb ports = 445
   server min protocol = SMB2_10
   logging = file
   log file = /dev/shm/log/samba.log
   max log size = 1000
   pid directory = /run/samba
   lock directory = /run/samba/lock
   cache directory = /run/samba/cache
   ncalrpc dir = /run/samba/ncalrpc
   state directory = /var/lib/samba
   private dir = /var/lib/samba/private
   load printers = no
   printcap name = /dev/null
   disable spoolss = yes

[zfs]
   path = /mnt/zfs/samba
   read only = no
   valid users = ${SMBUSER:-smb}
   force user = ${SMBUSER:-smb}
   create mask = 0664
   directory mask = 0775
F
echo 'daemon_list="smbd"' > $T/etc/conf.d/samba
cat > $T/etc/local.d/samba.start <<'F'
#!/bin/sh
# sobe o Samba so se o pool estiver montado (sem par de discos nao ha ZFS nem compartilhamento)
. /etc/rodocker.conf
mountpoint -q /mnt/zfs || { echo "samba: sem pool ZFS em /mnt/zfs; compartilhamento desativado"; exit 0; }
mkdir -p /run/samba/lock /run/samba/cache /run/samba/ncalrpc /mnt/zfs/samba && chown "$SMBUSER": /mnt/zfs/samba
pdbedit -L 2>/dev/null | grep -q "^$SMBUSER:" || printf '%s\n%s\n' "$SMBPW" "$SMBPW" | smbpasswd -s -a "$SMBUSER"
rc-service samba start
F
chmod 755 $T/etc/local.d/samba.start
printf '#!/bin/sh\n# recria os containers definidos em /etc/roapps (o estado do Docker some no reboot)\nexec /usr/local/sbin/roapp up\n' > $T/etc/local.d/roapp.start
chmod 755 $T/etc/local.d/roapp.start
# o setup-disk copia o /etc do live: sem o gatilho de autoinstall e sem o motd do instalador
rm -f $T/etc/local.d/autoinstall.start
cat > $T/etc/motd <<'F'

  Alpine RO: /, /boot/efi e imagens Docker somente leitura; containers em /dev/shm; dados em /mnt/zfs (ZFS)

  roctl check | rw on|off | store on|off     roapp ls | add | compose | up | pull | rm
  Samba: \\<host>\zfs = /mnt/zfs/samba

F

step "[5/6] servicos e bootloader (BIOS + UEFI, cmdline com ro)"
for s in udev:sysinit udev-trigger:sysinit udev-settle:sysinit udev-postmount:default \
	rodocker:boot networking:boot docker:default sshd:default crond:default local:default; do
	c rc-update add ${s%%:*} ${s#*:}
done
c rc-update del mdev sysinit 2>/dev/null || true
sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/d; /^GRUB_TIMEOUT=/d' $T/etc/default/grub
echo 'GRUB_TIMEOUT=3
GRUB_CMDLINE_LINUX_DEFAULT="modules=sd-mod,nvme,ext4 rootfstype=ext4 ro net.ifnames=0 console=ttyS0,115200 console=tty0"' >> $T/etc/default/grub
c grub-install --target=i386-pc $DISK                       # BIOS (legacy/CSM)
c grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=alpine --removable --no-nvram
if [ -n "$EFI" ]; then                                       # entrada na NVRAM da placa-mae
	c grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=alpine || \
		echo "aviso: nao gravei a NVRAM; o boot usa EFI/BOOT/BOOTX64.EFI"
fi
c grub-mkconfig -o /boot/grub/grub.cfg

step "[6/6] finalizando"
cat $T/etc/fstab $T/etc/network/interfaces
sync
[ -n "$EFI" ] && umount $T/sys/firmware/efi/efivars 2>/dev/null || true
for m in dev proc sys boot/efi; do umount $T/$m; done; umount $T
trap - EXIT; echo; echo "##### INSTALL_OK #####"
