#!/usr/bin/env bash
# GIMPS GPU bootstrap — установка БЕЗ Docker-реестра, прямо на VM/контейнере с CUDA devel
# (например, образ nvidia/cuda:12.9.1-devel-ubuntu24.04 на vast.ai / RunPod, или Ubuntu VM с CUDA Toolkit).
#   bash bootstrap.sh                       # собрать (3–6 минут)
#   GIMPS_USER=<логин> gimps-start --daemon # запустить
# Сгенерировано make-bootstrap.sh — не редактируйте вручную.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Запустите от root (sudo bash bootstrap.sh)"; exit 1; }
D=/opt/gimps-src/scripts
mkdir -p "$D"
cat > "$D/build.sh" <<'__GIMPS_EOF__'
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
MFAKTC_ARCHS="${MFAKTC_ARCHS:-75 80 86 89 90 100 103 120}"
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
__GIMPS_EOF__
cat > "$D/gimps-start" <<'__GIMPS_EOF__'
#!/usr/bin/env bash
# Запуск GIMPS на всех (или выбранных) GPU: на каждую GPU — свой воркер (PRPLL или mfaktc) и свой AutoPrimeNet
# в папке $DATA_DIR/<mode>-gpu<N>; параллельно — mprime на CPU, живой журнал, сторожевой таймер, бэкап.
#
#   gimps-start            — в foreground (для Docker ENTRYPOINT)
#   gimps-start --daemon   — в фоне (для onstart-скрипта vast.ai / RunPod / ssh)
#
# Настройки — переменные окружения (или файл $DATA_DIR/gimps.env):
#   GIMPS_USER       логин PrimeNet (mersenne.org). По умолчанию ANONYMOUS
#   GIMPS_MODE       prp (PRPLL, тесты на простоту) | tf (mfaktc, trial factoring). По умолч. prp
#   GIMPS_WORKPREF   тип работы PrimeNet. По умолч.: 150 (first-time PRP) для prp, 12 для tf
#   GIMPS_GPUS       список GPU через запятую, напр. "0,1". По умолч. все
#   GIMPS_NAME       префикс имени компьютера в PrimeNet. По умолч. vast<номер инстанса> на vast.ai, иначе cloud
#   GIMPS_DAYS_WORK  на сколько дней брать задания. По умолч. 1
#   GIMPS_NO_NEW_WORK  1 = не брать новые задания (досчитать имеющиеся); 0 = снять запрет; пусто = снять только
#                    на машине, которая продолжила чужой слот из бэкапа
#   PRPLL_BACKEND    cuda | opencl. По умолч. cuda
#   PRPLL_WORKERS    сколько PRP-тестов одновременно на одной GPU (PRPLL -workers). По умолч. 1
#   PRPLL_TUNE       auto (по умолч.) = один раз на модель GPU, версию PRPLL и диапазон экспонент прогнать
#                    "prpll -tune" (кэш в $DATA_DIR/tune-cache, бэкапится); 0 = не тюнить; 1 = перетюнить
#                    RTX 30 и старше (compute capability < 8.9) не тюнятся: выигрыш мал (PRPLL_TUNE=1 — всё же тюнить)
#   PRPLL_TUNE_ARGS  параметры тюнинга. По умолч. "inplace,exp=<экспонента задания ±3%, кратно 5M>"
#   PRPLL_TUNE_MAX_MIN  предел времени тюнинга, мин. По умолч. 20 (не уложился — работа с настройками по умолчанию)
#   PRPLL_CACHE      1 (по умолч.) = кэш скомпилированных ядер PRPLL (-cache): быстрый перезапуск
#   PRPLL_ARGS       доп. аргументы PRPLL
#   PRP_PROOF_POWER  proof power для PRP (по умолч. 6: 64 остатка, ~1,1 ГБ на тест 140M)
#   PROOF_DISK_GB    диск под proof-файлы на один GPU, ГБ, сообщается PrimeNet. По умолч. 5
#   GPU_SELFTEST     1 (по умолч.) = перед работой PRP-самотест GPU на известном простом M1257787 (раз в сутки)
#   WATCHDOG_MIN     перезапустить воркер, если его лог молчит дольше N минут. По умолч. 20 (0 — выкл.)
#   EE_MAX_PER_HOUR  выключить PRP-воркер, если ошибок Gerbicz (EE) больше N за час. По умолч. 3
#   APN_ARGS         доп. аргументы AutoPrimeNet (напр. "--cert-work")
#   LOG_MAX_MB       обрезать логи больше N МБ (оставляя последние ~25%). По умолч. 20
#   NOTIFY_*         уведомления в Telegram / вебхук — см. gimps-notify
#   CPU_WORK         auto (по умолч.) | 0 — параллельно считать на CPU через mprime (Prime95)
#   CPU_WORKPREF     тип работы для CPU: 4 = P-1 (по умолч.), 5 = ECM, 150 = PRP, 151 = PRP double-check
#   CPU_CORES, CPU_MEM_GB — ресурсы mprime (по умолч. авто)
#   BACKUP_*         внешний бэкап (R2/S3/Google Drive) — см. gimps-backup
#   DATA_DIR         где хранить всё состояние. По умолч. /data
set -uo pipefail

DATA_DIR="${DATA_DIR:-/data}"
# sshd (StrictModes) отвергает ключи, если /root, ~/.ssh или authorized_keys не принадлежат root или доступны на запись
# другим («bad ownership or modes»): так бывает на части хостов vast.ai. Чиним до старта sshd (On-start идёт раньше).
if [ "$(id -u)" = 0 ]; then
  # vast.ai может дописать ключи уже после On-start (с чужим владельцем), поэтому надёжнее отключить StrictModes
  if [ -f /etc/ssh/sshd_config ] && ! grep -q '^StrictModes no' /etc/ssh/sshd_config; then
    sed -i 's/^#\?StrictModes.*//' /etc/ssh/sshd_config; echo 'StrictModes no' >> /etc/ssh/sshd_config
  fi
  chown root:root /root 2>/dev/null; chmod go-w /root 2>/dev/null
  if [ -d /root/.ssh ]; then
    chown -R root:root /root/.ssh 2>/dev/null; chmod 700 /root/.ssh 2>/dev/null
    chmod 600 /root/.ssh/authorized_keys 2>/dev/null
  fi
fi
mkdir -p "$DATA_DIR/logs"
# Переменные из On-start (ключи R2, логин, уведомления…) не видны в SSH-сессии, поэтому gimps-stop/gimps-backup,
# запущенные вручную, их бы не знали. Сохраняем их в $DATA_DIR/.onstart.env (права 600, в бэкап не попадает).
# Перезаписываем только когда переменные действительно переданы (ручной запуск из SSH без них файл не затрёт).
if [ "${GIMPS_DAEMON:-0}" != "1" ] && compgen -v | grep -qE '^(GIMPS_USER|BACKUP_)'; then
  ( umask 077
    for k in $(compgen -v | grep -E '^(GIMPS_|BACKUP_|NOTIFY_|PRPLL_|PRP_PROOF_POWER|PROOF_DISK_GB|GPU_SELFTEST|WATCHDOG_MIN|EE_MAX_PER_HOUR|APN_ARGS|LOG_MAX_MB|CPU_|RCLONE_)' | grep -vx 'GIMPS_DAEMON'); do
      printf 'export %s=%q\n' "$k" "${!k}"
    done > "$DATA_DIR/.onstart.env.new" ) && mv -f "$DATA_DIR/.onstart.env.new" "$DATA_DIR/.onstart.env"
fi
for f in "$DATA_DIR/.onstart.env" "$DATA_DIR/gimps.env"; do [ -f "$f" ] && set -a && . "$f" && set +a; done

if [ "${1:-}" = "--daemon" ]; then
  GIMPS_DAEMON=1 setsid nohup "$0" >>"$DATA_DIR/logs/gimps-start.log" 2>&1 < /dev/null &
  echo "gimps-start запущен в фоне (pid $!). Живой журнал: gimps-watch ; статус: gimps-status"
  exit 0
fi

# Один экземпляр на машину: блокировку держат gimps-start и все его воркеры (наследуют дескриптор),
# поэтому повторный запуск откажет, пока жив хотя бы один процесс прошлого запуска.
exec 8>"$DATA_DIR/.gimps-start.lock"
if ! flock -n 8; then
  echo "[$(date '+%F %T')] gimps-start уже работает (или остались его воркеры). Статус: gimps-status; остановить: gimps-stop" >&2
  exit 1
fi
# одинаковая нумерация GPU у CUDA, OpenCL и nvidia-smi (иначе CUDA ставит «самую быструю» первой)
export CUDA_DEVICE_ORDER=PCI_BUS_ID

host="$(hostname)"
if [[ "$host" =~ ^C\.([0-9]+)$ ]]; then def_name="vast${BASH_REMATCH[1]}"; else def_name="cloud"; fi
export GIMPS_NAME="${GIMPS_NAME:-$def_name}"
export BACKUP_NAME="${BACKUP_NAME:-gimps}"          # не зависит от имени машины — иначе новая машина не найдёт бэкап
GIMPS_USER="${GIMPS_USER:-ANONYMOUS}"
GIMPS_MODE="${GIMPS_MODE:-prp}"
GIMPS_DAYS_WORK="${GIMPS_DAYS_WORK:-1}"
PRPLL_BACKEND="${PRPLL_BACKEND:-cuda}"
PRPLL_WORKERS="${PRPLL_WORKERS:-1}"
PROOF_DISK_GB="${PROOF_DISK_GB:-5}"
PRP_PROOF_POWER="${PRP_PROOF_POWER:-6}"
export WATCHDOG_MIN="${WATCHDOG_MIN:-20}" EE_MAX_PER_HOUR="${EE_MAX_PER_HOUR:-3}"
LOG_MAX_MB="${LOG_MAX_MB:-20}"
# -proof / -cache / -workers из PRPLL_ARGS имеют приоритет
[[ " ${PRPLL_ARGS:-} " == *" -proof "* ]] || PRPLL_ARGS="-proof $PRP_PROOF_POWER ${PRPLL_ARGS:-}"
[[ "${PRPLL_CACHE:-1}" = "1" && " $PRPLL_ARGS " != *" -cache "* ]] && PRPLL_ARGS="-cache $PRPLL_ARGS"
[[ "$PRPLL_WORKERS" -gt 1 && " $PRPLL_ARGS " != *" -workers "* ]] && PRPLL_ARGS="-workers $PRPLL_WORKERS $PRPLL_ARGS"
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
plog() { log "$*" | tee -a "$DATA_DIR/logs/progress.log"; }          # видно и в gimps-watch
notify() { ( gimps-notify "$*" >/dev/null 2>&1 & ) ; }

if ! nvidia-smi -L >/dev/null 2>&1; then
  plog "ОШИБКА: nvidia-smi не видит GPU. Контейнер запущен без --gpus all / без NVIDIA runtime?"
  notify "ОШИБКА: nvidia-smi не видит GPU — расчёт не запущен"; rm -f "$DATA_DIR/gimps-start.pid"; exit 1
fi
if [ -n "${GIMPS_GPUS:-}" ]; then
  IFS=',' read -r -a GPUS <<< "$GIMPS_GPUS"
else
  mapfile -t GPUS < <(nvidia-smi --query-gpu=index --format=csv,noheader)
fi
[ "$GIMPS_USER" = "ANONYMOUS" ] && log "ВНИМАНИЕ: GIMPS_USER не задан — работаю как ANONYMOUS (результаты не попадут в ваш аккаунт)"

