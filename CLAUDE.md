# CLAUDE.md

Guia para agentes trabalhando neste repositório. Visão geral para usuários: `README.md`.

## Objetivo e invariantes (não quebrar)

ISO do Alpine que instala um servidor com:

1. `/` e `/boot/efi` **sempre ro**. rw só via `roctl rw on`; o reboot sempre volta a ro (fstab + `ro` no cmdline).
2. Imagens Docker em p4 (`/mnt/docker-store`) **sempre ro**. rw só em `roctl store on`.
3. Estado de containers e logs em **`/dev/shm`**.
4. ZFS mirror em **`/mnt/zfs`** só se houver **2 discos inteiros livres do mesmo tamanho**. Nunca criar pool em disco com partições ou assinatura.
5. Samba compartilha só `/mnt/zfs/samba` (`/mnt/zfs` é do root; dados de apps em `/mnt/zfs/<app>_data` ficam fora), e só sobe se o pool estiver montado.
6. Funcionar em **bare metal**: BIOS e UEFI, NVMe/SATA, nunca apagar USB ou a mídia de boot.
7. O disco de boot (SSD/cartão SD) **só é lido** no dia a dia: nenhuma escrita fora de instalação, `rw on` e `store on` (medido: 0 KiB em 5 min de carga).

Qualquer coisa que precise escrever em runtime vai para `/run`, `/dev/shm` ou um dataset do pool, nunca para o root.

## Mapa

- `build.sh` (host): `docker build` + `docker run -u $(id -u) -v $PWD/out:/out`. Argumento opcional: versao do Alpine ou `latest`.
- `Dockerfile`: `alpine:3.24` + `xorriso` + `tar` (GNU, para `--owner=0` no overlay).
- `iso-src/build.sh` (container): resolve `latest` pelo `latest-releases.yaml`, baixa o ISO oficial e confere o SHA256 (cache em `/out`), cria `localhost.apkovl.tar.gz`, extrai os menus com `xorriso -osirrox on -extract`, aplica o `dup-entry.awk` e roda `xorriso -indev <iso> -outdev <novo> -boot_image any replay -map ...`.
- `iso-src/payload/install-ro.sh`: instalador. Particiona, roda `setup-disk`, instala pacotes, grava configs e instala GRUB i386-pc + x86_64-efi. `DRYRUN=1` para depois de escolher o disco e testar rede/repositorio.
- `iso-src/payload/rodiag`: relatorio da maquina no live (firmware, DMI, CPU, RAM, video/driver, PCI, discos, `DRYRUN=1 install-ro`, rede, `dmesg`) em `/tmp/rodiag.txt`; roda sozinho com `rodiag` no cmdline (`local.d/rodiag.start`).
- Menu do ISO (`dup-entry.awk`): `Linux lts`, `roinstall` (autoinstall), `rosafe` (autoinstall + `nomodeset`), `rodiag` (`nomodeset ignore_loglevel earlyprintk=efi|vga,keep initcall_debug`); sem `quiet` e com `initramfs_async=0` em todas; GRUB com `gfxpayload=keep`.
- `iso-src/payload/roctl`: toda a logica de runtime (`boot`, `stop`, `seed`, `layers`, `rw`, `store`, `zfs-init`, `snap`, `check`). `check` tem 17 itens com pool; sem pool, 12 + `SKIP ZFS`.
- `iso-src/payload/rodocker`: servico OpenRC (runlevel boot), wrapper do `roctl boot/stop`.
- `iso-src/payload/rodockerd`: `DOCKERD_BINARY`; roda `roctl layers` e faz `exec dockerd`.
- Cron (`/etc/crontabs/root`): `roctl snap` todo dia 0h (snapshot recursivo `tank@auto-*`, mantem `SNAP_KEEP`=30) e `zpool scrub` mensal.
- `iso-src/payload/roapp`: apps Docker recriados no boot (`/etc/local.d/roapp.start`) e apos `roctl store off`/`zfs-init` (que apagam todos os containers). Definicoes em `/etc/roapps/<app>.app` (`IMAGE`, `OPTS` com `-v @sub:/dst` = `/mnt/zfs/<app>_data/sub`, `CMD`, `ZFS`) ou `<app>.yml` (compose, `${DATA}`). `docker-cli-compose` vem instalado.
- `vm-test.sh` / `vm-del.sh` (este tambem tira `[localhost]:2222` e `[127.0.0.1]:2222` do `known_hosts`): VMs de teste QEMU/KVM em `~/vms/alpine-ro-<uefi|bios>`. Discos em virtio-scsi (`sda`, `sdb`, `sdc`; by-id `scsi-0QEMU_QEMU_HARDDISK_<serial>`), boot do disco antes do ISO, portas 2222/4450/9443/19999 + `EXTRA_PORTS` em 127.0.0.1 (o WSL2 repassa para o `localhost` do Windows; a VM ve o navegador como `10.0.2.2`), monitor em `monitor.sock`, serial em `serial.log`, `qemu.pid`.

