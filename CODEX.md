# Análise de memória e I/O — `alpine-ro`

Host consultado: `lrs@192.168.0.123`  
Data da coleta: 18/10/2026 (horário local do host: UTC−03:00)

## Memória

- RAM total: 7,7 GiB.
- Em uso no momento da consulta: aproximadamente 407 MiB; disponíveis: 6,7 GiB.
- Cache e buffers: aproximadamente 1,5 GiB, recuperáveis conforme a necessidade.
- Swap: não configurada.

Não havia sinal de pressão de memória na amostra. Esse valor é um retrato pontual, não uma série histórica.

## I/O de `sda`

`sda` foi monitorado por cinco minutos, com amostras a cada cinco segundos. Nenhuma amostra registrou escrita (`0 kB/s`). Houve duas leituras pequenas, de 8 KiB e 24 KiB; as demais amostras ficaram sem atividade.

Conclusão: `sda` permaneceu sem escrita detectável durante a janela observada. Isso não exclui gravações intermitentes fora desses cinco minutos.

## Espaço em disco observado

- `/dev/sda3`, montado em `/`: 19,5 GiB, 1,4 GiB usados (8%).
- `/dev/sda4`, montado em `/mnt/docker-store`: 89,3 GiB, 231,2 MiB usados (menos de 1%).
- `/dev/sdb1`, montado em `/mnt/disco`: 915,8 GiB, 797,7 GiB usados (92%), com 71,5 GiB disponíveis. Este é o ponto de atenção para capacidade.

## Limitações

As métricas refletem apenas as janelas de coleta realizadas em 18/10/2026. O `vmstat` não está instalado; a ferramenta `iostat` disponível é a versão BusyBox. A listagem de processos por RSS e alguns mounts do Docker não puderam ser consultados por limitações das ferramentas/permissões.