# ---------------------------------------------------------------- бэкап: выбор слота / восстановление
BACKUP_ON=0
rm -rf "$DATA_DIR/.snap"
if [ -n "${BACKUP_BUCKET:-}${BACKUP_REMOTE:-}${BACKUP_GDRIVE_TOKEN:-}" ]; then
  BACKUP_ON=1
  # С нуля НЕ стартуем, пока не убедились, что хранилище читается (иначе можно бросить задания и затереть бэкап).
  wait_min="${BACKUP_RESTORE_WAIT_MIN:-30}"; deadline=$(( $(date +%s) + wait_min * 60 )); notified=0
  while :; do
    gimps-backup claim; rc=$?
    [ $rc -eq 0 ] && break
    case $rc in
      5) why="хранилище недоступно (сеть, ключи, бакет?) — см. сообщение выше" ;;
      6) why="все слоты заняты живыми машинами (дождитесь освобождения или задайте другой BACKUP_NAME)" ;;
      *) why="ошибка gimps-backup claim (код $rc)" ;;
    esac
    [ $notified = 0 ] && { notify "Бэкап: $why. Жду до $wait_min мин."; notified=1; }
    if [ "$(date +%s)" -ge "$deadline" ]; then
      plog "ОШИБКА: $why. Ждал $wait_min мин — не запускаюсь, чтобы не начать задания заново и не затереть бэкап."
      notify "ОСТАНОВЛЕНО: $why"; rm -f "$DATA_DIR/gimps-start.pid"; exit 1
    fi
    plog "Бэкап: $why. Повтор через 60 с (до $wait_min мин)."
    sleep 60
  done
  for d in "$DATA_DIR"/*-gpu*; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"; m="${n%-gpu*}"; i="${n##*-gpu}"
    if [ "$m" != "$GIMPS_MODE" ] || [[ " ${GPUS[*]} " != *" $i "* ]]; then
      plog "ВНИМАНИЕ: папка $n (из бэкапа) не будет обсчитываться: режим $GIMPS_MODE, GPU ${GPUS[*]}. Нужна машина с тем же числом GPU / тем же GIMPS_MODE."
    fi
  done
  ( gimps-backup loop >>"$DATA_DIR/logs/backup.log" 2>&1 ) 8>&- &
  log "Внешний бэкап включён: каждые ${BACKUP_INTERVAL_MIN:-30} мин (лог: $DATA_DIR/logs/backup.log)"
fi
# остатки блокировок / pid-файлов от прошлого запуска (или из бэкапа) не должны мешать старту
find "$DATA_DIR" -maxdepth 3 \( -name '*.lck' -o -name '~lock' \) -delete 2>/dev/null
rm -f "$DATA_DIR"/.pid-*
log "Режим: $GIMPS_MODE, workpref=$WORKPREF, пользователь=$GIMPS_USER, имя=$GIMPS_NAME, GPU: ${GPUS[*]}"

# ---------------------------------------------------------------- фоновые службы
# живой журнал + сторожевой таймер (stdout + logs/progress.log; смотреть: gimps-watch).
# В фоновом режиме его вывод в gimps-start.log не дублируем.
if [ "${GIMPS_DAEMON:-0}" = "1" ]; then
  ( while [ ! -f "$STOP_FLAG" ]; do gimps-monitor >/dev/null 2>>"$DATA_DIR/logs/monitor-errors.log"; sleep 5; done ) 8>&- &
else
  ( while [ ! -f "$STOP_FLAG" ]; do gimps-monitor; sleep 5; done ) 8>&- &
fi
# обрезка логов: файл больше LOG_MAX_MB → оставить последнюю четверть (писатели держат O_APPEND — это безопасно)
(
  while [ ! -f "$STOP_FLAG" ]; do
    for f in "$DATA_DIR"/logs/*.log "$DATA_DIR"/*-gpu*/gpuowl-*.log "$DATA_DIR"/cpu/*.log; do
      [ -f "$f" ] || continue
      if [ "$(stat -c %s "$f")" -gt $(( LOG_MAX_MB * 1048576 )) ]; then
        tail -c $(( LOG_MAX_MB * 262144 )) "$f" > "$f.tmp" && cat "$f.tmp" > "$f" && rm -f "$f.tmp"
      fi
    done
    for _ in $(seq 60); do [ -f "$STOP_FLAG" ] && break; sleep 10; done   # 10 мин, но быстрый выход при остановке
  done
) 8>&- &          # служебные циклы не держат блокировку запуска — её держат только gimps-start и воркеры

# пауза, прерываемая остановкой (чтобы gimps-start завершался быстро и сразу освобождал блокировку)
pause() { local i; for ((i = 0; i < $1; i += 5)); do [ -f "$STOP_FLAG" ] && return; sleep 5; done; }

# ---------------------------------------------------------------- перезапуск воркеров
# forever <имя> <команда...>: перезапускает команду, пока нет стоп-флага. pid — в $DATA_DIR/.pid-<имя> (для сторожа).
# Флаг $DATA_DIR/.disabled-<имя> (самотест не прошёл / много ошибок) — воркер не запускается.
# 5 падений подряд в первые 5 минут работы — воркер выключается (неисправный хост / драйвер).
forever() {
  local name="$1"; shift
  local logf="$DATA_DIR/logs/$name.log" fast=0
  while [ ! -f "$STOP_FLAG" ]; do
    if [ -f "$DATA_DIR/.disabled-$name" ]; then pause 60; continue; fi
    log "старт: $*" >>"$logf"
    local t0; t0=$(date +%s)
    "$@" >>"$logf" 2>&1 &
    local pid=$!; echo "$pid" > "$DATA_DIR/.pid-$name"
    wait "$pid"; local rc=$?
    rm -f "$DATA_DIR/.pid-$name"
    [ -f "$STOP_FLAG" ] && break
    if [ $rc -ne 0 ] && [ $(( $(date +%s) - t0 )) -lt 300 ]; then fast=$((fast + 1)); else fast=0; fi
    if [ $fast -ge 5 ]; then
      echo "5 падений подряд (последний код $rc), см. logs/$name.log" > "$DATA_DIR/.disabled-$name"
      plog "ОШИБКА: $name падает 5 раз подряд — выключен (файл .disabled-$name). Проверьте logs/$name.log"
      notify "ВЫКЛЮЧЕН $name: 5 падений подряд (код $rc)"
      continue
    fi
    log "$name завершился (rc=$rc), перезапуск через 60 с" >>"$logf"
    pause 60
  done
}

shutdown() {
  log "Получен сигнал остановки — корректно останавливаю воркеры (сохранение чекпойнтов)"
  local by_stop=0; [ -f "$STOP_FLAG" ] && by_stop=1     # остановку начал gimps-stop: бэкап он делает сам
  touch "$STOP_FLAG"
  pkill -TERM -x prpll-cuda; pkill -TERM -x prpll-ocl; pkill -TERM -x mfaktc; pkill -INT -x mprime
  for _ in $(seq 1 90); do pgrep -x 'prpll-cuda|prpll-ocl|mfaktc|mprime' >/dev/null || break; sleep 1; done
  pkill -f '^python3 .*autoprimenet.py -w'
  pkill -f '^python3 .*gimps-monitor'
  if [ "$BACKUP_ON" = "1" ] && [ $by_stop = 0 ]; then
    log "Финальный бэкап во внешнее хранилище..."
    timeout 600 gimps-backup >>"$DATA_DIR/logs/backup.log" 2>&1 && log "бэкап ok" || log "бэкап не удался (см. logs/backup.log)"
  fi
  rm -f "$DATA_DIR/gimps-start.pid" "$DATA_DIR"/.pid-*
  wait
  log "Остановлено"
  exit 0
}
trap shutdown INT TERM

# ---------------------------------------------------------------- PRPLL: тюнинг и самотест
# Диапазон экспонент для тюнинга — узкий, вокруг полученных заданий (±3%, кратно 5M): тюнятся 1–2 размера FFT
# вместо всего диапазона, это в разы быстрее. Кэш с более широким покрывающим диапазоном используется повторно.
tune_range() {
  local dir="$1" lo hi
  # строки вида PRP=<AID>,1,2,<экспонента>,-1,77,0 — берём первое число 1M…10^10 после AID
  read -r lo hi < <(cat "$dir"/worktodo*.txt 2>/dev/null \
    | awk -F'[=,]' '/^[A-Za-z]+=/ {for(i=3;i<=NF;i++) if ($i ~ /^[0-9]+$/ && length($i) <= 10 && $i+0 > 1000000) {print $i; break}}' \
    | sort -n | awk 'NR==1{lo=$1} {hi=$1} END{if (NR) {l=int(lo*0.97/5e6)*5; h=int(hi*1.03/5e6+0.999)*5; if (l<1) l=1; printf "%d %d\n", l, h}}')
  if [ -n "${lo:-}" ]; then echo "exp=${lo}M-${hi}M"; else echo "exp=150M-165M"; fi
}

# Тюнинг под модель GPU: один раз, кэш (config.txt + tune.txt) на модель + бэкенд + версию PRPLL + диапазон.
# Неудачный тюнинг повторяется не чаще раза в сутки.
prpll_tune() {
  local g="$1" dir="$2" name="$3" mode="${PRPLL_TUNE:-auto}"
  [ "$mode" = "0" ] && return 0
  local ver; ver="$(cat /opt/gimps/PRPLL_VERSION 2>/dev/null || echo unknown)"
  local args="${PRPLL_TUNE_ARGS:-inplace,$(tune_range "$dir")}"
  local prefix; prefix="$(echo "$name-$PRPLL_BACKEND-$ver-" | tr -c 'A-Za-z0-9.\n-' '_')"
  local slug; slug="$prefix$(echo "${args##*exp=}" | tr -c 'A-Za-z0-9.\n-' '_')"
  local cache="$DATA_DIR/tune-cache/$slug"
  # уже есть тюнинг этой модели/версии на более широкий диапазон, покрывающий нужный, — берём его
  if [ "$mode" != "1" ] && [ ! -s "$cache/tune.txt" ]; then
    local want="${args##*exp=}" wlo whi d r clo chi
    wlo="${want%%M-*}"; whi="${want##*-}"; whi="${whi%M}"
    for d in "$DATA_DIR/tune-cache/$prefix"*; do
      [ -s "$d/tune.txt" ] || continue
      r="${d##*/$prefix}"; clo="${r%%M-*}"; chi="${r##*-}"; chi="${chi%M}"
      if [[ "$clo$chi$wlo$whi" =~ ^[0-9]+$ ]] && [ "$clo" -le "$wlo" ] && [ "$chi" -ge "$whi" ]; then
        cache="$d"; break
      fi
    done
  fi
  # RTX 30 и старше (compute capability < 8.9): выигрыш от тюнинга мал — не тратим на него время (PRPLL_TUNE=1 — всё же тюнить)
  if [ "$mode" != "1" ] && [ ! -s "$cache/tune.txt" ]; then
    local cc; cc="$(nvidia-smi -i "$g" --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ')"
    if [[ "$cc" =~ ^[0-9]+\.[0-9]+$ ]] && awk -v c="$cc" 'BEGIN{exit !(c < 8.9)}'; then
      log "GPU $g: $name (CC $cc, RTX 30 или старше) — тюнинг пропущен, настройки PRPLL по умолчанию (принудительно: PRPLL_TUNE=1)"
      return 0
    fi
  fi
  mkdir -p "$cache"
  (
    flock 9                                            # одинаковые GPU тюнятся один раз, остальные ждут
    if [ "$mode" != "1" ] && [ ! -s "$cache/tune.txt" ] && [ -f "$cache/.failed" ] \
       && [ $(( $(date +%s) - $(stat -c %Y "$cache/.failed") )) -lt 86400 ]; then
      log "GPU $g: тюнинг не удавался меньше суток назад — пропускаю (повтор: PRPLL_TUNE=1)"; exit 0
    fi
    if [ "$mode" = "1" ] || [ ! -s "$cache/tune.txt" ]; then
      local tmax="${PRPLL_TUNE_MAX_MIN:-20}"
      plog "GPU $g: ТЮНИНГ PRPLL под $name (-tune $args), обычно 5–15 мин, не дольше $tmax мин; ход — в gimps-watch, лог logs/tune-gpu$g.log"
      local tdir; tdir="$(mktemp -d "$DATA_DIR/tune-run.XXXX")"
      ( cd "$tdir" && timeout -k 30 "$(( tmax * 60 ))" "$PRPLL_BIN" -d 0 -dir "$tdir" -cache -tune "$args" >>"$DATA_DIR/logs/tune-gpu$g.log" 2>&1 )
      [ $? -eq 124 ] && log "GPU $g: тюнинг прерван по лимиту $tmax мин (PRPLL_TUNE_MAX_MIN)"
      if [ -s "$tdir/tune.txt" ]; then
        cp "$tdir/tune.txt" "$cache/tune.txt"; [ -f "$tdir/config.txt" ] && cp "$tdir/config.txt" "$cache/config.txt"
        rm -f "$cache/.failed"
        plog "GPU $g: тюнинг готов, сохранён в $cache"
      else
        touch "$cache/.failed"
        plog "GPU $g: тюнинг не дал tune.txt (см. logs/tune-gpu$g.log) — работаю с настройками PRPLL по умолчанию"
      fi
      rm -rf "$tdir"
    fi
  ) 9>"$cache/.lock"
  if [ -s "$cache/tune.txt" ]; then
    cp "$cache/tune.txt" "$dir/tune.txt"
    [ -f "$cache/config.txt" ] && cp "$cache/config.txt" "$dir/config.txt"
  fi
  return 0
}

