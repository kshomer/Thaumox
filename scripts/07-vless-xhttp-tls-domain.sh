#!/bin/bash

if [ -z "${BASH_VERSION:-}" ]; then
    echo "Ошибка: требуется bash. Запустите: bash $0" >&2
    exit 1
fi

#######################################
# Script Name: 07-vless-xhttp-tls-domain.sh
# Description: VLESS + XHTTP + TLS со своим доменом.
#              Caddy + Let's Encrypt.
# Author:      kshomer
# Version:     1.0
# Date:        09.09.2026
#
# Архитектура: Cloudflare DNS (серое облако) → VPS
#              Caddy :443 → / → статический сайт
#                          → /api/path → Xray XHTTP :8080
#######################################

set -o errexit
set -o nounset
set -o pipefail

# ============================================
# КОНСТАНТЫ
# ============================================


# Ставится стабильная версия Xray. Почти все релизы Xray-core помечены как
# предварительные, и единственное место, где видно стабильный, — GitHub
# releases/latest. Номер выясняется при запуске и записывается в compose
# конкретным числом, поэтому работающий сервер остаётся на своей версии.
# Константа ниже — запасной вариант, если GitHub недоступен.
readonly FALLBACK_XRAY_VERSION="26.3.27"
readonly XRAY_STABLE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly XRAY_REPO="ghcr.io/xtls/xray-core"
XRAY_VERSION="" XRAY_IMAGE=""
readonly INSTALL_DIR="/opt/xray-tls-domain"
readonly CONTAINER_NAME="xray-tls-domain"
readonly CADDY_CONTAINER="caddy-tls"
readonly XRAY_XHTTP_PORT=8080   # внутренний порт Xray XHTTP (только localhost)
readonly SSH_TIMEOUT=30
readonly SSH_RETRIES=3
readonly SSH_RETRY_DELAY=5

# Тайминги (секунды): держим в одном месте, а не числами по коду
readonly WAIT_CONTAINER_START=5      # пауза перед проверкой, что контейнер поднялся
readonly WAIT_CLIENT_READY=3         # пауза, пока временный клиент Xray выйдет на связь
readonly WAIT_PORT_RELEASE=2         # пауза после освобождения порта
readonly WAIT_AUTH_RETRY=3           # пауза между попытками SSH-аутентификации
readonly WAIT_APT_LOCK_STEP=3        # шаг ожидания снятия блокировки apt
readonly HTTP_TIMEOUT=10             # таймаут обычных HTTP-запросов
readonly HTTP_TIMEOUT_TUNNEL=20      # таймаут проверки через туннель
readonly HTTP_TIMEOUT_API=20         # таймаут обращений к API (реестры, Cloudflare)
readonly LOCK_FILE="/tmp/vless-tls-domain-install.lock"

# Показать, что именно будет опубликовано, и получить согласие.
# Каталог уходит в интернет целиком: Caddy отдаёт его через file_server, то есть
# любой файл внутри становится публично скачиваемым. Ошибка в пути (например,
# указан рабочий каталог вместо каталога сайта) публикует всё, что в нём лежит.
# Поэтому до отправки — опись, отдельная отметка о признаках «это не сайт»,
# и явное подтверждение.
# Снять экранирование с пути, введённого человеком. get_input читает строку как есть,
# оболочка её не разбирает, поэтому путь, перетащенный из терминала или Finder, приходит с
# обратными слэшами («Site\ \(1\)») или в кавычках. Снимать их вслепую нельзя: обратный
# слэш бывает и в настоящем имени файла. Поэтому функция только строит вторую версию пути,
# а решает вызывающий — и лишь когда исходной версии на диске нет.
unescape_path() {   # $1 = введённая строка
    local t="$1"
    if [[ "$t" == \'*\' ]]; then t="${t#\'}"; t="${t%\'}"; fi
    if [[ "$t" == \"*\" ]]; then t="${t#\"}"; t="${t%\"}"; fi
    printf '%s' "$t" | sed 's/\\\([^a-zA-Z0-9]\)/\1/g'
}

confirm_site_dir() {   # $1 = каталог; 0 = использовать, 1 = выбрать другой
    local dir="$1" nfiles size bytes ntop
    nfiles=$(find "$dir" -type f 2>/dev/null | wc -l | tr -d ' ')
    size=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
    bytes=$(du -sk "$dir" 2>/dev/null | awk '{print $1}')
    ntop=$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')

    echo
    echo -e "${CYAN}Будет опубликовано на ${TLS_DOMAIN}:${NC}"
    echo -e "  Каталог: ${YELLOW}${dir}${NC}"
    echo -e "  Файлов:  ${nfiles}    Объём: ${size:-?}"
    echo
    echo -e "${CYAN}Содержимое верхнего уровня:${NC}"
    find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | sed 's|.*/|  |' | head -15
    [[ "${ntop:-0}" -gt 15 ]] && echo "  … ещё $((ntop - 15))"

    # Признаки того, что указан не каталог сайта, а рабочий каталог
    local flagged=0 ngit
    ngit=$(find "$dir" -maxdepth 4 -type d -name .git 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${ngit:-0}" -gt 0 ]]; then
        [[ $flagged -eq 0 ]] && { echo; log WARN "Похоже, это не каталог сайта:"; flagged=1; }
        echo -e "  ${YELLOW}· внутри есть репозитории с историей (.git): ${ngit}${NC}"
    fi
    if [[ "${bytes:-0}" -gt 51200 ]]; then
        [[ $flagged -eq 0 ]] && { echo; log WARN "Похоже, это не каталог сайта:"; flagged=1; }
        echo -e "  ${YELLOW}· объём больше 50 МБ${NC}"
    fi
    if [[ "${nfiles:-0}" -gt 500 ]]; then
        [[ $flagged -eq 0 ]] && { echo; log WARN "Похоже, это не каталог сайта:"; flagged=1; }
        echo -e "  ${YELLOW}· больше 500 файлов${NC}"
    fi
    [[ $flagged -eq 1 ]] && \
        echo -e "  ${YELLOW}Всё перечисленное станет доступно по ссылке любому, кто её подберёт.${NC}"
    echo
    ask_yn "Опубликовать этот каталог?"
}

# Шаблоны служебных путей API
readonly -a XHTTP_PATH_TEMPLATES=(
    "/api/v2/sync"
    "/api/v1/push"
    "/internal/session"
    "/content/graphql"
    "/client/status"
    "/data/report"
    "/api/client/sync"
    "/session/update"
)

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Runtime
SERVER_IP="" SSH_PORT_SSH="22" SSH_USER="root" SSH_PASSWORD=""
PUBLIC_IP="" TLS_DOMAIN="" CF_API_TOKEN=""
XHTTP_PATH=""
USER_COUNT=1
declare -a USER_NAMES=() USER_UUIDS=()
declare -a TEMP_FILES=()
XRAY_PORT=443
# Отложенное действие по конфликту порта (выполняется после подтверждения) и путь бэкапа
BACKUP_DIR=""
# Очередь на снятие: параллельные массивы «кого» и «как» (backup|delete). Очередь, а не одно
# значение, потому что портов может быть несколько и держать их могут разные контейнеры.
# PORT_DELETED_DIRS нужен, чтобы не делать резервную копию каталога, который владелец только
# что велел удалить целиком.
PORT_KILL_SPECS=() PORT_RELEASE_NAMES=() PORT_RELEASE_MODES=() PORT_DELETED_DIRS=()

# ============================================
# ЛОГИРОВАНИЕ
# ============================================

log() {
    local level=$1; shift
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    case $level in
        INFO)    echo -e "${CYAN}[${ts}]${NC} $*" ;;
        WARN)    echo -e "${YELLOW}[${ts}] ⚠${NC}  $*" ;;
        ERROR)   echo -e "${RED}[${ts}] ✗${NC}  $*" >&2 ;;
        SUCCESS) echo -e "${GREEN}[${ts}] ✓${NC}  $*" ;;
        STEP)    echo -e "${BLUE}[${ts}] →${NC}  $*" ;;
    esac
}

print_header() {
    echo
    echo -e "${BLUE}==========================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}==========================================${NC}"
    echo
}

print_step() {
    echo
    echo -e "${BLUE}[Шаг $1]${NC} ${YELLOW}$2${NC}"
    echo
}

# ============================================
# ОЧИСТКА И LOCK
# ============================================

# Программы с полноэкранным интерфейсом (nano, less, htop и подобные) переводят
# терминал в режим application cursor keys — ESC[?1h. Если такой программе не дали
# выйти штатно (оборвалась ssh-сессия, Ctrl+C), режим остаётся включённым уже после
# её завершения, и тогда прокрутка колесом начинает подсовывать в ввод ^[OA и ^[OB
# вместо прокрутки. Проверено: наши скрипты этот режим не включают — в сырых логах
# сессий последовательностей ESC[? нет вовсе. Но вернуть терминал в норму при выходе
# дёшево, и это чинит его, даже если испортил кто-то другой.
restore_terminal() {
    [[ -t 1 ]] || return 0
    if command -v tput >/dev/null 2>&1; then
        tput rmkx 2>/dev/null || printf '\033[?1l'
    else
        printf '\033[?1l'
    fi
    stty echo 2>/dev/null || true
    return 0
}

cleanup() {
    local code=$?
    restore_terminal
    for f in "${TEMP_FILES[@]:-}"; do [[ -f "${f:-}" ]] && rm -f "$f"; done
    rm -f "$LOCK_FILE" 2>/dev/null || true
    _ssh_close
    [[ $code -ne 0 ]] && { echo; log ERROR "Скрипт завершился с ошибкой (код: $code)"; }
    exit $code
}
trap cleanup EXIT INT TERM

# Стабильная версия ядра: номер берётся из релиза GitHub, помеченного как latest
# (то есть не pre-release). При недоступности GitHub — запасной номер из константы.
resolve_stable_version() {
    log STEP "Запрос стабильной версии Xray (GitHub XTLS/Xray-core)..."
    local tag
    tag=$(curl -s --max-time "${HTTP_TIMEOUT_API}" "$XRAY_STABLE_API" 2>/dev/null \
          | jq -r '.tag_name // empty' 2>/dev/null) || true
    tag="${tag#v}"
    if [[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        XRAY_VERSION="$tag"
        log SUCCESS "Стабильная версия Xray: ${XRAY_VERSION}"
    else
        XRAY_VERSION="$FALLBACK_XRAY_VERSION"
        log WARN "GitHub не ответил — берётся версия из скрипта: ${XRAY_VERSION}"
    fi
    XRAY_IMAGE="${XRAY_REPO}:${XRAY_VERSION}"
}

acquire_lock() {
    if command -v flock &>/dev/null; then
        exec 9>"$LOCK_FILE"
        flock -n 9 || { log ERROR "Другой экземпляр уже запущен"; exit 1; }
    fi
}

create_temp() { local f; f=$(mktemp); TEMP_FILES+=("$f"); echo "$f"; }

# ============================================
# ВАЛИДАЦИЯ
# ============================================

validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local IFS='.'; read -ra o <<< "$ip"
        for oct in "${o[@]}"; do ((oct < 0 || oct > 255)) && return 1; done
        return 0
    fi
    python3 -c "import ipaddress; ipaddress.ip_address('${ip}')" 2>/dev/null && return 0
    return 1
}
validate_port()   { [[ $1 =~ ^[0-9]+$ ]] && ((${1} >= 1 && ${1} <= 65535)); }
validate_user()   { [[ $1 =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; }
validate_posint() { [[ $1 =~ ^[1-9][0-9]*$ ]]; }
validate_count()  { validate_posint "$1" && (( $1 <= 12 )); }
validate_path() {
    # только буквы/цифры и / _ - . ; без пробелов, кавычек, // и ..
    [[ $1 =~ ^/[A-Za-z0-9_./-]{1,100}$ && $1 != *//* && $1 != *..* ]]
}
validate_cf_token() { [[ $1 =~ ^[A-Za-z0-9_-]{20,128}$ ]]; }
# Прежняя версия проверяла только форму имени и пропускала «www.bing.c», «a.b»
# и даже «1.2.3.4»: домен верхнего уровня мог быть любым, вплоть до одной цифры.
# Теперь верхний уровень — только буквы, минимум две, либо punycode (xn--…).
# Опечатку в существующем домене (ww.bing.co) синтаксис поймать не может —
# для этого есть проверка доступности перед применением.
validate_domain() {
    local d="$1"
    [[ ${#d} -le 253 ]] || return 1
    [[ $d =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+([a-zA-Z]{2,63}|xn--[a-zA-Z0-9-]{2,59})$ ]] || return 1
    return 0
}

get_input() {
    local prompt=$1 var=$2 default=${3:-} validator=${4:-} errmsg=${5:-"Некорректное значение"}
    local val
    while true; do
        if [[ -n "$default" ]]; then
            read -r -p "$prompt (по умолчанию: $default): " val; val=${val:-$default}
        else read -r -p "$prompt: " val; fi
        [[ -z "$val" ]] && { log WARN "Значение не может быть пустым"; continue; }
        if [[ -n "$validator" ]] && ! $validator "$val"; then
            log WARN "$errmsg: $val"; continue
        fi
        # printf -v вместо eval — ввод не интерпретируется как код
        printf -v "$var" '%s' "$val"
        return 0
    done
}

# Вопрос да/нет: принимаются только y/yes и n/no (регистр не важен). Enter — вариант по умолчанию, если задан.
ask_yn() {   # $1 = вопрос, $2 = по умолчанию (y|n|пусто) → 0 = да, 1 = нет
    local q="$1" def="${2:-}" hint a
    case "$def" in y) hint="(Y/n)" ;; n) hint="(y/N)" ;; *) hint="(y/n)" ;; esac
    while true; do
        read -r -p "${q} ${hint}: " a
        a=$(echo "${a:-}" | tr '[:upper:]' '[:lower:]')
        [[ -z "$a" && -n "$def" ]] && a="$def"
        case "$a" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) log WARN "Введите y или n" ;;
        esac
    done
}
# Подтверждение опасного действия: только полное слово yes или no
ask_yes_no_word() {   # $1 = вопрос → 0 = yes, 1 = no
    local a
    while true; do
        read -r -p "${1} (yes/no): " a
        case "$(echo "${a:-}" | tr '[:upper:]' '[:lower:]')" in
            yes) return 0 ;;
            no)  return 1 ;;
            *) log WARN "Введите yes или no" ;;
        esac
    done
}


# ============================================
# SSH
# ============================================

# Одно SSH-соединение на весь запуск (ControlMaster): пароль вводится и проверяется один раз,
# остальные команды идут через уже открытый канал — быстрее и без разовых сбоев аутентификации.
SSH_CM_DIR=""
_ssh_opts() {
    # SSH_CM_DIR задаётся в main после ввода пароля; здесь — только страховка (короткий путь: лимит unix-сокета 104 байта)
    [[ -z "$SSH_CM_DIR" ]] && SSH_CM_DIR=$(mktemp -d /tmp/vless-ssh.XXXXXX)
    SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout="${SSH_TIMEOUT}" -o ServerAliveInterval=15
              -o ControlMaster=auto -o ControlPath="${SSH_CM_DIR}/cm-%C" -o ControlPersist=300)
}
_ssh_close() {
    [[ -n "${SSH_CM_DIR:-}" && -n "${SERVER_IP:-}" ]] && \
        ssh -o ControlPath="${SSH_CM_DIR}/cm-%C" -O exit -p "${SSH_PORT_SSH:-22}" "${SSH_USER:-root}@${SERVER_IP}" >/dev/null 2>&1 || true
    [[ -n "${SSH_CM_DIR:-}" ]] && rm -rf "$SSH_CM_DIR"
    return 0
}

_ssh_cmd() {
    _ssh_opts
    # пароль через переменную окружения (sshpass -e), а не через аргумент -p (виден в ps)
    SSHPASS="$SSH_PASSWORD" sshpass -e ssh "${SSH_OPTS[@]}" -o BatchMode=no -p "$SSH_PORT_SSH" "${SSH_USER}@${SERVER_IP}" "$@"
}

_scp_cmd() {
    _ssh_opts
    SSHPASS="$SSH_PASSWORD" sshpass -e scp "${SSH_OPTS[@]}" -P "$SSH_PORT_SSH" "$@"
}

# Свободный порт на сервере из диапазона $1..$1+$2. Прежде порт брался как
# 20000+RANDOM%20000 без всякой проверки: при совпадении с уже занятым временный клиент не
# поднимался и сквозная проверка давала ложный отказ — редко, но необъяснимо для владельца.
# Список занятых читаем одним запросом и выбираем первого кандидата, которого в нём нет.
# Если запрос не удался, ведём себя как прежде: отдаём случайный порт без проверки.
pick_free_port() {   # $1 = начало диапазона, $2 = размер диапазона
    local base="$1" span="$2" i busy port=""
    local -a cands=()
    for i in 1 2 3 4 5 6 7 8; do
        cands+=( "$(( base + RANDOM % span ))" )
    done
    busy=$(_ssh_cmd "ss -ltnu 2>/dev/null | awk '{print \$5}' | sed 's/.*://'" 2>/dev/null | tr -d '\r') || busy=""
    for port in "${cands[@]}"; do
        printf '%s\n' "$busy" | grep -qx -- "$port" || { echo "$port"; return 0; }
    done
    echo "$port"
}

execute_remote() {
    local cmd="$1" desc="${2:-}" retries=${3:-$SSH_RETRIES} attempt=1
    [[ -n "$desc" ]] && log STEP "${desc}..."
    while [ "$attempt" -le "$retries" ]; do
        if _ssh_cmd "$cmd" 2>&1; then
            [[ -n "$desc" ]] && log SUCCESS "$desc"; return 0
        fi
        [ "$attempt" -lt "$retries" ] && { log WARN "Попытка $attempt/$retries..."; sleep "$SSH_RETRY_DELAY"; }
        attempt=$((attempt + 1))
    done
    [[ -n "$desc" ]] && log ERROR "$desc (все попытки исчерпаны)"; return 1
}

execute_remote_output() { _ssh_cmd "$1" 2>/dev/null; }

copy_to_remote() {
    local src="$1" dst="$2" desc="$3" attempt=1
    log STEP "${desc}..."
    while [ "$attempt" -le "$SSH_RETRIES" ]; do
        if _scp_cmd "$src" "${SSH_USER}@${SERVER_IP}:${dst}" 2>&1; then
            log SUCCESS "$desc"; return 0
        fi
        [ "$attempt" -lt "$SSH_RETRIES" ] && { log WARN "Попытка $attempt..."; sleep "$SSH_RETRY_DELAY"; }
        attempt=$((attempt + 1))
    done
    log ERROR "$desc (все попытки исчерпаны)"; return 1
}

# ============================================
# CLOUDFLARE: ввод и проверка токена через API (до подтверждения установки)
# ============================================

verify_cf_token() {
    log STEP "Проверка токена через API Cloudflare..."
    local resp status
    resp=$(curl -sS --max-time ${HTTP_TIMEOUT_API} -H "Authorization: Bearer ${CF_API_TOKEN}" \
        "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null) || {
        log WARN "Нет доступа к api.cloudflare.com с этой машины — проверка токена пропущена"; return 0; }
    status=$(echo "$resp" | jq -r '.result.status // empty' 2>/dev/null)
    if [[ "$(echo "$resp" | jq -r '.success' 2>/dev/null)" != "true" || "$status" != "active" ]]; then
        log ERROR "Cloudflare отклонил токен: $(echo "$resp" | jq -r '.errors[0].message // "неизвестная ошибка"' 2>/dev/null) (status: ${status:-нет})"
        return 1
    fi
    log SUCCESS "Токен активен"

    # Токен должен видеть зону домена (acme.sh dns_cf делает тот же запрос)
    local zone="$TLS_DOMAIN" found=""
    while [[ "$zone" == *.* ]]; do
        found=$(curl -sS --max-time ${HTTP_TIMEOUT_API} -H "Authorization: Bearer ${CF_API_TOKEN}" \
            "https://api.cloudflare.com/client/v4/zones?name=${zone}&status=active" 2>/dev/null | jq -r '.result[0].name // empty' 2>/dev/null) || true
        [[ -n "$found" ]] && break
        zone="${zone#*.}"
    done
    if [[ -z "$found" ]]; then
        # Токен рабочий, но зоны для этого домена в аккаунте нет. Причина чаще всего
        # в домене (опечатка, домен не заведён в Cloudflare), а не в токене, поэтому
        # отдельный код возврата: вызывающий предложит исправить домен.
        log ERROR "В аккаунте Cloudflare нет зоны для ${TLS_DOMAIN}"
        log INFO "Либо домен указан с опечаткой, либо он не заведён в этом аккаунте,"
        log INFO "либо у токена нет прав Zone:DNS:Edit на его зону"
        return 2
    fi
    log SUCCESS "Зона Cloudflare: ${found}"
}

read_cf_token() {
    while true; do
        read -r -s -p "Cloudflare API Token: " CF_API_TOKEN; echo
        if [[ -z "$CF_API_TOKEN" ]]; then log WARN "Значение не может быть пустым (для выхода — Ctrl+C)"; continue; fi
        if ! validate_cf_token "$CF_API_TOKEN"; then
            log WARN "Токен выглядит некорректно (ожидаются буквы, цифры, «_» и «-»)"; continue
        fi
        local rc=0
        verify_cf_token || rc=$?
        case $rc in
            0) return 0 ;;
            2)  # Токен исправен, но зоны для домена нет — чаще всего дело в домене
                echo
                echo -e "  ${GREEN}1)${NC} Ввести другой домен"
                echo -e "  ${GREEN}2)${NC} Ввести другой токен"
                echo -e "  ${RED}0)${NC} Отменить установку"
                echo
                local zc
                while true; do
                    read -r -p "Выберите (0-2): " zc
                    case "$zc" in
                        1) get_input "Домен (например: app.example.com)" "TLS_DOMAIN" "" "validate_domain" "Некорректный домен"
                           break ;;
                        2) break ;;
                        0) log INFO "Установка отменена — сервер не изменён"; exit 0 ;;
                        *) log WARN "Введите 0, 1 или 2" ;;
                    esac
                done
                # Домен сменили — токен прежний, проверяем его уже с новым доменом
                if [[ "$zc" == "1" ]]; then
                    verify_cf_token && return 0
                fi
                ;;
            *) log WARN "Введите другой токен (для выхода — Ctrl+C)" ;;
        esac
    done
}

