#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════════════════
#   check_response.sh · проверка, отвечают ли IP-адреса по HTTP
# ═════════════════════════════════════════════════════════════════════════
#
#   Что делает скрипт
#   ─────────────────
#   1. Читает список IP-адресов из текстового файла.
#   2. Стучится на каждый адрес по HTTP (по умолчанию GET /generate_204,
#      порт 80) — адреса проверяются параллельно, поэтому список из
#      нескольких десятков адресов занимает считанные секунды.
#   3. По мере готовности выводит таблицу с колонками:
#
#          IP              STATUS    HTTP      TIME
#          188.72.103.107  WORKS     204       37 ms          ← ответил
#          188.72.103.102  FAIL      curl:28   таймаут        ← не ответил
#
#        IP      проверяемый адрес
#        STATUS  WORKS (зелёным) — адрес ответил по HTTP,
#                FAIL  (красным) — ответа нет
#        HTTP    код HTTP-ответа (например 204); у FAIL — код ошибки
#                (curl:7 — соединение отклонено, curl:28 — таймаут,
#                curl:6 — адрес не разрешился, curl:56 — соединение сброшено)
#        TIME    время ответа в миллисекундах; у FAIL — причина словами
#
#   4. После таблицы показывает рабочие адреса, отсортированные по времени
#      ответа — от самого быстрого к самому медленному.
#   5. В конце печатает итог: сколько всего, сколько WORKS и FAIL, минимальное /
#      среднее / максимальное время ответа.
#
#   Запуск
#   ──────
#     bash check_response.sh --file ips.txt
#
#   Формат файла: один IPv4 на строку, например
#     188.72.103.107
#     188.72.110.17        # после решётки можно писать комментарий
#   Пустые строки, комментарии, пробелы по краям и переводы строк Windows
#   (CRLF) игнорируются, повторяющиеся адреса проверяются один раз.
#   Строки, которые не похожи на IPv4, пропускаются с предупреждением.
#
#   Параметры (все необязательные, кроме --file)
#   ────────────────────────────────────────────
#     -f, --file ПУТЬ     файл со списком IP
#     -p, --port N        порт                                   (по умолч. 80)
#         --path ПУТЬ     путь запроса                  (по умолч. /generate_204)
#     -t, --timeout СЕК   таймаут на один адрес                   (по умолч. 3)
#     -j, --jobs N        сколько адресов проверять одновременно (по умолч. 20)
#         --https         использовать HTTPS (сертификат не проверяется)
#         --expect КОД    считать WORKS только при этом коде (например 204);
#                         любой другой код будет FAIL
#     -h, --help          эта справка
#
#   Что считается «ответил»
#   ───────────────────────
#   Любой HTTP-ответ (204, 200, 404, 503…): раз пришёл ответ, адрес достижим.
#   Нужен строго определённый код — используйте --expect.
#
#   Код выхода: 0 — ответили все, 1 — есть не ответившие, 2 — ошибка запуска.
#   Цвета отключаются переменной NO_COLOR=1.
# ═════════════════════════════════════════════════════════════════════════
set -u

FILE=""; PORT=80; URL_PATH=/generate_204; TIMEOUT=3; JOBS=20; SCHEME=http; EXPECT=""

# ── цвета (только в терминале и без NO_COLOR) ────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; C=$'\033[36m'; M=$'\033[35m'
  B=$'\033[1m';  D=$'\033[2m';  N=$'\033[0m'
else
  G=; R=; Y=; C=; M=; B=; D=; N=
fi