# Самотест GPU: PRP-тест известного простого M1257787 (секунды–минуты) в отдельной папке — результат
# никуда не отправляется. Не прошёл → воркер этой GPU выключен (.disabled-prp-gpuN) и приходит уведомление.
gpu_selftest() {
  local g="$1" name="$2"
  [ "${GPU_SELFTEST:-1}" = "1" ] || return 0
  local ok="$DATA_DIR/.selftest-ok-gpu$g"
  if [ -f "$ok" ] && [ $(( $(date +%s) - $(stat -c %Y "$ok") )) -lt 86400 ]; then return 0; fi
  local t; t="$(mktemp -d "$DATA_DIR/tune-run.st.XXXX")"
  plog "GPU $g: самотест PRPLL (M1257787 — известное простое)…"
  ( cd "$t" && timeout 1200 "$PRPLL_BIN" -d 0 -dir "$t" -prp 1257787 -proof 0 >>"$DATA_DIR/logs/selftest-gpu$g.log" 2>&1 )
  if grep -qE '"status" *: *"P"' "$t"/results*.txt 2>/dev/null; then
    touch "$ok"; rm -rf "$t"; plog "GPU $g: самотест пройден"; return 0
  fi
  rm -rf "$t"
  if grep -q 'cuInit failed' "$DATA_DIR/logs/selftest-gpu$g.log" 2>/dev/null; then
    plog "ОШИБКА: GPU $g: CUDA не инициализируется (cuInit failed) — драйвер/хост неисправен, смените машину"
  fi
  echo "самотест PRPLL не пройден $(ts) — см. logs/selftest-gpu$g.log" > "$DATA_DIR/.disabled-prp-gpu$g"
  plog "ОШИБКА: GPU $g ($name) не прошла самотест — воркер выключен. Хост/драйвер неисправен? См. logs/selftest-gpu$g.log"
  notify "GPU $g ($name) НЕ прошла самотест PRPLL — воркер выключен, смените машину"
  return 1
}

# Запрет на новые задания (gimps-stop --finish → QuitGIMPS в prime.ini) снимается автоматически только
# на машине, которая продолжила чужой слот из бэкапа; GIMPS_NO_NEW_WORK=1/0 — явно включить/снять.
apn_work_policy() {
  local dir="$1"
  [ -f "$dir/prime.ini" ] || return 0
  local quit=0; grep -Eiq '^QuitGIMPS *= *(1|true)' "$dir/prime.ini" && quit=1
  if [ "${GIMPS_NO_NEW_WORK:-}" = "1" ] && [ $quit = 0 ]; then
    $APN -w "$dir" --no-more-work >/dev/null 2>&1; log "$(basename "$dir"): новые задания не берутся (GIMPS_NO_NEW_WORK=1)"
  elif [ $quit = 1 ] && { [ "${GIMPS_NO_NEW_WORK:-}" = "0" ] || [ -f "$DATA_DIR/.restored-from-backup" ]; }; then
    $APN -w "$dir" --resume-work >/dev/null 2>&1; log "$(basename "$dir"): запрет на новые задания снят"
  elif [ $quit = 1 ]; then
    log "$(basename "$dir"): новые задания не берутся (было gimps-stop --finish; снять: GIMPS_NO_NEW_WORK=0)"
  fi
}

# ---------------------------------------------------------------- GPU-воркеры
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
    apn_args=(--prpll "${apn_common[@]}" --max-disk-space "$PROOF_DISK_GB" --num-workers "$PRPLL_WORKERS")
  else
    apn_args=(--mfaktc "${apn_common[@]}")
    [ -f "$dir/mfaktc.ini" ] || cp /opt/gimps/share/mfaktc.ini "$dir/mfaktc.ini"
  fi
  apn_work_policy "$dir"
  # shellcheck disable=SC2086
  ( forever "apn-gpu$g" $APN "${apn_args[@]}" ${APN_ARGS:-} ) &

  sleep 20   # даём AutoPrimeNet зарегистрироваться и получить первое задание

  if [ "$GIMPS_MODE" = "prp" ]; then
    # shellcheck disable=SC2086
    ( cd "$dir" && export CUDA_VISIBLE_DEVICES="$g" && prpll_tune "$g" "$dir" "$gpu_name" \
        && gpu_selftest "$g" "$gpu_name" \
        && forever "prp-gpu$g" stdbuf -oL -eL "$PRPLL_BIN" -d 0 -dir "$dir" -user "$GIMPS_USER" ${PRPLL_ARGS:-} ) &
  else
    # mfaktc при каждом запуске сам прогоняет короткий самотест и не стартует, если он не прошёл
    ( cd "$dir" && export CUDA_VISIBLE_DEVICES="$g" && forever "tf-gpu$g" stdbuf -oL -eL mfaktc -d 0 ) &
  fi
done
rm -f "$DATA_DIR/.restored-from-backup"

# ---------------------------------------------------------------- CPU: mprime (Prime95) параллельно с GPU
if [ "${CPU_WORK:-auto}" != "0" ] && [ -x /opt/gimps/mprime/mprime ]; then
  if gimps-cpu-setup; then
    log "CPU: mprime, тип работы ${CPU_WORKPREF:-4}, низкий приоритет (nice 19) — GPU-воркеры не замедляются"
    ( cd "$DATA_DIR/cpu" && forever "cpu" nice -n 19 unbuffer ./mprime -d ) &
  else
    plog "CPU: mprime не настроен автоматически — CPU не используется (см. $DATA_DIR/cpu/setup.log)"
  fi
fi

log "Запущено. Живой журнал: gimps-watch   Статус: gimps-status   Логи: $DATA_DIR/logs/"
notify "Запущено: режим $GIMPS_MODE, GPU: ${GPUS[*]}$([ "$BACKUP_ON" = 1 ] && echo ", бэкап: слот $(cat "$DATA_DIR/.backup-slot" 2>/dev/null || echo 1)")"
wait
__GIMPS_EOF__
cat > "$D/gimps-stop" <<'__GIMPS_EOF__'
#!/usr/bin/env bash
# Остановка GIMPS.
#   gimps-stop              — корректно остановить воркеры (чекпойнт), отправить результаты. Задания остаются за вами.
#   gimps-stop --finish     — НЕ брать новые задания; текущие досчитать (воркеры продолжают работать)
#   gimps-stop --unreserve  — остановить, ВЕРНУТЬ все незавершённые задания GPU в PrimeNet и убрать их из бэкапа
#                             (делайте это перед удалением VM, если не будете продолжать!)
set -uo pipefail
DATA_DIR="${DATA_DIR:-/data}"
for f in "$DATA_DIR/.onstart.env" "$DATA_DIR/gimps.env"; do [ -f "$f" ] && set -a && . "$f" && set +a; done
APN="python3 $(command -v autoprimenet.py)"
dirs=( "$DATA_DIR"/prp-gpu* "$DATA_DIR"/tf-gpu* )

each_dir() { for d in "${dirs[@]}"; do [ -f "$d/prime.ini" ] && { echo "== $d"; $APN -w "$d" "$@"; }; done; }

if [ "${1:-}" = "--finish" ]; then
  pkill -f '^python3 .*autoprimenet.py -w'; sleep 2     # AutoPrimeNet держит lock; цикл в gimps-start перезапустит его через минуту
  each_dir --no-more-work
  echo "GPU: новые задания больше не берутся. Когда gimps-status покажет пустую очередь — можно останавливать."
  echo "     Запрет сохраняется при перезапуске этой машины; на машине, продолжившей слот из бэкапа, снимается сам."
  echo "     Снять вручную: GIMPS_NO_NEW_WORK=0 при следующем gimps-start."
  [ -d "$DATA_DIR/cpu" ] && echo "CPU (mprime): задание P-1 длится часы; чтобы не брать новые — cd $DATA_DIR/cpu && ./mprime -m → Test/PrimeNet."
  exit 0
fi

touch "$DATA_DIR/.stop"
pkill -TERM -x prpll-cuda; pkill -TERM -x prpll-ocl; pkill -TERM -x mfaktc; pkill -INT -x mprime
echo "Жду сохранения чекпойнтов..."
for _ in $(seq 1 120); do pgrep -x 'prpll-cuda|prpll-ocl|mfaktc|mprime' >/dev/null || break; sleep 1; done
pkill -f '^python3 .*autoprimenet.py -w'
for _ in $(seq 1 15); do pgrep -f '^python3 .*autoprimenet.py -w' >/dev/null || break; sleep 1; done
echo "Отправляю результаты и proof-файлы..."
each_dir --upload-proofs
backup_on=0
{ [ -n "${BACKUP_BUCKET:-}${BACKUP_REMOTE:-}${BACKUP_GDRIVE_TOKEN:-}" ] || grep -qs '^BACKUP_' "$DATA_DIR/gimps.env"; } && backup_on=1
if [ "${1:-}" = "--unreserve" ]; then
  echo "Возвращаю задания GPU в PrimeNet..."; each_dir --unreserve-all
  [ -d "$DATA_DIR/cpu" ] && echo "CPU (mprime): незавершённое задание верните вручную: cd $DATA_DIR/cpu && ./mprime -m → Advanced → Unreserve exponent"
  # задания возвращены — их чекпойнты в бэкапе больше не нужны и не должны продолжиться на другой машине
  [ $backup_on = 1 ] && { echo "Убираю GPU-задания из слота бэкапа..."; gimps-backup release; }
elif [ $backup_on = 1 ]; then
  echo "Финальный бэкап во внешнее хранилище..."; gimps-backup
fi
[ -f "$DATA_DIR/gimps-start.pid" ] && kill "$(cat "$DATA_DIR/gimps-start.pid")" 2>/dev/null; rm -f "$DATA_DIR/gimps-start.pid"
# gimps-start и его фоновые циклы должны выйти сами (стоп-флаг); если кто-то задержался — завершаем принудительно
for _ in $(seq 1 30); do pgrep -f 'bash .*/gimps-start' >/dev/null || break; sleep 1; done
pkill -TERM -f 'bash .*/gimps-start' 2>/dev/null; sleep 3; pkill -KILL -f 'bash .*/gimps-start' 2>/dev/null
pkill -f '^python3 .*autoprimenet.py -w' 2>/dev/null; pkill -f 'python3 .*/gimps-monitor' 2>/dev/null
echo "Готово. Запуск заново: gimps-start --daemon"
__GIMPS_EOF__
cat > "$D/gimps-status" <<'__GIMPS_EOF__'
#!/usr/bin/env bash
# Сводка: GPU, CPU, задания по каждому воркеру, последние события прогресса, бэкап.
set -uo pipefail
DATA_DIR="${DATA_DIR:-/data}"

echo "===== GPU ====="
nvidia-smi --query-gpu=index,name,utilization.gpu,temperature.gpu,power.draw,power.limit,clocks.sm,clocks.mem,memory.used \
  --format=csv 2>/dev/null || echo "nvidia-smi недоступен"
echo
for d in "$DATA_DIR"/prp-gpu* "$DATA_DIR"/tf-gpu*; do
  [ -d "$d" ] || continue
  n="$(basename "$d")"
  echo "===== $n ====="
  echo "--- задания (worktodo):"
  cat "$d"/worktodo*.txt 2>/dev/null | grep -v '^\s*$' | head -5 || true
  q=$(cat "$d"/worktodo*.txt 2>/dev/null | grep -c . ); echo "    (всего в очереди: $q)"
  echo "--- результатов записано: $(cat "$d"/results*.txt 2>/dev/null | grep -c . )"
  [ -s "$d/tune.txt" ] && echo "--- PRPLL tune.txt: есть (оптимизировано под эту GPU)"
  echo "--- лог AutoPrimeNet:"
  tail -n 2 "$DATA_DIR/logs/apn-${n#*-}.log" 2>/dev/null
  echo
done
if [ -d "$DATA_DIR/cpu" ]; then
  echo "===== CPU (mprime) ====="
  if pgrep -x mprime >/dev/null; then
    ps -o pid,ni,%cpu,rss,etime,cmd -C mprime | sed 's/^/    /'
  else
    echo "    mprime не запущен"
  fi
  grep -h -E '^(Factor|Pfactor|Pminus1|PRP|ECM2|DoubleCheck|Test)=' "$DATA_DIR"/cpu/worktodo.txt 2>/dev/null | head -3 | sed 's/^/    /'
  tail -n 2 "$DATA_DIR/logs/cpu.log" 2>/dev/null | sed 's/^/    /'
  echo