# Предварительная проверка DNS с сервера (до подтверждения; dig на Ubuntu 24.04 есть, иначе getent)
precheck_dns() {
    log STEP "Проверка DNS: ${TLS_DOMAIN} → ${PUBLIC_IP}..."
    local dns_ip
    dns_ip=$(execute_remote_output "dig +short '${TLS_DOMAIN}' A 2>/dev/null | grep -E '^[0-9.]+$' | tail -1") || true
    dns_ip=$(echo "${dns_ip:-}" | tr -d '[:space:]')
    if [[ -z "$dns_ip" ]]; then
        dns_ip=$(execute_remote_output "getent ahostsv4 '${TLS_DOMAIN}' 2>/dev/null | awk '{print \$1}' | head -1") || true
        dns_ip=$(echo "${dns_ip:-}" | tr -d '[:space:]')
    fi
    if [[ -z "$dns_ip" ]]; then
        log WARN "Домен ${TLS_DOMAIN} не резолвится с сервера"
        echo -e "  ${YELLOW}Создайте A-запись ${TLS_DOMAIN} → ${PUBLIC_IP} (Proxy: OFF, серое облако) и дождитесь распространения${NC}"
        ask_yn "DNS настроен, продолжить?" || { log INFO "Отменено — сервер не изменён"; exit 0; }
    elif [[ "$dns_ip" == "$PUBLIC_IP" ]]; then
        log SUCCESS "DNS корректен: ${TLS_DOMAIN} → ${dns_ip}"
    else
        log WARN "DNS указывает на ${dns_ip}, ожидается ${PUBLIC_IP} (оранжевое облако Cloudflare? Proxy должен быть OFF)"
        ask_yn "Продолжить?" || { log INFO "Отменено — сервер не изменён"; exit 0; }
    fi
}

# ============================================
# ГЕНЕРАЦИЯ API PATH
# ============================================