## Armadilhas já resolvidas (não reintroduzir)

- **Docker 29 esconde submontagens**: na inicialização ele faz bind NÃO recursivo do data-root e do `overlay2` sobre si mesmos. O `roctl seed` torna `$DST` e `$DST/overlay2` pontos de montagem antes (`mount --bind X X; --make-private`). Sem isso os containers sobem com rootfs vazio e os volumes ZFS somem.
- `"features": {"containerd-snapshotter": false}` é obrigatório: o esquema depende do layout clássico do overlay2.
- **`zpool create` com link by-id falha** (`missing link: sdb was partitioned but .../ata-...-part1 is missing`): um disco pode ter dois links (`ata-*` e `scsi-*`) e o udev so recria `-part1` de um. O `zfs_init` cria com `/dev/sdX` e reimporta com `-d /dev/disk/by-id`; se falhar, `unpart` devolve os discos ao estado livre (senao nunca mais seriam "livres").
- `roctl store on/off` e `zfs-init` reiniciam o Docker com outro data-root: **todos os containers somem** e as imagens puxadas fora do `store on` também. Por isso ambos chamam `roapp up` no fim.
- O `setup-disk` copia o `/etc` do live: o `install-ro` remove `local.d/autoinstall.start` e troca o `motd` do instalador.
- **Logs com teto** (sistema 100 MiB, Docker 100 MiB): `/dev/shm/log` e `$DST/containers` sao tmpfs proprios (`roctl syslogfs`/`logfs`). Log driver `local` (2 x 2m): **o Docker 29 ignora `cache-max-size/file`** do cache do dual logging (fica 20m x 5 por container), por isso nao usar `syslog` + cache. `docker.log` via `log_proxy` (`LOGPROXY_ROTATION_SIZE`/`ROTATED_FILES` no conf.d).
- **O Docker desmonta o bind do `overlay2` e as camadas ro ao parar**: um `rc-service docker restart` subia containers com rootfs vazio. `DOCKERD_BINARY=/usr/local/sbin/rodockerd` chama `roctl layers` (idempotente) antes de todo start/respawn.
- **busybox `mountpoint` nao enxerga bind no mesmo fs** (compara `st_dev`): `mount --bind X X` em tmpfs da "not a mountpoint". Para isso usar `ismnt` (le `/proc/mounts`).
- **O ZFS ignora `zfs_arc_max` < `zfs_arc_min`** (padrao RAM/32, passa de 1 GiB com >32 GB de RAM): o `roctl boot` grava `arc_min`=ARC/4 antes do max. ARC = min(`ARC_MB`=1024, RAM/4).
- Sistema instalado em UTC por padrao do Alpine: o `install-ro` instala `tzdata` e grava `TZ` (padrao `America/Sao_Paulo`) para o snapshot das 0h e o cron.
- **busybox `blkid` ignora `-s/-o`**: extrair o UUID com `sed` (função `uuid()`).
- **busybox `awk` não aceita `{` ou `}` soltos em regex**: usar `[{]` e `[}]`.
- **busybox `ash` não tem `export -f`**; manter tudo POSIX sh.
- O overlay precisa ser root:root no tar (`--owner=0 --group=0`); o container roda como o usuario do host e sem isso o live herdaria `/etc` com outro dono.
- **Tela preta em UEFI antigo (ex.: H61) depois do GRUB**: o `quiet` do Alpine esconde ate o init (o `ebegin` dele nao imprime com `quiet`) e, sem `gfxpayload=keep`, o kernel pode ficar sem console ate o driver de video. O menu tira o `quiet`, poe `gfxpayload=keep` e oferece `rosafe`/`rodiag`; o `install-ro` grava `GRUB_GFXPAYLOAD_LINUX=keep` e repassa `nomodeset` do live ao sistema instalado.
- **`initramfs_async=0` em todas as entradas e no cmdline do sistema instalado**: na H61 (UEFI Aptio de 2011) o boot travava logo apos `PM: genpd: Disabling unused power domains`, esperando a descompactacao assincrona do initramfs; com o parametro (descompacta em sequencia) bootou.
- **Ventoy**: o hook dele para Alpine copia o `modloop` inteiro (~300 MB no 3.24) para a RAM antes do init ("Mounting boot media, please wait ......", do Ventoy); em QEMU, BIOS e UEFI bootam (Ventoy 1.1.18, ISO em FAT32). `INIT NOT FOUND` (o initramfs do Alpine nao chegou) foi relatado em bare metal e nao reproduziu.
- O menu do ISO oficial espera 1 s; o `dup-entry.awk` sobe para 10 s (GRUB `timeout=10`, syslinux `TIMEOUT 100`).
- Overlay do live: precisa de `etc/.default_boot_services`, senão o live perde os serviços padrão.
- **Botao de energia**: o `setup-disk` nao ativa o `acpid` (o live ativa); sem ele o botao nao faz nada. O `install-ro` poe `acpid:default` (`/etc/acpi/PWRF/00000080` = `poweroff`).
- Interfaces: `net.ifnames=0` no cmdline do sistema instalado (eudev renomearia `eth0`).
- `console=ttyS0,115200 console=tty0`: `tty0` por último para as mensagens irem ao monitor em bare metal.

