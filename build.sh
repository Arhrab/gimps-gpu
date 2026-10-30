#!/usr/bin/env bash
# Сборка GIMPS-софта для NVIDIA GPU (RTX 30/40/50) и CPU в /opt/gimps:
#   prpll-cuda / prpll-ocl  — PRPLL-NTT (PRP-тесты на GPU, CUDA и OpenCL бэкенды)
#   mfaktc                  — trial factoring на GPU
#   mprime                  — Prime95 для Linux (P-1/PRP/ECM на CPU)
#   autoprimenet.py         — задания и отчёты PrimeNet для GPU-программ
#   rclone                  — внешний бэкап (Google Drive / S3)
#
# Использование:
#   build.sh deps-build     # apt: компиляторы и заголовки (нужен CUDA devel, т.е. nvcc)
#   build.sh deps-runtime   # apt: только то, что нужно для запуска
#   build.sh build          # собрать всё в $PREFIX
#   build.sh all            # deps-build + deps-runtime + build (для голой VM / bootstrap)
#   build.sh versions       # показать, какие версии будут собраны
set -euo pipefail

PREFIX="${PREFIX:-/opt/gimps}"
# --- версии (проверено 2026-10-28: всё — последние на эту дату) ---
PRPLL_REPO="${PRPLL_REPO:-https://github.com/gwoltman/gpuowl}"
PRPLL_REF="${PRPLL_REF:-7ee576c0d3984bdc5fdcb97b5b0986a759568f04}"          # master 2026-10-26 (PRPLL-NTT v8.0-5xx, вкл. оптимизации M61 под sm_120)
MFAKTC_REPO="${MFAKTC_REPO:-https://github.com/primesearch/mfaktc}"
MFAKTC_REF="${MFAKTC_REF:-28bb656172184415ec21d6bd6488778fc9934dbe}"        # main 2026-10-26 = 0.24.1 + атомарная запись чекпойнтов и др. исправления
APN_REPO="${APN_REPO:-https://github.com/tdulcet/AutoPrimeNet}"
APN_REF="${APN_REF:-b4426a13f96c874cf6202aefa3b8f97345069245}"   # AutoPrimeNet 2.0.2 (2026-10-16, последняя)
MPRIME_FILE="${MPRIME_FILE:-p95v3019b20.linux64.tar.gz}"         # Prime95/mprime 30.19 build 20 (последняя бинарная)
MPRIME_SHA256="${MPRIME_SHA256:-4ce2377e03deb4cf189523136e26401ba08f67857a128e420dd030d00cdca601}"
MPRIME_URLS="${MPRIME_URLS:-https://www.mersenne.org/download/software/v30/30.19/$MPRIME_FILE https://download.mersenne.ca/gimps/v30/30.19/$MPRIME_FILE}"
RCLONE_VER="${RCLONE_VER:-v1.75.2}"
# SHA256 архивов rclone v1.75.2 (из официального SHA256SUMS релиза); для другой версии задайте RCLONE_SHA256
RCLONE_SHA256_amd64="349ac8fba6ff65d6247043f1750cdcb518ec5d500ef91463a10d37c0ccdf3702"
RCLONE_SHA256_arm64="7e1e8d69654941b7b7df84ee74c5f7fb09cce7d5496947fb7bf16b55ff427d10"
# Compute capabilities для mfaktc: RTX30/A10=86, RTX40/L4/L40=89, RTX50/RTX PRO 6000=120 — основные;
# + T4/RTX20=75, A100=80, H100=90, B200=100, B300=103 — на всякий случай. Неподдерживаемые nvcc отфильтровываются.
MFAKTC_ARCHS="${MFAKTC_ARCHS:-61 70 75 80 86 89 90 100 103 120}"   # 61 — Pascal (GTX 10xx, TITAN Xp, P40), 70 — Volta (V100, TITAN V)
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
  apt_install build-essential git ca-certificates ocl-icd-opencl-dev opencl-headers python3
  command -v nvcc >/dev/null || [ -x "$CUDA_HOME/bin/nvcc" ] || {
    echo "nvcc не найден: нужен образ/VM с CUDA Toolkit (например nvidia/cuda:12.9.1-devel-ubuntu24.04)" >&2; exit 1; }
}