generate_path() {
    local arr_name=$1 var_name=$2 label=$3
    local templates=()
    case "$arr_name" in
        XHTTP_PATH_TEMPLATES) templates=("${XHTTP_PATH_TEMPLATES[@]}") ;;
        *)                    templates=("/api/v2/sync") ;;
    esac
    # К шаблону дописывается случайный сегмент вида идентификатора ресурса.
    # Без него путь угадывается перебором: шаблонов всего восемь, и все они
    # показаны на этом же экране. Со случайным сегментом перебор не работает,
    # а выглядит такой путь естественнее «голого» эндпоинта.
    # Источник читаем через od -N4: он берёт ровно четыре байта и выходит сам. Прежде
    # здесь стояло «tr -dc … < /dev/urandom | head -c 8»: head закрывал канал после
    # восьми байт, tr получал SIGPIPE, под set -o pipefail код пайпа становился 141, и
    # «|| rnd=""» затирал уже полученное значение. Ветка с /dev/urandom не срабатывала
    # никогда, путь всегда строился запасной. Проверено: 0 удач из 300.
    local rnd
    rnd=$(od -An -tx1 -N4 /dev/urandom 2>/dev/null | tr -d ' \n') || true
    # Запасная ветка — четыре вызова по 8 бит. Прежние два вызова давали по 15 бит
    # (RANDOM не превышает 0x7fff), поэтому 1-й и 5-й знаки пути никогда не были больше
    # семи: и энтропии меньше заявленных 32 бит, и в самом пути виден след.
    [[ ${#rnd} -ne 8 ]] && rnd=$(printf '%02x%02x%02x%02x' \
        $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
    local suggested="${templates[$(( RANDOM % ${#templates[@]} ))]}/${rnd}"

    echo
    echo -e "${CYAN}${label}:${NC}"
    echo -e "  Путь, по которому Caddy отдаёт трафик в Xray. Все остальные адреса домена"
    echo -e "  ведут на статический сайт. Путь попадает в ссылки пользователей."
    echo
    echo -e "  Предложен: ${GREEN}${suggested}${NC}"
    echo -e "  Значение уникально для каждой установки."
    echo
    echo -e "  Enter — принять предложенный, либо введите свой (буквы, цифры, / _ - . )"
    echo
    local val
    while true; do
        read -r -p "Path (по умолчанию: ${suggested}): " val
        val="${val:-$suggested}"
        [[ "$val" != /* ]] && val="/${val}"
        validate_path "$val" && break
        log WARN "Некорректный path (допустимы буквы, цифры, / _ - . ; без пробелов и спецсимволов): $val"
    done
    printf -v "$var_name" '%s' "$val"
    log SUCCESS "${label}: ${val}"
}

port_listeners() {
    # Вывод ss для порта $1 по протоколу $2 (tcp по умолчанию) или пустая строка.
    # Caddy публикует не только 443/tcp: под HTTP/3 ему нужен и 443/udp, поэтому
    # занятость обязательно проверять по обоим протоколам, иначе запуск падает на
    # «Bind for 0.0.0.0:443 failed: port is already allocated» уже после установки.
    local flag="-tlnp"; [[ "${2:-tcp}" == "udp" ]] && flag="-ulnp"
    local info
    info=$(execute_remote_output "ss ${flag} | grep ':${1} ' || echo __free__") || info="__free__"
    [[ "$info" == *__free__* ]] && return 1
    echo "$info"; return 0
}

# Порты, которые публикует Caddy помимо 443/tcp. Конфликт по любому из них
# не даст контейнеру подняться, поэтому проверяем их до установки.
check_extra_ports() {
    # Caddy публикует три порта: 443/tcp, 443/udp (HTTP/3) и 80/tcp. Занятость любого
    # не даст контейнеру подняться, поэтому проверяем все до изменений на сервере.
    #
    # check_port работает по контракту «только запомнить решение»: контейнер, который
    # пользователь согласился заменить или удалить, к этому моменту ещё жив и снимется
    # в apply_port_action. Его порты считаем освобождаемыми — иначе повторная установка
    # поверх собственной предыдущей была бы невозможна в принципе.
    #
    # Если лишний порт держит контейнер, о котором check_port не знает (он смотрит только
    # 443/tcp), предлагаем тот же выбор, что и там; если порт держит обычный процесс —
    # принудительное освобождение. Ограничения «один контейнер за установку» больше нет:
    # очередь принимает сколько угодно. Блокировка остаётся только там, где владелец
    # отказался освобождать или владельца порта определить не удалось.
    local blocked=0 info owner label
    local spec
    for spec in "443:udp" "80:tcp"; do
        local p="${spec%%:*}" proto="${spec##*:}"
        label=$(echo "$proto" | tr '[:lower:]' '[:upper:]')
        if ! info=$(port_listeners "$p" "$proto"); then
            log SUCCESS "Порт ${p}/${label} свободен"
            continue
        fi
        owner=$(execute_remote_output \
            "docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -E ':${p}->[0-9]+/${proto}' | awk '{print \$1}' | head -1" \
            | tr -d '[:space:]') || true
        if [[ -n "$owner" ]] && port_release_queued "$owner"; then
            log SUCCESS "Порт ${p}/${label} занят '${owner}' — будет освобождён вместе с ним"
            continue
        fi
        echo; log WARN "Порт ${p}/${label} занят, а Caddy его публикует:"
        echo "$info"
        if [[ -n "$owner" ]]; then
            echo -e "  ${CYAN}Занят контейнером: ${owner}${NC}"
            if offer_release_container "$owner"; then
                log SUCCESS "Порт ${p}/${label} будет освобождён вместе с '${owner}'"
                continue
            fi
            log INFO "Порт ${p}/${label} остался занят по вашему решению"
        elif offer_kill_port "$p" "$proto" "$label"; then
            continue
        else
            log INFO "Порт ${p}/${label} остался занят по вашему решению"
        fi
        blocked=1
    done
    if [[ $blocked -eq 1 ]]; then
        echo
        log INFO "Схеме с доменом нужны все три порта: 443/TCP, 443/UDP (HTTP/3) и 80/TCP"
        log INFO "Освободите занятый порт и запустите установку заново"
        echo
        echo -e "  ${RED}0)${NC} Отменить установку"
        echo
        local c
        while true; do
            read -r -p "Выберите (0): " c
            [[ "$c" == "0" ]] && { log INFO "Установка отменена — сервер не изменён"; exit 0; }
            log WARN "Введите 0"
        done
    fi
}

# Дополнительный порт держит не контейнер, а обычный процесс. Раньше это был тупик:
# предлагалась одна отмена. Предлагаем то же принудительное освобождение, что и для
# основного порта; решение так же уходит в очередь, а не выполняется сразу.
offer_kill_port() {   # $1 = порт, $2 = proto, $3 = метка; 0 = освобождение запланировано
    local pt="$1" proto="$2" label="$3" a
    echo -e "  ${CYAN}Docker-контейнера на этом порту не найдено — порт держит обычный процесс${NC}"
    echo
    echo -e "  ${YELLOW}1)${NC} Освободить порт ${pt}/${label} принудительно (fuser -k)"
    echo -e "  ${RED}0)${NC} Не трогать"
    echo
    while true; do
        read -r -p "Выберите (0-1): " a
        case "$a" in
            1) PORT_KILL_SPECS+=("${pt}/${proto}")
               log INFO "Запланировано: принудительно освободить порт ${pt}/${label}"
               return 0 ;;
            0) return 1 ;;
            *) log WARN "Введите 0 или 1" ;;
        esac
    done
}

# Предложить снять контейнер, удерживающий порт. Решение ставится в очередь и
# выполняется в apply_port_action уже после подтверждения установки — тот же
# контракт, что и у check_port. 0 = контейнер будет снят, 1 = пользователь отказался.
offer_release_container() {   # $1 = имя контейнера
    local c="$1" choice
    echo
    echo -e "  ${YELLOW}1)${NC} Заменить '${c}' — данные сохранить в резервную копию"
    echo -e "     ${CYAN}   Каталог установки будет перемещён в <каталог>.bak.ДАТА${NC}"
    echo
    echo -e "  ${RED}2)${NC} Удалить '${c}' полностью"
    echo -e "     ${RED}   ⚠  Каталог установки, его резервные копии .bak.* и образы Docker${NC}"
    echo -e "     ${RED}      этого контейнера будут удалены безвозвратно, отката нет!${NC}"
    echo
    echo -e "  ${RED}0)${NC} Не трогать"
    echo
    while true; do
        read -r -p "Выберите (0-2): " choice
        case "$choice" in
            1) queue_port_release "$c" backup
               log INFO "Запланировано: остановить '${c}' и сохранить его данные в резервную копию"
               return 0 ;;
            2) log WARN "Удаление без резервной копии — необратимо!"
               if ask_yes_no_word "Подтвердить удаление '${c}' без резервной копии?"; then
                   queue_port_release "$c" delete
                   log INFO "Запланировано: удалить '${c}' вместе с данными"
                   return 0
               fi
               log WARN "Отменено" ;;
            0) return 1 ;;
            *) log WARN "Введите 0, 1 или 2" ;;
        esac
    done
}

find_conflict_container() {
    # Docker-контейнер, занимающий порт $1 (через опубликованные порты или процесс из ss).
    # Протокол в шаблоне обязателен: docker печатает «0.0.0.0:443->443/tcp», и без «/tcp»
    # под ':443->' попадал контейнер, слушающий тот же номер порта по другому протоколу.
    local c
    c=$(_ssh_cmd "docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -E ':${1}->[0-9]+/tcp' | awk '{print \$1}' | head -1 | tr -d '[:space:]'" 2>/dev/null) || true
    if [[ -z "${c:-}" ]]; then
        local _proc
        _proc=$(execute_remote_output "ss -tlnp 2>/dev/null | grep ':${1} ' | sed 's/.*users:((\"//' | cut -d'\"' -f1") || true
        _proc=$(echo "${_proc:-}" | tr -d '[:space:]')
        [[ -n "$_proc" ]] && \
            c=$(_ssh_cmd "docker ps --format '{{.Names}}' 2>/dev/null | grep -i '${_proc}' | head -1 | tr -d '[:space:]'" 2>/dev/null) || true
    fi
    echo "${c:-}"
}

warn_non443() {
    [[ "$XRAY_PORT" == "443" ]] && return 0
    log WARN "Reality на порту ${XRAY_PORT} (не 443): рекомендуемый порт для Reality — 443."
}

# Стоит ли контейнер уже в очереди на снятие.
port_release_queued() {   # $1 = имя контейнера; 0 = стоит
    local c="$1" i=0 n=${#PORT_RELEASE_NAMES[@]}
    while [[ $i -lt $n ]]; do
        [[ "${PORT_RELEASE_NAMES[$i]}" == "$c" ]] && return 0
        i=$((i+1))
    done
    return 1
}

# Поставить контейнер в очередь на снятие. Повторная постановка того же контейнера не
# дублируется, а более строгий режим побеждает: delete сильнее backup.
queue_port_release() {   # $1 = имя контейнера, $2 = backup|delete
    local c="$1" mode="$2" i=0 n=${#PORT_RELEASE_NAMES[@]}
    while [[ $i -lt $n ]]; do
        if [[ "${PORT_RELEASE_NAMES[$i]}" == "$c" ]]; then
            [[ "$mode" == "delete" ]] && PORT_RELEASE_MODES[i]="delete"
            return 0
        fi
        i=$((i+1))
    done
    PORT_RELEASE_NAMES+=("$c"); PORT_RELEASE_MODES+=("$mode")
}

# Строки сводки о том, что будет сделано с портами, — по одной на каждое запланированное
# действие. Раньше действие было одно, и хватало case.
print_port_plan() {   # $1 = подпись слева
    local label="$1" i=0 n=${#PORT_KILL_SPECS[@]}
    while [[ $i -lt $n ]]; do
        echo -e "  ${label}${YELLOW}процесс на порту ${PORT_KILL_SPECS[$i]} будет завершён${NC}"
        i=$((i+1))
    done
    i=0; n=${#PORT_RELEASE_NAMES[@]}
    while [[ $i -lt $n ]]; do
        if [[ "${PORT_RELEASE_MODES[$i]}" == "delete" ]]; then
            echo -e "  ${label}${RED}контейнер '${PORT_RELEASE_NAMES[$i]}' и его данные будут УДАЛЕНЫ${NC}"
        else
            echo -e "  ${label}${YELLOW}контейнер '${PORT_RELEASE_NAMES[$i]}' будет остановлен, данные — в резервную копию${NC}"
        fi
        i=$((i+1))
    done
}

# Удалял ли владелец этот каталог целиком — тогда копировать нечего.
port_deleted_dir_is() {   # $1 = каталог
    local d="$1" i=0 n=${#PORT_DELETED_DIRS[@]}
    while [[ $i -lt $n ]]; do
        [[ "${PORT_DELETED_DIRS[$i]}" == "$d" ]] && return 0
        i=$((i+1))
    done
    return 1
}

# ТОЛЬКО определяет конфликт и ставит выбранное действие в очередь.
# Само действие (стоп/бэкап/удаление) выполняет apply_port_action() ПОСЛЕ подтверждения установки.
check_port() {
    PORT_KILL_SPECS=(); PORT_RELEASE_NAMES=(); PORT_RELEASE_MODES=()
    log STEP "Проверка занятости порта ${XRAY_PORT}..."
    local info
    if ! info=$(port_listeners "$XRAY_PORT"); then
        log SUCCESS "Порт ${XRAY_PORT}/TCP свободен"; warn_non443; return 0
    fi

    echo; log WARN "Порт ${XRAY_PORT}/TCP занят:"; echo "$info"; echo

    local conflict_container
    conflict_container=$(find_conflict_container "$XRAY_PORT")
    [[ -n "$conflict_container" ]] && \
        { echo -e "  ${CYAN}Занят: Docker-контейнер: ${conflict_container}${NC}"; echo; }

    echo -e "${YELLOW}Варианты:${NC}"
    echo
    # Варианта «другой порт» здесь нет: схеме с доменом нужен именно 443 (HTTPS)
    # и 80 (перенаправление и проверки ACME), Caddy публикует их жёстко. Смена
    # XRAY_PORT влияла бы только на проверки, а развёртывание всё равно шло бы на 443.
    if [[ -n "$conflict_container" ]]; then
        echo -e "  ${YELLOW}1)${NC} Заменить '${conflict_container}' — данные сохранить в резервную копию"
        echo -e "     ${CYAN}   Каталог установки будет перемещён в <каталог>.bak.ДАТА${NC}"
        echo
        echo -e "  ${RED}2)${NC} Удалить '${conflict_container}' полностью и установить новый на порт ${XRAY_PORT}"
        echo -e "     ${RED}   ⚠  Каталог установки, его резервные копии .bak.* и образы Docker${NC}"
        echo -e "     ${RED}      этого контейнера будут удалены безвозвратно, отката нет!${NC}"
    else
        echo -e "  ${YELLOW}1)${NC} Принудительно освободить порт (fuser -k)"
    fi
    echo
    echo -e "  ${RED}0)${NC} Отменить установку"; echo
    echo -e "${CYAN}Выбранное действие будет выполнено только после подтверждения установки.${NC}"; echo

    local max_choice=1
    [[ -n "$conflict_container" ]] && max_choice=2
    local choice
    while true; do
        read -r -p "Выберите (0-${max_choice}): " choice
        case $choice in
            1)
                if [[ -n "$conflict_container" ]]; then
                    queue_port_release "$conflict_container" backup
                    log INFO "Запланировано: остановить '${conflict_container}' и сохранить его данные в резервную копию"
                else
                    PORT_KILL_SPECS+=("${XRAY_PORT}/tcp")
                    log INFO "Запланировано: принудительно освободить порт ${XRAY_PORT}"
                fi
                return 0
                ;;
            2)
                [[ -z "$conflict_container" ]] && { log WARN "Введите 0-${max_choice}"; continue; }
                log WARN "Удаление без резервной копии — необратимо!"
                if ask_yes_no_word "Подтвердить удаление '${conflict_container}' без резервной копии?"; then
                    queue_port_release "$conflict_container" delete
                    log INFO "Запланировано: удалить '${conflict_container}' вместе с данными"
                    return 0
                fi
                log WARN "Отменено"; check_port; return $?
                ;;
            0) log INFO "Установка отменена — сервер не изменён"; exit 0 ;;
            *) log WARN "Введите 0-${max_choice}" ;;
        esac
    done
}

# Каталог данных конфликтующего контейнера: по метке docker compose, иначе /opt/<имя>
conflict_data_dir() {
    local c="$1" d
    d=$(execute_remote_output \
        "docker inspect '${c}' --format '{{index .Config.Labels \"com.docker.compose.project.working_dir\"}}' 2>/dev/null") || true
    d=$(echo "${d:-}" | tr -d '[:space:]')
    [[ -z "$d" || "$d" == "<no value>" ]] && d="/opt/${c}"
    echo "$d"
}

# Снять привязку сертификата acme.sh к каталогу, которого больше нет по прежнему пути.
# acme.sh держит в <домен>.conf пути установки и reloadcmd; после переименования каталога
# cron четыре раза в сутки пытался бы положить сертификат в исчезнувший путь и выполнить
# «cd <каталог> && docker compose restart caddy». Сам сертификат не удаляем: он ещё
# пригодится, а привязку заново проставит setup_cert_renewal следующей установки.
detach_acme_cert() {   # $1 = домен
    local dom="$1" conf="/root/.acme.sh/${1}_ecc/${1}.conf"
    execute_remote "
        if [ -f '${conf}' ]; then
            sed -i \"s|^Le_RealKeyPath=.*|Le_RealKeyPath=''|; s|^Le_RealFullChainPath=.*|Le_RealFullChainPath=''|; s|^Le_RealCertPath=.*|Le_RealCertPath=''|; s|^Le_ReloadCmd=.*|Le_ReloadCmd=''|\" '${conf}'
            echo 'acme.sh: привязка к прежнему каталогу снята, сертификат ${dom} сохранён'
        else
            echo 'acme.sh: записей для ${dom} нет'
        fi" "Отвязка сертификата ${dom} от прежнего каталога" 1 || true
}

# Снять один контейнер: остановить его compose-проект, затем либо сохранить каталог в
# резервную копию, либо удалить вместе с копиями и образами.
release_one_container() {   # $1 = имя контейнера, $2 = backup|delete
    local c="$1" mode="$2" d conflict_repo=""
    d=$(conflict_data_dir "$c")
    # Образ читаем ДО остановки: после docker rm инспектировать уже нечего
    conflict_repo=$(execute_remote_output "docker inspect '${c}' --format '{{.Config.Image}}' 2>/dev/null" | tr -d '[:space:]') || conflict_repo=""
    conflict_repo="${conflict_repo%%:*}"
    # Останавливаем весь compose-проект (например xray + caddy), если каталог с compose найден
    execute_remote "
        if [ -f '${d}/docker-compose.yml' ]; then cd '${d}' && docker compose down -v --remove-orphans 2>/dev/null || true; fi
        docker stop '${c}' 2>/dev/null || true; docker rm -v '${c}' 2>/dev/null || true" \
        "Остановка '${c}'" 1
    [[ "$mode" == "delete" ]] && PORT_DELETED_DIRS+=("$d")
    if [[ "$mode" == "backup" ]]; then
        # Метка времени — серверная (RT-08)
        local bak
        bak=$(execute_remote_output \
            "if [ -d '${d}' ]; then b='${d}.bak.'\$(date +%Y%m%d_%H%M%S); mv '${d}' \"\$b\" && echo \"\$b\"; fi") || true
        bak=$(echo "${bak:-}" | tr -d '[:space:]')
        if [[ -n "$bak" ]]; then
            log SUCCESS "Данные '${c}' сохранены в ${bak}"
            # Каталог переехал — снимаем привязку acme.sh к прежнему пути. Ветка
            # ниже делает то же для полного удаления, только там сертификат ещё и
            # удаляется; здесь владелец просил данные сохранить.
            local dom_bak
            dom_bak=$(execute_remote_output "grep -m1 '^Домен:' '${bak}/users.txt' 2>/dev/null | awk '{print \$2}'" | tr -d '[:space:]') || true
            if [[ -n "$dom_bak" ]]; then
                detach_acme_cert "$dom_bak"
            fi
        else
            log WARN "Каталог данных '${d}' не найден — бэкап не создан"
        fi
    else
        # TLS-проект: убрать сертификат и задание acme.sh (иначе cron будет вызывать reloadcmd на удалённый каталог)
        local dom
        dom=$(execute_remote_output "grep -m1 '^Домен:' '${d}/users.txt' 2>/dev/null | awk '{print \$2}'" | tr -d '[:space:]') || true
        if [[ -n "$dom" ]]; then
            execute_remote "[ -x /root/.acme.sh/acme.sh ] && /root/.acme.sh/acme.sh --remove -d '${dom}' --ecc >/dev/null 2>&1; rm -rf \"/root/.acme.sh/${dom}_ecc\"; echo 'acme.sh: сертификат и задание для ${dom} удалены'" "Очистка acme.sh (${dom})" 1 || true
        fi
        # «Полностью» — значит полностью: каталог, его резервные копии и образы того
        # же репозитория, кроме образа, который сейчас устанавливается.
        execute_remote "rm -rf '${d}' '${d}'.bak.* 2>/dev/null || true" "Удаление данных и резервных копий '${d}'" 1
        if [[ -n "$conflict_repo" ]]; then
            execute_remote "for img in \$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^${conflict_repo}:'); do
                    [ \"\$img\" = '$XRAY_IMAGE' ] && { echo \"оставлен (нужен для установки): \$img\"; continue; }
                    docker rmi \"\$img\" >/dev/null 2>&1 && echo \"удалён образ: \$img\" || echo \"занят другим контейнером, оставлен: \$img\"
                done" "Удаление образов ${conflict_repo}" 1 || true
        else
            log INFO "Образ конфликтующего контейнера определить не удалось — образы не трогаем"
        fi
    fi
}

# Освобождение портов. Проходим по очереди, а не выполняем одно действие: принудительное
# освобождение основного порта — отдельный флаг, поэтому случай «посторонний процесс на
# основном порту плюс контейнер на дополнительном» отрабатывается целиком.
apply_port_action() {
    local nk=${#PORT_KILL_SPECS[@]} n=${#PORT_RELEASE_NAMES[@]} i=0 spec
    if [[ $nk -eq 0 && $n -eq 0 ]]; then
        log SUCCESS "Порт ${XRAY_PORT} свободен — действий не требуется"; return 0
    fi
    while [[ $i -lt $nk ]]; do
        spec="${PORT_KILL_SPECS[$i]}"
        execute_remote "fuser -k ${spec} 2>/dev/null || true" "Освобождение порта ${spec}" 1
        i=$((i+1))
    done
    i=0
    while [[ $i -lt $n ]]; do
        release_one_container "${PORT_RELEASE_NAMES[$i]}" "${PORT_RELEASE_MODES[$i]}"
        i=$((i+1))
    done
    sleep "$WAIT_PORT_RELEASE"
    local still
    if still=$(port_listeners "$XRAY_PORT"); then
        log ERROR "Порт ${XRAY_PORT} по-прежнему занят — установка прервана"
        log INFO "Порт удерживает:"; echo "$still"
        log INFO "Освободите порт вручную или запустите установку заново и выберите другой порт"
        exit 1
    fi
    log SUCCESS "Порт ${XRAY_PORT} освобождён"
}

backup_existing_install() {
    # Пользователь выбрал «удалить полностью» именно этот каталог — копии быть не должно.
    # Без этой проверки копировался бы каталог, который скрипт создал сам уже после удаления.
    if port_deleted_dir_is "$INSTALL_DIR"; then
        log INFO "Выбрано полное удаление ${INSTALL_DIR} — резервная копия не создаётся"
        return 0
    fi
    # Если в INSTALL_DIR уже есть установка (тот же порт/имя контейнера) — копия перед перезаписью
    local bak
    bak=$(execute_remote_output \
        "if [ -d '${INSTALL_DIR}' ] && [ -n \"\$(ls -A '${INSTALL_DIR}' 2>/dev/null)\" ]; then \
            b='${INSTALL_DIR}.bak.'\$(date +%Y%m%d_%H%M%S); cp -a '${INSTALL_DIR}' \"\$b\" && echo \"\$b\"; fi") || true
    bak=$(echo "${bak:-}" | tr -d '[:space:]')
    if [[ -n "$bak" ]]; then
        BACKUP_DIR="$bak"
        log WARN "В ${INSTALL_DIR} уже была установка — копия сохранена в ${BACKUP_DIR}"
    else
        log INFO "Предыдущей установки в ${INSTALL_DIR} нет"
    fi
}

cleanup_old_images() {
    # Удаляем старые теги того же репозитория (не используемые контейнерами — иначе docker rmi откажет)
    local repo="${XRAY_IMAGE%%:*}"
    execute_remote \
        "docker images --format '{{.Repository}}:{{.Tag}}' | grep '^${repo}:' | grep -vx '${XRAY_IMAGE}' | xargs -r docker rmi 2>/dev/null || true" \
        "Удаление старых образов ${repo}" 1 || true
}


# ============================================
# ГЕНЕРАЦИЯ ШАБЛОННОГО САЙТА
# ============================================

generate_static_site() {
    # Принимает путь к директории как аргумент
    local tmp_site="${1:-$(mktemp -d)}"

    # Учебный сайт «Как наш мир превращается в 0 и 1»: главная, три страницы и общий
    # style.css. Ссылки относительные, внешних зависимостей нет, вкладки — на CSS.
    # Шапка и подвал общие для всех страниц.
    local nav foot
    nav='<nav id="top">
    <a class="logo" href="index.html">0 и 1</a>
    <div class="links"><a href="index.html">Главная</a><a href="text.html">Текст</a><a href="images.html">Изображения</a><a href="sound.html">Звук</a></div>
</nav>'
    foot='<footer>Учебный материал о двоичном кодировании · <a href="#top">Наверх</a></footer>'
    site_page() {   # $1 = заголовок, $2 = описание; содержимое страницы — со стандартного ввода
        printf '<!DOCTYPE html>\n<html lang="ru">\n<head>\n    <meta charset="UTF-8">\n    <meta name="viewport" content="width=device-width, initial-scale=1.0">\n    <meta name="description" content="%s">\n    <title>%s</title>\n    <link rel="icon" type="image/x-icon" href="favicon.ico">\n    <link rel="stylesheet" href="style.css">\n</head>\n<body>\n%s\n' "$2" "$1" "$nav"
        cat
        printf '%s\n</body>\n</html>\n' "$foot"
    }

    cat > "${tmp_site}/style.css" << 'CSS'
:root{--bg:#f8fafc;--fg:#0f172a;--muted:#475569;--card:#fff;--line:#e2e8f0;--accent:#2563eb;--code:#eef2ff}
@media (prefers-color-scheme:dark){:root{--bg:#0f1117;--fg:#e2e8f0;--muted:#94a3b8;--card:#161b26;--line:#252c3b;--accent:#60a5fa;--code:#1e2433}}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:var(--bg);color:var(--fg);line-height:1.65}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
code,.bits{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
code{background:var(--code);padding:.1rem .35rem;border-radius:4px;font-size:.9em}
nav{max-width:960px;margin:0 auto;padding:1.25rem 1.5rem;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:.5rem}
.logo{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-weight:700;color:var(--fg)}
nav .links a{margin-left:1.25rem;color:var(--muted);font-size:.95rem}
main{max-width:960px;margin:0 auto;padding:0 1.5rem 3rem}
.hero{padding:3rem 0 2rem}
.hero h1{font-size:2.6rem;line-height:1.15;letter-spacing:-.02em;margin-bottom:1rem}
.lead{font-size:1.15rem;color:var(--muted);max-width:640px}
.bits{color:var(--accent);letter-spacing:.12em;margin-top:1.5rem;font-size:.95rem;overflow-wrap:anywhere}
h2{font-size:1.6rem;margin:2.5rem 0 1rem}
.cards{display:grid;grid-template-columns:repeat(3,1fr);gap:1rem}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:1.25rem}
.card h3{font-size:1.05rem;margin-bottom:.4rem}
.card p,.tab p{color:var(--muted)}
.tabs input{position:absolute;opacity:0;pointer-events:none}
.labels label{display:inline-block;padding:.55rem 1.1rem;border:1px solid var(--line);border-bottom:0;border-radius:8px 8px 0 0;margin-right:.25rem;cursor:pointer;color:var(--muted)}
.tab{display:none;background:var(--card);border:1px solid var(--line);border-radius:0 10px 10px 10px;padding:1.5rem}
.tab p+p{margin-top:.75rem}
#t-text:checked~#p-text,#t-img:checked~#p-img,#t-sound:checked~#p-sound{display:block}
#t-text:checked~.labels [for=t-text],#t-img:checked~.labels [for=t-img],#t-sound:checked~.labels [for=t-sound]{background:var(--card);color:var(--fg);font-weight:600}
.tabs input:focus-visible~.labels label{outline-offset:2px}
article h1{font-size:2.2rem;line-height:1.2;margin:2rem 0 1rem}
article p{margin:.75rem 0}
table{width:100%;border-collapse:collapse;margin:1rem 0;background:var(--card)}
th,td{border:1px solid var(--line);padding:.55rem .75rem;text-align:left}
th{color:var(--muted);font-weight:600}
td code{background:none;padding:0}
.back{display:inline-block;margin-top:2rem}
footer{border-top:1px solid var(--line);text-align:center;padding:1.5rem;color:var(--muted);font-size:.9rem}
@media(max-width:720px){.cards{grid-template-columns:1fr}.hero h1{font-size:2rem}nav .links a{margin:0 1rem 0 0}}
CSS

    site_page "Как наш мир превращается в 0 и 1" \
        "Почему компьютеры используют двоичный код и как в нём записываются текст, изображения и звук" \
        > "${tmp_site}/index.html" << 'HTML'
<main>
<section class="hero">
    <h1>Как наш мир превращается в 0 и 1</h1>
    <p class="lead">Тексты, фотографии и музыка внутри компьютера — это длинные цепочки нулей и единиц. Разберёмся, почему так устроено и как это работает.</p>
    <p class="bits">01001000 01101001 00100001</p>
</section>

<h2>Три причины двоичного кода</h2>
<div class="cards">
    <div class="card"><h3>Надёжность</h3><p>Двоичному сигналу хватает двух состояний: ток есть — тока нет. Их легко различить даже при помехах, поэтому данные не искажаются.</p></div>
    <div class="card"><h3>Простота</h3><p>Каждый бит хранит и обрабатывает транзистор — микроскопический выключатель. В современном процессоре их миллиарды.</p></div>
    <div class="card"><h3>Универсальность</h3><p>Любую информацию можно свести к последовательности ответов «да» или «нет». Один такой ответ — это бит.</p></div>
</div>

<h2>Как кодируется информация</h2>
<div class="tabs">
    <input type="radio" name="tab" id="t-text" checked>
    <input type="radio" name="tab" id="t-img">
    <input type="radio" name="tab" id="t-sound">
    <div class="labels"><label for="t-text">Текст</label><label for="t-img">Изображения</label><label for="t-sound">Звук</label></div>
    <div class="tab" id="p-text">
        <p>Каждому символу присвоен номер в таблице Unicode. Буква A — номер 65, в двоичном виде <code>01000001</code>. В кодировке UTF-8 латиница занимает 1 байт, кириллица — 2.</p>
        <p><a href="text.html">Подробнее о тексте →</a></p>
    </div>
    <div class="tab" id="p-img">
        <p>Изображение — это сетка точек-пикселей. Цвет пикселя задают три числа: яркость красного, зелёного и синего каналов от 0 до 255, по 8 бит на каждый. Чистый красный — <code>11111111 00000000 00000000</code>.</p>
        <p><a href="images.html">Подробнее об изображениях →</a></p>
    </div>
    <div class="tab" id="p-sound">
        <p>Микрофон превращает звук в электрический сигнал. При оцифровке его измеряют много раз в секунду — для качества CD 44 100 раз — и каждое измерение записывают 16-битным числом.</p>
        <p><a href="sound.html">Подробнее о звуке →</a></p>
    </div>
</div>
</main>
HTML

    site_page "Текст — как наш мир превращается в 0 и 1" \
        "Как символы превращаются в числа Unicode и байты UTF-8" \
        > "${tmp_site}/text.html" << 'HTML'
<main><article>
<h1>Как текст становится нулями и единицами</h1>
<p>Компьютер хранит не буквы, а числа. Каждому символу присвоен номер в международной таблице Unicode — в ней больше 150 тысяч символов всех письменностей мира.</p>
<h2>От символа к числу</h2>
<table>
    <tr><th>Символ</th><th>Номер в Unicode</th><th>Двоичный код</th></tr>
    <tr><td>A</td><td>65</td><td><code>01000001</code></td></tr>
    <tr><td>a</td><td>97</td><td><code>01100001</code></td></tr>
    <tr><td>0 (цифра)</td><td>48</td><td><code>00110000</code></td></tr>
    <tr><td>пробел</td><td>32</td><td><code>00100000</code></td></tr>
</table>
<p>Слово «Hi»: H — 72, i — 105. В памяти это <code>01001000 01101001</code>.</p>
<h2>UTF-8: от числа к байтам</h2>
<p>Номер символа записывается байтами по правилам кодировки UTF-8: латиница и цифры занимают 1 байт, кириллица — 2, иероглифы — 3, эмодзи — 4.</p>
<table>
    <tr><th>Символ</th><th>Байты UTF-8</th></tr>
    <tr><td>A</td><td><code>01000001</code></td></tr>
    <tr><td>Я</td><td><code>11010000 10101111</code></td></tr>
    <tr><td>😀</td><td><code>11110000 10011111 10011000 10000000</code></td></tr>
</table>
<p>Текстовый файл — это последовательность таких байтов. Программа читает их и по той же таблице превращает обратно в символы.</p>
<a class="back" href="index.html">← На главную</a>
</article></main>
HTML

    site_page "Изображения — как наш мир превращается в 0 и 1" \
        "Как пиксели и цвета RGB превращаются в биты" \
        > "${tmp_site}/images.html" << 'HTML'
<main><article>
<h1>Как изображение становится нулями и единицами</h1>
<p>Цифровое изображение — это сетка крошечных квадратов, пикселей. Экран Full HD содержит 1920 × 1080 = 2 073 600 пикселей.</p>
<h2>Цвет — это три числа</h2>
<p>Каждый пиксель смешивает красный (R), зелёный (G) и синий (B) свет. Яркость каждого канала — число от 0 до 255, то есть 8 бит. Вместе — 24 бита на пиксель и 16 777 216 возможных цветов.</p>
<table>
    <tr><th>Цвет</th><th>R, G, B</th><th>Двоичный код</th></tr>
    <tr><td>Чёрный</td><td>0, 0, 0</td><td><code>00000000 00000000 00000000</code></td></tr>
    <tr><td>Белый</td><td>255, 255, 255</td><td><code>11111111 11111111 11111111</code></td></tr>
    <tr><td>Красный</td><td>255, 0, 0</td><td><code>11111111 00000000 00000000</code></td></tr>
    <tr><td>Жёлтый</td><td>255, 255, 0</td><td><code>11111111 11111111 00000000</code></td></tr>
</table>
<h2>Сколько это весит</h2>
<p>Кадр Full HD без сжатия: 2 073 600 пикселей × 3 байта ≈ 6,2 МБ. Форматы PNG и JPEG уменьшают размер: PNG — без потерь, JPEG — отбрасывая детали, малозаметные глазу.</p>
<a class="back" href="index.html">← На главную</a>
</article></main>
HTML

    site_page "Звук — как наш мир превращается в 0 и 1" \
        "Как звуковая волна превращается в последовательность чисел" \
        > "${tmp_site}/sound.html" << 'HTML'
<main><article>
<h1>Как звук становится нулями и единицами</h1>
<p>Звук — это колебания воздуха. Микрофон превращает их в электрический сигнал, напряжение которого плавно меняется вслед за звуковой волной.</p>
<h2>Дискретизация</h2>
<p>Сигнал измеряют через равные промежутки времени. Для качества CD — 44 100 раз в секунду (44,1 кГц). По теореме Котельникова частота измерений должна быть больше удвоенной высшей частоты сигнала: человек слышит примерно до 20 кГц, поэтому 44,1 кГц достаточно.</p>
<h2>Квантование</h2>
<p>Каждое измерение округляется до ближайшего из фиксированных уровней и записывается числом. При 16 битах таких уровней 65 536.</p>
<h2>Сколько это весит</h2>
<p>Стереозапись качества CD: 44 100 измерений × 16 бит × 2 канала = 1 411 200 бит в секунду. Минута такого звука — около 10,6 МБ. Форматы MP3 и AAC сжимают звук в 10 раз и более, убирая то, что слух почти не воспринимает.</p>
<a class="back" href="index.html">← На главную</a>
</article></main>
HTML

    # robots.txt
    # Без Disallow: прежние строки перечисляли /api/ и /internal/ независимо от
    # выбранного пути — то есть либо подсказывали префикс туннеля, либо указывали
    # на разделы, которых на сайте нет.
    cat > "${tmp_site}/robots.txt" << 'ROBOTS'
User-agent: *
Allow: /

Sitemap: https://DOMAIN_PLACEHOLDER/sitemap.xml
ROBOTS

    # sitemap.xml — все страницы сайта
    cat > "${tmp_site}/sitemap.xml" << 'SITEMAP'
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://DOMAIN_PLACEHOLDER/</loc></url>
  <url><loc>https://DOMAIN_PLACEHOLDER/text.html</loc></url>
  <url><loc>https://DOMAIN_PLACEHOLDER/images.html</loc></url>
  <url><loc>https://DOMAIN_PLACEHOLDER/sound.html</loc></url>
</urlset>
SITEMAP

    # Favicon — минимальный PNG (1x1 прозрачный)
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' \
        > "${tmp_site}/favicon.ico"
}

# ============================================
# ГЕНЕРАЦИЯ XRAY КОНФИГА
# ============================================

generate_xray_config() {
    local clients_json="[]"
    for ((i=0; i<USER_COUNT; i++)); do
        clients_json=$(echo "$clients_json" | jq \
            --arg id    "${USER_UUIDS[$i]}" \
            --arg email "${USER_NAMES[$i]}" \
            '. += [{"id": $id, "email": $email}]'
        )
    done

    jq -n \
        --argjson clients "$clients_json" \
        --arg xhttp_port "$XRAY_XHTTP_PORT" \
        --arg xhttp_path "$XHTTP_PATH" \
        '{
            "log": {"loglevel": "warning"},
            "inbounds": [{
                "port": ($xhttp_port | tonumber),
                "protocol": "vless",
                "settings": {"clients": $clients, "decryption": "none"},
                "streamSettings": {
                    "network": "xhttp",
                    "security": "none",
                    "xhttpSettings": {
                        "mode": "auto",
                        "path": $xhttp_path,
                        "extra": {
                            "scMaxConcurrentPosts": 100,
                            "scMaxEachPostBytes": "1000000",
                            "scMinPostsIntervalMs": 10,
                            "xPaddingBytes": "100-1000"
                        }
                    },
                    "sockopt": {
                        "trustedXForwardedFor": ["172.16.0.0/12", "192.168.0.0/16", "10.0.0.0/8"]
                    }
                }
            }],
            "outbounds": [{"protocol": "freedom", "tag": "direct"}],
            "routing": {"domainStrategy": "AsIs", "rules": []}
        }'
}

# ============================================
# ГЕНЕРАЦИЯ CADDY КОНФИГА
# ============================================

generate_caddyfile() {
    # handle, а не handle_path: префикс не срезается, Xray получает полный URI,
    # совпадающий с xhttpSettings.path. Звёздочка обязательна — XHTTP дописывает
    # к пути свои сегменты, нужно префиксное совпадение.
    #
    # handle_response ниже — единообразная обработка ошибок: ответы Xray с кодом 4xx
    # (404, а на вложенных адресах — 400) заменяются страницей сайта, как на любом
    # другом пути домена. Валидные XHTTP-ответы идут с кодом 200 и под правило не попадают.
    local xhttp_handle="${XHTTP_PATH}*"
    printf '%s\n' \
        "${TLS_DOMAIN} {" \
        "    tls /etc/caddy/certs/fullchain.pem /etc/caddy/certs/privkey.pem" \
        "    log {" \
        "        output file /var/log/caddy/access.log {" \
        "            roll_size 10mb" \
        "            roll_keep 3" \
        "        }" \
        "    }" \
        "    handle ${xhttp_handle} {" \
        "        reverse_proxy xray:${XRAY_XHTTP_PORT} {" \
        "            @notxhttp status 4xx" \
        "            handle_response @notxhttp {" \
        "                root * /var/www/site" \
        "                rewrite * /index.html" \
        "                file_server" \
        "            }" \
        "        }" \
        "    }" \
        "    handle {" \
        "        root * /var/www/site" \
        "        file_server {" \
        "            hide .git .svn .hg .env .DS_Store" \
        "        }" \
        "        try_files {path} /index.html" \
        "    }" \
        "}"
}

# ============================================
# DOCKER-COMPOSE
# ============================================

generate_docker_compose() {
    jq -n \
        --arg xray_image     "$XRAY_IMAGE" \
        --arg xray_container "$CONTAINER_NAME" \
        --arg caddy_container "$CADDY_CONTAINER" \
        '{
            "services": {
                "xray": {
                    "image": $xray_image,
                    "container_name": $xray_container,
                    "restart": "unless-stopped",
                    "volumes": [
                        "./config/xray.json:/etc/xray/config.json:ro",
                        "./log/xray:/var/log/xray",
                        "xray-etc:/usr/local/etc/xray"
                    ],
                    "command": ["run", "-config", "/etc/xray/config.json"],
                    "security_opt": ["no-new-privileges:true"],
                    "cap_drop": ["ALL"],
                    "networks": ["xray-net"],
                    "logging": {
                        "driver": "json-file",
                        "options": {"max-size": "10m", "max-file": "3"}
                    }
                },
                "caddy": {
                    "image": "caddy:2-alpine",
                    "container_name": $caddy_container,
                    "restart": "unless-stopped",
                    "ports": ["443:443/tcp", "443:443/udp", "80:80/tcp"],
                    "volumes": [
                        "./config/Caddyfile:/etc/caddy/Caddyfile:ro",
                        "./certs:/etc/caddy/certs:ro",
                        "./site:/var/www/site:ro",
                        "./log/caddy:/var/log/caddy",
                        "./caddy_data:/data",
                        "./caddy_config:/config"
                    ],
                    "security_opt": ["no-new-privileges:true"],
                    "cap_drop": ["ALL"],
                    "cap_add": ["NET_BIND_SERVICE"],
                    "networks": ["xray-net"],
                    "logging": {
                        "driver": "json-file",
                        "options": {"max-size": "10m", "max-file": "3"}
                    }
                }
            },
            "networks": {
                "xray-net": {"driver": "bridge"}
            },
            "volumes": {"xray-etc": {}}
        }'
}

# ============================================
# TLS СЕРТИФИКАТ (acme.sh + Cloudflare DNS-01)
# ============================================

setup_tls_certificate() {
    print_step "TLS" "Получение сертификата Let's Encrypt (acme.sh + Cloudflare DNS)"

    # Утилиты для DNS-проверки и acme.sh — ДО проверки DNS (на чистой системе dig может отсутствовать)
    execute_remote "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl socat dnsutils >/dev/null 2>&1 || true" \
        "Установка curl/socat/dnsutils"

    # Проверка DNS
    log STEP "Проверка DNS: ${TLS_DOMAIN} → ${PUBLIC_IP}..."
    local dns_ip
    dns_ip=$(execute_remote_output "dig +short '${TLS_DOMAIN}' A 2>/dev/null | grep -E '^[0-9.]+$' | tail -1") || true
    dns_ip=$(echo "${dns_ip:-}" | tr -d '[:space:]')
    if [[ -z "$dns_ip" ]]; then
        dns_ip=$(execute_remote_output "getent ahostsv4 '${TLS_DOMAIN}' 2>/dev/null | awk '{print \$1}' | head -1") || true
        dns_ip=$(echo "${dns_ip:-}" | tr -d '[:space:]')
    fi

    # Основная (интерактивная) проверка DNS сделана до подтверждения (precheck_dns); здесь — контроль
    if [[ "$dns_ip" == "$PUBLIC_IP" ]]; then
        log SUCCESS "DNS корректен: ${TLS_DOMAIN} → ${dns_ip}"
    else
        log WARN "DNS сейчас: '${dns_ip:-нет ответа}', ожидается ${PUBLIC_IP} — выпуск через DNS-01 всё равно возможен"
    fi

    # Установка acme.sh
    execute_remote "[ -f /root/.acme.sh/acme.sh ] || curl -fsSL https://get.acme.sh | sh -s email=admin@${TLS_DOMAIN}" \
        "Установка acme.sh"

    # Директория сертификатов
    execute_remote "mkdir -p ${INSTALL_DIR}/certs" "Создание директории сертификатов"

    # Запись CF_Token через скрипт-файл
    local tmp_token; tmp_token=$(create_temp)
    {
        echo '#!/bin/bash'
        echo 'mkdir -p /root/.acme.sh'
        printf 'export CF_Token=%q\n' "${CF_API_TOKEN}"
        echo 'if grep -q CF_Token /root/.acme.sh/account.conf 2>/dev/null; then'
        printf '    sed -i "s|CF_Token=.*|CF_Token=%q|" /root/.acme.sh/account.conf\n' "${CF_API_TOKEN}"
        echo 'else'
        printf '    echo "CF_Token=%q" >> /root/.acme.sh/account.conf\n' "${CF_API_TOKEN}"
        echo 'fi'
        echo 'grep -q CF_Token /root/.acme.sh/account.conf && echo CF_Token_OK || { echo CF_Token_FAIL; exit 1; }'
    } > "$tmp_token"
    copy_to_remote "$tmp_token" "/tmp/write_cf_token.sh" "Загрузка скрипта токена"
    execute_remote "bash /tmp/write_cf_token.sh && rm -f /tmp/write_cf_token.sh" "Запись Cloudflare токена"

    # Получение сертификата
    local tmp_acme; tmp_acme=$(create_temp)
    {
        echo '#!/bin/bash'
        echo 'set -e'
        printf 'export CF_Token=%q\n' "${CF_API_TOKEN}"
        echo 'export CF_Account_ID=""'
        echo "/root/.acme.sh/acme.sh --issue \\"
        echo "    --dns dns_cf \\"
        echo "    -d '${TLS_DOMAIN}' \\"
        echo "    --server letsencrypt \\"
        echo "    --log"
    } > "$tmp_acme"
    copy_to_remote "$tmp_acme" "/tmp/run_acme.sh" "Загрузка скрипта acme.sh"

    local issue_out issue_rc=0
    issue_out=$(execute_remote_output "bash /tmp/run_acme.sh 2>&1; rc=\$?; rm -f /tmp/run_acme.sh; exit \$rc") || issue_rc=$?
    echo "$issue_out"
    # acme.sh: 0 — выпущен; 2 — пропуск (сертификат уже есть и не требует обновления)
    if [[ $issue_rc -eq 0 ]]; then
        log SUCCESS "Сертификат выпущен"
    elif [[ $issue_rc -eq 2 ]] || echo "$issue_out" | grep -qE "Domains not changed|Skipping"; then
        log SUCCESS "Сертификат уже выпущен ранее — используем существующий"
    else
        log ERROR "Ошибка получения сертификата (acme.sh exit: $issue_rc)"
        return 1
    fi

    # Установка сертификата в нужные пути
    execute_remote "
        /root/.acme.sh/acme.sh --install-cert \
            -d '${TLS_DOMAIN}' \
            --key-file      '${INSTALL_DIR}/certs/privkey.pem' \
            --fullchain-file '${INSTALL_DIR}/certs/fullchain.pem'
    " "Установка сертификата"

    # Проверка
    execute_remote \
        "[ -f '${INSTALL_DIR}/certs/fullchain.pem' ] && \
         openssl x509 -in '${INSTALL_DIR}/certs/fullchain.pem' -noout -subject -dates 2>/dev/null && \
         echo OK || { echo CERT_NOT_FOUND; exit 1; }" \
        "Проверка сертификата"

    log SUCCESS "Сертификат для ${TLS_DOMAIN} получен"
}

# ============================================
# УСТАНОВКА DOCKER
# ============================================

install_docker() {
    execute_remote "
        i=0
        while fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend               >/dev/null 2>&1; do
            i=\$((i+1))
            [ \$i -gt 60 ] && break
            sleep ${WAIT_APT_LOCK_STEP}
        done
    " "Ожидание-apt-lock"
    execute_remote "DEBIAN_FRONTEND=noninteractive apt-get update -qq" "Обновление пакетов"
    # Полный upgrade — по решению владельца; пропускаем, если обновлять нечего
    execute_remote "
        n=\$(DEBIAN_FRONTEND=noninteractive apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true)
        if [ \"\${n:-0}\" -gt 0 ]; then
            echo \"Пакетов к обновлению: \$n\"
            DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq \
                -o Dpkg::Options::='--force-confdef' -o Dpkg::Options::='--force-confold'
        else
            echo 'Обновлений нет — пропускаем'
        fi" "Обновление системы"
    execute_remote \
        "which docker >/dev/null 2>&1 || (curl -fsSL https://get.docker.com | sh)" \
        "Установка Docker"
    # Обновление пакетов Docker — шаг необязательный: он имеет смысл только когда Docker
    # пришёл из официального репозитория. Прежде наличие репозитория определялось по файлам,
    # среди них ключ в /etc/apt/keyrings, — а ключ остаётся и после удаления репозитория. В
    # таком состоянии apt не находил docker-compose-plugin, объяснение уходило в /dev/null,
    # шаг возвращал ненулевой код, и set -o errexit убивал установку, не назвав причины.
    # Теперь условие смотрит только на файлы репозитория, ошибка apt видна, Compose ставит
    # отдельный блок ниже (у него есть запасной пакет дистрибутива), а неудача этого шага
    # установку не прерывает: годен ли Docker, решают проверки следом.
    execute_remote "
        if [ -f /etc/apt/sources.list.d/docker.list ] \
        || [ -f /etc/apt/sources.list.d/docker.sources ]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                docker-ce docker-ce-cli containerd.io \
            && echo 'Пакеты Docker обновлены'
        else
            echo 'Официального репозитория Docker нет — обновление пакетов пропущено'
        fi
    " "Обновление Docker" 1 || log WARN "Обновить пакеты Docker не удалось — продолжаем с уже установленным"
    execute_remote "systemctl start docker && systemctl enable docker" "Запуск Docker" 1
    # Плагин Compose выше ставится только вместе с пакетами официального репозитория, то
    # есть Docker из snap или из пакетов дистрибутива его не получает. Прежде установка в
    # таком случае обрывалась на проверке ниже, и притом молча: у неё был пустой заголовок,
    # поэтому причина не называлась. Теперь плагин доставляется отдельно, а при неудаче
    # отказ объясняется и подсказывает, что сделать вручную. Плагин ищем сначала в
    # официальном репозитории (docker-compose-plugin), затем в репозитории дистрибутива
    # (docker-compose-v2) — второй закрывает случай Docker из сторонних пакетов.
    execute_remote "
        if docker compose version >/dev/null 2>&1; then
            echo 'docker compose на месте'
        else
            echo 'docker compose отсутствует — устанавливаем плагин'
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-plugin 2>/dev/null \
                || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-v2 2>/dev/null \
                || true
            docker compose version >/dev/null 2>&1
        fi" "Проверка docker compose" 1 || {
        log ERROR "docker compose недоступен: Docker установлен не из официального репозитория, а плагин доставить не удалось"
        log ERROR "Установите его вручную (apt-get install docker-compose-plugin) и запустите установку заново"
        exit 1
    }
    execute_remote "docker --version && docker compose version" "Проверка Docker и Compose" 1
}

# ============================================
# HEALTH CHECK
# ============================================

health_check() {
    log STEP "Проверка работоспособности..."
    sleep "$WAIT_CONTAINER_START"

    execute_remote \
        "docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' \
         | grep -E '${CONTAINER_NAME}|${CADDY_CONTAINER}'" "" 1 || true

    local errors=0 c
    for c in "$CONTAINER_NAME" "$CADDY_CONTAINER"; do
        if _ssh_cmd "docker ps --format '{{.Names}}' | grep -q '^${c}$'" 2>/dev/null; then
            log SUCCESS "Контейнер ${c} запущен"
        else
            log ERROR "Контейнер ${c} не запущен"
            execute_remote "docker logs --tail 10 ${c} 2>&1" "" 1 || true
            errors=$((errors+1))
        fi
    done

    if _ssh_cmd "ss -tlnp | grep -q ':443 '" 2>/dev/null; then
        log SUCCESS "Порт TCP 443 слушается"
    else
        log ERROR "Порт 443 не слушается"; errors=$((errors+1))
    fi

    # Реальный HTTPS-ответ сайта через Caddy (локально на сервере, через --resolve)
    local code
    code=$(execute_remote_output \
        "curl -sk -o /dev/null -w '%{http_code}' --max-time ${HTTP_TIMEOUT} --resolve '${TLS_DOMAIN}:443:127.0.0.1' 'https://${TLS_DOMAIN}/'") || true
    code=$(echo "${code:-}" | tr -d '[:space:]')
    if [[ "$code" == "200" ]]; then
        log SUCCESS "HTTPS-сайт отвечает (200)"
    else
        log ERROR "HTTPS-сайт не отвечает (код: ${code:-нет ответа})"; errors=$((errors+1))
    fi

    return $errors
}

# ============================================
# НАСТРОЙКА АВТООБНОВЛЕНИЯ СЕРТИФИКАТА
# ============================================

setup_cert_renewal() {
    execute_remote "
        /root/.acme.sh/acme.sh --install-cert \
            -d '${TLS_DOMAIN}' \
            --key-file      '${INSTALL_DIR}/certs/privkey.pem' \
            --fullchain-file '${INSTALL_DIR}/certs/fullchain.pem' \
            --reloadcmd     'cd ${INSTALL_DIR} && docker compose restart caddy'
    " "Настройка автообновления сертификата"
}

# ============================================
# СКВОЗНАЯ ПРОВЕРКА: временный Xray-клиент на сервере подключается по ссылке
# и делает HTTPS-запрос через туннель. Единственный способ убедиться, что работает.
# ============================================

selftest_connection() {   # $1 = vless-ссылка, $2 = образ, $3 = xtls|teddysun
    local link="$1" image="$2" src="$3"
    local rport ep=""
    rport=$(pick_free_port 20000 20000)
    [[ "$src" == "teddysun" ]] && ep="--entrypoint xray"
    log STEP "Сквозная проверка подключения (клиент Xray на сервере, socks:${rport})..."

    local cfg
    cfg=$(python3 - "$link" "$rport" <<'PY'
import sys, json, urllib.parse
u = sys.argv[1].strip(); port_local = int(sys.argv[2])
body = u[len('vless://'):].split('#')[0]
userinfo, rest = body.split('@', 1)
hostport, _, qs = rest.partition('?')
host, port = hostport.rsplit(':', 1)
q = {k: v[0] for k, v in urllib.parse.parse_qs(qs, keep_blank_values=True).items()}
user = {"id": userinfo, "encryption": "none"}
if q.get('flow'): user['flow'] = q['flow']
ss = {"network": q.get('type', 'tcp'), "security": q.get('security', 'none')}
if ss['security'] == 'reality':
    ss['realitySettings'] = {"serverName": q.get('sni', ''), "fingerprint": q.get('fp', 'chrome'),
                             "publicKey": q.get('pbk', ''), "shortId": q.get('sid', '')}
elif ss['security'] == 'tls':
    ss['tlsSettings'] = {"serverName": q.get('sni', host), "fingerprint": q.get('fp', 'chrome')}
if ss['network'] == 'xhttp':
    x = {"path": q.get('path', '/'), "mode": q.get('mode', 'auto')}
    if q.get('host'): x['host'] = q['host']
    ss['xhttpSettings'] = x
cfg = {"log": {"loglevel": "warning"},
       "inbounds": [{"listen": "127.0.0.1", "port": port_local, "protocol": "socks", "settings": {"udp": False}}],
       "outbounds": [{"protocol": "vless",
                      "settings": {"vnext": [{"address": host, "port": int(port), "users": [user]}]},
                      "streamSettings": ss}]}
print(json.dumps(cfg))
PY
) || { log WARN "Self-test: не удалось собрать конфиг клиента из ссылки"; return 1; }

    local tmp; tmp=$(create_temp); printf '%s\n' "$cfg" > "$tmp"
    local rtmp="/tmp/xray-selftest.$$.json"
    _scp_cmd "$tmp" "${SSH_USER}@${SERVER_IP}:${rtmp}" >/dev/null 2>&1 || { log WARN "Self-test: не удалось загрузить конфиг клиента"; return 1; }

    local out code
    out=$(_ssh_cmd "
        chmod 644 ${rtmp}
        docker rm -f -v xray-selftest >/dev/null 2>&1 || true
        docker run -d --name xray-selftest --network host ${ep} -v ${rtmp}:/etc/xray/config.json:ro ${image} run -config /etc/xray/config.json >/dev/null 2>&1
        sleep ${WAIT_CLIENT_READY}
        code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time ${HTTP_TIMEOUT_TUNNEL} -x socks5h://127.0.0.1:${rport} https://www.gstatic.com/generate_204 2>/dev/null); [ -z \"\$code\" ] && code=000
        echo \"CODE=\$code\"
        [ \"\$code\" != 204 ] && { echo '--- логи клиента:'; docker logs --tail 8 xray-selftest 2>&1; }
        docker rm -f -v xray-selftest >/dev/null 2>&1 || true
        rm -f ${rtmp}" 2>/dev/null) || true
    code=$(echo "$out" | sed -n 's/^CODE=//p' | tail -1)
    if [[ "$code" == "204" ]]; then
        log SUCCESS "Сквозная проверка пройдена: клиент подключился через туннель (HTTP 204)"; return 0
    fi
    log ERROR "Сквозная проверка НЕ пройдена (ответ: ${code:-нет})"
    echo "$out" | grep -v '^CODE='
    return 1
}

# ============================================
# ВЫВОД РЕЗУЛЬТАТА
# ============================================

print_result() {
    print_header "Установка завершена"

    echo -e "${BLUE}Сервер:${NC}"
    echo -e "  Домен:       ${GREEN}${TLS_DOMAIN}${NC}"
    echo -e "  IP:          ${GREEN}${PUBLIC_IP}${NC}"
    echo -e "  Образ Xray:  ${GREEN}${XRAY_IMAGE}${NC}"
    echo -e "  Сертификат:  ${GREEN}Let's Encrypt (автообновление через acme.sh)${NC}"
    echo
    echo -e "${BLUE}Транспорт:${NC}"
    echo -e "  XHTTP path:  ${GREEN}${XHTTP_PATH}${NC}"
    echo
    echo -e "${BLUE}Пользователи:${NC}"
    echo -e "${BLUE}------------------------------------------${NC}"
    for ((i=0; i<USER_COUNT; i++)); do
        local xhttp_link
        xhttp_link="vless://${USER_UUIDS[$i]}@${TLS_DOMAIN}:443?security=tls&sni=${TLS_DOMAIN}&fp=chrome&type=xhttp&path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${XHTTP_PATH}', safe=''))" 2>/dev/null || echo "${XHTTP_PATH}")&host=${TLS_DOMAIN}&mode=auto#${USER_NAMES[$i]}-xhttp"
        echo
        echo -e "  ${GREEN}${USER_NAMES[$i]}${NC}"
        echo -e "  UUID:  ${CYAN}${USER_UUIDS[$i]}${NC}"
        echo -e "  XHTTP: ${YELLOW}${xhttp_link}${NC}"
    done
    echo
    echo -e "${BLUE}------------------------------------------${NC}"
    echo -e "${CYAN}Файлы на сервере:${NC}"
    echo -e "  Конфиг Xray:  ${INSTALL_DIR}/config/xray.json"
    echo -e "  Caddyfile:    ${INSTALL_DIR}/config/Caddyfile"
    echo -e "  Сертификат:   ${INSTALL_DIR}/certs/"
    echo -e "  Сайт:         ${INSTALL_DIR}/site/"
    echo -e "  Ссылки:       ${INSTALL_DIR}/users.txt"
    echo -e "${CYAN}Логи ограничены по размеру:${NC} json-file, до 10 MB × 3 файла (максимум 30 MB)."
    echo
    echo -e "${CYAN}Управление:${NC}"
    echo -e "  Логи Xray:    ssh ${SSH_USER}@${PUBLIC_IP} 'docker logs ${CONTAINER_NAME}'"
    echo -e "  Логи Caddy:   ssh ${SSH_USER}@${PUBLIC_IP} 'docker logs ${CADDY_CONTAINER}'"
    echo -e "  Стоп:         ssh ${SSH_USER}@${PUBLIC_IP} 'cd ${INSTALL_DIR} && docker compose down'"
    echo
}

# ============================================
# СОХРАНЕНИЕ ДАННЫХ
# ============================================

save_server_data() {
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
    local tmp_users; tmp_users=$(create_temp)
    {
        echo "VLESS+XHTTP+TLS+Domain — Пользователи"
        echo "============================================"
        echo "Дата:        $ts"
        echo "Домен:       $TLS_DOMAIN"
        echo "IP:          $PUBLIC_IP"
        echo "Образ:       $XRAY_IMAGE"
        echo "XHTTP path:  $XHTTP_PATH"
            echo "--------------------------------------------"
        for ((i=0; i<USER_COUNT; i++)); do
            echo "Пользователь: ${USER_NAMES[$i]}"
            echo "UUID: ${USER_UUIDS[$i]}"
            local path_encoded
            path_encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${XHTTP_PATH}', safe=''))" 2>/dev/null || echo "${XHTTP_PATH}")
            echo "XHTTP: vless://${USER_UUIDS[$i]}@${TLS_DOMAIN}:443?security=tls&sni=${TLS_DOMAIN}&fp=chrome&type=xhttp&path=${path_encoded}&host=${TLS_DOMAIN}&mode=auto#${USER_NAMES[$i]}"
            echo "--------------------------------------------"
        done
    } > "$tmp_users"
    copy_to_remote "$tmp_users" "/tmp/users.txt" "Загрузка пользователей"
    execute_remote \
        "mv /tmp/users.txt ${INSTALL_DIR}/users.txt && chmod 600 ${INSTALL_DIR}/users.txt" \
        "Сохранение пользователей"
}

# ============================================
# MAIN
# ============================================

main() {
    clear
    print_header "VLESS + XHTTP + TLS · свой домен"
    echo -e "  ${CYAN}Сервер VLESS на своём домене с сертификатом Let's Encrypt${NC}"
    echo -e "  ${CYAN}Caddy :443 → сайт + Xray XHTTP${NC}"
    echo
    acquire_lock

    # Проверка зависимостей
    log STEP "Проверка локальных зависимостей..."
    local missing=()
    for dep in ssh scp jq python3 sshpass; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log ERROR "Отсутствуют: ${missing[*]}"
        log INFO "macOS: brew install ${missing[*]}"
        # sshpass в основном репозитории Homebrew отсутствует — нужен отдельный tap
        [[ " ${missing[*]} " == *" sshpass "* ]] && \
            log INFO "sshpass на macOS: brew install hudochenkov/sshpass/sshpass"
        exit 1
    fi
    log SUCCESS "Все зависимости найдены"

    resolve_stable_version
    echo -e "  ${CYAN}Образ:${NC} xray-official (${XRAY_REPO}) · версия ${XRAY_VERSION}"

    # Шаг 1: Подключение
    print_step 1 "Параметры подключения к серверу"
    get_input "IP адрес сервера" "SERVER_IP" "" "validate_ip" "Некорректный IP"
    echo
    echo -e "${CYAN}Порт SSH:${NC}"
    echo -e "  Если нажать Enter — будет использован стандартный порт 22."
    echo -e "  Если требуется другой порт — введите его вручную."
    get_input "Порт SSH" "SSH_PORT_SSH" "22" "validate_port" "Порт 1-65535"
    echo
    echo -e "${CYAN}Пользователь SSH:${NC}"
    echo -e "  Если нажать Enter — будет использован root."
    echo -e "  Если используется другой логин — введите его вручную."
    get_input "Имя пользователя SSH" "SSH_USER" "root" "validate_user" "Некорректное имя"
    echo
    echo -e "${CYAN}Пароль SSH:${NC}"
    echo -e "  Если настроена авторизация по SSH-ключам, вводить пароль не нужно — просто нажмите Enter."
    read -r -s -p "Пароль SSH: " SSH_PASSWORD; echo
    echo
    # Каталог сокета ControlMaster создаётся здесь, в родительской оболочке: вызовы ssh внутри $(...)
    # идут в подоболочках и иначе каждый заводил бы собственный мастер (и собственную аутентификацию)
    SSH_CM_DIR=$(mktemp -d /tmp/vless-ssh.XXXXXX)

    if ! command -v sshpass &>/dev/null; then
        log ERROR "Требуется sshpass: brew install hudochenkov/sshpass/sshpass"; exit 1
    fi

    # Шаг 2: Проверка сервера
    print_step 2 "Проверка доступности"
    log STEP "Проверка TCP:${SSH_PORT_SSH}..."
    if bash -c "echo >/dev/tcp/${SERVER_IP}/${SSH_PORT_SSH}" 2>/dev/null; then
        log SUCCESS "Сервер доступен (TCP:${SSH_PORT_SSH})"
    else
        log ERROR "Сервер недоступен"; exit 1
    fi

    log STEP "Проверка SSH-аутентификации..."
    local auth_ok=0 auth_err="" attempt retry=0
    for attempt in 1 2 3; do
        auth_err=$(_ssh_cmd "echo SSH_OK" 2>&1) && [[ "$auth_err" == *SSH_OK* ]] && { auth_ok=1; break; }
        [[ $attempt -lt 3 ]] && { log WARN "Попытка ${attempt}/3 не удалась — повтор через ${WAIT_AUTH_RETRY} с..."; sleep "$WAIT_AUTH_RETRY"; }
    done
    # Повторный ввод пароля: не больше трёх раз и по одной проверке на ввод — частые
    # неудачные попытки могут привести к блокировке IP на сервере (например, fail2ban)
    while [[ $auth_ok -eq 0 && $retry -lt 3 ]]; do
        log ERROR "Ошибка SSH-аутентификации: неверный пароль или пользователь, вход по паролю запрещён либо SSH-ключ не установлен на сервере"
        read -r -s -p "Повторите ввод пароля SSH (Enter — выход): " SSH_PASSWORD; echo
        [[ -z "$SSH_PASSWORD" ]] && exit 1
        retry=$((retry + 1))
        auth_err=$(_ssh_cmd "echo SSH_OK" 2>&1) && [[ "$auth_err" == *SSH_OK* ]] && auth_ok=1
    done
    if [[ $auth_ok -eq 1 ]]; then
        log SUCCESS "SSH-аутентификация успешна"
    else
        log ERROR "Ошибка SSH-аутентификации: неверный пароль или пользователь, вход по паролю запрещён либо SSH-ключ не установлен на сервере"
        echo "$auth_err" | grep -v "^$" | tail -3
        exit 1
    fi

    log STEP "Получение публичного IP..."
    PUBLIC_IP=$(execute_remote_output \
        "curl -s --max-time ${HTTP_TIMEOUT} ifconfig.me || curl -s --max-time ${HTTP_TIMEOUT} ipinfo.io/ip || echo '${SERVER_IP}'"
    ) || PUBLIC_IP="$SERVER_IP"
    PUBLIC_IP=$(echo "${PUBLIC_IP:-$SERVER_IP}" | tr -d '[:space:]')
    if ! validate_ip "$PUBLIC_IP"; then
        log WARN "Не удалось определить публичный IP (ответ: '${PUBLIC_IP:0:40}') — используем ${SERVER_IP}"
        PUBLIC_IP="$SERVER_IP"
    fi
    log SUCCESS "Публичный IP: $PUBLIC_IP"

    log STEP "Проверка требований сервера..."
    local srv_info
    srv_info=$(execute_remote_output "
        os=\$(. /etc/os-release 2>/dev/null && echo \"\$ID \$VERSION_ID\" || echo unknown)
        echo \"OS:\$os ARCH:\$(uname -m) MEM:\$(free -m 2>/dev/null | awk '/^Mem:/{print \$2}')MB\"
    ") || true
    log INFO "Сервер: ${srv_info:-неизвестно}"
    if ! echo "${srv_info:-}" | grep -qiE "ubuntu.*(22|24|25|26)"; then
        log WARN "Рекомендуется Ubuntu 22.04+"
        ask_yn "Продолжить?" || exit 0
    fi

    log STEP "Проверка ресурсов сервера..."
    local free_mb mem_mb
    free_mb=$(execute_remote_output "df -Pm / | awk 'NR==2{print \$4}'" | tr -d '[:space:]') || true
    mem_mb=$(echo "${srv_info:-}" | sed -n 's/.*MEM:\([0-9]*\)MB.*/\1/p')
    if [[ "${free_mb:-}" =~ ^[0-9]+$ ]] && (( free_mb < 1500 )); then
        log WARN "Свободно на / всего ${free_mb} MB — для Docker и образов нужно ≥ 1.5 GB"
        ask_yn "Продолжить?" || exit 0
    fi
    if [[ "${mem_mb:-}" =~ ^[0-9]+$ ]] && (( mem_mb < 512 )); then
        log WARN "Мало памяти: ${mem_mb} MB (рекомендуется ≥ 512 MB)"
    fi
    log SUCCESS "Диск: свободно ${free_mb:-?} MB | RAM: ${mem_mb:-?} MB"

    # Шаг 3: Домен и Cloudflare
    print_step 3 "Настройка домена и Cloudflare"
    echo -e "${CYAN}Требования:${NC}"
    echo -e "  • Домен добавлен в Cloudflare"
    echo -e "  • A-запись: ${GREEN}домен → ${PUBLIC_IP}${NC} (Proxy: ${RED}OFF${NC} / серое облако)"
    echo -e "  • Cloudflare API Token с правами Zone:DNS:Edit"
    echo
    echo -e "${CYAN}Как получить API Token:${NC}"
    echo -e "  Cloudflare Dashboard → My Profile → API Tokens"
    echo -e "  → Create Token → Edit zone DNS → Zone: All zones"
    echo
    get_input "Домен (например: app.example.com)" "TLS_DOMAIN" "" "validate_domain" "Некорректный домен"
    echo
    read_cf_token
    log SUCCESS "Домен: ${TLS_DOMAIN}"
    precheck_dns

    # Шаг 3.5: Проверка портов (Caddy публикует 443/tcp, 443/udp и 80/tcp)
    print_step "3.5" "Проверка портов"
    XRAY_PORT=443
    check_port
    check_extra_ports

    # Шаг 4: API Paths
    print_step 4 "Настройка API paths"
    generate_path XHTTP_PATH_TEMPLATES "XHTTP_PATH" "XHTTP endpoint path"



    # Шаг 5: Сайт
    print_step 5 "Сайт"
    echo -e "${CYAN}Шаблонный сайт:${NC}"
    echo -e "  Учебный сайт «Как наш мир превращается в 0 и 1»: 4 страницы"
    echo -e "  HTML/CSS без зависимостей"
    echo
    local site_dir=""
    if ! ask_yn "Использовать шаблонный сайт?"; then
        echo
        echo -e "${CYAN}Укажите свой сайт:${NC}"
        echo -e "  Каталог с index.html внутри — или сам файл index.html,"
        echo -e "  тогда будет взят каталог, в котором он лежит."
        local custom_site_dir
        while true; do
            get_input "Путь" "custom_site_dir" "" "" ""
            # ~ раскрываем сами: get_input читает строку как есть, оболочка её не трогает
            custom_site_dir="${custom_site_dir/#\~/$HOME}"
            # Путь мог прийти с экранированием или в кавычках. Пробуем снятую версию только
            # если исходной на диске нет, — иначе сломали бы имя с настоящим обратным слэшем.
            if [[ ! -e "$custom_site_dir" ]]; then
                local unescaped; unescaped=$(unescape_path "$custom_site_dir")
                unescaped="${unescaped/#\~/$HOME}"
                if [[ "$unescaped" != "$custom_site_dir" && -e "$unescaped" ]]; then
                    log INFO "Путь принят без экранирования: ${unescaped}"
                    custom_site_dir="$unescaped"
                fi
            fi
            # Указали сам index.html — берём его каталог
            if [[ -f "$custom_site_dir" && "$(basename "$custom_site_dir")" == "index.html" ]]; then
                custom_site_dir="$(dirname "$custom_site_dir")"
            fi
            if [[ ! -d "$custom_site_dir" ]]; then
                log ERROR "Каталог не найден: ${custom_site_dir}"
                echo -e "  ${YELLOW}Нужен каталог, внутри которого лежит index.html, либо сам файл index.html.${NC}"
                echo -e "  ${YELLOW}HTML-файл с другим именем не подойдёт — переименуйте его в index.html.${NC}"
            elif [[ ! -f "${custom_site_dir}/index.html" ]]; then
                log ERROR "В каталоге ${custom_site_dir} нет index.html"
                echo -e "  ${YELLOW}Стартовая страница должна называться именно index.html — Caddy отдаёт её по адресу домена.${NC}"
            elif confirm_site_dir "$custom_site_dir"; then
                site_dir="$custom_site_dir"
                log SUCCESS "Будет использован ваш сайт: ${site_dir}"
                break
            else
                log INFO "Каталог не принят"
            fi
            echo
            echo -e "  ${GREEN}1)${NC} Указать путь заново"
            echo -e "  ${GREEN}2)${NC} Использовать шаблонный сайт"
            echo -e "  ${RED}0)${NC} Отменить установку"
            echo
            local sc
            while true; do
                read -r -p "Выберите (0-2): " sc
                case "$sc" in
                    1|2) break ;;
                    0) log INFO "Установка отменена — сервер не изменён"; exit 0 ;;
                    *) log WARN "Введите 0, 1 или 2" ;;
                esac
            done
            if [[ "$sc" == "2" ]]; then log INFO "Используется шаблонный сайт"; break; fi
        done
    fi

    # Шаг 6: Пользователи
    print_step 6 "Создание пользователей"
    get_input "Количество пользователей" "USER_COUNT" "1" "validate_count" "Введите число от 1 до 12"
    for ((i=1; i<=USER_COUNT; i++)); do
        local uname
        get_input "Имя пользователя $i" "uname" "" "validate_user" "Только a-z A-Z 0-9 _ -"
        USER_NAMES+=("$uname"); log SUCCESS "Добавлен: $uname"
    done

    # Шаг 7: UUID
    print_step 7 "Генерация UUID"
    for ((i=0; i<USER_COUNT; i++)); do
        local uuid; uuid=$(execute_remote_output "cat /proc/sys/kernel/random/uuid" | tr -d '[:space:]')
        [[ -z "$uuid" ]] && { log ERROR "Не удалось сгенерировать UUID"; exit 1; }
        USER_UUIDS+=("$uuid"); log SUCCESS "${USER_NAMES[$i]}: $uuid"
    done

    # Подтверждение
    print_header "Параметры установки"
    echo -e "  Сервер:      ${GREEN}${SSH_USER}@${SERVER_IP}:${SSH_PORT_SSH}${NC}"
    echo -e "  Публичный IP:${GREEN}${PUBLIC_IP}${NC}"
    echo -e "  Домен:       ${GREEN}${TLS_DOMAIN}${NC}"
    echo -e "  Образ:       ${GREEN}${XRAY_IMAGE}${NC}"
    echo -e "  XHTTP path:  ${GREEN}${XHTTP_PATH}${NC}"
    echo -e "  Пользователей:${GREEN}${USER_COUNT}${NC}"
    print_port_plan "Порт 443:    "
    echo -e "  Система:     ${YELLOW}будет выполнен apt-get update && apt-get upgrade, установлен/обновлён Docker${NC}"
    echo
    ask_yn "Начать установку?" || { log INFO "Отменено — сервер не изменён"; exit 0; }

    # Шаг 7.5: освобождение порта (действие выбрано на шаге 3.5, выполняется только сейчас)
    print_step "7.5" "Освобождение порта"
    apply_port_action
    backup_existing_install

    # Шаг 8: Docker
    print_step 8 "Установка Docker"
    install_docker

    # Шаг 9: Образ
    print_step 9 "Загрузка образов"
    execute_remote "docker pull ${XRAY_IMAGE}" "Загрузка xray-core"
    execute_remote "docker pull caddy:2-alpine" "Загрузка Caddy"

    # Шаг 10: TLS сертификат
    print_step 10 "TLS сертификат"
    setup_tls_certificate

    # Шаг 11: Развёртывание
    print_step 11 "Развёртывание"
    execute_remote "mkdir -p ${INSTALL_DIR}/{config,certs,site,log/xray,log/caddy,caddy_data,caddy_config}" \
        "Создание директорий"

    # Xray конфиг
    local tmp_xray; tmp_xray=$(create_temp)
    generate_xray_config > "$tmp_xray"
    copy_to_remote "$tmp_xray" "/tmp/xray-new.json" "Загрузка Xray конфига"
    # Официальный образ работает от UID 65532 → владелец 65532, режим 640: конфиг с UUID
    # пользователей читают только root и контейнер (как в установщиках 01–06 и в менеджере)
    execute_remote "chown 65532:65532 /tmp/xray-new.json && chmod 640 /tmp/xray-new.json" "" 1 || true

    # Валидация xray конфига
    local test_rc=0 test_out
    test_out=$(_ssh_cmd "docker run --rm \
        -v /tmp/xray-new.json:/etc/xray/config.json:ro \
        ${XRAY_IMAGE} run -test -config /etc/xray/config.json 2>&1") || test_rc=$?
    if [[ $test_rc -ne 0 ]]; then
        log ERROR "Xray конфиг не прошёл валидацию (exit: $test_rc):"
        echo "$test_out"
        execute_remote "rm -f /tmp/xray-new.json" "" 1 || true
        exit 1
    fi
    log SUCCESS "Xray конфиг валиден"
    execute_remote \
        "mv /tmp/xray-new.json ${INSTALL_DIR}/config/xray.json && \
         chown 65532:65532 ${INSTALL_DIR}/config/xray.json && \
         chmod 640 ${INSTALL_DIR}/config/xray.json" \
        "Применение Xray конфига"

    # Caddyfile
    local tmp_caddy; tmp_caddy=$(create_temp)
    generate_caddyfile > "$tmp_caddy"
    copy_to_remote "$tmp_caddy" "${INSTALL_DIR}/config/Caddyfile" "Загрузка Caddyfile"

    # Права на сертификаты
    execute_remote \
        "chmod 644 ${INSTALL_DIR}/certs/fullchain.pem && \
         chmod 600 ${INSTALL_DIR}/certs/privkey.pem" \
        "Права на сертификаты" 1 || true

    # Сайт
    if [[ -n "$site_dir" ]]; then
        log STEP "Загрузка вашего сайта..."
        # Служебные каталоги на сайте не нужны и содержат лишнее (история репозитория,
        # переменные окружения). --safe-links отбрасывает симлинки за пределы каталога:
        # -a сохранил бы их как есть и утащил бы на сервер ссылки наружу.
        local rc=0
        # rsync или scp directory
        if command -v rsync &>/dev/null; then
            _ssh_opts
            SSHPASS="$SSH_PASSWORD" sshpass -e rsync -av --delete --safe-links \
                --exclude='.git' --exclude='.svn' --exclude='.hg' \
                --exclude='node_modules' --exclude='.env' --exclude='.DS_Store' \
                -e "ssh -p ${SSH_PORT_SSH} -o StrictHostKeyChecking=accept-new -o ControlPath=${SSH_CM_DIR}/cm-%C" \
                "${site_dir}/" "${SSH_USER}@${SERVER_IP}:${INSTALL_DIR}/site/" 2>&1 || rc=$?
        else
            # Резервный путь без rsync: чистим каталог сами, чтобы поведение совпадало
            # с --delete, и копируем каталог целиком — glob со звёздочкой пропустил бы
            # файлы, начинающиеся с точки.
            execute_remote "rm -rf ${INSTALL_DIR}/site && mkdir -p ${INSTALL_DIR}/site" "" 1 || rc=$?
            _scp_cmd -r "${site_dir}/." "${SSH_USER}@${SERVER_IP}:${INSTALL_DIR}/site/" 2>&1 || rc=$?
            execute_remote "rm -rf ${INSTALL_DIR}/site/.git ${INSTALL_DIR}/site/.svn ${INSTALL_DIR}/site/.hg \
                            ${INSTALL_DIR}/site/node_modules ${INSTALL_DIR}/site/.env ${INSTALL_DIR}/site/.DS_Store" "" 1 || true
        fi
        if [[ $rc -ne 0 ]]; then
            log ERROR "Сайт не загружен (код: $rc) — установка прервана"
            exit 1
        fi
        log SUCCESS "Сайт загружен"
    else
        log STEP "Генерация шаблонного сайта..."
        # Создаём временную директорию в основном shell (не в subshell)
        local tmp_site_dir; tmp_site_dir=$(mktemp -d)
        generate_static_site "$tmp_site_dir"

        # Подставляем реальный домен в robots.txt и sitemap.xml
        for _f in robots.txt sitemap.xml; do
            local _src="${tmp_site_dir}/${_f}"
            local _tmp="${tmp_site_dir}/${_f}.tmp"
            if [[ -f "$_src" ]]; then
                while IFS= read -r _line; do
                    printf '%s\n' "${_line//DOMAIN_PLACEHOLDER/${TLS_DOMAIN}}"
                done < "$_src" > "$_tmp" && mv "$_tmp" "$_src"
            fi
        done

        # Загружаем файлы по одному явно
        for _file in "${tmp_site_dir}/index.html" "${tmp_site_dir}/text.html" "${tmp_site_dir}/images.html" "${tmp_site_dir}/sound.html" "${tmp_site_dir}/style.css" "${tmp_site_dir}/robots.txt"                      "${tmp_site_dir}/sitemap.xml" "${tmp_site_dir}/favicon.ico"; do
            [[ -f "$_file" ]] &&                 copy_to_remote "$_file" "${INSTALL_DIR}/site/$(basename "$_file")"                     "Загрузка $(basename "$_file")"
        done
        rm -rf "$tmp_site_dir"
        log SUCCESS "Шаблонный сайт развёрнут"
    fi

    # Docker-compose
    local tmp_dc; tmp_dc=$(create_temp)
    generate_docker_compose > "$tmp_dc"
    copy_to_remote "$tmp_dc" "${INSTALL_DIR}/docker-compose.yml" "Загрузка docker-compose"

    # Остановка старых контейнеров
    execute_remote "docker stop ${CONTAINER_NAME} ${CADDY_CONTAINER} 2>/dev/null || true" "" 1
    execute_remote "docker rm -v ${CONTAINER_NAME} ${CADDY_CONTAINER} 2>/dev/null || true" "" 1

    # Запуск
    # Без повторов: повтор после неудачного bind оставляет контейнер запущенным,
    # но без опубликованных портов, и это выглядит как успех.
    execute_remote "cd ${INSTALL_DIR} && docker compose up -d" "Запуск контейнеров" 1 || {
        log ERROR "Контейнеры не запустились"
        execute_remote "cd ${INSTALL_DIR} && docker compose logs --tail 20 2>&1" "" 1 || true
        exit 1
    }
    # Публикация портов могла не примениться — проверяем именно её, а не факт запуска
    local published
    published=$(execute_remote_output "docker inspect ${CADDY_CONTAINER} --format '{{json .NetworkSettings.Ports}}' 2>/dev/null") || true
    if [[ -z "${published:-}" || "$published" == "{}" ]]; then
        log ERROR "Контейнер ${CADDY_CONTAINER} запущен, но порты не опубликованы"
        log INFO "Обычно это значит, что 443/tcp, 443/udp или 80/tcp заняты другим процессом"
        execute_remote "ss -tlnp | grep ':443 '; ss -ulnp | grep ':443 '; ss -tlnp | grep ':80 '" "" 1 || true
        exit 1
    fi

    # Шаг 12: Проверка
    print_step 12 "Проверка работоспособности"
    local SELFTEST_OK=1
    if health_check; then
        local path_enc
        path_enc=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${XHTTP_PATH}', safe=''))" 2>/dev/null || echo "${XHTTP_PATH}")
        selftest_connection "vless://${USER_UUIDS[0]}@${TLS_DOMAIN}:443?security=tls&sni=${TLS_DOMAIN}&fp=chrome&type=xhttp&path=${path_enc}&host=${TLS_DOMAIN}&mode=auto#selftest" \
            "$XRAY_IMAGE" "xtls" && SELFTEST_OK=0
    else
        log WARN "Некоторые проверки не прошли"
    fi

    # Настройка автообновления сертификата
    sleep "$WAIT_CLIENT_READY"
    setup_cert_renewal

    # Шаг 13: Сохранение
    print_step 13 "Сохранение данных"
    save_server_data

    print_result
    [[ -n "$BACKUP_DIR" ]] && echo -e "  ${YELLOW}Предыдущая установка сохранена в: ${BACKUP_DIR}${NC}"
    if [[ "$SELFTEST_OK" -eq 0 ]]; then
        log SUCCESS "Установка завершена! Сквозная проверка подключения пройдена."
    else
        log WARN "Установка завершена, но сквозная проверка подключения НЕ пройдена — разберитесь до выдачи ссылок."
    fi
    echo
    echo -e "${CYAN}Проверка сайта:${NC} https://${TLS_DOMAIN}"
    echo
}

main "$@"
