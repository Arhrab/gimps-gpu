#!/usr/bin/env bash
# GIMPS GPU bootstrap — установка БЕЗ Docker-реестра, прямо на VM/контейнере с CUDA devel
# (например, образ nvidia/cuda:12.8.1-devel-ubuntu24.04 на vast.ai / RunPod, или Ubuntu VM с CUDA Toolkit).
#   bash bootstrap.sh                       # собрать (3–6 минут)
#   GIMPS_USER=<логин> gimps-start --daemon # запустить
# Сгенерировано make-bootstrap.sh — не редактируйте вручную.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Запустите от root (sudo bash bootstrap.sh)"; exit 1; }
D=/opt/gimps-src/scripts
mkdir -p "$D"
cat > "$D/build.sh" <<'__GIMPS_EOF__'
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
__GIMPS_EOF__
cat > "$D/gimps-start" <<'__GIMPS_EOF__'
#!/usr/bin/env bash
# Запуск GIMPS на всех (или выбранных) GPU: на каждую GPU — свой воркер (PRPLL или mfaktc)
# и свой AutoPrimeNet, каждый в своей папке $DATA_DIR/<mode>-gpu<N>.
#
#   gimps-start            — в foreground (для Docker ENTRYPOINT)
#   gimps-start --daemon   — в фоне (для onstart-скрипта vast.ai / RunPod / ssh)
#
# Настройки — переменные окружения (или файл $DATA_DIR/gimps.env):
#   GIMPS_USER       логин PrimeNet (mersenne.org). По умолчанию ANONYMOUS
#   GIMPS_MODE       prp (PRPLL, тесты на простоту) | tf (mfaktc, trial factoring). По умолч. prp
#   GIMPS_WORKPREF   тип работы PrimeNet. По умолч.: 150 (first-time PRP) для prp, 12 для tf
#   GIMPS_GPUS       список GPU через запятую, напр. "0,1". По умолч. все
#   GIMPS_NAME       префикс имени компьютера в PrimeNet. По умолч. "cloud"
#   GIMPS_DAYS_WORK  на сколько дней брать задания. По умолч. 1
#   PRPLL_BACKEND    cuda | opencl. По умолч. cuda
#   PRPLL_TUNE       1 = перед первым запуском прогнать "prpll -tune" (долго, но быстрее потом)
#   PRPLL_ARGS       доп. аргументы PRPLL
#   APN_ARGS         доп. аргументы AutoPrimeNet (напр. "--cert-work")
#   PROOF_DISK_GB    диск под proof-файлы на один GPU, ГБ. По умолч. 30
#   DATA_DIR         где хранить всё состояние. По умолч. /data
set -uo pipefail

DATA_DIR="${DATA_DIR:-/data}"
mkdir -p "$DATA_DIR/logs"
[ -f "$DATA_DIR/gimps.env" ] && set -a && . "$DATA_DIR/gimps.env" && set +a

if [ "${1:-}" = "--daemon" ]; then
  setsid nohup "$0" >>"$DATA_DIR/logs/gimps-start.log" 2>&1 < /dev/null &
  echo "gimps-start запущен в фоне (pid $!). Лог: $DATA_DIR/logs/gimps-start.log ; статус: gimps-status"
  exit 0
fi

GIMPS_USER="${GIMPS_USER:-ANONYMOUS}"
GIMPS_MODE="${GIMPS_MODE:-prp}"
GIMPS_NAME="${GIMPS_NAME:-cloud}"
GIMPS_DAYS_WORK="${GIMPS_DAYS_WORK:-1}"
PRPLL_BACKEND="${PRPLL_BACKEND:-cuda}"
PROOF_DISK_GB="${PROOF_DISK_GB:-30}"
case "$GIMPS_MODE" in
  prp) WORKPREF="${GIMPS_WORKPREF:-150}" ;;
  tf)  WORKPREF="${GIMPS_WORKPREF:-12}" ;;
  *) echo "GIMPS_MODE должен быть prp или tf" >&2; exit 2 ;;
esac
case "$PRPLL_BACKEND" in
  cuda)   PRPLL_BIN=prpll-cuda ;;
  opencl) PRPLL_BIN=prpll-ocl ;;
  *) echo "PRPLL_BACKEND должен быть cuda или opencl" >&2; exit 2 ;;