install_rclone() {
  command -v rclone >/dev/null && return 0
  local arch sha; arch="$(dpkg --print-architecture)"
  sha="${RCLONE_SHA256:-}"; [ -z "$sha" ] && [ "$RCLONE_VER" = "v1.75.2" ] && eval "sha=\${RCLONE_SHA256_$arch:-}"
  [ -n "$sha" ] || { echo "rclone: нет SHA256 для $RCLONE_VER/$arch — задайте RCLONE_SHA256" >&2; exit 1; }
  log "rclone $RCLONE_VER (sha256 ${sha:0:12}…)"
  python3 - "$RCLONE_VER" "$arch" "$sha" <<'PY'
import hashlib, io, sys, urllib.request, zipfile, os
v, arch, sha = sys.argv[1], sys.argv[2], sys.argv[3]
url = f"https://github.com/rclone/rclone/releases/download/{v}/rclone-{v}-linux-{arch}.zip"
data = urllib.request.urlopen(url, timeout=120).read()
if hashlib.sha256(data).hexdigest() != sha:
    sys.exit(f"rclone: SHA256 не совпал ({hashlib.sha256(data).hexdigest()} != {sha})")
z = zipfile.ZipFile(io.BytesIO(data))
open("/usr/local/bin/rclone", "wb").write(z.read(f"rclone-{v}-linux-{arch}/rclone"))
os.chmod("/usr/local/bin/rclone", 0o755)
PY
}

deps_runtime() {
  log "Устанавливаю runtime-зависимости"
  # expect: настройка mprime без вопросов + unbuffer (построчный вывод mprime в лог)
  apt_install python3 python3-requests ocl-icd-libopencl1 clinfo tini procps tmux less ca-certificates expect
  install_rclone
  # NVIDIA OpenCL ICD: сама библиотека libnvidia-opencl пробрасывается драйвером хоста
  mkdir -p /etc/OpenCL/vendors
  [ -f /etc/OpenCL/vendors/nvidia.icd ] || echo "libnvidia-opencl.so.1" > /etc/OpenCL/vendors/nvidia.icd
}

build_prpll() {
  log "PRPLL ${PRPLL_REF} из ${PRPLL_REPO}"
  rm -rf "$SRC/prpll"
  git -c advice.detachedHead=false clone -q "$PRPLL_REPO" "$SRC/prpll"   # полный клон: git describe → версия для PrimeNet
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
  local nvcc="$CUDA_HOME/bin/nvcc"; [ -x "$nvcc" ] || nvcc="$(command -v nvcc)"
  # оставляем только архитектуры, которые знает этот nvcc
  local supported archs="" a
  supported="$("$nvcc" --list-gpu-arch 2>/dev/null | sed -n 's/^compute_\([0-9]*\)$/\1/p' | tr '\n' ' ')"
  for a in $MFAKTC_ARCHS; do
    if [ -z "$supported" ] || [[ " $supported " == *" $a "* ]]; then archs+="$a "; else log "  nvcc не знает sm_$a — пропускаю"; fi
  done
  log "mfaktc ${MFAKTC_REF} (sm: ${archs})"
  rm -rf "$SRC/mfaktc"
  git -c advice.detachedHead=false clone -q "$MFAKTC_REPO" "$SRC/mfaktc"
  git -C "$SRC/mfaktc" -c advice.detachedHead=false checkout -q "$MFAKTC_REF"
  cd "$SRC/mfaktc/src"
  sed -i '/^NVCCFLAGS += --generate-code arch=compute_/d' Makefile
  local gen="" last=""
  for a in $archs; do gen+="NVCCFLAGS += --generate-code arch=compute_${a},code=sm_${a}\n"; last="$a"; done
  gen+="NVCCFLAGS += --generate-code arch=compute_${last},code=compute_${last}\n"   # PTX для будущих GPU
  sed -i "s|^# pass some options to the C host compiler|${gen}# pass some options to the C host compiler|" Makefile
  sed -i "s|^CUDA_DIR = .*|CUDA_DIR = $CUDA_HOME|" Makefile
  PATH="$CUDA_HOME/bin:$PATH" make -j"$JOBS" >/tmp/mfaktc-build.log 2>&1 || { tail -40 /tmp/mfaktc-build.log; exit 1; }
  install -m755 ../mfaktc "$PREFIX/bin/mfaktc"
  install -m644 mfaktc.ini "$PREFIX/share/mfaktc.ini"     # в main: src/mfaktc.ini (в 0.24.1 — ../mfaktc.ini)
  # Настройки для RTX 30/40/50 (замер на RTX 5060 Ti: GPUSieveSize=2047 +2.2%, GPUSieveProcessSize=32 −1%):
  #   GPUSieveSize=2047 — максимум, «рекомендуется для новых GPU» (mfaktc.ini); PrintMode=0 — построчный лог.
  sed -i 's/^GPUSieveSize=.*/GPUSieveSize=2047/; s/^GPUSieveProcessSize=.*/GPUSieveProcessSize=16/; s/^PrintMode=.*/PrintMode=0/' \
    "$PREFIX/share/mfaktc.ini"
  echo "$(git -C "$SRC/mfaktc" describe --tags --always) ($MFAKTC_REF)" > "$PREFIX/MFAKTC_VERSION"
}