fi
echo "===== последние события (полный живой журнал: gimps-watch) ====="
tail -n 8 "$DATA_DIR/logs/progress.log" 2>/dev/null || echo "    журнал ещё пуст"
if [ -f "$DATA_DIR/logs/backup.log" ]; then
  echo
  echo "===== внешний бэкап ====="
  echo "слот: $(cat "$DATA_DIR/.backup-slot" 2>/dev/null || echo 1) | последний успешный: $(cat "$DATA_DIR/logs/last-backup" 2>/dev/null || echo 'ещё не было')"
  tail -n 2 "$DATA_DIR/logs/backup.log"
fi
for f in "$DATA_DIR"/.disabled-*; do
  [ -f "$f" ] || continue
  echo "!!! ВЫКЛЮЧЕН $(basename "$f" | sed 's/^.disabled-//'): $(cat "$f")  — вернуть: rm $f"
done
[ -f "$DATA_DIR/.stop" ] && echo "(стоп-флаг установлен — воркеры остановлены)"
exit 0
__GIMPS_EOF__
cat > "$D/gimps-backup" <<'__GIMPS_EOF__'
#!/usr/bin/env bash
# Резервное копирование состояния GIMPS ($DATA_DIR: чекпойнты PRPLL/mfaktc/mprime, proof-остатки, задания,
# prime.ini, кэш тюнинга) наружу — в Cloudflare R2 / любое S3, Google Drive или любой remote rclone.
#
#   gimps-backup            — синхронизировать сейчас
#   gimps-backup loop       — синхронизировать каждые BACKUP_INTERVAL_MIN минут (запускается из gimps-start)
#   gimps-backup claim      — (на пустой машине) выбрать слот и восстановить из него; вызывается gimps-start
#   gimps-backup restore    — восстановить из текущего слота вручную (FORCE=1 — даже если слот «живой»)
#   gimps-backup release    — убрать из слота чекпойнты GPU-заданий (после gimps-stop --unreserve)
#   gimps-backup ls         — что лежит в хранилище по всем слотам
#   gimps-backup check      — проверить доступ к хранилищу
#
# Слоты: BACKUP_NAME, BACKUP_NAME-2 … BACKUP_NAME-9. Каждая работающая машина держит свой слот и пишет в него
# «пульс» (owner.txt) каждые 2 минуты. Новая машина берёт слот брошенной машины (данные есть, пульса нет
# дольше BACKUP_STALE_SEC) и продолжает её задания; если таких нет — первый пустой слот. Возраст пульса
# считается по часам хранилища, а не машин.
#
# Cloudflare R2: BACKUP_BUCKET, BACKUP_R2_ACCOUNT_ID, BACKUP_S3_ACCESS_KEY, BACKUP_S3_SECRET_KEY
# S3 (B2, AWS…):  BACKUP_BUCKET, BACKUP_S3_ENDPOINT, BACKUP_S3_ACCESS_KEY, BACKUP_S3_SECRET_KEY, BACKUP_S3_REGION
# Google Drive:   BACKUP_GDRIVE_TOKEN, BACKUP_GDRIVE_CLIENT_ID, BACKUP_GDRIVE_CLIENT_SECRET, BACKUP_GDRIVE_FOLDER
# Другое:         BACKUP_REMOTE — готовый путь rclone для первого слота (с RCLONE_CONFIG_* переменными)
# Общие:
#   BACKUP_NAME            базовое имя слотов. По умолч. gimps
#   BACKUP_INTERVAL_MIN    период синхронизации, мин. По умолч. 30
#   BACKUP_S3_CHUNK_SIZE   размер части multipart-загрузки S3/R2. По умолч. 64M
#   BACKUP_PROOF           0 = не копировать proof-остатки. По умолч. 1
#   BACKUP_MAX_DELETE      не удалять в хранилище больше N файлов за раз. По умолч. 300
#   BACKUP_ALLOW_SHRINK    1 = разрешить синхронизацию, даже если локально пропала папка воркера (иначе — отказ)
#   BACKUP_STALE_SEC       через сколько секунд без пульса слот считается брошенным. По умолч. 360
#
# Коды возврата claim/restore: 0 — готово (восстановлено или чистый старт), 5 — хранилище недоступно/ошибка,
# 6 — все слоты заняты живыми машинами, 4 — слот занят живой машиной (restore без FORCE).
set -uo pipefail
DATA_DIR="${DATA_DIR:-/data}"
mkdir -p "$DATA_DIR/logs"
for f in "$DATA_DIR/.onstart.env" "$DATA_DIR/gimps.env"; do [ -f "$f" ] && set -a && . "$f" && set +a; done

BASE_NAME="${BACKUP_NAME:-gimps}"
INTERVAL="${BACKUP_INTERVAL_MIN:-30}"
STALE_SEC="${BACKUP_STALE_SEC:-360}"
MAX_SLOTS=9

if [ -n "${BACKUP_REMOTE:-}" ]; then
  BASE_PATH="${BACKUP_REMOTE%/}"
elif [ -n "${BACKUP_GDRIVE_TOKEN:-}" ]; then
  export RCLONE_CONFIG_GIMPSGD_TYPE=drive
  export RCLONE_CONFIG_GIMPSGD_SCOPE=drive.file          # rclone видит только свои файлы, а не весь Диск
  export RCLONE_CONFIG_GIMPSGD_TOKEN="$BACKUP_GDRIVE_TOKEN"
  export RCLONE_CONFIG_GIMPSGD_CLIENT_ID="${BACKUP_GDRIVE_CLIENT_ID:?нужен BACKUP_GDRIVE_CLIENT_ID}"
  export RCLONE_CONFIG_GIMPSGD_CLIENT_SECRET="${BACKUP_GDRIVE_CLIENT_SECRET:?нужен BACKUP_GDRIVE_CLIENT_SECRET}"
  export RCLONE_CONFIG_GIMPSGD_USE_TRASH=false
  BASE_PATH="gimpsgd:${BACKUP_GDRIVE_FOLDER:-gimps-backup}/${BASE_NAME}"
elif [ -n "${BACKUP_BUCKET:-}" ]; then
  export RCLONE_CONFIG_GIMPSS3_TYPE=s3
  export RCLONE_CONFIG_GIMPSS3_PROVIDER=Other
  if [ -n "${BACKUP_R2_ACCOUNT_ID:-}" ]; then          # Cloudflare R2: адрес и регион из Account ID
    export RCLONE_CONFIG_GIMPSS3_PROVIDER=Cloudflare
    BACKUP_S3_ENDPOINT="${BACKUP_S3_ENDPOINT:-https://${BACKUP_R2_ACCOUNT_ID}.r2.cloudflarestorage.com}"
    BACKUP_S3_REGION="${BACKUP_S3_REGION:-auto}"
  fi
  export RCLONE_CONFIG_GIMPSS3_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY:?нужен BACKUP_S3_ACCESS_KEY}"
  export RCLONE_CONFIG_GIMPSS3_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_KEY:?нужен BACKUP_S3_SECRET_KEY}"
  export RCLONE_CONFIG_GIMPSS3_ENDPOINT="${BACKUP_S3_ENDPOINT:?нужен BACKUP_S3_ENDPOINT}"
  export RCLONE_CONFIG_GIMPSS3_REGION="${BACKUP_S3_REGION:-us-east-1}"
  export RCLONE_CONFIG_GIMPSS3_NO_CHECK_BUCKET=true
  export RCLONE_CONFIG_GIMPSS3_CHUNK_SIZE="${BACKUP_S3_CHUNK_SIZE:-64M}"
  BASE_PATH="gimpss3:${BACKUP_BUCKET}/${BASE_NAME}"
else
  echo "Бэкап не настроен (нет BACKUP_BUCKET / BACKUP_GDRIVE_TOKEN / BACKUP_REMOTE)"; exit 3
fi

slot_path() { if [ "$1" -le 1 ]; then echo "$BASE_PATH"; else echo "$BASE_PATH-$1"; fi; }
SLOT_FILE="$DATA_DIR/.backup-slot"          # номер слота этой машины (в бэкап не попадает)
SLOT="$(cat "$SLOT_FILE" 2>/dev/null || echo 1)"; [[ "$SLOT" =~ ^[0-9]+$ ]] || SLOT=1
REMOTE="$(slot_path "$SLOT")"

[ -f "$DATA_DIR/.machine-id" ] || head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$DATA_DIR/.machine-id"
MID="$(cat "$DATA_DIR/.machine-id")"
OK_MARK="$DATA_DIR/.backup-ok"              # эта машина имеет право писать в свой слот
SNAP="$DATA_DIR/.snap"                       # мгновенный снимок (жёсткие ссылки) для согласованной загрузки
LOCK="$DATA_DIR/.backup.lock"

RC=(rclone --config /dev/null --transfers 4 --checkers 16 --retries 3 --retries-sleep 10s
    --low-level-retries 10 --contimeout 30s --timeout 5m --stats 0 -q)
EXCL=(--exclude "logs/**" --exclude ".snap/**" --exclude "*.new" --exclude "~lock" --exclude ".stop"
      --exclude "gimps-start.pid" --exclude ".machine-id" --exclude ".backup-ok" --exclude ".backup-slot"
      --exclude ".backup.lock" --exclude ".gimps-start.lock" --exclude "kernel-cache/**" --exclude "gimps.env" --exclude ".onstart.env*"
      --exclude "tune-run.*/**" --exclude "**/.lock" --exclude "*.lck" --exclude "*.write"
      --exclude ".selftest-ok-*" --exclude ".disabled-*" --exclude ".pid-*" --exclude ".restored-from-backup"
      --exclude ".monitor.lock" --exclude "gpuowl-*.log" --exclude "autoprimenet.log*")
[ "${BACKUP_PROOF:-1}" = "0" ] && EXCL+=(--exclude "/*/*/proof/**")   # <gpu-dir>/<exponent>/proof/<k>

ts() { date '+%F %T'; }
log() { echo "[$(ts)] backup[$(basename "$REMOTE")]: $*"; }

# локально есть рабочие данные?
local_has_data() { ls "$DATA_DIR"/*/prime.ini "$DATA_DIR"/cpu/prime.txt >/dev/null 2>&1; }

# Возраст файла в хранилище по часам ХРАНИЛИЩА (пишем пробу и сравниваем времена изменения). Печатает секунды.
# Код: 0 — ок, 1 — файла нет, 2 — ошибка доступа.
remote_age() {
  local dir="$1" name="$2" probe=".probe-$MID" js
  echo x | "${RC[@]}" rcat "$dir/$probe" || return 2
  js="$("${RC[@]}" lsjson --use-server-modtime --files-only "$dir" 2>/dev/null)"; local rc=$?
  "${RC[@]}" deletefile "$dir/$probe" >/dev/null 2>&1
  [ $rc -eq 0 ] || return 2
  python3 -c '
import json, re, sys, datetime as d
def t(s):
    m = re.match(r"(.*?\d\d:\d\d:\d\d)(\.\d+)?(Z|[+-]\d\d:\d\d)?$", s)
    frac = (m.group(2) or "")[:7]; tz = m.group(3) or "Z"
    return d.datetime.fromisoformat(m.group(1) + frac + ("+00:00" if tz == "Z" else tz))
items = {x["Name"]: x["ModTime"] for x in json.loads(sys.stdin.read() or "[]")}
name, probe = sys.argv[1], sys.argv[2]
if name not in items: sys.exit(1)
print(max(0, int((t(items[probe]) - t(items[name])).total_seconds())))' "$name" "$probe" <<<"$js"
}

# Состояние слота: печатает empty | stale | live | mine. Код 2 — ошибка доступа.
slot_state() {
  local p="$1" list rc owner omid age has_data=0
  list="$("${RC[@]}" lsf --max-depth 1 "$p" 2>/dev/null)"; rc=$?
  if [ $rc -ne 0 ] && [ $rc -ne 3 ]; then return 2; fi     # 3 = «папки нет» — это просто пусто
  grep -qx 'data/' <<<"$list" && has_data=1
  if grep -qx 'owner.txt' <<<"$list"; then
    owner="$("${RC[@]}" cat "$p/owner.txt" 2>/dev/null)" || return 2
    read -r omid _ <<<"$owner"
    if [ "$omid" = "$MID" ]; then echo mine; return 0; fi
    age="$(remote_age "$p" owner.txt)"; rc=$?
    [ $rc -eq 2 ] && return 2
    if [ $rc -eq 0 ] && [ "$age" -lt "$STALE_SEC" ]; then echo live; return 0; fi
  fi
  if [ $has_data = 1 ]; then echo stale; else echo empty; fi
}

heartbeat() { echo "$MID $(date +%s) $(hostname) $(ts)" | "${RC[@]}" rcat "$REMOTE/owner.txt"; }

# 0 — можно писать в свой слот; 1 — в нём пишет другая живая машина; 2 — ошибка доступа
owner_ok() {
  local s; s="$(slot_state "$REMOTE")" || return 2
  [ "$s" = live ] && return 1 || return 0
}

with_lock() { ( flock -w 1800 9 || { log "не дождался блокировки"; exit 1; }; "$@" ) 9>"$LOCK"; }

# Мгновенный снимок на жёстких ссылках: место не занимает, файлы, заменяемые через переименование
# (сейвфайлы PRPLL, чекпойнты mfaktc), в снимке не меняются. Сначала всё, кроме proof-остатков, потом остатки —
# так каждому сейвфайлу в снимке соответствуют все остатки до его итерации. Мелкие файлы (их пишут «на месте»)
# копируются по-настоящему.
snap_make() {
  rm -rf "$SNAP"; mkdir -p "$SNAP"
  local prune=( \( -path ./.snap -o -path ./logs -o -name 'tune-run.*' -o -name 'kernel-cache' \) -prune -o )
  ( cd "$DATA_DIR" && find . -mindepth 1 "${prune[@]}" -type f ! -path '*/proof/*' -print0 \
      | xargs -0 -r cp -l --parents -t "$SNAP" 2>/dev/null )
  ( cd "$DATA_DIR" && find . -mindepth 1 "${prune[@]}" -type f -path '*/proof/*' -print0 \
      | xargs -0 -r cp -l --parents -t "$SNAP" 2>/dev/null )
  find "$SNAP" -type f -size -2048k -print0 | while IFS= read -r -d '' f; do
    cp -p "$f" "$f.cp.$$" 2>/dev/null && mv -f "$f.cp.$$" "$f"
  done
  return 0
}

# Отказ, если в хранилище есть папка воркера (prime.ini / cpu/prime.txt), которой нет локально:
# синхронизация удалила бы её задания из бэкапа.
shrink_guard() {
  [ "${BACKUP_ALLOW_SHRINK:-0}" = "1" ] && return 0
  local f missing=""
  while IFS= read -r f; do
    [ -n "$f" ] && [ ! -f "$SNAP/$f" ] && missing+="$f "
  done < <("${RC[@]}" lsf -R --files-only --include "*/prime.ini" --include "cpu/prime.txt" "$REMOTE/data" 2>/dev/null)
  if [ -n "$missing" ]; then
    log "ОТКАЗ: в хранилище есть, а локально нет: $missing— бэкап не трогаю (если так и задумано: BACKUP_ALLOW_SHRINK=1)"
    return 1
  fi
}

