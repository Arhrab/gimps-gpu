#!/usr/bin/env bash
# Сборка GIMPS-софта для NVIDIA GPU в /opt/gimps:
#   prpll-cuda / prpll-ocl  — PRPLL-NTT (PRP-тесты, CUDA и OpenCL бэкенды)
#   mfaktc                  — trial factoring на GPU
#   autoprimenet.py         — получение заданий / отправка результатов в PrimeNet
#
# Использование:
#   build.sh deps-build     # apt: компиляторы и заголовки (нужен CUDA devel, т.е. nvcc)
#   build.sh deps-runtime   # apt: только то, что нужно для запуска
#   build.sh build          # собрать всё в $PREFIX
#   build.sh all            # deps-build + deps-runtime + build (для голой VM / bootstrap)
set -euo pipefail

PREFIX="${PREFIX:-/opt/gimps}"
PRPLL_REPO="${PRPLL_REPO:-https://github.com/gwoltman/gpuowl}"
PRPLL_REF="${PRPLL_REF:-5ce7df1}"          # 2026-10-09, соответствует официальной сборке PRPLL-NTT 2026-10-09
MFAKTC_REPO="${MFAKTC_REPO:-https://github.com/primesearch/mfaktc}"
MFAKTC_REF="${MFAKTC_REF:-0.24.1}"
APN_REPO="${APN_REPO:-https://github.com/tdulcet/AutoPrimeNet}"
APN_REF="${APN_REF:-b4426a13f96c874cf6202aefa3b8f97345069245}"   # AutoPrimeNet 2.0.2
# Compute capabilities для mfaktc: V100=70, T4/RTX20=75, A100=80, RTX30/A10=86, RTX40/L4/L40=89,
# H100=90, B200=100, RTX50/RTX PRO 6000=120
MFAKTC_ARCHS="${MFAKTC_ARCHS:-70 75 80 86 89 90 100 120}"
CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
JOBS="${JOBS:-$(nproc)}"
SRC="${SRC:-/tmp/gimps-src}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo -e "\e[1;36m[build]\e[0m $*"; }

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends "$@"
  rm -rf /var/lib/apt/lists/*
}

deps_build() {
  log "Устанавливаю build-зависимости"
  apt_install build-essential git ca-certificates ocl-icd-opencl-dev opencl-headers
  command -v nvcc >/dev/null || [ -x "$CUDA_HOME/bin/nvcc" ] || {
    echo "nvcc не найден: нужен образ/VM с CUDA Toolkit (например nvidia/cuda:12.8.1-devel-ubuntu24.04)" >&2; exit 1; }
}

deps_runtime() {
  log "Устанавливаю runtime-зависимости"
  apt_install python3 python3-requests ocl-icd-libopencl1 clinfo tini procps tmux less ca-certificates
  # NVIDIA OpenCL ICD: сама библиотека libnvidia-opencl пробрасывается драйвером хоста
  mkdir -p /etc/OpenCL/vendors
  [ -f /etc/OpenCL/vendors/nvidia.icd ] || echo "libnvidia-opencl.so.1" > /etc/OpenCL/vendors/nvidia.icd
}

build_prpll() {
  log "PRPLL ${PRPLL_REF} из ${PRPLL_REPO}"
  rm -rf "$SRC/prpll"
  git -c advice.detachedHead=false clone -q "$PRPLL_REPO" "$SRC/prpll"           # полный клон: git describe даёт версию, которая уходит в PrimeNet
  cd "$SRC/prpll"
  git -c advice.detachedHead=false checkout -q "$PRPLL_REF"
  local ver; ver="$(git describe --tags --long --always)"
  log "  версия PRPLL: $ver"
  make -j"$JOBS" CUDA=1 VERSION="$ver" LDFLAGS="-L$CUDA_HOME/lib64/stubs" >/tmp/prpll-cuda-build.log 2>&1 \
    || { tail -40 /tmp/prpll-cuda-build.log; exit 1; }
  make -j"$JOBS" VERSION="$ver" >/tmp/prpll-ocl-build.log 2>&1 \
    || { tail -40 /tmp/prpll-ocl-build.log; exit 1; }
  install -m755 build-cuda/prpll    "$PREFIX/bin/prpll-cuda"
  install -m755 build-release/prpll "$PREFIX/bin/prpll-ocl"
  echo "$ver" > "$PREFIX/PRPLL_VERSION"
  # libnvrtc нужен CUDA-бэкенду в рантайме (ядра компилируются под конкретную GPU при старте)
  cp -a "$CUDA_HOME"/lib64/libnvrtc.so.* "$CUDA_HOME"/lib64/libnvrtc-builtins.so.* "$PREFIX/lib/" 2>/dev/null || true
}

build_mfaktc() {
  log "mfaktc ${MFAKTC_REF} (sm: ${MFAKTC_ARCHS})"
  rm -rf "$SRC/mfaktc"
  git -c advice.detachedHead=false clone -q --depth 1 -b "$MFAKTC_REF" "$MFAKTC_REPO" "$SRC/mfaktc"
  cd "$SRC/mfaktc/src"
  # заменяем список архитектур на свой
  sed -i '/^NVCCFLAGS += --generate-code arch=compute_/d' Makefile
  local gen=""
  for a in $MFAKTC_ARCHS; do gen+="NVCCFLAGS += --generate-code arch=compute_${a},code=sm_${a}\n"; done
  local last; last="$(echo $MFAKTC_ARCHS | awk '{print $NF}')"
  gen+="NVCCFLAGS += --generate-code arch=compute_${last},code=compute_${last}\n"   # PTX для будущих GPU
  sed -i "s|^# pass some options to the C host compiler|${gen}# pass some options to the C host compiler|" Makefile
  sed -i "s|^CUDA_DIR = .*|CUDA_DIR = $CUDA_HOME|" Makefile
  PATH="$CUDA_HOME/bin:$PATH" make -j"$JOBS" >/tmp/mfaktc-build.log 2>&1 || { tail -40 /tmp/mfaktc-build.log; exit 1; }
  install -m755 ../mfaktc "$PREFIX/bin/mfaktc"
  install -m644 ../mfaktc.ini "$PREFIX/share/mfaktc.ini"
}

fetch_apn() {
  log "AutoPrimeNet ${APN_REF:0:7}"
  rm -rf "$SRC/apn"
  git -c advice.detachedHead=false clone -q "$APN_REPO" "$SRC/apn"
  git -C "$SRC/apn" -c advice.detachedHead=false checkout -q "$APN_REF"
  install -m755 "$SRC/apn/autoprimenet.py" "$PREFIX/bin/autoprimenet.py"
}

build_all() {
  mkdir -p "$PREFIX"/{bin,lib,share} "$SRC"
  build_prpll
  build_mfaktc
  fetch_apn
  # служебные скрипты (если запускаемся из репозитория)
  for s in gimps-start gimps-stop gimps-status; do
    [ -f "$HERE/$s" ] && install -m755 "$HERE/$s" "$PREFIX/bin/$s"
  done
  echo "$PREFIX/lib" > /etc/ld.so.conf.d/gimps.conf && ldconfig
  for b in "$PREFIX"/bin/*; do ln -sf "$b" /usr/local/bin/; done
  rm -rf "$SRC"
  log "Готово: $(ls "$PREFIX/bin" | tr '\n' ' ')"
}

case "${1:-all}" in
  deps-build)   deps_build ;;
  deps-runtime) deps_runtime ;;
  build)        build_all ;;
  all)          deps_build; deps_runtime; build_all ;;
  *) echo "usage: $0 {deps-build|deps-runtime|build|all}" >&2; exit 2 ;;
esac