fetch_apn() {
  log "AutoPrimeNet ${APN_REF:0:7}"
  rm -rf "$SRC/apn"
  git -c advice.detachedHead=false clone -q "$APN_REPO" "$SRC/apn"
  git -C "$SRC/apn" -c advice.detachedHead=false checkout -q "$APN_REF"
  # Маленький патч: писать в лог кредит (GHz-days) за КАЖДЫЙ принятый результат — его читает gimps-monitor.
  python3 - "$SRC/apn/autoprimenet.py" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
old = "\t\t\t\tghd = float(ghzdays.group(1))\n"
new = old + '\t\t\t\tadapter.info("Credit for exponent %s: %s GHz-days", assignment.n, ghd)\n'
if old not in s:
    sys.exit("AutoPrimeNet: место для патча не найдено")
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
  install -m755 "$SRC/apn/autoprimenet.py" "$PREFIX/bin/autoprimenet.py"
}

fetch_mprime() {
  [ "${SKIP_MPRIME:-0}" = "1" ] && { log "mprime пропущен (SKIP_MPRIME=1)"; return 0; }
  log "mprime ${MPRIME_FILE}"
  mkdir -p "$PREFIX/mprime" "$SRC/mprime"
  local ok=0 u
  for u in $MPRIME_URLS; do
    if python3 -c "import sys,urllib.request; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])" "$u" "$SRC/mprime/$MPRIME_FILE" 2>/dev/null \
       && echo "$MPRIME_SHA256  $SRC/mprime/$MPRIME_FILE" | sha256sum -c --quiet; then ok=1; break; fi
    log "  не удалось с $u, пробую следующее зеркало"
  done
  [ "$ok" = 1 ] || { echo "mprime: скачать/проверить SHA256 не удалось" >&2; exit 1; }
  tar -xzf "$SRC/mprime/$MPRIME_FILE" -C "$PREFIX/mprime"
  [ -x "$PREFIX/mprime/mprime" ] || { echo "mprime: в архиве нет бинарника" >&2; exit 1; }
  echo "${MPRIME_FILE%.linux64.tar.gz}" > "$PREFIX/MPRIME_VERSION"
}

versions() {
  cat <<EOF
PRPLL       $PRPLL_REPO @ $PRPLL_REF
mfaktc      $MFAKTC_REPO @ $MFAKTC_REF
AutoPrimeNet $APN_REPO @ ${APN_REF:0:7}
mprime      $MPRIME_FILE (sha256 ${MPRIME_SHA256:0:12}…)
rclone      $RCLONE_VER
CUDA        $("$CUDA_HOME/bin/nvcc" --version 2>/dev/null | sed -n 's/.*release \([0-9.]*\).*/\1/p' || echo '?')
EOF
}

build_all() {
  mkdir -p "$PREFIX"/{bin,lib,share} "$SRC"
  build_prpll
  build_mfaktc
  fetch_apn
  fetch_mprime
  # служебные скрипты и файлы (если запускаемся из репозитория)
  for s in gimps-start gimps-stop gimps-status gimps-backup gimps-monitor gimps-watch gimps-cpu-setup gimps-notify; do
    [ -f "$HERE/$s" ] && install -m755 "$HERE/$s" "$PREFIX/bin/$s"
  done
  [ -f "$HERE/mprime-setup.exp" ] && install -m644 "$HERE/mprime-setup.exp" "$PREFIX/share/mprime-setup.exp"
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
  versions)     versions ;;
  *) echo "usage: $0 {deps-build|deps-runtime|build|all|versions}" >&2; exit 2 ;;
esac