esac
APN="python3 $(command -v autoprimenet.py)"
STOP_FLAG="$DATA_DIR/.stop"
rm -f "$STOP_FLAG"
echo $$ > "$DATA_DIR/gimps-start.pid"

ts() { date '+%F %T'; }
log() { echo "[$(ts)] $*"; }

if ! nvidia-smi -L >/dev/null 2>&1; then
  log "ОШИБКА: nvidia-smi не видит GPU. Контейнер запущен без --gpus all / без NVIDIA runtime?"; exit 1
fi
if [ -n "${GIMPS_GPUS:-}" ]; then
  IFS=',' read -r -a GPUS <<< "$GIMPS_GPUS"
else
  mapfile -t GPUS < <(nvidia-smi --query-gpu=index --format=csv,noheader)
fi
[ "$GIMPS_USER" = "ANONYMOUS" ] && log "ВНИМАНИЕ: GIMPS_USER не задан — работаю как ANONYMOUS (результаты не попадут в ваш аккаунт)"
log "Режим: $GIMPS_MODE, workpref=$WORKPREF, пользователь=$GIMPS_USER, GPU: ${GPUS[*]}"

# бесконечный перезапуск команды, пока нет стоп-флага
forever() {
  local name="$1"; shift
  local logf="$DATA_DIR/logs/$name.log"
  while [ ! -f "$STOP_FLAG" ]; do
    log "старт: $*" >>"$logf"
    "$@" >>"$logf" 2>&1
    local rc=$?
    [ -f "$STOP_FLAG" ] && break
    log "$name завершился (rc=$rc), перезапуск через 60 с" >>"$logf"
    sleep 60
  done
}

shutdown() {
  log "Получен сигнал остановки — корректно останавливаю воркеры (сохранение чекпойнтов)"
  touch "$STOP_FLAG"
  pkill -TERM -x prpll-cuda; pkill -TERM -x prpll-ocl; pkill -TERM -x mfaktc
  for _ in $(seq 1 90); do pgrep -x 'prpll-cuda|prpll-ocl|mfaktc' >/dev/null || break; sleep 1; done
  pkill -f '^python3 .*autoprimenet.py -w'
  rm -f "$DATA_DIR/gimps-start.pid"
  wait
  log "Остановлено"
  exit 0
}
trap shutdown INT TERM

for g in "${GPUS[@]}"; do
  g="$(echo "$g" | tr -d ' ')"
  dir="$DATA_DIR/${GIMPS_MODE}-gpu${g}"
  mkdir -p "$dir"
  gpu_name="$(nvidia-smi -i "$g" --query-gpu=name --format=csv,noheader | head -1)"
  gpu_mem="$(nvidia-smi -i "$g" --query-gpu=memory.total --format=csv,noheader,nounits | head -1)"
  cname="${GIMPS_NAME}-${GIMPS_MODE}${g}"
  log "GPU $g: $gpu_name (${gpu_mem} MiB) -> $dir, computer=$cname"

  apn_common=(-w "$dir" -u "$GIMPS_USER" -T "$WORKPREF" -H "$cname" -W "$GIMPS_DAYS_WORK"
              --processor-model "$gpu_name" --no-version-check --no-color)
  if [ "$GIMPS_MODE" = "prp" ]; then
    apn_args=(--prpll "${apn_common[@]}" --max-disk-space "$PROOF_DISK_GB")
  else
    apn_args=(--mfaktc "${apn_common[@]}")
    [ -f "$dir/mfaktc.ini" ] || cp /opt/gimps/share/mfaktc.ini "$dir/mfaktc.ini"
  fi
  # shellcheck disable=SC2086
  ( forever "apn-gpu$g" $APN "${apn_args[@]}" ${APN_ARGS:-} ) &

  sleep 20   # даём AutoPrimeNet зарегистрироваться и получить первое задание

  if [ "$GIMPS_MODE" = "prp" ]; then
    if [ "${PRPLL_TUNE:-0}" = "1" ] && [ ! -f "$dir/tune.txt" ]; then
      log "GPU $g: prpll -tune (может занять 30–90 минут)..."
      ( cd "$dir" && export CUDA_VISIBLE_DEVICES="$g" && "$PRPLL_BIN" -d 0 -dir "$dir" -tune >>"$DATA_DIR/logs/tune-gpu$g.log" 2>&1 )
    fi
    # shellcheck disable=SC2086
    ( cd "$dir" && export CUDA_VISIBLE_DEVICES="$g" && forever "prp-gpu$g" "$PRPLL_BIN" -d 0 -dir "$dir" -user "$GIMPS_USER" ${PRPLL_ARGS:-} ) &
  else
    ( cd "$dir" && export CUDA_VISIBLE_DEVICES="$g" && forever "tf-gpu$g" mfaktc -d 0 ) &
  fi
