#!/bin/sh
# Sobe uma VM de teste do Alpine RO com QEMU/KVM (WSL2 ou Linux).
# uso: ./vm-test.sh [uefi|bios] [iso]       sem iso: boota do disco ja instalado
# env: SSH_PUBKEY=~/.ssh/id_rsa.pub TCG=1 (sem KVM) MEM=8G CPUS=2 BOOT_SIZE=128G Z1_SIZE=6T Z2_SIZE=6T VMS=~/vms
#      (Z2_SIZE diferente de Z1_SIZE testa o cenario "sem ZFS")
# Portas no host (127.0.0.1; no WSL2 tambem em localhost no Windows): ssh 2222, samba 4450, portainer 9443,
# netdata 19999 e EXTRA_PORTS="P1 P2" (mesma porta na VM). Com a VM ligada: echo "hostfwd_add n tcp:127.0.0.1:P-:P" | socat - UNIX:monitor.sock
set -e
MODE=${1:-uefi} ISO=$2
case $MODE in uefi|bios) ;; *) echo "uso: $0 [uefi|bios] [iso]"; exit 1 ;; esac
D=${VMS:-$HOME/vms}/alpine-ro-$MODE
[ -n "$ISO" ] && { [ -f "$ISO" ] || { echo "ISO nao encontrado: $ISO"; exit 1; }; ISO=$(readlink -f "$ISO"); }
# KVM exige /dev/kvm gravavel e vmx/svm visivel (WSL2: nestedVirtualization=true); senao TCG (lento)
if [ -w /dev/kvm ] && grep -qwE 'vmx|svm' /proc/cpuinfo; then ACCEL="-enable-kvm -cpu host"
elif [ "$TCG" = 1 ]; then ACCEL="-accel tcg,thread=multi -cpu max"; echo "AVISO: sem KVM, usando TCG (emulado, bem mais lento)"
else echo "KVM indisponivel (sem vmx/svm no /proc/cpuinfo ou /dev/kvm sem permissao; grupo kvm? nestedVirtualization?). TCG=1 forca emulacao"; exit 1; fi
command -v qemu-system-x86_64 >/dev/null || { echo "instale: sudo apt install -y qemu-system-x86 qemu-utils ovmf"; exit 1; }
if [ -f $D/qemu.pid ] && kill -0 "$(cat $D/qemu.pid)" 2>/dev/null; then echo "VM $MODE ja esta rodando (pid $(cat $D/qemu.pid))"; exit 1; fi

mkdir -p $D
for d in boot:${BOOT_SIZE:-128G} z1:${Z1_SIZE:-6T} z2:${Z2_SIZE:-6T}; do
	[ -f $D/${d%%:*}.qcow2 ] || qemu-img create -q -f qcow2 $D/${d%%:*}.qcow2 ${d#*:}
done

FW=
if [ $MODE = uefi ]; then
	CODE=$(ls /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd 2>/dev/null | head -1)
	VARS=$(ls /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd 2>/dev/null | head -1)
	[ -n "$CODE" ] || { echo "instale o pacote ovmf"; exit 1; }
	[ -f $D/VARS.fd ] || cp $VARS $D/VARS.fd
	FW="-drive if=pflash,format=raw,readonly=on,file=$CODE -drive if=pflash,format=raw,file=$D/VARS.fd"
fi
# disco primeiro (bootindex=1): com disco vazio cai no ISO; depois de instalado nao reinstala em loop
CD=; [ -n "$ISO" ] && CD="-drive id=cd,file=$ISO,if=none,media=cdrom,readonly=on -device scsi-cd,drive=cd,bootindex=2"
# chave publica do usuario -> fw_cfg; o install-ro grava em /root/.ssh/authorized_keys da VM
KEY=${SSH_PUBKEY:-$HOME/.ssh/id_rsa.pub} FWCFG=
if [ -f "$KEY" ]; then FWCFG="-fw_cfg name=opt/alpine-ro/authorized_keys,file=$KEY"
else echo "aviso: $KEY nao existe; a VM so aceita a chave embutida no ISO (ou o console)"; fi
FWD=; for p in $EXTRA_PORTS; do FWD="$FWD,hostfwd=tcp:127.0.0.1:$p-:$p"; done
if [ -n "$DISPLAY$WAYLAND_DISPLAY" ] && qemu-system-x86_64 -display help 2>/dev/null | grep -qx gtk; then DISP="-display gtk"
else DISP="-display none -vnc 127.0.0.1:0"; echo "sem WSLg ou QEMU sem gtk: use um cliente VNC em 127.0.0.1:5900"; fi

echo "VM $MODE: ${MEM:-8G} RAM, ${CPUS:-2} vCPU, discos em $D"
echo "serial: tail -f $D/serial.log | ssh: ssh -p 2222 root@127.0.0.1 | monitor: socat - UNIX:$D/monitor.sock"
qemu-system-x86_64 -name alpine-ro-$MODE -machine q35 $ACCEL \
	-smp ${CPUS:-2} -m ${MEM:-8G} $FW \
	-device virtio-scsi-pci,id=scsi \
	-drive id=boot,file=$D/boot.qcow2,if=none,discard=unmap -device scsi-hd,drive=boot,serial=BOOT,bootindex=1 \
	-drive id=z1,file=$D/z1.qcow2,if=none,discard=unmap   -device scsi-hd,drive=z1,serial=ZFS1,id=dz1 \
	-drive id=z2,file=$D/z2.qcow2,if=none,discard=unmap   -device scsi-hd,drive=z2,serial=ZFS2,id=dz2 \
	$CD $FWCFG \
	-netdev user,id=n,hostfwd=tcp:127.0.0.1:2222-:22,hostfwd=tcp:127.0.0.1:4450-:445,hostfwd=tcp:127.0.0.1:9443-:9443,hostfwd=tcp:127.0.0.1:19999-:19999$FWD \
	-device virtio-net-pci,netdev=n \
	-serial file:$D/serial.log \
	-monitor unix:$D/monitor.sock,server,nowait \
	-pidfile $D/qemu.pid \
	$DISP