usage() { sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//; /^═/d'; }
die()   { printf '%sОшибка:%s %s\n' "$R" "$N" "$*" >&2; exit 2; }

# ── разбор аргументов ────────────────────────────────────────────────────
need_val() { [ -n "${2:-}" ] || die "у параметра $1 нет значения"; }
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--file)    need_val "$1" "${2:-}"; FILE=$2; shift 2 ;;
    --file=*)     FILE=${1#*=}; shift ;;
    -p|--port)    need_val "$1" "${2:-}"; PORT=$2; shift 2 ;;
    --port=*)     PORT=${1#*=}; shift ;;
    --path)       need_val "$1" "${2:-}"; URL_PATH=$2; shift 2 ;;
    --path=*)     URL_PATH=${1#*=}; shift ;;
    -t|--timeout) need_val "$1" "${2:-}"; TIMEOUT=$2; shift 2 ;;
    --timeout=*)  TIMEOUT=${1#*=}; shift ;;
    -j|--jobs)    need_val "$1" "${2:-}"; JOBS=$2; shift 2 ;;
    --jobs=*)     JOBS=${1#*=}; shift ;;
    --https)      SCHEME=https; shift ;;
    --expect)     need_val "$1" "${2:-}"; EXPECT=$2; shift 2 ;;
    --expect=*)   EXPECT=${1#*=}; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "не понял аргумент: $1 (справка: bash $0 --help)" ;;
  esac
done

[ -n "$FILE" ] || { usage >&2; printf '\n'; die "укажите файл: bash $0 --file ips.txt"; }
[ -r "$FILE" ] || die "не могу прочитать файл: $FILE"
command -v curl >/dev/null 2>&1 || die "не найден curl"
case "$PORT"    in ''|*[!0-9]*) die "порт должен быть числом" ;; esac
case "$JOBS"    in ''|*[!0-9]*|0) die "--jobs должен быть числом больше 0" ;; esac
case "$TIMEOUT" in ''|*[!0-9]*|0) die "--timeout должен быть целым числом секунд больше 0" ;; esac
case "$URL_PATH" in /*) : ;; *) URL_PATH=/$URL_PATH ;; esac

# ── чтение списка: убираем CR, комментарии, пробелы, пустые строки, дубли ──
IPS=(); BAD=()
while IFS= read -r ip; do
  if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] &&
     [ "${BASH_REMATCH[1]}" -le 255 ] && [ "${BASH_REMATCH[2]}" -le 255 ] &&
     [ "${BASH_REMATCH[3]}" -le 255 ] && [ "${BASH_REMATCH[4]}" -le 255 ]; then
    IPS+=("$ip")
  else
    BAD+=("$ip")
  fi
done < <(tr -d '\r' < "$FILE" | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | awk 'NF && !seen[$0]++')

TOTAL=${#IPS[@]}
[ "$TOTAL" -gt 0 ] || die "в файле нет ни одного корректного IPv4: $FILE"

# ── проверка одного адреса (запускается параллельно) ─────────────────────
# Результат кладём в $TMP/<номер>.res одной строкой:
#   ok|код|мс|секунды   или   fail|код ошибки|описание
check_one() {
  local idx=$1 ip=$2 out rc code t ms desc opts
  opts="--connect-timeout $TIMEOUT --max-time $TIMEOUT"
  [ "$SCHEME" = https ] && opts="$opts -k"
  # shellcheck disable=SC2086
  out=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' $opts "${SCHEME}://${ip}:${PORT}${URL_PATH}" 2>/dev/null)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    code=${out%% *}; t=${out##* }; t=${t/,/.}
    ms=$(awk -v t="$t" 'BEGIN{printf "%d", t*1000+0.5}')
    if [ "$code" = 000 ]; then
      printf 'fail|http:000|нет HTTP-ответа\n' > "$TMP/$idx.tmp"
    elif [ -n "$EXPECT" ] && [ "$code" != "$EXPECT" ]; then
      printf 'fail|http:%s|ожидался %s\n' "$code" "$EXPECT" > "$TMP/$idx.tmp"
    else
      printf 'ok|%s|%s|%s\n' "$code" "$ms" "$t" > "$TMP/$idx.tmp"
    fi
  else
    case "$rc" in
      6)  desc="адрес не разрешился" ;;
      7)  desc="соединение отклонено" ;;
      28) desc="таймаут" ;;
      35) desc="ошибка TLS" ;;
      52) desc="пустой ответ" ;;
      55) desc="ошибка отправки" ;;
      56) desc="соединение сброшено" ;;
      60) desc="ошибка сертификата" ;;
      *)  desc="ошибка curl" ;;
    esac
    printf 'fail|curl:%s|%s\n' "$rc" "$desc" > "$TMP/$idx.tmp"
  fi
  mv "$TMP/$idx.tmp" "$TMP/$idx.res"   # атомарно: читающий не увидит недописанный файл
}
export -f check_one
export SCHEME PORT URL_PATH TIMEOUT EXPECT

TMP=$(mktemp -d) || die "не удалось создать временный каталог"
export TMP
XPID=""
cleanup() { [ -n "$XPID" ] && kill "$XPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
trap 'printf "\n"; exit 130' INT TERM

# ── шапка и заголовок таблицы ────────────────────────────────────────────
LINE_W=56
rule() { printf '%*s\n' "$LINE_W" '' | tr ' ' "$1"; }

printf '\n%s%scheck_response%s  %s%s://<ip>:%s%s · таймаут %sс · потоков %s · адресов %s%s\n\n' \
  "$B" "$C" "$N" "$D" "$SCHEME" "$PORT" "$URL_PATH" "$TIMEOUT" "$JOBS" "$TOTAL" "$N"
for b in "${BAD[@]+"${BAD[@]}"}"; do
  printf '  %s!%s пропущено (не IPv4): %s\n' "$Y" "$N" "$b"
done
[ "${#BAD[@]}" -gt 0 ] && printf '\n'

printf '%s%-16s%-10s%-10s%s%s\n' "$B" "IP" "STATUS" "HTTP" "TIME" "$N"
rule '-'

# ── запуск проверок параллельно ──────────────────────────────────────────
{
  i=0
  for ip in "${IPS[@]}"; do i=$((i+1)); printf '%s %s\n' "$i" "$ip"; done
} | xargs -n 2 -P "$JOBS" bash -c 'check_one "$1" "$2"' _ &
XPID=$!

# ── строки таблицы по порядку, по мере готовности ────────────────────────
OKN=0; FAILN=0; SUM=0; MIN=""; MAX=0
SORT_IN=""   # сюда копим «секунды|ip» рабочих адресов для сортировки
for ((i=1; i<=TOTAL; i++)); do
  ip=${IPS[$((i-1))]}
  while [ ! -f "$TMP/$i.res" ]; do
    if ! kill -0 "$XPID" 2>/dev/null && [ ! -f "$TMP/$i.res" ]; then
      printf 'fail|внутр.|проверка не выполнена\n' > "$TMP/$i.res"; break
    fi
    sleep 0.05
  done
  IFS='|' read -r st a b c < "$TMP/$i.res"
  if [ "$st" = ok ]; then
    OKN=$((OKN+1)); SUM=$((SUM+b))
    { [ -z "$MIN" ] || [ "$b" -lt "$MIN" ]; } && MIN=$b
    [ "$b" -gt "$MAX" ] && MAX=$b
    SORT_IN+="${c}|${ip}"$'\n'
    printf '%-16s%s%s%-10s%s%-10s%s%s ms%s\n' "$ip" "$G" "$B" "WORKS" "$N" "$a" "$D" "$b" "$N"
  else
    FAILN=$((FAILN+1))
    printf '%-16s%s%s%-10s%s%s%-10s%s%s%s\n' "$ip" "$R" "$B" "FAIL" "$N" "$R" "$a" "$N" "$D" "$b$N"
  fi
done
rule '-'

# ── рабочие адреса: от быстрого к медленному ─────────────────────────────
if [ "$OKN" -gt 0 ]; then
  printf '\n'; rule '='
  printf '%sРАБОЧИЕ EDGE — ОТ БЫСТРОГО К МЕДЛЕННОМУ%s\n' "$B" "$N"
  rule '='
  printf '%s' "$SORT_IN" | LC_ALL=C sort -t'|' -k1,1n | while IFS='|' read -r t ip; do
    [ -n "$ip" ] && printf '%s%-20s%s%s sec\n' "$M" "$ip" "$N" "$t"
  done
fi

# ── итог ─────────────────────────────────────────────────────────────────
printf '\n'; rule '-'
printf '  Итого: %s%s%s · %sWORKS %s%s · %sFAIL %s%s' "$B" "$TOTAL" "$N" "$G" "$OKN" "$N" "$R" "$FAILN" "$N"
if [ "$OKN" -gt 0 ]; then
  printf ' · время: мин %s / ср %s / макс %s ms' "$MIN" "$((SUM / OKN))" "$MAX"
fi
printf '\n\n'

[ "$FAILN" -eq 0 ]
