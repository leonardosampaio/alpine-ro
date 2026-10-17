# Alpine RO

ISO de instalação do Alpine Linux que gera um servidor com **sistema somente leitura**, **Docker** e **armazenamento ZFS em RAID1 compartilhado via Samba**. Funciona em bare metal (BIOS e UEFI) e em VMs.

## O que o sistema instalado faz

| Item | Comportamento |
|---|---|
| `/` e `/boot/efi` | Sempre montados **ro**. Escrita só com `roctl rw on` (volta a ro no reboot) |
| Imagens Docker | Partição própria (p4), sempre **ro**. Atualizar só com `roctl store on` |
| Containers | Camada gravável em `/dev/shm` (RAM): somem no reboot |
| Logs | Na RAM, com teto: sistema ≤ 100 MiB (`/dev/shm/log`), Docker ≤ 100 MiB (veja [Logs](#logs)) |
| Snapshots | Snapshot diário do pool às 0h (fuso `TZ`), mantém os 30 últimos (veja [Snapshots](#snapshots-zfs)) |
| ZFS | Mirror (RAID1 por software) montado em **`/mnt/zfs`**, criado no 1º boot **somente se houver 2 discos livres do mesmo tamanho** |
| Volumes Docker | No pool ZFS (`tank/docker-volumes`), persistentes |
| Samba | Compartilha `/mnt/zfs/samba` em `\\<host>\zfs` (só sobe se o pool existir). Os dados dos apps (`/mnt/zfs/<app>_data`) ficam fora do compartilhamento |
| Apps Docker | Definidos em `/etc/roapps` e recriados a cada boot pelo `roapp` |
| RAM | `/dev/shm` = 3/8 da RAM; cache ARC do ZFS até **1 GiB** (no máximo 1/4 da RAM; mude com `ARC_MB=` em `/etc/rodocker.conf`) |

Sem o par de discos, não há ZFS nem Samba: os volumes Docker ficam em RAM.

### Desgaste do disco de boot (SSD, cartão SD)

O objetivo do `/` ro é o disco de boot **só ser lido** no dia a dia; toda escrita vai para a RAM ou para os discos do pool. Medido em VM (5 min com containers gravando, Redis salvando, arquivos no pool e syslog): **0 KiB escritos no disco de boot**, 44 MiB em cada disco do mirror.

| Escreve no disco de boot | Quando |
|---|---|
| Instalação | uma vez |
| `roctl rw on` (ex.: `apk upgrade`) | só enquanto estiver ligado |
| `roctl store on` / `roapp pull` / `roapp add` com imagem nova | só durante o download das imagens (p4) |
| Nada mais | containers, logs, `/tmp` e cache na RAM; dados e volumes no pool |

Cuidados:

- Sem o pool, nada é escrito em disco nenhum, mas os dados dos apps somem no reboot (por isso o `roapp` não sobe apps com dados sem o pool).
- HDs externos USB servem para o pool se o kernel os mostrar como não removíveis (`/sys/block/sdX/removable` = 0; pendrives costumam ser 1 e são ignorados). Prefira SATA/NVMe internos ou gavetas USB com UAS estável: um disco que cai e volta deixa o mirror `DEGRADED` até o `zpool online`/`clear`.
- Queda de energia não corrompe o sistema: `/`, `/boot/efi` e p4 estão ro, e o ZFS é transacional.

## Gerar o ISO (Docker)

Requisitos: Linux ou WSL2 com Docker, e internet.

```sh
./build.sh            # ultima versao estavel do Alpine
./build.sh 3.24.2     # versao especifica
```

Saida: `out/alpine-ro-<versao>-x86_64.iso` e o `.sha256` correspondente, em cerca de 1 minuto apos o download.

O container (`Dockerfile`, Alpine + `xorriso`) baixa o `alpine-standard-<versao>-x86_64.iso` oficial para `out/` (cache, conferido por SHA256). Depois acrescenta o overlay do live com o instalador e a entrada "instalar automaticamente" nos menus, e regrava o ISO **preservando o boot BIOS + UEFI e o isohybrid do original**. Nao precisa de `--privileged` nem de VM.

Para embutir sua chave SSH no sistema instalado, coloque-a em `iso-src/payload/authorized_keys` antes do build. Nas VMs de teste não precisa: o `vm-test.sh` passa a sua `~/.ssh/id_rsa.pub` para a instalação (veja abaixo).

## Instalar

1. Grave o ISO num pendrive com **Rufus (modo DD)** ou **balenaEtcher**.
2. **Desative o Secure Boot** (o GRUB do Alpine não é assinado).
3. Conecte o cabo de rede: a instalação baixa os pacotes (DHCP).
4. No menu de boot (10 s):
   - **Linux lts**: live; faça login como `root` e rode `install-ro`.
   - **Alpine RO - instalar automaticamente**: instala sozinho e desliga. **Apaga o disco escolhido.**

Disco de boot: o **menor disco interno ≥ 32 GiB** (nunca USB nem o próprio pendrive). Para escolher, use `rodisk=/dev/sdX` no cmdline do boot ou `DISK=/dev/sdX install-ro`.

Senhas padrão: root `alpine`, Samba (usuário `smb`) `alpine`. Para trocar, use `ROOTPW=... SMBPW=... install-ro`.

Outras variáveis do `install-ro`: `TZ` (fuso, padrão `America/Sao_Paulo`; define a hora do snapshot diário) e `SNAP_KEEP` (snapshots mantidos, padrão 30). Ex.: `TZ=Europe/Lisbon SNAP_KEEP=14 install-ro`.

### Layout do disco de boot

| Partição | Tamanho | Uso |
|---|---|---|
| p1 | 1 MiB | BIOS boot (GRUB legado) |
| p2 | 512 MiB | EFI (`/boot/efi`, ro) |
| p3 | 20 GiB | `/` (ro) |
| p4 | resto | `/mnt/docker-store`: imagens Docker (ro) |

## Uso no dia a dia: `roctl`

```sh
roctl check          # valida tudo (ro, logs, docker, zfs, samba, RAM)
roctl rw on|off      # libera/trava / e /boot/efi (ex.: apk upgrade)
roctl store on|off   # modo manutenção de imagens: docker pull/build/rmi
roctl zfs-init [A B] # cria o pool manualmente (sem args: 1º par livre de mesmo tamanho)
roctl snap           # snapshot do pool agora (o cron faz todo dia às 0h)
```

Exemplo, atualizar imagens:

```sh
roctl store on && docker pull nginx:alpine && roctl store off
```

Esqueceu o `off`? O reboot volta tudo para ro.

Exemplo, atualizar o sistema:

```sh
roctl rw on && apk upgrade && roctl rw off
```

`roctl rw on` só faz `mount -o remount,rw /` e `/boot/efi`. Se o `rw off` falhar com "busy", reinicie. Ele não libera `/mnt/docker-store`: para isso use `roctl store on/off`.

## Snapshots ZFS

Todo dia às 0h (fuso do sistema) o cron roda `roctl snap`: snapshot recursivo de todo o pool (`/mnt/zfs`, volumes Docker, estado do Samba) com nome `auto-AAAA-MM-DD_HHMMSS`, mantendo os `SNAP_KEEP` mais novos (padrão 30, em `/etc/rodocker.conf`). Snapshots ocupam só o que mudou desde então.

```sh
zfs list -t snapshot -o name,used,creation                  # listar
ls /mnt/zfs/.zfs/snapshot/                                  # navegar (somente leitura)
cp /mnt/zfs/.zfs/snapshot/auto-2026-10-17_000000/samba/doc.txt /mnt/zfs/samba/   # recuperar um arquivo
zfs rollback -r tank@auto-2026-10-17_000000                 # voltar o /mnt/zfs inteiro (apaga os mais novos)
SNAP_KEEP=7 roctl snap                                      # snapshot agora, mantendo so 7
```

Para mudar o horário: `roctl rw on`, editar a linha `0 0 * * * /usr/local/sbin/roctl snap` em `/etc/crontabs/root`, `rc-service crond restart`, `roctl rw off`. O fuso fica em `/etc/localtime` (`setup-timezone` com `rw on`).

## Disco do pool com defeito

Com um disco a menos o mirror fica `DEGRADED`, mas tudo segue funcionando (containers, Samba, escrita no pool, reboot). O `roctl check` passa a mostrar `FAIL  pool tank ONLINE`. Para trocar:

```sh
zpool status tank                      # nome do disco ausente/FAULTED (ex.: ata-WDC_..._ABC123)
ls -l /dev/disk/by-id/ | grep -v part  # ache o disco novo (vazio, tamanho >= ao antigo)
zpool replace tank ata-WDC_..._ABC123 /dev/disk/by-id/ata-WDC_..._XYZ789
zpool status tank                      # acompanha o resilver; ao fim, ONLINE
```

Se o disco só caiu e voltou (cabo, gaveta USB): `zpool online tank <nome>` e `zpool clear tank`. Um disco antigo que já saiu do pool fica com partições e nunca é reaproveitado sozinho; para reutilizar, apague-o à mão (confira o `X` duas vezes):

```sh
zpool labelclear -f /dev/sdX1
dd if=/dev/zero of=/dev/sdX bs=1M count=2
dd if=/dev/zero of=/dev/sdX bs=512 seek=$(( $(cat /sys/block/sdX/size) - 4096 )) count=4096
```

Testado em VM: remoção a quente com escrita contínua, reboot degradado, troca a quente e resilver, queda de energia com escrita no pool e no meio de um `docker pull` em `store on` (a p4 volta com `recovering journal` → `clean`; as camadas já baixadas são reaproveitadas no próximo pull).

## Logs

Tudo na RAM, com teto (sem ele, o padrão do Docker passaria de 1 GB):

| Logs | Teto | Onde |
|---|---|---|
| Sistema | **100 MiB** (tmpfs próprio) | `/dev/shm/log`: `messages` (syslog, 20 MiB + 3 rotações), `docker.log` (daemon, 2 × 4 MiB), `samba.log` (2 × 1 MiB), `dmesg` |
| Containers | **100 MiB** com o `docker.log` (tmpfs de 92 MiB) | `/dev/shm/docker/containers`, driver `local`: ≤ 4 MiB por container (2 × 2 MiB, compactado) |

```sh
docker logs -f NOME                 # saida de um container
tail -f /var/log/messages           # sistema (/var/log -> /dev/shm/log)
df -h /dev/shm/log /dev/shm/docker/containers
```

Um container pode passar dos 4 MiB só com `--log-driver`/`--log-opt` próprios; mesmo assim o total dos containers não passa do tmpfs.

## Apps Docker persistentes: `roapp`

O estado do Docker vive em `/dev/shm`, então **todo container some no reboot**, mesmo com `--restart=always` (e também em `roctl store on/off`). Persistem só as imagens gravadas no disco de imagens (p4) e os dados no pool. O `roapp` guarda a *definição* de cada app em `/etc/roapps` e recria os containers no boot (`/etc/local.d/roapp.start`) e depois de cada `roctl store off`.

| O quê | Onde fica |
|---|---|
| Definição (`<app>.app` ou `<app>.yml`) | `/etc/roapps` (no `/` ro; o `roapp` faz o `rw on/off` sozinho) |
| Imagens | p4, gravadas pelo próprio `roapp` (`store on/off`) |
| Dados (bind) | `/mnt/zfs/<app>_data` (ZFS, fora do Samba) |
| Volumes nomeados (`-v nome:/dst`) | `tank/docker-volumes` (ZFS) |

### `docker run`: `roapp add`

```sh
roapp add NOME IMAGEM [opcoes do docker run] [-- comando]
```

Em `-v`, **`@` é a pasta de dados do app**: `-v @:/data` vira `-v /mnt/zfs/NOME_data:/data` e `-v @conf:/etc/x` vira `/mnt/zfs/NOME_data/conf:/etc/x` (as pastas são criadas). Sem `--restart`, o `roapp` usa `--restart=unless-stopped`. Se a imagem não estiver no disco, o `roapp` grava ela (`store on`, `pull`, `store off`, que recria todos os apps).

Exemplo, Portainer:

```sh
roapp add portainer portainer/portainer-ce:lts -p 9443:9443 -p 8000:8000 \
  -v /var/run/docker.sock:/var/run/docker.sock -v @:/data
```

Fica em `/etc/roapps/portainer.app`:

```sh
IMAGE='portainer/portainer-ce:lts'
OPTS='-p 9443:9443 -p 8000:8000 -v /var/run/docker.sock:/var/run/docker.sock -v @:/data'
CMD=''
ZFS=
```

Outros exemplos:

```sh
roapp add web nginx:alpine -p 8080:80 -v @html:/usr/share/nginx/html:ro
roapp add pihole pihole/pihole:latest -p 53:53/udp -p 53:53 -p 8081:80 -e "TZ=America/Sao_Paulo" \
  -v @etc:/etc/pihole -v @dnsmasq:/etc/dnsmasq.d
roapp add relogio busybox:latest -- sh -c "while :; do date; sleep 60; done"
```

### `docker compose`: `roapp compose`

```sh
roapp compose NOME arquivo.yml        # copia para /etc/roapps/NOME.yml e sobe (projeto NOME)
```

No arquivo, **`${DATA}`** é `/mnt/zfs/NOME_data`:

```yaml
services:
  db:
    image: postgres:17-alpine
    environment: { POSTGRES_PASSWORD: troque }
    volumes: ["${DATA}/pg:/var/lib/postgresql/data"]
    restart: unless-stopped
  app:
    image: nextcloud:apache
    ports: ["8088:80"]
    volumes: ["${DATA}/html:/var/www/html"]
    depends_on: [db]
    restart: unless-stopped
```

### Dia a dia

```sh
roapp ls                  # apps, tipo, imagem, estado
roapp show NOME           # definicao
roapp recreate NOME       # depois de editar /etc/roapps/NOME.* (roctl rw on; vi ...; roctl rw off)
roapp pull [NOME...]      # atualiza imagens no disco e recria TODOS os apps
roapp down NOME           # para e remove o container (volta no proximo boot ou roapp up)
roapp rm NOME             # remove a definicao e o container; os dados ficam em /mnt/zfs/NOME_data
roapp up                  # cria o que faltar (o boot ja faz)
```

Regras:

- Um app que usa o pool (`@`, `/mnt/zfs`, volume nomeado ou compose) **não sobe sem o pool montado**, para não começar vazio com dados na RAM. Para subir mesmo assim com volumes nomeados na RAM (perdidos no reboot), coloque `ZFS=0` no `.app`; binds em `/mnt/zfs` (`@`) nunca sobem sem pool.
- Imagem puxada fora do `roapp`/`store on` fica na RAM e some no próximo reboot ou `store on/off`. O `roapp up` avisa.
- Containers que rodam com outro usuário (ex.: uid 1000) precisam da pasta de dados com esse dono: `chown -R 1000:1000 /mnt/zfs/NOME_data`.
- O `roapp` marca os containers que cria (`--label roapp.app=NOME`) e não adota um container de mesmo nome criado à mão (`docker run`); `roapp recreate NOME` o substitui.
- As definições ficam no `/` ro de propósito: só o root as altera. Não as coloque no pool, que é gravável por containers e (em `samba`) pela rede.
- Para copiar arquivos para um app pela rede, use `\\<host>\zfs` (`/mnt/zfs/samba`) e um bind para lá, ex.: `-v /mnt/zfs/samba/musicas:/music:ro`.

Portas publicadas: `-p 9443:9443` sem IP já escuta em **todas as interfaces** (`0.0.0.0` e `::`). Para deixar explícito: `-p 0.0.0.0:9443:9443 -p [::]:9443:9443`. Para restringir a uma interface: `-p 192.168.0.10:9443:9443`. Confira com `docker ps --format '{{.Names}} {{.Ports}}'`. O Portainer responde em `https://IP-DO-SERVIDOR:9443` (certificado autoassinado). A porta 8000 só é necessária para o Edge Agent.

## Testar em VM (QEMU/KVM no WSL2 ou Linux)

Pre-requisitos (uma vez):

```sh
sudo apt install -y qemu-system-x86 qemu-utils ovmf socat
sudo usermod -aG kvm $USER     # e reabra o terminal; /dev/kvm precisa existir
```

No Windows, `%UserProfile%\.wslconfig` com `[wsl2]`, `nestedVirtualization=true` e `memory=16GB`, seguido de `wsl --shutdown`. Se o `/proc/cpuinfo` do WSL nao mostrar `vmx`/`svm`, o KVM nao funciona: `TCG=1 ./vm-test.sh ...` emula (bem mais lento).

```sh
./vm-test.sh uefi out/alpine-ro-3.24.2-x86_64.iso   # instala (menu: "instalar automaticamente")
./vm-test.sh uefi                                     # depois: boota do disco
./vm-test.sh bios out/alpine-ro-3.24.2-x86_64.iso   # cenario BIOS legado (VM separada; no "boot:" digite roinstall)
Z2_SIZE=5T ./vm-test.sh uefi out/...iso               # discos diferentes: nao deve criar ZFS
./vm-del.sh uefi        # desliga e apaga a VM (uefi|bios|all, -y sem perguntar)
```

| VM padrao | Valor (env para mudar) |
|---|---|
| RAM / vCPU | 8G / 2 (`MEM`, `CPUS`) |
| Discos | boot 128G + 2 x 6T, qcow2 esparso (`BOOT_SIZE`, `Z1_SIZE`, `Z2_SIZE`) |
| Pasta | `~/vms/alpine-ro-<modo>` (`VMS`) |
| Portas no host | ssh 2222, samba 4450, portainer 9443, netdata 19999 e `EXTRA_PORTS="P1 P2"` (em `127.0.0.1`; no WSL2 também em `localhost` no Windows) |
| Chave SSH | `~/.ssh/id_rsa.pub` do usuário vai para o `authorized_keys` da VM na instalação (`SSH_PUBKEY` para outra; `ssh -p 2222 root@127.0.0.1`) |

- Tela: janela via WSLg; sem WSLg, VNC em `127.0.0.1:5900`. Serial: `tail -f ~/vms/alpine-ro-uefi/serial.log`.
- Monitor do QEMU: `socat - UNIX:$HOME/vms/alpine-ro-uefi/monitor.sock`
  - `device_del dz2`: arranca um disco ZFS com a VM ligada (teste de mirror DEGRADED);
  - `quit`: queda de energia.
- Snapshot (VM desligada): `qemu-img snapshot -c pos-instalacao ~/vms/alpine-ro-uefi/boot.qcow2` (`-a` restaura).
- O disco tem prioridade de boot sobre o ISO: depois de instalado, a VM nao reinstala em loop.

## Estrutura

```
build.sh               gera o ISO (docker build + docker run)
vm-test.sh             sobe VM de teste (QEMU/KVM): uefi|bios, 8G, boot 128G + 2x6T
vm-del.sh              desliga e apaga VMs de teste (e as chaves de host delas no known_hosts)
Dockerfile             imagem do builder (alpine + xorriso)
iso-src/
  build.sh             roda no container: baixa o ISO, overlay, menus, xorriso
  dup-entry.awk        duplica a entrada do GRUB/syslinux com "autoinstall"
  payload/
    install-ro.sh      instalador (vira /usr/local/sbin/install-ro no live)
    roctl              ferramenta de controle do sistema instalado
    roapp              apps Docker recriados no boot (/etc/roapps)
    rodocker           servico OpenRC de boot (chama roctl boot/stop)
    rodockerd          DOCKERD_BINARY: remonta as camadas ro antes de cada start do dockerd
    authorized_keys    (opcional, fora do git) sua chave SSH publica
out/                   ISOs oficial (cache) e gerado (fora do git)
```

## Limitações

- A instalação precisa de internet (os pacotes vêm do repositório do Alpine).
- Secure Boot precisa estar desligado.
- Wi-Fi não é configurado; a rede usa DHCP nas placas ethernet.
- Containers não sobrevivem ao reboot; use o `roapp` (veja acima).
- Logs ficam só na RAM (somem no reboot) e têm teto de 100 MiB cada (sistema e Docker); a saída dos containers fica no `docker logs`, não no syslog.
