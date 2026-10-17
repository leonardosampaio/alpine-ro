#!/bin/sh
# Desliga e apaga VMs de teste criadas pelo vm-test.sh (discos, NVRAM, logs) e as chaves de host delas no known_hosts.
# uso: ./vm-del.sh [uefi|bios|all] [-y]
set -e
WHAT=${1:-all} YES=$2 V=${VMS:-$HOME/vms}
case $WHAT in uefi|bios) L=$WHAT ;; all) L="uefi bios" ;; *) echo "uso: $0 [uefi|bios|all] [-y]"; exit 1 ;; esac
for m in $L; do
	D=$V/alpine-ro-$m
	[ -d "$D" ] || { echo "$m: nao existe"; continue; }
	if [ "$YES" != -y ]; then
		printf "apagar %s (%s em uso)? [s/N] " "$D" "$(du -sh "$D" | cut -f1)"; read r
		case $r in s|S|y|Y) ;; *) echo "$m: mantida"; continue ;; esac
	fi
	if [ -f $D/qemu.pid ] && P=$(cat $D/qemu.pid) && kill -0 "$P" 2>/dev/null; then
		echo "$m: desligando (pid $P)"
		kill "$P"; for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$P" 2>/dev/null || break; sleep 1; done
		kill -0 "$P" 2>/dev/null && kill -9 "$P"
	fi
	rm -rf -- "$D"
	echo "$m: apagada"; DEL=1
done
# a proxima VM gera chaves de host novas na mesma porta: tira as antigas do known_hosts
if [ -n "$DEL" ] && [ -f "$HOME/.ssh/known_hosts" ]; then
	for h in '[localhost]:2222' '[127.0.0.1]:2222'; do
		ssh-keygen -F "$h" >/dev/null 2>&1 && ssh-keygen -R "$h" >/dev/null 2>&1 && echo "known_hosts: $h removido"
	done
fi
rmdir "$V" 2>/dev/null || true
