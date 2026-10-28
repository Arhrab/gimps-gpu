#!/usr/bin/env bash
# Генерирует самодостаточный bootstrap.sh (все скрипты внутри) из scripts/
set -euo pipefail
cd "$(dirname "$0")"
{
cat <<'HDR'
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
HDR
for f in build.sh gimps-start gimps-stop gimps-status gimps-backup gimps-monitor gimps-watch gimps-cpu-setup gimps-notify mprime-setup.exp; do
  n="$(basename "$f")"
  echo "cat > \"\$D/$n\" <<'__GIMPS_EOF__'"
  cat "$f"
  echo "__GIMPS_EOF__"
done
cat <<'FTR'
chmod +x "$D"/*
"$D/build.sh" all
mkdir -p "${DATA_DIR:-/data}"
echo
echo "Установлено. Запуск:  GIMPS_USER=<ваш логин mersenne.org> gimps-start --daemon"
echo "Статус: gimps-status    Остановка: gimps-stop [--finish|--unreserve]"
FTR
} > bootstrap.sh
chmod +x bootstrap.sh
echo "bootstrap.sh: $(wc -c < bootstrap.sh) байт"
