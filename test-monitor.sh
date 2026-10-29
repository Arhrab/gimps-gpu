#!/usr/bin/env bash
# Тест gimps-monitor на образцах логов mfaktc / PRPLL (2 экспоненты одновременно) / mprime / AutoPrimeNet / бэкапа.
# Без GPU: nvidia-smi подменяется. Запуск: bash test-monitor.sh  (код 0 — всё ок)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; [ -f "$HERE/gimps-monitor" ] || HERE="$(cd "$HERE/.." && pwd)"
T="$(mktemp -d)"; trap 'kill $MP 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/data/logs" "$T/data/tf-gpu0"
cat > "$T/bin/nvidia-smi" <<'EOF'
#!/bin/bash
echo "NVIDIA GeForce RTX 5060 Ti, 98, 41, 63, 145.57, 180.00, 2775, 3135, 14001, 239, 16311, 45, P2, 0x0000000000000000, 12.0"
EOF
printf '#!/bin/sh\nexit 0\n' > "$T/bin/gimps-notify"
chmod +x "$T/bin/"*
L="$T/data/logs"
: > "$L/tf-gpu0.log"; : > "$L/prp-gpu1.log"; : > "$L/cpu.log"; : > "$L/apn-gpu1.log"; : > "$L/backup.log"
PATH="$T/bin:$PATH" DATA_DIR="$T/data" NO_COLOR=1 WATCHDOG_MIN=0 python3 "$HERE/gimps-monitor" > "$T/out" 2>"$T/err" &
MP=$!
sleep 3
cat >> "$L/tf-gpu0.log" <<'EOF'
Starting trial factoring M164185409 from 2^77 to 2^78 (186.33 GHz-days)
Oct 28 15:14 |    3   0.1% |  4.420  70m01s |   3801.00    82485    n.a.%
Oct 28 15:15 |   15   1.2% |  4.420  69m01s |   3801.00    82485    n.a.%
Oct 28 15:16 |   25   2.3% |  4.420  68m01s |   3801.00    82485    n.a.%
no factor for M164185409 from 2^77 to 2^78 [mfaktc 0.24.1 barrett87_mul32_gs]
EOF
cat >> "$L/prp-gpu1.log" <<'EOF'
20261028 15:00:05 141234567 FFT: 7.50M 1K:15:256 (18.37 bpw)
20261028 15:00:05 152345671 FFT: 8M 1K:16:256 (18.16 bpw)
20261028 15:00:12 141234567 OK  1420000 1234567890abcdef  135.1 ETA 5:15; Z=35 (avg 34.1)
20261028 15:00:12 152345671 OK  1530000 1234567890abcdef  150.1 ETA 6:15; Z=35 (avg 34.1)
20261028 15:10:12 141234567 OK  2830000 1234567890abcdef  135.0 ETA 5:12; Z=35 (avg 34.1)
20261028 20:30:00 141234567 {"status":"C", "exponent":141234567, "worktype":"PRP-3", "res64":"abcdef0123456789"}
EOF
echo "[Main thread] INFO: Credit for exponent 141234567: 612.4 GHz-days" >> "$L/apn-gpu1.log"
cat >> "$L/cpu.log" <<'EOF'
[Work thread Oct 28 15:00] Starting P-1 factoring of M139876543 using AVX-512 FFT length 7680K
[Work thread Oct 28 15:01] M139876543 stage 1 is 0.52% complete. Time: 30.123 sec.
[Work thread Oct 28 15:02] M139876543 stage 1 is 1.50% complete. Time: 30.123 sec.
EOF
echo "[2026-10-28 15:30:00] backup[gimps]: хранилище недоступно — синхронизация пропущена" >> "$L/backup.log"
sleep 5
fail=0
check() { grep -qF -- "$1" "$T/out" || { echo "НЕ НАЙДЕНО: $1"; fail=1; }; }
check "НОВАЯ ЗАДАЧА ━━ TF M164185409"
check "оценка: 186.33 GHz-d"
check "M164185409   1.20%"
check "делителей в 2^77–2^78 нет"
check "НОВАЯ ЗАДАЧА ━━ PRP-тест M141234567"
check "НОВАЯ ЗАДАЧА ━━ PRP-тест M152345671"
check "M141234567   2.00%"
check "M141234567: составное"
check "PrimeNet засчитал M141234567"
check "НОВАЯ ЗАДАЧА ━━ P-1 M139876543"
check "[BACKUP] слот gimps: хранилище недоступно"
grep -q '"kind": "PRP", "exp": 141234567' "$T/data/.credit-history.json" || { echo "кредит не записан как PRP"; fail=1; }
[ -s "$T/err" ] && { echo "ошибки монитора:"; cat "$T/err"; fail=1; }
if [ $fail = 0 ]; then echo "test-monitor: OK"; else echo "--- вывод монитора:"; cat "$T/out"; fi
exit $fail
