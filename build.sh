#!/bin/sh
# Gera out/alpine-ro-<versao>-x86_64.iso usando Docker.
# uso: ./build.sh [versao|latest]      ex.: ./build.sh 3.24.2
# O ISO oficial baixado fica em cache em out/ (conferido por SHA256).
set -e
cd "$(dirname "$0")"
docker build -q -t alpine-ro-builder . >/dev/null
mkdir -p out
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD/out:/out" alpine-ro-builder "$@"