do_sync() {
  if [ ! -f "$OK_MARK" ]; then
    # эта машина ещё ни разу не восстанавливалась и не писала: не затираем чужой бэкап
    local s; s="$(slot_state "$REMOTE")"; local rc=$?
    if [ $rc -ne 0 ]; then log "хранилище недоступно — синхронизация пропущена"; return 1; fi
    if [ "$s" = stale ] && ! local_has_data; then
      log "в слоте есть данные, а локально пусто — сначала gimps-backup claim/restore. Пропускаю."; return 1
    fi
    touch "$OK_MARK"
  fi
  owner_ok; case $? in
    1) log "в слот пишет ДРУГАЯ живая машина — синхронизация пропущена (одинаковый слот на двух машинах?)"; return 1 ;;
    2) log "хранилище недоступно — синхронизация пропущена"; return 1 ;;
  esac
  heartbeat || { log "не удалось записать пульс"; return 1; }
  snap_make
  shrink_guard || { rm -rf "$SNAP"; return 1; }
  if "${RC[@]}" sync "$SNAP" "$REMOTE/data" "${EXCL[@]}" --max-delete "${BACKUP_MAX_DELETE:-300}"; then
    date '+%F %T' > "$DATA_DIR/logs/last-backup"
    log "ok ($(du -sh --exclude=logs --exclude=.snap "$DATA_DIR" 2>/dev/null | cut -f1))"
    rm -rf "$SNAP"
  else
    log "ошибка синхронизации (повторю в следующий раз)"; rm -rf "$SNAP"; return 1
  fi
}

restore_from() {   # $1 — слот
  local p; p="$(slot_path "$1")"
  REMOTE="$p"
  log "восстанавливаю $p/data -> $DATA_DIR ..."
  if "${RC[@]}" copy "$p/data" "$DATA_DIR" "${EXCL[@]}"; then
    echo "$1" > "$SLOT_FILE"; touch "$OK_MARK" "$DATA_DIR/.restored-from-backup"; heartbeat
    log "восстановлено: $(cd "$DATA_DIR" && ls -d *-gpu* cpu 2>/dev/null | tr '\n' ' ')"
    return 0
  fi
  log "ошибка восстановления"; return 5
}

do_claim() {
  if local_has_data; then
    [ -f "$SLOT_FILE" ] || echo 1 > "$SLOT_FILE"
    log "локальные данные есть — работаю со своим слотом"; return 0
  fi
  local i s stale="" empty=""
  for i in $(seq 1 $MAX_SLOTS); do
    s="$(slot_state "$(slot_path "$i")")" || { log "хранилище недоступно (сеть / ключи / бакет) — не стартую с нуля"; return 5; }
    case "$s" in
      stale|mine) [ -z "$stale" ] && stale=$i ;;
      empty)      [ -z "$empty" ] && empty=$i ;;
    esac
    [ -n "$stale" ] && break                 # брошенная машина важнее пустого слота
  done
  if [ -n "$stale" ]; then
    REMOTE="$(slot_path "$stale")"; heartbeat || return 5
    sleep $(( 3 + RANDOM % 6 ))              # защита от гонки двух новых машин
    s="$(slot_state "$REMOTE")" || return 5
    if [ "$s" != mine ]; then log "слот $stale только что заняла другая машина — ищу дальше"; do_claim; return $?; fi
    log "слот $(basename "$REMOTE") брошен — продолжаю его задания"
    restore_from "$stale"; return $?
  fi
  if [ -n "$empty" ]; then
    echo "$empty" > "$SLOT_FILE"; REMOTE="$(slot_path "$empty")"
    heartbeat || return 5
    sleep $(( 3 + RANDOM % 6 ))
    s="$(slot_state "$REMOTE")" || return 5
    if [ "$s" != mine ]; then rm -f "$SLOT_FILE"; log "слот $empty только что заняла другая машина — ищу дальше"; do_claim; return $?; fi
    touch "$OK_MARK"
    log "брошенных слотов нет — чистый старт в пустом слоте $(basename "$REMOTE")"; return 0
  fi
  log "все $MAX_SLOTS слотов заняты живыми машинами"; return 6
}

# После gimps-stop --unreserve: задания GPU возвращены в PrimeNet — их чекпойнты из слота удаляем,
# чтобы следующая машина не продолжила уже чужие задания. Папка cpu (mprime) и кэш тюнинга остаются.
do_release() {
  owner_ok; case $? in
    1) log "слот занят другой живой машиной — не трогаю"; return 1 ;;
    2) log "хранилище недоступно — освободить слот не удалось"; return 5 ;;
  esac
  local d n=0
  while IFS= read -r d; do
    [[ "$d" == *-gpu*/ ]] || continue
    "${RC[@]}" purge "$REMOTE/data/${d%/}" && n=$((n + 1))
  done < <("${RC[@]}" lsf --dirs-only --max-depth 1 "$REMOTE/data" 2>/dev/null)
  echo "$MID $(date +%s) $(hostname) $(ts) released" | "${RC[@]}" rcat "$REMOTE/owner.txt"
  log "слот освобождён: удалено папок GPU-воркеров — $n (задания возвращены в PrimeNet)"
}

do_restore() {
  local s; s="$(slot_state "$REMOTE")" || { log "хранилище недоступно"; return 5; }
  case "$s" in
    empty) log "слот пуст — восстанавливать нечего"; return 0 ;;
    live)  log "слот занят живой машиной. Если она точно мертва — подождите $((STALE_SEC/60)) мин или FORCE=1 gimps-backup restore"
           [ "${FORCE:-0}" = "1" ] || return 4 ;;
  esac
  restore_from "$SLOT"
}

case "${1:-sync}" in
  sync)    with_lock do_sync ;;
  claim)   with_lock do_claim ;;
  restore) with_lock do_restore ;;
  release) with_lock do_release ;;
  ls)      for i in $(seq 1 $MAX_SLOTS); do
             p="$(slot_path "$i")"; s="$(slot_state "$p")" || { echo "$p: ошибка доступа"; continue; }
             [ "$s" = empty ] && continue
             echo "== $p ($s)$([ "$i" = "$SLOT" ] && echo ' ← эта машина')"
             "${RC[@]}" cat "$p/owner.txt" 2>/dev/null; "${RC[@]}" size "$p/data" 2>/dev/null
           done ;;
  check)   echo test | "${RC[@]}" rcat "$REMOTE/.check" && "${RC[@]}" deletefile "$REMOTE/.check" \
             && log "доступ к $REMOTE есть" || { log "НЕТ доступа к $REMOTE"; exit 5; } ;;
  loop)
    with_lock do_sync   # сразу при старте
    t=0
    while [ ! -f "$DATA_DIR/.stop" ]; do
      sleep 10; t=$((t + 10))
      [ -f "$DATA_DIR/.stop" ] && break
      if [ $((t % (INTERVAL * 60))) -eq 0 ]; then with_lock do_sync
      elif [ $((t % 120)) -eq 0 ] && [ -f "$OK_MARK" ]; then
        owner_ok && heartbeat
      fi
    done ;;
  *) echo "usage: gimps-backup [sync|loop|claim|restore|release|ls|check]"; exit 2 ;;
esac
__GIMPS_EOF__
cat > "$D/gimps-monitor" <<'__GIMPS_EOF__'
#!/usr/bin/env python3
"""gimps-monitor — единый построчный журнал прогресса всех задач GIMPS на машине.

Читает логи воркеров ($DATA_DIR/logs/tf-gpuN.log, prp-gpuN.log, cpu.log, apn-gpuN.log),
пишет понятные строки в stdout и в $DATA_DIR/logs/progress.log:
  * НОВАЯ ЗАДАЧА — что считается, оценка в GHz-days, сколько займёт, полный снимок GPU/CPU;
  * прогресс на каждом новом 1% — процент, осталось, скорость (GHz-d/day), кратко GPU;
  * результат задачи и засчитанный PrimeNet кредит;
  * ход тюнинга PRPLL, ошибки бэкапа.
Заодно — сторож: перезапускает воркер, чей лог молчит дольше WATCHDOG_MIN минут, и выключает PRP-воркер,
если ошибок Gerbicz (EE) больше EE_MAX_PER_HOUR за час. Важное дублирует в Telegram/вебхук (gimps-notify).
Запускается из gimps-start (один экземпляр); смотреть: gimps-watch.
"""
import fcntl, glob, json, os, re, signal, subprocess, sys, time

DATA = os.environ.get("DATA_DIR", "/data")
LOGS = os.path.join(DATA, "logs")
OUT = os.path.join(LOGS, "progress.log")
HIST = os.path.join(DATA, ".credit-history.json")
COLOR = os.environ.get("NO_COLOR") is None
POLL = 2.0
WATCHDOG_MIN = float(os.environ.get("WATCHDOG_MIN", "20") or 0)
EE_MAX = int(os.environ.get("EE_MAX_PER_HOUR", "3") or 3)
NOTIFY_ALL = os.environ.get("NOTIFY_LEVEL", "important") == "all"

