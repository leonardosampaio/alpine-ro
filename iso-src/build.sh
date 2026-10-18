#!/bin/sh
# Roda DENTRO do container (veja Dockerfile e ../build.sh).
# Gera $OUT/alpine-ro-<versao>-x86_64.iso a partir do ISO oficial alpine-standard:
#   overlay do live (instalador + autoinstall) e entrada de menu extra; o boot BIOS/UEFI
#   e o isohybrid do original sao preservados pelo xorriso (-boot_image any replay).
# uso: build.sh [versao|latest]   (env: OUT=/out MIRROR=https://dl-cdn.alpinelinux.org/alpine)
set -e
S=$(cd "$(dirname "$0")" && pwd) OUT=${OUT:-/out} W=/tmp/w O=/tmp/ovl ARCH=x86_64
M=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
V=${1:-${ALPINE_VERSION:-latest}}
rm -rf $W $O; mkdir -p $W $O $OUT

echo "=== [1/4] ISO oficial ==="
if [ "$V" = latest ]; then
	V=$(wget -qO- $M/latest-stable/releases/$ARCH/latest-releases.yaml \
		| sed -n "s/.*file: alpine-standard-\(.*\)-$ARCH\.iso.*/\1/p" | head -1)
	[ -n "$V" ] || { echo "nao consegui descobrir a versao latest"; exit 1; }
fi
ISO=alpine-standard-$V-$ARCH.iso URL=$M/v${V%.*}/releases/$ARCH
SRC=$OUT/$ISO
wget -qO $W/iso.sha256 $URL/$ISO.sha256
if [ ! -f $SRC ] || ! (cd $OUT && sha256sum -c $W/iso.sha256 >/dev/null 2>&1); then
	echo "baixando $URL/$ISO"
	wget -q -O $SRC.part $URL/$ISO && mv $SRC.part $SRC
fi
(cd $OUT && sha256sum -c $W/iso.sha256) || { echo "SHA256 do ISO oficial nao confere"; exit 1; }

echo "=== [2/4] overlay do live (localhost.apkovl.tar.gz) ==="
mkdir -p $O/usr/local/sbin $O/usr/share/rodocker $O/etc/local.d $O/etc/runlevels/default $O/etc/apk
install -m 755 $S/payload/install-ro.sh $O/usr/local/sbin/install-ro
install -m 755 $S/payload/rodiag $O/usr/local/sbin/rodiag
install -m 755 $S/payload/roctl $S/payload/rodocker $S/payload/roapp $S/payload/rodockerd $O/usr/share/rodocker/
[ -f $S/payload/authorized_keys ] && install -m 600 $S/payload/authorized_keys $O/usr/share/rodocker/
touch $O/etc/.default_boot_services                  # mantem os servicos padrao do live
echo /media/cdrom/apks > $O/etc/apk/repositories
echo alpine-base > $O/etc/apk/world
ln -s /etc/init.d/local $O/etc/runlevels/default/local
cat > $O/etc/local.d/autoinstall.start <<'EOF'
#!/bin/sh
grep -qw autoinstall /proc/cmdline || exit 0
{
	echo; echo ">>> AUTOINSTALL: o disco escolhido sera APAGADO em 15 s (Ctrl+Alt+Del cancela)"; sleep 15
	if /usr/local/sbin/install-ro; then
		echo ">>> Instalado. Desligando em 10 s; remova o pendrive/ISO antes de ligar."; sleep 10; poweroff
	else
		echo ">>> Falhou. Veja as mensagens acima; rode 'install-ro' para tentar de novo."
	fi
} 2>&1 | tee /dev/tty1 /dev/ttyS0 2>/dev/null
EOF
chmod 755 $O/etc/local.d/autoinstall.start
cat > $O/etc/local.d/rodiag.start <<'EOF'
#!/bin/sh
# entrada "diagnostico" do menu: relatorio da maquina, sem instalar nada
grep -qw rodiag /proc/cmdline || exit 0
/usr/local/sbin/rodiag 2>&1 | tee /dev/tty1 /dev/ttyS0 >/dev/null 2>&1
EOF
chmod 755 $O/etc/local.d/rodiag.start
cat > $O/etc/motd <<'EOF'

  Alpine RO (/, /boot/efi e imagens Docker somente leitura; containers em /dev/shm; volumes e /mnt/zfs em ZFS RAID1 + Samba)

  install-ro           instala no menor disco interno >= 32 GiB (APAGA o disco)
  DISK=/dev/X install-ro   escolhe o disco      (ou rodisk=/dev/X no boot)
  rodiag               relatorio da maquina (firmware, video, discos, rede); nao grava nada

EOF
find $O -type d -exec chmod 755 {} +
tar --owner=0 --group=0 --numeric-owner -C $O -czf $W/localhost.apkovl.tar.gz .
tar -tzvf $W/localhost.apkovl.tar.gz

echo "=== [3/4] menus de boot (espera 10 s + entrada de instalacao automatica) ==="
MAP=
for c in grub:/boot/grub/grub.cfg syslinux:/boot/syslinux/syslinux.cfg; do
	k=${c%%:*} p=${c#*:}
	xorriso -osirrox on -indev $SRC -extract $p $W/$k.orig >/dev/null 2>&1 || continue
	awk -f $S/dup-entry.awk -v kind=$k $W/$k.orig > $W/$k.cfg
	MAP="$MAP -map $W/$k.cfg $p"
	cat $W/$k.cfg
done

echo "=== [4/4] xorriso ==="
DST=$OUT/alpine-ro-$V-$ARCH.iso
rm -f $DST
xorriso -indev $SRC -outdev $DST -boot_image any replay \
	-map $W/localhost.apkovl.tar.gz /localhost.apkovl.tar.gz $MAP -commit >$W/x.log 2>&1 \
	|| { cat $W/x.log; echo "xorriso falhou"; exit 1; }
grep -v 'UPDATE' $W/x.log | tail -4
xorriso -indev $DST -report_el_torito plain 2>&1 | grep -E 'El Torito (boot img|platform)|^El Torito' | head -6
(cd $OUT && sha256sum ${DST##*/} > ${DST##*/}.sha256)
echo
echo "OK: ${DST##*/} ($(($(stat -c %s $DST)/1048576)) MiB)  sha256 $(cut -d' ' -f1 $DST.sha256)"