done

log "Запущено. Логи: $DATA_DIR/logs/  Статус: gimps-status"
wait
__GIMPS_EOF__
cat > "$D/gimps-stop" <<'__GIMPS_EOF__'
#!/usr/bin/env bash
# Остановка GIMPS.
#   gimps-stop              — корректно остановить воркеры (чекпойнт), отправить результаты. Задания остаются за вами.
#   gimps-stop --finish     — НЕ брать новые задания; текущие досчитать (воркеры продолжают работать)
#   gimps-stop --unreserve  — остановить и ВЕРНУТЬ все незавершённые задания в PrimeNet
#                             (делайте это перед удалением VM, если не будете продолжать!)
set -uo pipefail
DATA_DIR="${DATA_DIR:-/data}"
APN="python3 $(command -v autoprimenet.py)"
dirs=( "$DATA_DIR"/prp-gpu* "$DATA_DIR"/tf-gpu* )

each_dir() { for d in "${dirs[@]}"; do [ -f "$d/prime.ini" ] && { echo "== $d"; $APN -w "$d" "$@"; }; done; }

if [ "${1:-}" = "--finish" ]; then
  pkill -f '^python3 .*autoprimenet.py -w'; sleep 2     # AutoPrimeNet держит lock; цикл в gimps-start перезапустит его через минуту
  each_dir --no-more-work
  echo "Новые задания больше не берутся. Когда gimps-status покажет пустую очередь — можно останавливать."
  exit 0
fi

touch "$DATA_DIR/.stop"
pkill -TERM -x prpll-cuda; pkill -TERM -x prpll-ocl; pkill -TERM -x mfaktc
echo "Жду сохранения чекпойнтов..."
for _ in $(seq 1 120); do pgrep -x 'prpll-cuda|prpll-ocl|mfaktc' >/dev/null || break; sleep 1; done
pkill -f '^python3 .*autoprimenet.py -w' ; sleep 2
echo "Отправляю результаты и proof-файлы..."
each_dir --upload-proofs
[ "${1:-}" = "--unreserve" ] && { echo "Возвращаю задания в PrimeNet..."; each_dir --unreserve-all; }
[ -f "$DATA_DIR/gimps-start.pid" ] && kill "$(cat "$DATA_DIR/gimps-start.pid")" 2>/dev/null; rm -f "$DATA_DIR/gimps-start.pid"
echo "Готово."
__GIMPS_EOF__
cat > "$D/gimps-status" <<'__GIMPS_EOF__'
#!/usr/bin/env bash
# Сводка: GPU, задания и ETA по каждому воркеру, последние строки логов.
set -uo pipefail
DATA_DIR="${DATA_DIR:-/data}"

echo "===== GPU ====="
nvidia-smi --query-gpu=index,name,utilization.gpu,temperature.gpu,power.draw,memory.used --format=csv
echo
for d in "$DATA_DIR"/prp-gpu* "$DATA_DIR"/tf-gpu*; do
  [ -d "$d" ] || continue
  n="$(basename "$d")"
  echo "===== $n ====="
  echo "--- задания (worktodo):"
  cat "$d"/worktodo*.txt 2>/dev/null | grep -v '^\s*$' || echo "(пусто)"
  echo "--- отправлено результатов: $(cat "$d"/results*.txt 2>/dev/null | grep -c . )"
  echo "--- лог воркера:"
  tail -n 4 "$DATA_DIR/logs/${n}.log" 2>/dev/null
  echo "--- лог AutoPrimeNet:"
  tail -n 3 "$DATA_DIR/logs/apn-${n#*-}.log" 2>/dev/null
  echo
done
[ -f "$DATA_DIR/.stop" ] && echo "(стоп-флаг установлен — воркеры остановлены)"
__GIMPS_EOF__
chmod +x "$D"/*
"$D/build.sh" all
mkdir -p "${DATA_DIR:-/data}"
echo
echo "Установлено. Запуск:  GIMPS_USER=<ваш логин mersenne.org> gimps-start --daemon"
echo "Статус: gimps-status    Остановка: gimps-stop [--finish|--unreserve]"