_last_notify = {}
def notify(text, key=None, every=0):
    """Уведомление через gimps-notify (в фоне). key/every — не чаще раза в every секунд."""
    if key:
        if time.time() - _last_notify.get(key, 0) < every:
            return
        _last_notify[key] = time.time()
    try:
        subprocess.Popen(["gimps-notify", text], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass

def c(code, s):
    return f"\033[{code}m{s}\033[0m" if COLOR else s

B, G, Y, R, CY, DIM = "1", "32", "33", "31", "36", "2"

# ---------------------------------------------------------------- вывод
_out = None
def emit(text):
    global _out
    if _out is None:
        os.makedirs(LOGS, exist_ok=True)
        _out = open(OUT, "a", encoding="utf-8", buffering=1)
    for line in text.splitlines():
        print(line, flush=True)
        _out.write(line + "\n")

def now():
    return time.strftime("%m-%d %H:%M:%S")

def fmt_dur(sec):
    if sec is None or sec < 0:
        return "?"
    sec = int(sec)
    d, h, m = sec // 86400, sec // 3600 % 24, sec // 60 % 60
    if d:
        return f"{d}д {h}ч {m:02d}м"
    if h:
        return f"{h}ч {m:02d}м"
    return f"{m}м {sec % 60:02d}с"

def parse_dur(s):
    """'44m03s' / '1h05m' / '2d 03:04' / '05:12' / '1d 2h' -> секунды"""
    s = s.strip()
    m = re.match(r"(?:(\d+)d\s*)?(\d+):(\d+)$", s)
    if m:
        return int(m.group(1) or 0) * 86400 + int(m.group(2)) * 3600 + int(m.group(3)) * 60
    tot, found = 0, False
    for v, u in re.findall(r"(\d+(?:\.\d+)?)\s*([dhms])", s):
        tot += float(v) * {"d": 86400, "h": 3600, "m": 60, "s": 1}[u]; found = True
    return tot if found else None

# ---------------------------------------------------------------- GPU / CPU
_THR = [(0x4, "лимит мощности"), (0x8, "HW slowdown"), (0x20, "перегрев(SW)"),
        (0x40, "перегрев(HW)"), (0x80, "power brake"), (0x2, "app clocks")]
_gcache = {}
def gpu(idx):
    t = time.time()
    if idx in _gcache and t - _gcache[idx][0] < 3:
        return _gcache[idx][1]
    q = ("name,utilization.gpu,utilization.memory,temperature.gpu,power.draw,power.limit,"
         "clocks.sm,clocks.max.sm,clocks.mem,memory.used,memory.total,fan.speed,pstate,"
         "clocks_event_reasons.active,compute_cap")
    try:
        r = subprocess.run(["nvidia-smi", "-i", str(idx), f"--query-gpu={q}", "--format=csv,noheader,nounits"],
                           capture_output=True, text=True, timeout=10).stdout.strip().split(", ")
        keys = q.split(",")
        d = dict(zip(keys, r)) if len(r) >= len(keys) - 1 else {}
    except Exception:
        d = {}
    _gcache[idx] = (t, d)
    return d

def _num(v, fmt="{:.0f}"):
    try:
        return fmt.format(float(v))
    except Exception:
        return "?"

def gpu_full(idx):
    d = gpu(idx)
    if not d:
        return f"GPU{idx}: nvidia-smi недоступен"
    try:
        reasons = int(d.get("clocks_event_reasons.active", "0"), 16)
    except ValueError:
        reasons = 0
    thr = ", ".join(n for b, n in _THR if reasons & b) or "нет"
    fan = d.get("fan.speed", "")
    fan = f"{_num(fan)}%" if fan and "N/A" not in fan else "н/д"
    return (f"GPU{idx} {d.get('name','?')} (CC {d.get('compute_cap','?')}): загрузка {_num(d.get('utilization.gpu'))}%, "
            f"память-шина {_num(d.get('utilization.memory'))}% | {_num(d.get('temperature.gpu'))}°C, вентилятор {fan} | "
            f"{_num(d.get('power.draw'), '{:.0f}')}/{_num(d.get('power.limit'))} Вт | ядро {_num(d.get('clocks.sm'))}"
            f"/{_num(d.get('clocks.max.sm'))} МГц, память {_num(d.get('clocks.mem'))} МГц | "
            f"VRAM {_num(d.get('memory.used'))}/{_num(d.get('memory.total'))} МБ | {d.get('pstate','?')} | "
            f"ограничения частоты: {thr}")

def gpu_short(idx):
    d = gpu(idx)
    if not d:
        return ""
    return (f"{_num(d.get('utilization.gpu'))}% {_num(d.get('temperature.gpu'))}°C "
            f"{_num(d.get('power.draw'))}W {_num(d.get('clocks.sm'))}/{_num(d.get('clocks.mem'))}МГц")

_cpu_prev = None
def cpu_load():
    global _cpu_prev
    try:
        v = list(map(int, open("/proc/stat").readline().split()[1:]))
        idle, tot = v[3] + v[4], sum(v)
        if _cpu_prev:
            di, dt = idle - _cpu_prev[0], tot - _cpu_prev[1]
            _cpu_prev = (idle, tot)
            return 100.0 * (1 - di / dt) if dt else None
        _cpu_prev = (idle, tot)
    except Exception:
        pass
    return None

def cpu_temp():
    for f in glob.glob("/sys/class/hwmon/hwmon*/temp1_input"):
        try:
            name = open(os.path.join(os.path.dirname(f), "name")).read().strip()
            if name in ("k10temp", "coretemp", "zenpower", "cpu_thermal"):
                return int(open(f).read()) / 1000
        except Exception:
            pass
    return None

def cpu_full():
    try:
        model = next(l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name"))
    except Exception:
        model = "?"
    ld = cpu_load()
    t = cpu_temp()
    return (f"CPU {model}, потоков {os.cpu_count()} | загрузка {('%.0f%%' % ld) if ld is not None else '?'} | "
            f"load avg {os.getloadavg()[0]:.1f} | температура {('%.0f°C' % t) if t else 'н/д'}")

def cpu_short():
    ld = cpu_load(); t = cpu_temp()
    return f"CPU {('%.0f%%' % ld) if ld is not None else '?'}" + (f" {t:.0f}°C" if t else "")

# ---------------------------------------------------------------- кредит (GHz-days)
def tf_ghd(exp, bmin, bmax):
    g, b = 0.0, bmin + 1
    while b <= bmax:
        g += (0.011160 if b <= 62 else 0.017832 if b <= 64 else 0.016968) * 2.0 ** (b - 48); b += 1
    return g * 1680.0 / exp

def hist_load():
    try:
        return json.load(open(HIST))
    except Exception:
        return []

def hist_add(kind, exp, ghd):
    h = [x for x in hist_load() if not (x["kind"] == kind and x["exp"] == exp)]
    h.append({"kind": kind, "exp": exp, "ghd": ghd})
    try:
        json.dump(h[-200:], open(HIST, "w"))
    except Exception:
        pass

def ghd_estimate(kind, exp):
    """Оценка кредита по прошлым результатам того же типа: работа PRP/LL растёт ~ E^2.1."""
    h = [x for x in hist_load() if x["kind"] == kind and x["ghd"] > 0]
    if not h or not exp:
        return None
    ref = min(h, key=lambda x: abs(x["exp"] - exp))
    return ref["ghd"] * (exp / ref["exp"]) ** (2.1 if kind in ("PRP", "LL") else 1.0)

# ---------------------------------------------------------------- воркеры
class Worker:
    def __init__(self, kind, idx):
        self.kind, self.idx = kind, idx          # kind: TF | PRP | CPU
        self.label = f"GPU{idx} {kind}" if kind != "CPU" else "CPU"
        self.reset()

    def reset(self):
        self.task = None; self.exp = None; self.ghd = None; self.ghd_est = False
        self.started = None; self.announced = False; self.last_int = -1
        self.extra = ""; self.fft = None; self.proof = None; self.errors = 0
        self.first_pct = None; self.first_t = None; self.subtype = ""

    def tag(self):
        return c(CY, f"[{self.label}]")

    def snap_full(self):
        return gpu_full(self.idx) if self.kind != "CPU" else cpu_full()

    def snap_short(self):
        return gpu_short(self.idx) if self.kind != "CPU" else cpu_short()

    def announce(self, eta_sec, speed_txt=""):
        self.announced = True
        ghd = "н/д (появится после первого результата этого типа)" if self.ghd is None else \
              (f"≈{self.ghd:.1f} GHz-d (оценка)" if self.ghd_est else f"{self.ghd:.2f} GHz-d")
        emit(c(B, f"━━ {now()} {self.label}: НОВАЯ ЗАДАЧА ━━ {self.task}"))
        extra = self.extra if self.extra and self.extra not in speed_txt else ""
        emit(f"   оценка: {ghd} | займёт ≈ {fmt_dur(eta_sec) if eta_sec is not None else 'уточнится после первых %'}" + (f" | {speed_txt.strip()}" if speed_txt else "")
             + (f" | {extra}" if extra else ""))
        emit(c(DIM, "   " + self.snap_full()))

    def progress(self, pct, eta_sec, speed_txt, silent):
        ip = int(pct)
        if not self.announced:
            if silent:
                self.announced = True; self.last_int = ip; return
            self.announce(eta_sec, speed_txt)
            self.last_int = ip
        if ip != self.last_int and not silent:
            self.last_int = ip
            emit(f"{now()} {self.tag()} {self.short_task()} {c(B, f'{pct:6.2f}%')} | осталось {fmt_dur(eta_sec):>10} | "
                 f"{speed_txt} | {self.snap_short()}")
        self.last_int = ip

    def short_task(self):
        return f"M{self.exp}" if self.exp else (self.task or "?")

    def done(self, text, good=False, bad=False, silent=False):
        if silent:
            self.reset(); return
        el = f" за {fmt_dur(time.time() - self.started)}" if self.started else ""
        col = Y if good else (R if bad else G)
        emit(c(col, f"✔ {now()} {self.label}: {text}{el}"))
        if good or bad or NOTIFY_ALL:
            notify(f"{self.label}: {text}{el}")
        self.reset()

# ---------------------------------------------------------------- парсеры
RE_TF_START = re.compile(r"Starting trial factoring M(\d+) from 2\^(\d+) to 2\^(\d+) \(([\d.]+) GHz-days\)")
RE_TF_PROG = re.compile(r"^\s*\w{3}\s+\d+\s+[\d:]+\s*\|\s*(\d+)\s+([\d.]+)%\s*\|\s*([\d.]+)\s+(\S+)\s*\|\s*([\d.]+)")
RE_TF_NOF = re.compile(r"no factor for M(\d+) from 2\^(\d+) to 2\^(\d+)")
RE_TF_FAC = re.compile(r"M(\d+) has a factor: (\d+)")
RE_PRP_PROG = re.compile(r"^\d{8} [\d:]{8} (\d+) (OK|EE)\s+(\d+) ([0-9a-f]{16})\s+([\d.]+) ETA ([^;]+);")
RE_PRP_FFT = re.compile(r"^\d{8} [\d:]{8} (\d+) FFT: (\S+) (\S+) \(([\d.]+) bpw\)")
RE_PRP_PROOF = re.compile(r"Proof of power (\d+) requires about ([\d.]+)GB")
RE_CREDIT = re.compile(r"Credit for exponent (\d+): ([\d.]+) GHz-days")
RE_MP_PCT = re.compile(r"(\d+(?:\.\d+)?)% complete|\[(\d+(?:\.\d+)?)%\]")
RE_MP_EXP = re.compile(r"\bM(\d{5,10})\b")
RE_MP_CREDIT = re.compile(r"CPU credit is ([\d.]+) GHz-days")

def worktodo_tf(idx):
    try:
        for l in open(os.path.join(DATA, f"tf-gpu{idx}", "worktodo.txt")):
            p = l.strip().split("=", 1)[-1].split(",")
            if len(p) >= 4 and p[1].isdigit():
                return int(p[1]), int(p[2]), int(p[3])
    except Exception:
        pass
    return None

def handle_tf(w, line, silent):
    m = RE_TF_START.search(line)
    if m:
        w.reset()
        w.exp, b1, b2, w.ghd = int(m[1]), int(m[2]), int(m[3]), float(m[4])
        w.task = f"TF M{w.exp}: поиск делителей 2^{b1}→2^{b2}"
        w.started = time.time(); return
    m = RE_TF_PROG.search(line)
    if m:
        pct, eta, gdd = float(m[2]), parse_dur(m[4]), float(m[5])
        if not w.task:                                   # монитор запущен посреди задачи
            wt = worktodo_tf(w.idx)
            if wt:
                w.exp = wt[0]; w.ghd = tf_ghd(*wt)
                w.task = f"TF M{wt[0]}: поиск делителей 2^{wt[1]}→2^{wt[2]} (продолжение)"
            else:
                w.task = "TF (продолжение)"
            w.started = time.time()
        w.progress(pct, eta, f"{gdd:7.1f} GHz-d/day", silent); return
    m = RE_TF_FAC.search(line)
    if m:
        if not silent:
            emit(c(Y, f"★★★ {now()} {w.label}: НАЙДЕН ДЕЛИТЕЛЬ M{m[1]}: {m[2]} ★★★"))
            notify(f"★ НАЙДЕН ДЕЛИТЕЛЬ M{m[1]}: {m[2]} ({w.label})")
        return
    m = RE_TF_NOF.search(line)
    if m:
        g = f", {w.ghd:.2f} GHz-d" if w.ghd else ""
        w.done(f"M{m[1]}: делителей в 2^{m[2]}–2^{m[3]} нет{g}", silent=silent); return
    if "found" in line and "factor" in line and " for M" in line:
        w.done(line.strip(), good=True, silent=silent)

def handle_prp(w, line, silent):
    m = RE_PRP_FFT.search(line)
    if m:
        if w.exp != int(m[1]):
            w.reset(); w.exp = int(m[1]); w.started = time.time()
        w.fft = f"FFT {m[2]} {m[3]} ({m[4]} bpw)"; return
    m = RE_PRP_PROOF.search(line)
    if m:
        w.proof = f"proof power {m[1]} (~{m[2]} ГБ на диске)"; return
    if "Proof generation disabled" in line:
        w.proof = "без proof"; return
    m = RE_PRP_PROG.search(line)
    if m:
        exp, ok, k, us, eta = int(m[1]), m[2], int(m[3]), float(m[5]), parse_dur(m[6])
        if us <= 0 or k == 0:                              # строка загрузки чекпойнта, без скорости
            return
        if w.exp != exp or not w.task:
            if w.exp != exp:
                w.reset(); w.exp = exp; w.started = time.time()
            w.task = f"PRP-тест M{exp} ({int(exp * 0.30103) + 1:,} цифр)".replace(",", " ")
            est = ghd_estimate("PRP", exp)
            w.ghd, w.ghd_est = est, est is not None
            w.extra = " | ".join(x for x in (w.fft, w.proof) if x)
        if ok == "EE":
            w.errors += 1
            if not silent:
                emit(c(R, f"{now()} {w.label}: ошибка проверки Gerbicz на итерации {k} (PRPLL откатится к чекпойнту)"))
                ee_event(w.idx)
        total_days = exp * us / 1e6 / 86400
        speed = f"{us:6.1f} мкс/ит, {1e6/us:,.0f} ит/с".replace(",", " ")
        if w.ghd:
            speed += f", ≈{w.ghd / total_days:,.0f} GHz-d/day".replace(",", " ")
        w.progress(100.0 * k / exp, eta, speed, silent); return
    if '"worktype"' in line and '"status"' in line:
        try:
            r = json.loads(line[line.index("{"):])
        except Exception:
            r = {}
        e = r.get("exponent", w.exp)
        if r.get("status") == "P":
            if not silent:
                emit(c(Y, f"★★★★★ {now()} {w.label}: M{e} — ВЕРОЯТНО ПРОСТОЕ! Срочно проверьте results и почту! ★★★★★"))
                notify(f"★★★★★ M{e} — ВЕРОЯТНО ПРОСТОЕ! ({w.label}) Проверьте results и mersenne.org")
            w.done(f"M{e}: PROBABLE PRIME", good=True, silent=silent)
        else:
            w.done(f"M{e}: составное (res64 {r.get('res64','?')}), {r.get('worktype','PRP')}"
                   + (f", ошибок {w.errors}" if w.errors else ""), silent=silent)

def handle_cpu(w, line, silent):
    m = RE_MP_CREDIT.search(line)
    if m:
        g = float(m[1])
        if w.exp:
            hist_add(w.subtype or "CPU", w.exp, g)
        if not silent:
            emit(c(G, f"   {now()} CPU: PrimeNet засчитал {g:.3f} GHz-d"))
        return
    if any(s in line for s in ("is not prime", "completed P-1", "found a factor", "has a factor", "is a probable prime",
                               "completed ECM", "Mersenne number is prime")):
        good = "factor" in line or "prime!" in line.lower() or "probable prime" in line
        w.done(re.sub(r"^\[.*?\]\s*", "", line.strip()), good=good, silent=silent); return
    me = RE_MP_EXP.search(line); mp = RE_MP_PCT.search(line)
    if me and ("Starting" in line or "P-1 on" in line or "PRP test of" in line or "ECM on" in line
               or (mp and w.exp and int(me[1]) != w.exp)):
        if w.exp != int(me[1]):
            w.reset(); w.exp = int(me[1]); w.started = time.time()
        sub = "P-1" if "P-1" in line else "PRP" if "PRP" in line else "ECM" if "ECM" in line else w.subtype or "CPU"
        w.subtype = sub
        w.task = f"{sub} M{w.exp} на CPU (mprime)"
        est = ghd_estimate(sub, w.exp)
        w.ghd, w.ghd_est = est, est is not None
    if mp and w.exp:
        pct = float(mp[1] or mp[2])
        stg = re.search(r"[Ss]tage (\d)", line)
        if stg:
            w.extra = f"stage {stg[1]}"
        eta = None
        me2 = re.search(r"ETA:?\s*([0-9dhms: ]+)", line)
        if me2:
            eta = parse_dur(me2[1])
        if eta is None:                                   # считаем по скорости
            t = time.time()
            if w.first_pct is None or pct < w.first_pct:
                w.first_pct, w.first_t = pct, t
            elif pct > w.first_pct and t - w.first_t >= 20:
                eta = (100 - pct) * (t - w.first_t) / (pct - w.first_pct)
        speed = f"mprime{', ' + w.extra if w.extra else ''}"
        if not w.task:
            w.task = f"M{w.exp} на CPU (mprime)"
        w.progress(pct, eta, speed, silent)


# ---------------------------------------------------------------- сторож и аварийное выключение
def read_pid(name):
    try:
        return int(open(os.path.join(DATA, f".pid-{name}")).read().strip())
    except Exception:
        return None

def alive(pid):
    try:
        os.kill(pid, 0); return True
    except Exception:
        return False

def stop_worker(name, sig=signal.SIGTERM):
    if name == "cpu":
        subprocess.run(["pkill", "-INT", "-x", "mprime"], check=False)
        return
    pid = read_pid(name)
    if pid and alive(pid):
        try:
            os.kill(pid, sig)
        except Exception:
            pass

def disable(name, why):
    try:
        open(os.path.join(DATA, f".disabled-{name}"), "w").write(f"{time.strftime('%F %T')} {why}\n")
    except Exception:
        pass
    stop_worker(name)
    emit(c(R, f"✖ {now()} {name}: ВЫКЛЮЧЕН — {why}. Вернуть: rm {DATA}/.disabled-{name} (воркер стартует сам)"))
    notify(f"ВЫКЛЮЧЕН {name}: {why}")

_ee = {}
def ee_event(idx):
    t = time.time()
    lst = [x for x in _ee.get(idx, []) if t - x < 3600] + [t]
    _ee[idx] = lst
    if len(lst) > EE_MAX:
        disable(f"prp-gpu{idx}", f"{len(lst)} ошибок Gerbicz за час — вероятно, неисправна GPU/память")
        _ee[idx] = []

_wd_restarts = {}
def watchdog():
    if WATCHDOG_MIN <= 0:
        return
    t = time.time(); limit = WATCHDOG_MIN * 60
    for pf in glob.glob(os.path.join(DATA, ".pid-*")):
        name = os.path.basename(pf)[5:]
        if not re.match(r"(tf|prp)-gpu\d+$|cpu$", name):
            continue
        pid = read_pid(name)
        if not pid or not alive(pid):
            continue
        try:
            started = os.path.getmtime(pf)
            last = os.path.getmtime(os.path.join(LOGS, f"{name}.log"))
        except OSError:
            continue
        # PRPLL ведёт и собственный лог (gpuowl-*.log) — учитываем самый свежий из логов воркера
        for f in glob.glob(os.path.join(DATA, name, "gpuowl-*.log")):
            try:
                last = max(last, os.path.getmtime(f))
            except OSError:
                pass
        if t - started < limit or t - last < limit:
            continue
        rs = [x for x in _wd_restarts.get(name, []) if t - x < 3 * 3600] + [t]
        _wd_restarts[name] = rs
        if len(rs) > 3:
            disable(name, f"завис {len(rs)} раза за 3 часа")
            continue
        emit(c(R, f"⟳ {now()} {name}: лог молчит {fmt_dur(t - last)} — перезапускаю (сторож, WATCHDOG_MIN={WATCHDOG_MIN:g})"))
        notify(f"{name}: завис ({fmt_dur(t - last)} без вывода) — перезапускаю")
        stop_worker(name)
        os.utime(pf, None)                     # следующая проверка — не раньше, чем через WATCHDOG_MIN

# ---------------------------------------------------------------- тюнинг и бэкап в журнале
_tune = {}
def handle_tune(idx, line, silent):
    line = line.strip()
    if not line or silent:
        return
    st = _tune.setdefault(idx, {"t0": time.time(), "last_emit": 0})
    t = time.time()
    if t - st["last_emit"] >= 300:
        st["last_emit"] = t
        emit(c(DIM, f"{now()} [GPU{idx} TUNE] идёт тюнинг PRPLL ({fmt_dur(t - st['t0'])}): {line[:140]}"))

RE_BK_BAD = re.compile(r"ОТКАЗ|ошибка|недоступно|не удалось|ДРУГАЯ")
def handle_backup(line, silent):
    m = re.search(r"backup\[([^\]]*)\]:\s*(.*)", line)
    if silent or not m:
        return
    msg = f"{m[1]}: {m[2]}"
    if RE_BK_BAD.search(line):
        emit(c(R, f"{now()} [BACKUP] слот {msg}"))
        notify(f"Бэкап: {msg}", key="backup", every=3600)
    elif "]: ok" in line:
        emit(c(DIM, f"{now()} [BACKUP] слот {msg}"))

RE_PRP_EXP = re.compile(r"^\d{8} [\d:]{8} (\d+) ")

# ---------------------------------------------------------------- слежение за файлами
class Follow:
    def __init__(self, path, existed=True):
        # existed=False: файл появился после старта монитора — читаем с начала и НЕ молча
        self.path, self.pos, self.ino, self.buf = path, (None if existed else 0), None, ""
        self.silent_first = existed

    def lines(self, backlog=262144):
        try:
            st = os.stat(self.path)
        except FileNotFoundError:
            return [], False
        first = self.pos is None
        if self.ino is None and not first:
            self.ino = st.st_ino
        if first or st.st_ino != self.ino or st.st_size < self.pos:
            self.pos = max(0, st.st_size - backlog) if first else 0
            self.ino = st.st_ino; self.buf = ""
        if st.st_size == self.pos:
            return [], first
        with open(self.path, "rb") as f:
            f.seek(self.pos); data = f.read(); self.pos = f.tell()
        text = self.buf + data.decode("utf-8", "replace").replace("\r", "\n")
        parts = text.split("\n"); self.buf = parts.pop()
        return parts, first

def main():
    lockf = open(os.path.join(DATA, ".monitor.lock"), "w")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("gimps-monitor уже запущен — второй экземпляр не нужен", file=sys.stderr)
        time.sleep(30); return
    followers, workers = {}, {}
    emit(c(B, f"══ {now()} gimps-monitor запущен: прогресс по каждому 1%, файл {OUT} ══"))
    cpu_load()
    initial = set(glob.glob(os.path.join(LOGS, "*.log")))
    last_wd = 0
    while True:
        for path in sorted(glob.glob(os.path.join(LOGS, "*.log"))):
            name = os.path.basename(path)[:-4]
            m = re.match(r"(tf|prp)-gpu(\d+)$", name)
            kind, idx = None, None
            if m:
                kind, idx = m[1].upper(), int(m[2])
            elif name == "cpu":
                kind, idx = "CPU", -1
            elif re.match(r"apn-gpu\d+$", name):
                kind, idx = "APN", int(name[7:])
            elif re.match(r"tune-gpu\d+$", name):
                kind, idx = "TUNE", int(name[8:])
            elif name == "backup":
                kind = "BACKUP"
            if not kind:
                continue
            f = followers.get(path) or followers.setdefault(path, Follow(path, existed=path in initial))
            lines, first = f.lines()
            for ln in lines:
                try:
                    if kind == "APN":
                        mc = RE_CREDIT.search(ln)
                        if mc:
                            exp, g = int(mc[1]), float(mc[2])
                            # тип — по режиму этой GPU (какой лог воркера обновлялся последним)
                            def mt(n):
                                try:
                                    return os.path.getmtime(os.path.join(LOGS, n))
                                except OSError:
                                    return 0
                            kd = "PRP" if mt(f"prp-gpu{idx}.log") >= mt(f"tf-gpu{idx}.log") and mt(f"prp-gpu{idx}.log") else "TF"
                            hist_add(kd, exp, g)
                            if not first:
                                emit(c(G, f"   {now()} GPU{idx}: PrimeNet засчитал M{exp}: {g:.3f} GHz-d"))
                                if NOTIFY_ALL:
                                    notify(f"GPU{idx}: PrimeNet засчитал M{exp}: {g:.3f} GHz-d")
                    elif kind == "TUNE":
                        handle_tune(idx, ln, first)
                    elif kind == "BACKUP":
                        handle_backup(ln, first)
                    elif kind == "PRP":
                        # PRPLL может считать несколько экспонент (-workers N): своё состояние на каждую
                        me = RE_PRP_EXP.match(ln)
                        exp = int(me[1]) if me else None
                        if exp is None and '"exponent"' in ln:
                            mj = re.search(r'"exponent"\s*:\s*"?(\d+)', ln)
                            exp = int(mj[1]) if mj else None
                        if exp is None:
                            continue
                        key = f"{name}:{exp}"
                        w = workers.get(key)
                        if w is None:
                            w = workers[key] = Worker("PRP", idx)
                            w.exp, w.started = exp, time.time()
                        handle_prp(w, ln, first)
                        if w.exp is None:              # задача завершена — состояние больше не нужно
                            workers.pop(key, None)
                    else:
                        w = workers.setdefault(name, Worker(kind, idx))
                        {"TF": handle_tf, "CPU": handle_cpu}[kind](w, ln, first)
                except Exception as e:                  # монитор не должен падать из-за странной строки
                    print(f"[monitor] {name}: {e}", file=sys.stderr)
            if first and kind in ("TF", "PRP", "CPU"):
                for key, w in list(workers.items()):
                    if (key == name or key.startswith(name + ":")) and w.task:
                        emit(c(B, f"── {now()} {w.label}: сейчас в работе — {w.task}, {w.last_int if w.last_int >= 0 else '?'}%"))
                        emit(c(DIM, "   " + w.snap_full()))
        if time.time() - last_wd >= 30:
            last_wd = time.time()
            try:
                watchdog()
            except Exception as e:
                print(f"[monitor] watchdog: {e}", file=sys.stderr)
        time.sleep(POLL)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
__GIMPS_EOF__
cat > "$D/gimps-watch" <<'__GIMPS_EOF__'
#!/usr/bin/env bash
# Живой построчный журнал всех задач (GPU и CPU): новая задача с оценкой и снимком GPU/CPU,
# прогресс на каждом 1%, результаты и засчитанный кредит. Выход: Ctrl+C (расчёт не останавливается).
#   gimps-watch          — последние 30 событий + дальше в реальном времени
#   gimps-watch -n 200   — показать больше истории
#   gimps-watch GPU0     — только строки, где есть «GPU0» (или CPU, TF, PRP, M<экспонента>)
DATA_DIR="${DATA_DIR:-/data}"
LOG="$DATA_DIR/logs/progress.log"
N=30
[ "${1:-}" = "-n" ] && { N="${2:-30}"; shift 2; }
FILTER="${1:-}"
if [ ! -f "$LOG" ]; then
  echo "Нет $LOG — gimps-start ещё не запущен?"; exit 1
fi
if ! pgrep -f "gimps-monitor" >/dev/null; then
  echo "ВНИМАНИЕ: gimps-monitor не запущен — новые строки не появятся. Запуск: (gimps-monitor >/dev/null 2>&1 &)"
fi
echo "Журнал: $LOG  (выход: Ctrl+C — расчёт продолжится)"
if [ -n "$FILTER" ]; then
  tail -n "$N" -F "$LOG" 2>/dev/null | grep --line-buffered -F -- "$FILTER"
else
  tail -n "$N" -F "$LOG" 2>/dev/null
fi
__GIMPS_EOF__
cat > "$D/gimps-cpu-setup" <<'__GIMPS_EOF__'
#!/usr/bin/env bash
# Первичная настройка mprime (Prime95 для Linux) для расчётов на CPU параллельно с GPU.
# Вызывается из gimps-start автоматически; вручную: gimps-cpu-setup [--force]
# Переменные: GIMPS_USER, GIMPS_NAME, CPU_WORKPREF (по умолч. 4 = P-1), CPU_CORES (auto), CPU_MEM_GB (auto), DATA_DIR
set -uo pipefail
DATA_DIR="${DATA_DIR:-/data}"
for f in "$DATA_DIR/.onstart.env" "$DATA_DIR/gimps.env"; do [ -f "$f" ] && set -a && . "$f" && set +a; done
D="$DATA_DIR/cpu"; mkdir -p "$D"; cd "$D" || exit 1
for f in /opt/gimps/mprime/*; do [ -e "$(basename "$f")" ] || ln -s "$f" .; done


# сколько CPU выделено контейнеру (cgroup v2 / v1), иначе — nproc
alloc="$(nproc)"
if [ -r /sys/fs/cgroup/cpu.max ]; then
  read -r q p < /sys/fs/cgroup/cpu.max; [ "$q" != "max" ] && alloc=$(( (q + p - 1) / p ))
elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
  q=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us); p=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
  [ "$q" -gt 0 ] && alloc=$(( (q + p - 1) / p ))
fi
[ "$alloc" -gt "$(nproc)" ] && alloc="$(nproc)"
tpc="$(lscpu 2>/dev/null | awk -F: '/Thread\(s\) per core/ {gsub(/ /,"",$2); print $2}')"; tpc="${tpc:-1}"
phys=$(( alloc / tpc )); [ "$phys" -lt 1 ] && phys=1
# одно ядро оставляем GPU-воркерам (mfaktc/PRPLL)
CORES="${CPU_CORES:-$(( phys > 1 ? phys - 1 : 1 ))}"

# память: половина лимита контейнера (или RAM), но не больше 64 ГиБ
mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
if [ -r /sys/fs/cgroup/memory.max ] && [ "$(cat /sys/fs/cgroup/memory.max)" != "max" ]; then
  mem_kb=$(( $(cat /sys/fs/cgroup/memory.max) / 1024 ))
fi
MEM="${CPU_MEM_GB:-$(( mem_kb / 1024 / 1024 / 2 ))}"; [ "$MEM" -gt 64 ] && MEM=64; [ "$MEM" -lt 1 ] && MEM=1

# Число потоков mprime — явно в local.txt: в контейнере mprime видит все ядра хоста, а не выделенные нам.
# (Ключи NumWorkers / CoresPerTest — из local.txt Prime95 v29+; mprime перечитывает их при старте.)
enforce_cores() {
  [ -f local.txt ] || return 0
  local k v
  for kv in "NumWorkers=1" "CoresPerTest=$CORES"; do
    k="${kv%%=*}"; v="${kv#*=}"
    if grep -q "^$k=" local.txt; then sed -i "s/^$k=.*/$k=$v/" local.txt; else echo "$k=$v" >> local.txt; fi
  done
}

if [ "${1:-}" != "--force" ] && grep -qs '^V5UserID=' prime.txt; then
  enforce_cores
  echo "mprime уже настроен ($D/prime.txt), потоков: $CORES. Перенастроить: gimps-cpu-setup --force"; exit 0
fi

USERID="${GIMPS_USER:-ANONYMOUS}"
NAME="${GIMPS_NAME:-cloud}-cpu"
TYPE="${CPU_WORKPREF:-4}"
echo "mprime: пользователь=$USERID, компьютер=$NAME, тип работы=$TYPE, ядер=$CORES (выделено CPU: $alloc), память stage 2=$MEM ГиБ"
[ "${1:-}" = "--force" ] && rm -f prime.txt local.txt
timeout 900 expect /opt/gimps/share/mprime-setup.exp "$USERID" "$NAME" "$TYPE" "$CORES" "$MEM" > setup.log 2>&1
rc=$?
if grep -qs '^V5UserID=' prime.txt; then
  enforce_cores
  echo "mprime настроен (лог: $D/setup.log), потоков: $CORES"; exit 0
fi
echo "mprime: автонастройка не удалась (rc=$rc), см. $D/setup.log. Можно настроить вручную: cd $D && ./mprime -m"
exit 1
__GIMPS_EOF__
cat > "$D/gimps-notify" <<'__GIMPS_EOF__'
#!/usr/bin/env python3
"""gimps-notify "текст" — отправить уведомление (Telegram и/или вебхук). Без настроек — молча ничего не делает.

  NOTIFY_TELEGRAM_TOKEN   токен бота (@BotFather)
  NOTIFY_TELEGRAM_CHAT    chat_id (свой id можно узнать у @userinfobot)
  NOTIFY_WEBHOOK_URL      любой URL, принимающий POST с текстом (например https://ntfy.sh/<ваш-топик>)
  GIMPS_NAME              подпись машины в сообщении
Ошибки сети не прерывают работу (код возврата всегда 0).
"""
import json, os, sys, urllib.parse, urllib.request

def load_env():
    for name in (".onstart.env", "gimps.env"):
        load_file(os.path.join(os.environ.get("DATA_DIR", "/data"), name))

def load_file(p):
    try:
        for line in open(p, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                k = k.replace("export ", "").strip()
                os.environ.setdefault(k, v.strip().strip("'\""))
    except OSError:
        pass

def send(text):
    who = os.environ.get("GIMPS_NAME") or os.uname().nodename
    text = f"[{who}] {text}"
    tok, chat = os.environ.get("NOTIFY_TELEGRAM_TOKEN"), os.environ.get("NOTIFY_TELEGRAM_CHAT")
    if tok and chat:
        try:
            data = urllib.parse.urlencode({"chat_id": chat, "text": text[:4000]}).encode()
            urllib.request.urlopen(f"https://api.telegram.org/bot{tok}/sendMessage", data, timeout=20).read()
        except Exception as e:
            print(f"gimps-notify: Telegram: {e}", file=sys.stderr)
    url = os.environ.get("NOTIFY_WEBHOOK_URL")
    if url:
        try:
            urllib.request.urlopen(urllib.request.Request(url, text.encode(), {"Content-Type": "text/plain; charset=utf-8"}),
                                   timeout=20).read()
        except Exception as e:
            print(f"gimps-notify: webhook: {e}", file=sys.stderr)

if __name__ == "__main__":
    load_env()
    if len(sys.argv) > 1:
        send(" ".join(sys.argv[1:]))
    sys.exit(0)
__GIMPS_EOF__
cat > "$D/mprime-setup.exp" <<'__GIMPS_EOF__'
#!/usr/bin/expect -f
# Первичная настройка mprime без вопросов (на основе mprime.exp из
# github.com/tdulcet/Distributed-Computing-Scripts, MIT License, © Teal Dulcet).
# Запуск: expect mprime-setup.exp <User ID> <Computer name> <Type of work> <CPU cores> <Stage 2 memory GiB>

set timeout 600
set USERID   [lindex $argv 0]
set COMPUTER [lindex $argv 1]
set TYPE     [lindex $argv 2]
set CORES    [lindex $argv 3]
set MEM      [lindex $argv 4]

spawn ./mprime -m
expect "Join Gimps? (*):"
sleep 1; send -- "y\r"
expect "Use PrimeNet to get work and report results (*):"
sleep 1; send -- "y\r"
expect "Your user ID or \"ANONYMOUS\" (*):"
sleep 1; send -- "$USERID\r"
expect "Optional computer name:"
sleep 1; send -- "$COMPUTER\r"
expect {
	"Type of work to get (*):"            { sleep 1; send -- "$TYPE\r"; exp_continue }
	"stage 2 memory in GiB (*):"          { sleep 1; send -- "$MEM\r"; exp_continue }
	"*umber of workers*(*):"              { sleep 1; send -- "1\r"; exp_continue }
	"*ores to use*(*):"                   { sleep 1; send -- "$CORES\r"; exp_continue }
	"*ores per test*(*):"                 { sleep 1; send -- "$CORES\r"; exp_continue }
	"Upload bandwidth limit in Mbps (*):" { sleep 1; send -- "10000\r"; exp_continue }
	"Skip advanced resource settings (*):" { sleep 1; send -- "n\r"; exp_continue }
	"Optional directory to hold *:"       { sleep 1; send -- "\r"; exp_continue }
	"Your choice:" { }
	"Use the following values to select a work type:" { exp_continue }
	"*: 1" { exp_continue }
	" (*):" { sleep 1; send -- "\r"; exp_continue }
	timeout { send \x03; sleep 5; send -- "5\r"; expect eof; exit 2 }
}
expect {
	"Done communicating with server." { }
	timeout { }
}
send \x03
sleep 10
expect "Choose Test/Continue to restart."
sleep 1
send -- "15\r"
expect {
	"Days between sending end dates (*):" { sleep 1; send -- "0.25\r"; exp_continue }
	"Your choice:" { }
	" (*):" { sleep 1; send -- "\r"; exp_continue }
	timeout { }
}
expect {
	"Done communicating with server." { }
	timeout { }
}
sleep 1
send -- "5\r"
expect eof
__GIMPS_EOF__
chmod +x "$D"/*
"$D/build.sh" all
mkdir -p "${DATA_DIR:-/data}"
echo
echo "Установлено. Запуск:  GIMPS_USER=<ваш логин mersenne.org> gimps-start --daemon"
echo "Статус: gimps-status    Остановка: gimps-stop [--finish|--unreserve]"