## Persistência no sistema instalado

| O quê | Onde fica | Sobrevive ao reboot? |
|---|---|---|
| Imagens Docker | p4 (`/mnt/docker-store`, ro) via `roctl store on` | sim |
| Imagens puxadas fora do `store on` | `/dev/shm` | não |
| Containers (inclusive `--restart=always`) | `/dev/shm/docker` | **não** (recriados pelo `roapp`) |
| Definicoes de apps | `/etc/roapps` (ro) | sim |
| Volumes nomeados | `tank/docker-volumes` | sim (com pool) |
| Dados de apps | `/mnt/zfs/<app>_data` (bind) | sim (com pool) |
| Configuração do sistema | `/` (ro), via `roctl rw on` | sim |

Padrão para um serviço que precisa voltar após o reboot: `roapp add` / `roapp compose` (README). **Nunca guardar definições de apps no pool**: o pool é gravável por containers e o Samba fica nele; uma definição ali viraria execução como root no boot. Não tentar "consertar" isso persistindo `/var/lib/docker`: estado efêmero é requisito.

Escrever em `/`: `roctl rw on` (remonta `/` e `/boot/efi` rw) e depois `roctl rw off`; o reboot sempre volta a ro.

`-p H:C` sem IP já publica em todas as interfaces (`0.0.0.0` e `::`). Não há firewall configurado.

## Convenções

- Shell: POSIX sh compatível com busybox. Rodar `sh -n` em tudo antes de entregar.
- Scripts `.sh`, `roctl`, `roapp`, `rodiag`, `rodocker`, `rodockerd` e `.awk`: **LF**. O `Dockerfile` também faz `sed 's/\r$//'` por segurança.
- Textos e mensagens em português, sem acentos nos scripts (consoles e serial).
- O ZFS é criado no **1º boot do sistema instalado**, e não no live: o `zfs-lts` do repositório pode não casar com o kernel do ISO.

## Testes (QEMU no WSL2)

Ambiente esperado: WSL2 com Docker e `/dev/kvm` (QEMU, OVMF, socat; `tesseract` e ImageMagick ajudam a ler a tela pelo `screendump`). Fluxo:

```sh
./build.sh 3.24.2                                          # gera out/alpine-ro-3.24.2-x86_64.iso
./vm-test.sh uefi out/alpine-ro-3.24.2-x86_64.iso &        # escolher "instalar automaticamente" no GRUB
tail -f ~/vms/alpine-ro-uefi/serial.log                    # espera "INSTALL_OK"; a VM desliga sozinha
./vm-test.sh uefi &                                        # 1o boot do sistema instalado (cria o pool)
ssh -p 2222 root@127.0.0.1 roctl check                     # chave ~/.ssh/id_rsa.pub do host (fw_cfg); senha e negada
```

- Selecionar a entrada automatica sem interacao: UEFI (GRUB) `sendkey end` e `sendkey ret` dentro dos 10 s (a entrada automatica e a ultima; `tesseract` no `screendump` detecta o menu); BIOS (syslinux sem `menu.c32`, so o prompt `boot:`) digitar `roinstall` + `ret`. O ISOLINUX nao limpa a tela: detectar o banner, nao tela vazia.
- SSH no teste: o `vm-test.sh` passa `~/.ssh/id_rsa.pub` (ou `SSH_PUBKEY=`) por `-fw_cfg name=opt/alpine-ro/authorized_keys`; o `install-ro` le em `/sys/firmware/qemu_fw_cfg/by_name/...` (modulo `qemu_fw_cfg`) e grava no `authorized_keys`. So vale na instalacao (VM ja instalada antes disso: console, `sendkey` ~50 ms por tecla). Root por senha e negado (`prohibit-password`). Nao embutir chave de teste no ISO (`out/` pode ir para producao).
- Sessao sem o grupo `kvm` (usermod sem relogin): `sg kvm -c ./vm-test.sh ...`. Sem `vmx`/`svm` no `/proc/cpuinfo` o KVM falha mesmo com `/dev/kvm`: `TCG=1` (instalacao ~15 min em vez de ~3).
- Cenario principal (UEFI, discos iguais): ZFS mirror em `/mnt/zfs`, Samba ativo, `roctl check` todo PASS.
- Cenario negativo: `Z2_SIZE=5T` ou modo `bios` com discos diferentes. Sem ZFS, `check` mostra `SKIP ZFS`.
- Falhas: `device_del dz2` (DEGRADED, containers seguem), `quit` no meio de escrita (root e p4 voltam `clean`), encher `/dev/shm` (ENOSPC sem derrubar o host), `roctl store on` / `rw on` + reboot (volta a ro).

## Estado atual (handoff)

Tudo abaixo validado em QEMU no WSL2 em 2026-10-17, com TCG (o WSL nao expunha `svm`), ISO 3.24.2; antes disso, uma versao anterior foi validada em VirtualBox.

- **Instalacao e boot**: BIOS (`boot: roinstall`, GRUB i386-pc) e UEFI (GRUB do ISO, NVRAM `alpine` + fallback `\EFI\boot\bootx64.efi`); 1o boot cria o mirror; `check` 17/17; reboot reimporta o pool.
- **ZFS**: mirror por `/dev/sdX` reimportado por by-id; sem par de discos (`Z2_SIZE=5T`) nao cria pool e o Samba nao sobe; disco com particao ou so assinatura e recusado; `zfs-init` em runtime sobe Samba e apps; disco antigo reconectado e ignorado; snapshots diarios com rotacao e recuperacao por `.zfs/snapshot`; ARC parou em ~1 GiB lendo 2 GiB do pool.
- **Docker**: camadas ro na p4, estado em `/dev/shm`, `rc-service docker restart` e `store on/off` preservam as camadas; `roapp` (`add` com `@`, `compose` com `${DATA}`, volume nomeado, `ls/show/recreate/down/up/pull/rm`, label `roapp.app`, sem pool nao sobe apps com dados).
- **Logs**: estresse de 40-110 MB por container: syslog parou em 80 MiB, cada container em ~2,2 MiB.
- **Disco de boot**: 0 KiB escritos em 5 min de carga.
- **Falhas**: disco do mirror arrancado com escrita continua (DEGRADED, tudo segue, `check` acusa); reboot degradado; troca a quente + resilver; `quit` com escrita no pool e no meio de `docker pull` em `store on` (p4: `recovering journal` -> clean, camadas reaproveitadas); `/dev/shm` 100% (so `docker run` novo falha); reboot com `rw on` / `store on` esquecidos volta a ro.
- Em TCG o boot com muitas camadas leva >1 min ate o `roapp up` terminar: esperar antes do `check`.
- **Bare metal validado (2026-10-18)**: placa TGT H61 (LGA1155, UEFI Aptio de 2011, sem Legacy/CSM), SSD de ~112 GB. Antes: em UEFI o live travava logo apos `PM: genpd: Disabling unused power domains` (espera do initramfs) e pelo Ventoy dava `INIT NOT FOUND`; com `initramfs_async=0` bootou. Instalacao ok (p3 20 GiB, p4 91 GiB), 1o boot ok (DHCP), `check` 12 PASS + `SKIP ZFS` (um disco so). O sistema instalado bootou mesmo sem `initramfs_async=0` (initramfs dele e menor); o parametro foi mantido por seguranca.
- **Pendente:** ZFS + Samba em bare metal (precisa de 2 discos vazios do mesmo tamanho); Ventoy em bare metal com o ISO atual.
- Ideias em aberto: instalacao offline (pacotes embutidos no ISO); "Versoes anteriores" do Samba com os snapshots (`vfs_shadow_copy2`).

## Segurança

- Nao embutir chave de teste no ISO: nas VMs, o `vm-test.sh` passa a chave do usuario por fw_cfg. Nunca versionar chave privada.
- `iso-src/payload/authorized_keys` é embutido no ISO: em produção, usar a chave do próprio usuário ou remover o arquivo.
- Senhas padrão (`alpine`) só para teste; documentar `ROOTPW` e `SMBPW`.
- Root no SSH so por chave (`prohibit-password`, padrao do OpenSSH): a senha so vale no console. Nao liberar `PermitRootLogin yes` de forma permanente; o README ensina a liberar so para o `ssh-copy-id`.
