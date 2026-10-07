#!/bin/bash

if [ -z "${BASH_VERSION:-}" ]; then
    echo "Ошибка: требуется bash. Запустите: bash $0" >&2
    exit 1
fi

#######################################
# Script Name: 00-manager.sh
# Description: Менеджер установок Xray и sing-box: пользователи, SNI, версия, статус,
#              JSON-профиль клиента, сквозная проверка, удаление.
# Author:      kshomer
# Version:     1.0
# Date:        09.09.2026
#######################################

set -o nounset
set -o pipefail

# ============================================
# КОНСТАНТЫ
# ============================================

readonly SSH_TIMEOUT=30
readonly SSH_RETRIES=3
readonly SSH_RETRY_DELAY=5

# Тайминги (секунды): держим в одном месте, а не числами по коду
readonly WAIT_AFTER_RESTART=2        # пауза после docker compose restart
readonly WAIT_CLIENT_READY=3         # пауза, пока временный клиент Xray выйдет на связь
readonly WAIT_AUTH_RETRY=3           # пауза между попытками SSH-аутентификации
readonly HTTP_TIMEOUT=10             # таймаут обычных HTTP-запросов
readonly HTTP_TIMEOUT_TUNNEL=20      # таймаут проверки через туннель
readonly HTTP_TIMEOUT_PROBE=15       # таймаут Reality-пробы
readonly HTTP_TIMEOUT_API=20         # таймаут обращений к API (реестры, Cloudflare)
readonly RESTART_TIMEOUT=90          # предел на docker compose restart

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Известные установки — контейнер:каталог:транспорт:ядро
# Транспорт «auto» означает: определяется из server-info.txt после подключения.
declare -a KNOWN_INSTALLS=(
    "xray-tcp-reality:/opt/xray-tcp-reality:tcp:xray"
    "xray-xhttp-reality:/opt/xray-xhttp-reality:xhttp:xray"
    "xray-tls-domain:/opt/xray-tls-domain:tls:xray"
    "singbox:/opt/singbox:auto:singbox"
)
readonly DEFAULT_XRAY_VERSION="26.6.27"
readonly DEFAULT_SINGBOX_IMAGE="ghcr.io/sagernet/sing-box:v1.14.0"
readonly XRAY_REALITY_SNI_DEFAULT="www.nvidia.com"
readonly SELFSIGNED_SNI_DEFAULT="www.bing.com"
readonly SELFSIGNED_MONTHS=120

# Runtime
SERVER_IP="" SSH_PORT_SSH="22" SSH_USER="root" SSH_PASSWORD=""
PUBLIC_IP="" XRAY_PORT=443 XRAY_IMAGE="" TLS_DOMAIN=""
CONTAINER_NAME="" INSTALL_DIR="" TRANSPORT="" CORE="xray"
REALITY_PUBLIC_KEY="" REALITY_SHORT_ID="" XRAY_REALITY_SNI="" REALITY_PRIVATE_KEY=""
CURRENT_FINGERPRINT="chrome"
CONTAINER_STATUS=""

declare -a TEMP_FILES=()

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

# ============================================
# ОЧИСТКА
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
    _ssh_close
    [[ $code -ne 0 && $code -ne 130 ]] && { echo; log ERROR "Ошибка (код: $code)"; }
    exit $code
}
trap cleanup EXIT INT TERM

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
validate_port() { [[ $1 =~ ^[0-9]+$ ]] && ((${1} >= 1 && ${1} <= 65535)); }
validate_user()   { [[ $1 =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; }
validate_posint() { [[ $1 =~ ^[1-9][0-9]*$ ]]; }
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
validate_tag()    { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; }
validate_count()  { validate_posint "$1" && (( $1 <= 12 )); }

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
    local src="$1" dst="$2" desc="${3:-}" attempt=1
    [[ -n "$desc" ]] && log STEP "${desc}..."
    while [ "$attempt" -le "$SSH_RETRIES" ]; do
        if _scp_cmd "$src" "${SSH_USER}@${SERVER_IP}:${dst}" 2>&1; then
            [[ -n "$desc" ]] && log SUCCESS "$desc"; return 0
        fi
        [ "$attempt" -lt "$SSH_RETRIES" ] && { log WARN "Попытка $attempt..."; sleep "$SSH_RETRY_DELAY"; }
        attempt=$((attempt + 1))
    done
    [[ -n "$desc" ]] && log ERROR "$desc (все попытки исчерпаны)"; return 1
}

get_remote_file() {
    local remote="$1" local_path="$2" desc="${3:-}" attempt=1
    [[ -n "$desc" ]] && log STEP "${desc}..."
    while [ "$attempt" -le "$SSH_RETRIES" ]; do
        if _scp_cmd "${SSH_USER}@${SERVER_IP}:${remote}" "$local_path" 2>/dev/null; then
            [[ -n "$desc" ]] && log SUCCESS "$desc"; return 0
        fi
        attempt=$((attempt + 1))
    done
    [[ -n "$desc" ]] && log ERROR "$desc (все попытки исчерпаны)"; return 1
}

# ============================================
# ПОДКЛЮЧЕНИЕ И АВТООПРЕДЕЛЕНИЕ УСТАНОВКИ
# ============================================

connect_to_server() {
    print_header "Подключение к серверу"

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

    # Проверка доступности
    log STEP "Проверка доступности (TCP:${SSH_PORT_SSH})..."
    if bash -c "echo >/dev/tcp/${SERVER_IP}/${SSH_PORT_SSH}" 2>/dev/null; then
        log SUCCESS "Сервер доступен"
    else
        log ERROR "Сервер недоступен"; exit 1
    fi

    # Проверка SSH-аутентификации
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

    # Публичный IP
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

    # Автоопределение установки
    detect_installation
}

detect_installation() {
    log STEP "Поиск установок на сервере..."

    # docker ps -a: видим и остановленные контейнеры (упавший сервер — как раз тот случай, когда нужен менеджер)
    local ps_out
    ps_out=$(execute_remote_output "docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null") || true

    local found=() entry cname dir transport core st rest
    for entry in "${KNOWN_INSTALLS[@]}"; do
        IFS=':' read -r cname dir transport core <<< "$entry"
        st=$(printf '%s\n' "$ps_out" | awk -F'\t' -v n="$cname" '$1==n{print $2}' | head -1)
        [[ -n "$st" ]] && found+=("${cname}|${dir}|${transport}|${core}|${st}")
    done

    if [[ ${#found[@]} -eq 0 ]]; then
        log ERROR "Установки не найдены на сервере (искали контейнеры: xray-tcp-reality, xray-xhttp-reality, xray-tls-domain, singbox)"
        log INFO "Запустите один из установщиков"
        exit 1
    fi

    local sel
    if [[ ${#found[@]} -eq 1 ]]; then
        sel="${found[0]}"
    else
        echo
        echo -e "${CYAN}Найдено несколько установок:${NC}"
        echo
        local i=1
        for entry in "${found[@]}"; do
            IFS='|' read -r cname dir transport core st <<< "$entry"
            local what
            [[ "$transport" == "auto" ]] && what="ядро sing-box" || what="$(echo "$transport" | tr '[:lower:]' '[:upper:]')"
            echo -e "  ${GREEN}${i})${NC} ${cname} — ${what} (${dir}) — ${st}"
            ((i++))
        done
        echo
        local choice
        while true; do
            read -r -p "Выберите установку (1-${#found[@]}): " choice
            [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#found[@]})) && break
            log WARN "Введите число от 1 до ${#found[@]}"
        done
        sel="${found[$((choice-1))]}"
    fi

    IFS='|' read -r CONTAINER_NAME INSTALL_DIR TRANSPORT CORE CONTAINER_STATUS <<< "$sel"
    load_server_data
    log SUCCESS "Установка: ${CONTAINER_NAME} | $(core_label) | $(transport_label) — ${CONTAINER_STATUS}"
    [[ "$CONTAINER_STATUS" != Up* ]] && \
        log WARN "Контейнер не запущен — используйте «Проверить статус» и «Перезапустить»"
    return 0
}

load_server_data() {
    XRAY_PORT=443

    if is_singbox; then
        load_singbox_data
        return 0
    fi

    if [[ "$TRANSPORT" == "tls" ]]; then
        # TLS-domain: конфиг лежит в xray.json, домен — в users.txt
        local tmp_cfg; tmp_cfg=$(create_temp)
        get_remote_file "$(cfg_path)" "$tmp_cfg" "Чтение данных установки" || {
            log WARN "Конфиг не найден — некоторые функции ограничены"
            return 0
        }
        XRAY_IMAGE=$(execute_remote_output \
            "docker inspect ${CONTAINER_NAME} --format '{{.Config.Image}}' 2>/dev/null | tr -d '[:space:]'") || true
        local tmp_users; tmp_users=$(create_temp)
        get_remote_file "${INSTALL_DIR}/users.txt" "$tmp_users" "" || true
        TLS_DOMAIN=$(grep "^Домен:" "$tmp_users" 2>/dev/null | awk '{print $2}' | tr -d '[:space:]') || true
        [[ -z "${XRAY_IMAGE:-}" ]] && XRAY_IMAGE="ghcr.io/xtls/xray-core:${DEFAULT_XRAY_VERSION}"
        log SUCCESS "Данные загружены | Порт: ${XRAY_PORT} | ${XRAY_IMAGE}"
        return 0
    fi

    # Reality (TCP/XHTTP) на ядре Xray: читаем reality-keys.txt
    local tmp; tmp=$(create_temp)
    get_remote_file "$(info_file)" "$tmp" "Чтение данных установки" || {
        log WARN "Файл ключей не найден — некоторые функции ограничены"
        return 0
    }

    local data; data=$(cat "$tmp")
    XRAY_PORT=$(echo "$data"    | grep "^Порт:"        | awk '{print $2}' | tr -d '[:space:]') || true
    XRAY_IMAGE=$(echo "$data"   | grep "^Image:"       | awk '{print $2}' | tr -d '[:space:]') || true
    XRAY_REALITY_SNI=$(echo "$data" | grep "^SNI:"     | awk '{print $2}' | tr -d '[:space:]') || true
    REALITY_PUBLIC_KEY=$(echo "$data" | grep "^Public Key:" | awk '{print $NF}' | tr -d '[:space:]') || true
    REALITY_SHORT_ID=$(echo "$data"   | grep "^Short ID:"   | awk '{print $NF}' | tr -d '[:space:]') || true
    REALITY_PRIVATE_KEY=$(echo "$data" | grep "^Private Key:" | awk '{print $NF}' | tr -d '[:space:]') || true

    [[ -z "$XRAY_PORT"  ]] && XRAY_PORT=443
    [[ -z "$XRAY_IMAGE" ]] && XRAY_IMAGE="unknown"
    log SUCCESS "Данные загружены | Порт: ${XRAY_PORT} | ${XRAY_IMAGE}"
}

# Данные установки sing-box: протокол и ключи лежат в server-info.txt
load_singbox_data() {
    local tmp; tmp=$(create_temp)
    if ! get_remote_file "$(info_file)" "$tmp" "Чтение данных установки"; then
        log WARN "server-info.txt не найден — определяю протокол по конфигу"
        TRANSPORT=$(execute_remote_output "jq -r '.inbounds[0].type // empty' $(cfg_path) 2>/dev/null" | tr -d '[:space:]')
        [[ "$TRANSPORT" == "vless" ]] && TRANSPORT="vless-reality"
        XRAY_IMAGE=$(execute_remote_output "docker inspect ${CONTAINER_NAME} --format '{{.Config.Image}}' 2>/dev/null" | tr -d '[:space:]')
        [[ -z "$XRAY_IMAGE" ]] && XRAY_IMAGE="$DEFAULT_SINGBOX_IMAGE"
        XRAY_PORT=$(execute_remote_output "jq -r '.inbounds[0].listen_port // 443' $(cfg_path) 2>/dev/null" | tr -d '[:space:]')
        [[ -z "$XRAY_PORT" ]] && XRAY_PORT=443
        return 0
    fi

    local data; data=$(cat "$tmp")
    TRANSPORT=$(echo "$data"          | grep "^Protocol:"    | awk '{print $2}' | tr -d '[:space:]') || true
    XRAY_PORT=$(echo "$data"          | grep "^Порт:"        | awk '{print $2}' | tr -d '[:space:]') || true
    XRAY_IMAGE=$(echo "$data"         | grep "^Image:"       | awk '{print $2}' | tr -d '[:space:]') || true
    XRAY_REALITY_SNI=$(echo "$data"   | grep "^SNI:"         | awk '{print $2}' | tr -d '[:space:]') || true
    REALITY_PUBLIC_KEY=$(echo "$data" | grep "^Public Key:"  | awk '{print $NF}' | tr -d '[:space:]') || true
    REALITY_SHORT_ID=$(echo "$data"   | grep "^Short ID:"    | awk '{print $NF}' | tr -d '[:space:]') || true
    REALITY_PRIVATE_KEY=$(echo "$data" | grep "^Private Key:" | awk '{print $NF}' | tr -d '[:space:]') || true

    [[ -z "$TRANSPORT"  ]] && TRANSPORT="vless-reality"
    [[ -z "$XRAY_PORT"  ]] && XRAY_PORT=443
    [[ -z "$XRAY_IMAGE" ]] && XRAY_IMAGE="$DEFAULT_SINGBOX_IMAGE"
    log SUCCESS "Данные загружены | Порт: ${XRAY_PORT} | ${XRAY_IMAGE}"
}

# ============================================
# ВСПОМОГАТЕЛЬНЫЕ
# ============================================

# ============================================
# СЛОЙ АБСТРАКЦИИ ЯДРА
# Менеджер работает с двумя ядрами: Xray (установщики 01–07) и sing-box (08).
# Различия — расположение пользователей в конфиге, команда проверки конфига,
# формат ссылки и реестр версий. Всё остальное общее.
# ============================================

is_singbox() { [[ "$CORE" == "singbox" ]]; }

# Установка использует Reality (на любом ядре)
is_reality() { [[ "$TRANSPORT" == "tcp" || "$TRANSPORT" == "xhttp" || "$TRANSPORT" == "vless-reality" ]]; }

# Установка работает поверх QUIC/UDP (только sing-box)
is_quic() { [[ "$TRANSPORT" == "hysteria2" || "$TRANSPORT" == "tuic" ]]; }

core_label() { is_singbox && echo "sing-box" || echo "Xray"; }

transport_label() {
    case "$TRANSPORT" in
        tcp)           echo "TCP+Reality" ;;
        xhttp)         echo "XHTTP+Reality" ;;
        tls)           echo "XHTTP+TLS+Domain" ;;
        vless-reality) echo "VLESS+Reality (TCP)" ;;
        hysteria2)     echo "Hysteria2 (QUIC/UDP)" ;;
        tuic)          echo "TUIC v5 (QUIC/UDP)" ;;
        *)             echo "UNKNOWN" ;;
    esac
}

# Путь к конфигу на сервере
cfg_path() {
    if [[ "$CORE" == "xray" && "$TRANSPORT" == "tls" ]]; then
        echo "${INSTALL_DIR}/config/xray.json"
    else
        echo "${INSTALL_DIR}/config/config.json"
    fi
}

# Имя сервиса в docker-compose.yml
compose_service() { is_singbox && echo "singbox" || echo "xray"; }

# Путь jq до массива пользователей и имя поля с именем пользователя
users_jq()   { is_singbox && echo '.inbounds[0].users' || echo '.inbounds[0].settings.clients'; }
name_field() { is_singbox && echo 'name' || echo 'email'; }

# Число пользователей в конфиге $1
users_count() { jq "$(users_jq) | length" "$1" 2>/dev/null || echo 0; }
# Имя пользователя с индексом $2 в конфиге $1
user_name_at() { jq -r "$(users_jq)[$2].$(name_field) // \"user\"" "$1" 2>/dev/null; }

# Файл с данными установки: у Xray это reality-keys.txt, у sing-box — server-info.txt
info_file() { is_singbox && echo "${INSTALL_DIR}/server-info.txt" || echo "${INSTALL_DIR}/reality-keys.txt"; }

# Репозиторий на GitHub для «стабильного релиза»
core_github_repo() { is_singbox && echo "SagerNet/sing-box" || echo "XTLS/Xray-core"; }

# Источник образа по имени: xtls (ghcr.io/xtls/xray-core) или teddysun
image_source_of() { [[ "$1" == *"xtls/xray-core"* ]] && echo "xtls" || echo "teddysun"; }

# Права на конфиг: официальный образ работает от UID 65532 → 65532:65532/640; teddysun от root → 600
config_perms() {
    # sing-box в официальном образе работает от root; конфиг содержит ключи и пароли — 600.
    if is_singbox; then echo "root:root 600"
    elif [[ "$(image_source_of "$XRAY_IMAGE")" == "xtls" ]]; then echo "65532:65532 640"
    else echo "root:root 600"; fi
}

# xray внутри образа (учёт разного ENTRYPOINT)
xray_in_image() {   # $1 = image, остальное — аргументы xray
    local img="$1"; shift
    if [[ "$(image_source_of "$img")" == "teddysun" ]]; then
        echo "docker run --rm --entrypoint xray ${img} $*"
    else
        echo "docker run --rm ${img} $*"
    fi
}

# Версия Xray внутри образа (например 26.6.27)
image_version() {
    if is_singbox; then
        # «sing-box version 1.14.0» → третье поле
        execute_remote_output "docker run --rm $1 version 2>/dev/null | head -1 | awk '{print \$3}'" | tr -d '[:space:]'
    else
        execute_remote_output "$(xray_in_image "$1" version) 2>/dev/null | head -1 | awk '{print \$2}'" | tr -d '[:space:]'
    fi
}

# $1 < $2 ? (сравнение версий по числовым компонентам)
version_lt() {
    python3 - "$1" "$2" <<'PY'
import sys, re
def key(v): return [int(x) for x in re.findall(r"\d+", v)]
sys.exit(0 if key(sys.argv[1]) < key(sys.argv[2]) else 1)
PY
}

# Проверка конфига указанным образом. $1 = удалённый путь к конфигу, $2 = образ
core_test_remote() {   # $1 = удалённый путь к конфигу, $2 = образ
    local cfg="$1" img="$2" out rc=0
    if is_singbox; then
        # certs монтируем: конфиги Hysteria2 и TUIC ссылаются на сертификат
        out=$(_ssh_cmd "docker run --rm -v ${cfg}:/etc/sing-box/config.json:ro \
            -v ${INSTALL_DIR}/certs:/etc/sing-box/certs:ro \
            ${img} check -c /etc/sing-box/config.json 2>&1") || rc=$?
        if [[ $rc -ne 0 ]]; then
            log ERROR "Конфиг не прошёл sing-box check (код: $rc):"; echo "$out"; return 1
        fi
    else
        local ep=""
        [[ "$(image_source_of "$img")" == "teddysun" ]] && ep="--entrypoint xray"
        out=$(_ssh_cmd "docker run --rm ${ep} -v ${cfg}:/etc/xray/config.json:ro ${img} run -test -config /etc/xray/config.json 2>&1") || rc=$?
        if [[ $rc -ne 0 ]]; then
            log ERROR "Конфиг не прошёл xray test (код: $rc):"; echo "$out"; return 1
        fi
    fi
    return 0
}

# Перезапуск контейнера с проверкой: StartedAt должен измениться, контейнер — работать
restart_container() {
    local before after running out rc=0
    before=$(execute_remote_output "docker inspect -f '{{.State.StartedAt}}' ${CONTAINER_NAME} 2>/dev/null" | tr -d '[:space:]') || true
    log STEP "Перезапуск контейнера ${CONTAINER_NAME}..."
    if [[ -n "$before" ]]; then
        out=$(_ssh_cmd "cd ${INSTALL_DIR} && timeout ${RESTART_TIMEOUT} docker compose restart $(compose_service) 2>&1") || rc=$?
    else
        out=$(_ssh_cmd "cd ${INSTALL_DIR} && timeout ${RESTART_TIMEOUT} docker compose up -d $(compose_service) 2>&1") || rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        log ERROR "Перезапуск не удался (exit: $rc):"; echo "$out"; return 1
    fi
    sleep "$WAIT_AFTER_RESTART"
    after=$(execute_remote_output "docker inspect -f '{{.State.StartedAt}}' ${CONTAINER_NAME} 2>/dev/null" | tr -d '[:space:]') || true
    running=$(execute_remote_output "docker inspect -f '{{.State.Running}}' ${CONTAINER_NAME} 2>/dev/null" | tr -d '[:space:]') || true
    if [[ "$running" == "true" && "$after" != "$before" ]]; then
        log SUCCESS "Контейнер перезапущен (StartedAt: ${before:-—} → ${after})"; CONTAINER_STATUS="Up"; return 0
    elif [[ "$running" == "true" ]]; then
        log WARN "Контейнер работает, но время старта не изменилось — проверьте вручную"; return 0
    fi
    log ERROR "Контейнер не запущен после перезапуска. Логи:"
    execute_remote "docker logs --tail 20 ${CONTAINER_NAME} 2>&1" "" 1 || true
    return 1
}

# Загрузить локальный конфиг на сервер, проверить xray -test, применить атомарно, перезапустить
push_and_apply_config() {
    local local_cfg="$1"
    local remote_tmp="/tmp/manager-config-new.$$.json" cfg_dest owner mode
    read -r owner mode <<< "$(config_perms)"
    cfg_dest="$(cfg_path)"

    execute_remote "rm -f ${remote_tmp}" "" 1 || true
    copy_to_remote "$local_cfg" "$remote_tmp" "Загрузка конфига" || return 1
    execute_remote "chown ${owner} ${remote_tmp} && chmod ${mode} ${remote_tmp}" "" 1 || return 1

    if ! core_test_remote "$remote_tmp" "$XRAY_IMAGE"; then
        execute_remote "rm -f ${remote_tmp}" "" 1 || true
        return 1
    fi
    log SUCCESS "Конфиг прошёл валидацию"

    execute_remote \
        "mv ${remote_tmp} ${cfg_dest} && chown ${owner} ${cfg_dest} && chmod ${mode} ${cfg_dest}" \
        "Применение конфига (atomic)" 1 || return 1

    restart_container
}

# Мягкая проверка SNI-цели (TLS 1.3 + HTTP/2)
# Имя для самоподписанного сертификата (Hysteria2, TUIC).
# Технически подойдёт любое имя — клиент подписи не проверяет. Но это же имя
# подставляется в masquerade.url: сайт, содержимым которого sing-box отвечает на
# запросы без аутентификации. Если имени нет в DNS или оно молчит по HTTPS,
# параметр masquerade работать не будет. Опечатки вроде «www.bing.c» ловятся здесь.
check_cert_name() {   # $1 = имя
    log STEP "Проверка имени ${1} (DNS и HTTPS)..."
    local out ip code
    out=$(execute_remote_output "
        ip=\$(getent hosts '${1}' 2>/dev/null | head -1 | awk '{print \$1}')
        code=\$(curl -sS -o /dev/null --max-time ${HTTP_TIMEOUT} -w '%{http_code}' 'https://${1}/' 2>/dev/null) || code=000
        echo \"IP=\${ip:-none} CODE=\${code:-000}\"") || true
    ip=$(echo "${out:-}"   | sed -n 's/.*IP=\([^ ]*\).*/\1/p' | tail -1)
    code=$(echo "${out:-}" | sed -n 's/.*CODE=\([0-9]\{3\}\).*/\1/p' | tail -1)
    if [[ "${code:-}" =~ ^[2-4][0-9][0-9]$ ]]; then
        log SUCCESS "Имя существует и отвечает по HTTPS (код ${code})"
        return 0
    fi
    if [[ "${ip:-none}" == "none" ]]; then
        log ERROR "Имени ${1} нет в DNS — похоже на опечатку"
    else
        log ERROR "Имя ${1} есть в DNS (${ip}), но не отвечает по HTTPS (код ${code:-нет ответа})"
    fi
    log INFO "Это имя уходит в сертификат и в masquerade — несуществующее брать нельзя"
    return 1
}

# Имя не прошло проверку. Принять его нельзя, поэтому выбор из двух вариантов.
ask_retry_or_cancel() {   # 0 = выбрать другое имя, 1 = отмена
    local a
    echo
    echo -e "  ${GREEN}1)${NC} Выбрать другое имя"
    echo -e "  ${RED}0)${NC} Отмена"
    echo
    while true; do
        read -r -p "Выберите (0-1): " a
        case "$a" in
            1) return 0 ;;
            0) return 1 ;;
            *) log WARN "Введите 0 или 1" ;;
        esac
    done
}

check_sni_target() {
    # Быстрая ступень для Reality: цель обязана отвечать по TLS 1.3 + HTTP/2.
    # Окончательный ответ даёт probe_reality — настоящее рукопожатие.
    local sni="$1" hv
    log STEP "Проверка SNI-цели ${sni} (TLS 1.3 / HTTP/2)..."
    hv=$(execute_remote_output \
        "curl -sS -o /dev/null --tlsv1.3 --http2 --max-time ${HTTP_TIMEOUT} -w '%{http_version}' https://${sni}/ 2>/dev/null") || true
    hv=$(echo "${hv:-}" | tr -d '[:space:]')
    if [[ "$hv" == "2" ]]; then log SUCCESS "SNI-цель отвечает по TLS 1.3 + HTTP/2"; return 0; fi
    log ERROR "SNI-цель ${sni} не отвечает по TLS 1.3/HTTP-2 (http_version='${hv:-нет ответа}')"
    log INFO "С такой целью Reality не заработает — нужно другое имя"
    return 1
}

# ============================================
# СКВОЗНАЯ ПРОВЕРКА: временный Xray-клиент на сервере подключается по ссылке
# и делает HTTPS-запрос через туннель. Единственный способ убедиться, что работает.
# ============================================

# Разбор vless-ссылки в outbound формата Xray-core. Один разбор на двух потребителей:
# сквозную проверку (поднимает временный клиент на сервере) и генератор клиентского JSON.
# Отпечаток uTLS берётся из самой ссылки: pick_link_for_generator уже подставил в неё
# выбранный. Умеет tcp и xhttp, reality и tls.
xray_outbound_from_link() {   # $1 = ссылка, $2 = tag
    python3 - "$1" "${2:-proxy}" <<'PY'
import sys, json, urllib.parse
u = sys.argv[1].strip(); tag = sys.argv[2]
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
print(json.dumps({"tag": tag, "protocol": "vless",
                  "settings": {"vnext": [{"address": host, "port": int(port), "users": [user]}]},
                  "streamSettings": ss}))
PY
}

selftest_connection() {   # $1 = vless-ссылка, $2 = образ, $3 = xtls|teddysun
    local link="$1" image="$2" src="$3"
    local rport ep=""
    rport=$(pick_free_port 20000 20000)
    [[ "$src" == "teddysun" ]] && ep="--entrypoint xray"
    log STEP "Сквозная проверка подключения (клиент Xray на сервере, socks:${rport})..."

    local ob cfg
    ob=$(xray_outbound_from_link "$link" "proxy") \
        || { log WARN "Self-test: не удалось собрать конфиг клиента из ссылки"; return 1; }
    cfg=$(jq -n --argjson ob "$ob" --argjson port "$rport" \
        '{"log": {"loglevel": "warning"},
          "inbounds": [{"listen": "127.0.0.1", "port": $port, "protocol": "socks", "settings": {"udp": false}}],
          "outbounds": [$ob]}') \
        || { log WARN "Self-test: не удалось собрать конфиг клиента"; return 1; }

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

# Новейший числовой тег в реестре (запрос с этой машины). $1 = репозиторий образа
registry_newest_tag() {
    local repo="$1" tags="" resp
    if [[ "$repo" == ghcr.io/* ]]; then
        local path="${repo#ghcr.io/}" token url hdr
        token=$(curl -s --max-time ${HTTP_TIMEOUT_API} "https://ghcr.io/token?scope=repository:${path}:pull" | jq -r '.token // empty' 2>/dev/null) || true
        [[ -z "$token" ]] && return 1
        hdr=$(create_temp); url="https://ghcr.io/v2/${path}/tags/list?n=1000"
        for _ in 1 2 3 4 5 6 7 8; do
            resp=$(curl -s --max-time ${HTTP_TIMEOUT_API} -D "$hdr" -H "Authorization: Bearer $token" "$url") || break
            tags+=$'\n'$(echo "$resp" | jq -r '.tags[]?' 2>/dev/null)
            local next; next=$(grep -i '^link:' "$hdr" | sed -E 's/.*<([^>]+)>.*/\1/' | tr -d '\r')
            [[ -z "$next" ]] && break
            url="https://ghcr.io${next}"
        done
    else
        local page=1
        for _ in 1 2 3 4 5 6 7 8; do
            resp=$(curl -s --max-time ${HTTP_TIMEOUT_API} "https://hub.docker.com/v2/repositories/${repo}/tags?page_size=100&page=${page}") || break
            tags+=$'\n'$(echo "$resp" | jq -r '.results[].name' 2>/dev/null)
            [[ -z "$(echo "$resp" | jq -r '.next // empty' 2>/dev/null)" ]] && break
            page=$((page+1))
        done
    fi
    # Новейший тег, включая предварительные сборки (1.15.0-alpha.2 и подобные).
    # Порядок как в semver: 1.14.0 < 1.15.0-alpha.2 < 1.15.0. Префикс «v» — часть
    # имени тега у sing-box, у Xray его нет.
    echo "$tags" | python3 -c '
import sys, re
pat = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$")
best = best_key = None
for line in sys.stdin:
    t = line.strip()
    m = pat.match(t) if t else None
    if not m:
        continue
    pre = m.group(4)
    if pre is None:
        pk = (1,)
    else:
        parts = tuple((0, int(p), "") if p.isdigit() else (1, 0, p) for p in pre.split("."))
        pk = (0, parts)
    key = (int(m.group(1)), int(m.group(2)), int(m.group(3)), pk)
    if best_key is None or key > best_key:
        best_key, best = key, t
print(best or "")'
}

# Последний стабильный релиз ядра (GitHub "latest release", без pre-release).
# Тег отдаётся как есть: у sing-box теги образов с префиксом «v», у Xray — без него.
github_stable_release() {   # $1 = owner/repo
    curl -s --max-time ${HTTP_TIMEOUT_API} "https://api.github.com/repos/${1}/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null
}

# Ссылка первого пользователя текущей установки (для self-test)
first_user_link() {
    get_clients_from_config >/dev/null 2>&1 || return 1
    local cnt; cnt=$(users_count "$CURRENT_CONFIG_TMP")
    [[ "${cnt:-0}" -eq 0 ]] && return 1
    make_user_link 0
}

run_selftest() {
    local link
    link=$(first_user_link) || { log WARN "Self-test: нет пользователей или конфиг недоступен"; return 1; }
    if is_singbox; then
        selftest_singbox "$link"
    else
        selftest_connection "$link" "$XRAY_IMAGE" "$(image_source_of "$XRAY_IMAGE")"
    fi
}

# Клиентский конфиг sing-box из ссылки vless:// | hysteria2:// | tuic://
singbox_client_config() {   # $1 = ссылка, $2 = локальный socks-порт
    python3 - "$1" "$2" <<'PY'
import sys, json, urllib.parse

uri = sys.argv[1].strip()
port_local = int(sys.argv[2])
scheme, _, rest = uri.partition("://")
body = rest.split("#")[0]
userinfo, _, hostpart = body.partition("@")
hostport, _, qs = hostpart.partition("?")
hostport = hostport.rstrip("/")
host, _, port = hostport.rpartition(":")
q = {k: v[0] for k, v in urllib.parse.parse_qs(qs, keep_blank_values=True).items()}
insecure = q.get("insecure", q.get("allow_insecure", "0")) == "1"

if scheme == "vless":
    out = {"type": "vless", "tag": "proxy", "server": host, "server_port": int(port),
           "uuid": userinfo,
           "tls": {"enabled": True, "server_name": q.get("sni", host),
                   "utls": {"enabled": True, "fingerprint": q.get("fp", "chrome")},
                   "reality": {"enabled": True, "public_key": q.get("pbk", ""),
                               "short_id": q.get("sid", "")}}}
    if q.get("flow"):
        out["flow"] = q["flow"]
elif scheme == "hysteria2":
    out = {"type": "hysteria2", "tag": "proxy", "server": host, "server_port": int(port),
           "password": urllib.parse.unquote(userinfo),
           "tls": {"enabled": True, "server_name": q.get("sni", host),
                   "alpn": ["h3"], "insecure": insecure}}
elif scheme == "tuic":
    uuid, _, password = userinfo.partition(":")
    out = {"type": "tuic", "tag": "proxy", "server": host, "server_port": int(port),
           "uuid": uuid, "password": urllib.parse.unquote(password),
           "congestion_control": q.get("congestion_control", "bbr"),
           "tls": {"enabled": True, "server_name": q.get("sni", host),
                   "alpn": ["h3"], "insecure": insecure}}
else:
    sys.exit(1)

print(json.dumps({
    "log": {"level": "warn"},
    "dns": {"servers": [{"type": "udp", "tag": "dns-direct", "server": "1.1.1.1"}], "final": "dns-direct"},
    "inbounds": [{"type": "mixed", "tag": "in", "listen": "127.0.0.1", "listen_port": port_local}],
    "outbounds": [out, {"type": "direct", "tag": "direct"}],
    "route": {"final": "proxy", "default_domain_resolver": {"server": "dns-direct"}}}))
PY
}

# Сквозная проверка для установки на ядре sing-box
selftest_singbox() {   # $1 = ссылка
    local link="$1" rport
    rport=$(pick_free_port 20000 20000)
    log STEP "Сквозная проверка подключения (клиент sing-box на сервере, socks:${rport})..."

    local cfg
    cfg=$(singbox_client_config "$link" "$rport") \
        || { log WARN "Self-test: не удалось собрать конфиг клиента из ссылки"; return 1; }

    local tmp; tmp=$(create_temp); printf '%s\n' "$cfg" > "$tmp"
    local rtmp="/tmp/singbox-selftest.$$.json"
    _scp_cmd "$tmp" "${SSH_USER}@${SERVER_IP}:${rtmp}" >/dev/null 2>&1 \
        || { log WARN "Self-test: не удалось загрузить конфиг клиента"; return 1; }

    local out code
    out=$(_ssh_cmd "
        chmod 644 ${rtmp}
        docker rm -f -v singbox-selftest >/dev/null 2>&1 || true
        docker run -d --name singbox-selftest --network host -v ${rtmp}:/c.json:ro ${XRAY_IMAGE} run -c /c.json >/dev/null 2>&1
        sleep ${WAIT_CLIENT_READY}
        code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time ${HTTP_TIMEOUT_TUNNEL} -x socks5h://127.0.0.1:${rport} https://www.gstatic.com/generate_204 2>/dev/null); [ -z \"\$code\" ] && code=000
        echo \"CODE=\$code\"
        [ \"\$code\" != 204 ] && { echo '--- логи клиента:'; docker logs --tail 8 singbox-selftest 2>&1; }
        docker rm -f -v singbox-selftest >/dev/null 2>&1 || true
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
# ПРОВЕРКА SNI-ЦЕЛИ НАСТОЯЩИМ REALITY-РУКОПОЖАТИЕМ
# Временный сервер и клиент Xray на 127.0.0.1 сервера с теми же ключами.
# curl-проверка «TLS 1.3 + HTTP/2» этого не заменяет: www.microsoft.com её проходит,
# но Reality с ним не работает («handshake did not complete successfully»).
# ============================================

probe_reality_target() {   # $1 = SNI, $2 = образ, $3 = xtls|teddysun; использует REALITY_* ключи
    local sni="$1" image="$2" src="$3"
    local sport cport ep="" owner="root:root" mode="600" uuid
    sport=$(pick_free_port 30000 20000)
    cport=$(pick_free_port 10000 20000)
    [[ "$src" == "teddysun" ]] && ep="--entrypoint xray"
    [[ "$src" == "xtls" ]] && { owner="65532:65532"; mode="640"; }
    uuid=$(execute_remote_output "cat /proc/sys/kernel/random/uuid" | tr -d '[:space:]')
    [[ -z "$uuid" ]] && uuid="11111111-1111-4111-8111-111111111111"
    log STEP "Проверка SNI-цели ${sni} настоящим Reality-рукопожатием (временный сервер 127.0.0.1:${sport})..."

    local tmp_s tmp_c; tmp_s=$(create_temp); tmp_c=$(create_temp)
    jq -n --arg u "$uuid" --arg sni "$sni" --arg priv "$REALITY_PRIVATE_KEY" --arg sid "$REALITY_SHORT_ID" --argjson port "$sport" \
        '{log:{loglevel:"warning"},
          inbounds:[{listen:"127.0.0.1",port:$port,protocol:"vless",
                     settings:{clients:[{id:$u,flow:"xtls-rprx-vision"}],decryption:"none"},
                     streamSettings:{network:"tcp",security:"reality",
                                     realitySettings:{dest:($sni+":443"),serverNames:[$sni],privateKey:$priv,shortIds:[$sid]}}}],
          outbounds:[{protocol:"freedom"}]}' > "$tmp_s"
    jq -n --arg u "$uuid" --arg sni "$sni" --arg pbk "$REALITY_PUBLIC_KEY" --arg sid "$REALITY_SHORT_ID" --argjson port "$sport" --argjson cport "$cport" \
        '{log:{loglevel:"warning"},
          inbounds:[{listen:"127.0.0.1",port:$cport,protocol:"socks"}],
          outbounds:[{protocol:"vless",
                      settings:{vnext:[{address:"127.0.0.1",port:$port,users:[{id:$u,encryption:"none",flow:"xtls-rprx-vision"}]}]},
                      streamSettings:{network:"tcp",security:"reality",
                                      realitySettings:{serverName:$sni,fingerprint:"chrome",publicKey:$pbk,shortId:$sid}}}]}' > "$tmp_c"

    local rs="/tmp/xray-probe-s.$$.json" rc="/tmp/xray-probe-c.$$.json"
    { _scp_cmd "$tmp_s" "${SSH_USER}@${SERVER_IP}:${rs}" && _scp_cmd "$tmp_c" "${SSH_USER}@${SERVER_IP}:${rc}"; } >/dev/null 2>&1 \
        || { log WARN "Probe: не удалось загрузить конфиги на сервер"; return 2; }

    local out code
    out=$(_ssh_cmd "
        chown ${owner} ${rs} ${rc}; chmod ${mode} ${rs}; chmod 644 ${rc}
        docker rm -f -v xray-probe-s xray-probe-c >/dev/null 2>&1 || true
        docker run -d --name xray-probe-s --network host ${ep} -v ${rs}:/etc/xray/config.json:ro ${image} run -config /etc/xray/config.json >/dev/null 2>&1
        docker run -d --name xray-probe-c --network host ${ep} -v ${rc}:/etc/xray/config.json:ro ${image} run -config /etc/xray/config.json >/dev/null 2>&1
        sleep ${WAIT_CLIENT_READY}
        code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time ${HTTP_TIMEOUT_PROBE} -x socks5h://127.0.0.1:${cport} https://www.gstatic.com/generate_204 2>/dev/null); [ -z \"\$code\" ] && code=000
        echo \"CODE=\$code\"
        [ \"\$code\" != 204 ] && docker logs --tail 5 xray-probe-s 2>&1 | grep -i reality
        docker rm -f -v xray-probe-s xray-probe-c >/dev/null 2>&1 || true
        rm -f ${rs} ${rc}" 2>/dev/null) || true
    code=$(echo "$out" | sed -n 's/^CODE=//p' | tail -1)
    if [[ "$code" == "204" ]]; then
        log SUCCESS "SNI-цель ${sni} пригодна: Reality-рукопожатие и трафик через туннель работают"; return 0
    fi
    log ERROR "SNI-цель ${sni} НЕ работает с Reality (ответ: ${code:-нет})"
    echo "$out" | grep -v '^CODE=' | head -3
    return 1
}

# Проба Reality на ядре sing-box: временный сервер и клиент на 127.0.0.1 с теми же ключами
probe_reality_singbox() {   # $1 = SNI
    local sni="$1"
    local sport cport uuid
    sport=$(pick_free_port 30000 20000)
    cport=$(pick_free_port 10000 20000)
    uuid=$(execute_remote_output "cat /proc/sys/kernel/random/uuid" | tr -d '[:space:]')
    [[ -z "$uuid" ]] && uuid="11111111-1111-4111-8111-111111111111"
    log STEP "Проверка SNI-цели ${sni} настоящим Reality-рукопожатием (временный сервер 127.0.0.1:${sport})..."

    local tmp_s tmp_c; tmp_s=$(create_temp); tmp_c=$(create_temp)
    jq -n --arg u "$uuid" --arg sni "$sni" --arg priv "$REALITY_PRIVATE_KEY" --arg sid "$REALITY_SHORT_ID" --argjson port "$sport" \
        '{log:{level:"warn"},
          inbounds:[{type:"vless",tag:"in",listen:"127.0.0.1",listen_port:$port,
                     users:[{name:"probe",uuid:$u,flow:"xtls-rprx-vision"}],
                     tls:{enabled:true,server_name:$sni,
                          reality:{enabled:true,handshake:{server:$sni,server_port:443},
                                   private_key:$priv,short_id:[$sid]}}}],
          outbounds:[{type:"direct",tag:"direct"}]}' > "$tmp_s"
    jq -n --arg u "$uuid" --arg sni "$sni" --arg pbk "$REALITY_PUBLIC_KEY" --arg sid "$REALITY_SHORT_ID" --argjson port "$sport" --argjson cport "$cport" \
        '{log:{level:"warn"},
          inbounds:[{type:"mixed",tag:"in",listen:"127.0.0.1",listen_port:$cport}],
          outbounds:[{type:"vless",tag:"proxy",server:"127.0.0.1",server_port:$port,uuid:$u,flow:"xtls-rprx-vision",
                      tls:{enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"},
                           reality:{enabled:true,public_key:$pbk,short_id:$sid}}},
                     {type:"direct",tag:"direct"}],
          route:{final:"proxy"}}' > "$tmp_c"

    local rs="/tmp/singbox-probe-s.$$.json" rc="/tmp/singbox-probe-c.$$.json"
    { _scp_cmd "$tmp_s" "${SSH_USER}@${SERVER_IP}:${rs}" && _scp_cmd "$tmp_c" "${SSH_USER}@${SERVER_IP}:${rc}"; } >/dev/null 2>&1 \
        || { log WARN "Probe: не удалось загрузить конфиги на сервер"; return 2; }

    local out code
    out=$(_ssh_cmd "
        chmod 644 ${rs} ${rc}
        docker rm -f -v singbox-probe-s singbox-probe-c >/dev/null 2>&1 || true
        docker run -d --name singbox-probe-s --network host -v ${rs}:/c.json:ro ${XRAY_IMAGE} run -c /c.json >/dev/null 2>&1
        docker run -d --name singbox-probe-c --network host -v ${rc}:/c.json:ro ${XRAY_IMAGE} run -c /c.json >/dev/null 2>&1
        sleep ${WAIT_CLIENT_READY}
        code=\$(curl -s -o /dev/null -w '%{http_code}' --max-time ${HTTP_TIMEOUT_PROBE} -x socks5h://127.0.0.1:${cport} https://www.gstatic.com/generate_204 2>/dev/null); [ -z \"\$code\" ] && code=000
        echo \"CODE=\$code\"
        [ \"\$code\" != 204 ] && docker logs --tail 5 singbox-probe-s 2>&1 | tail -3
        docker rm -f -v singbox-probe-s singbox-probe-c >/dev/null 2>&1 || true
        rm -f ${rs} ${rc}" 2>/dev/null) || true
    code=$(echo "$out" | sed -n 's/^CODE=//p' | tail -1)
    if [[ "$code" == "204" ]]; then
        log SUCCESS "SNI-цель ${sni} пригодна: Reality-рукопожатие и трафик через туннель работают"; return 0
    fi
    log ERROR "SNI-цель ${sni} НЕ работает с Reality (ответ: ${code:-нет})"
    echo "$out" | grep -v '^CODE=' | head -3
    return 1
}

# Единая точка: выбирает пробу под текущее ядро
probe_reality() {   # $1 = SNI
    if is_singbox; then
        probe_reality_singbox "$1"
    else
        probe_reality_target "$1" "$XRAY_IMAGE" "$(image_source_of "$XRAY_IMAGE")"
    fi
}

# Перевыпуск самоподписанного сертификата (Hysteria2 и TUIC): имя сервера зашито в сертификат
reissue_selfsigned_cert() {   # $1 = новое имя
    local sni="$1"
    log STEP "Перевыпуск самоподписанного сертификата на ${sni}..."
    # sing-box следит за файлами сертификата и ключа и перечитывает пару, как только
    # меняется любой из них. При подмене на живую между двумя mv он успевает увидеть
    # новый ключ со старым сертификатом и пишет в лог «private key does not match
    # public key». Поэтому сначала готовим и сверяем пару, потом останавливаем
    # контейнер и только затем подменяем оба файла; обратно его поднимет
    # restart_container из push_and_apply_config.
    execute_remote "
        set -e
        mkdir -p ${INSTALL_DIR}/certs
        cd ${INSTALL_DIR}/certs
        docker run --rm ${XRAY_IMAGE} generate tls-keypair '${sni}' -m ${SELFSIGNED_MONTHS} > combined.pem
        awk '/BEGIN PRIVATE KEY/,/END PRIVATE KEY/' combined.pem > key.pem.new
        awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/'  combined.pem > cert.pem.new
        rm -f combined.pem
        [ -s key.pem.new ] && [ -s cert.pem.new ]
        c=\$(openssl x509 -in cert.pem.new -noout -pubkey 2>/dev/null | openssl md5)
        k=\$(openssl pkey -in key.pem.new -pubout 2>/dev/null | openssl md5)
        if [ -z \"\$c\" ] || [ \"\$c\" != \"\$k\" ]; then
            rm -f key.pem.new cert.pem.new
            echo 'Ключ и сертификат не сошлись — подмена не выполнена'
            exit 1
        fi
        echo 'Пара ключ/сертификат сверена'
    " "Создание сертификата" || return 1

    execute_remote "cd ${INSTALL_DIR} && docker compose stop $(compose_service) >/dev/null 2>&1 || true" \
        "Остановка контейнера на время подмены" 1 || true

    # Прежнюю пару сохраняем рядом: если применить конфиг не удастся, её вернёт
    # restore_selfsigned_cert. Без этого имя в сертификате разошлось бы с именем в
    # конфиге, а контейнер остался бы остановленным.
    execute_remote "
        set -e
        cd ${INSTALL_DIR}/certs
        if [ -f cert.pem ] && [ -f key.pem ]; then
            cp -p cert.pem cert.pem.prev
            cp -p key.pem  key.pem.prev
        fi
        mv key.pem.new key.pem
        mv cert.pem.new cert.pem
        chmod 600 key.pem
        chmod 644 cert.pem
    " "Подмена сертификата" 1 || {
        log ERROR "Подмена не завершилась — возврат прежней пары"
        restore_selfsigned_cert || true
        return 1
    }
}

# Возврат прежней пары ключ/сертификат и подъём контейнера. Нужен потому, что
# reissue_selfsigned_cert останавливает контейнер и подменяет файлы, а поднимает его
# restart_container внутри push_and_apply_config — то есть шагом позже. Если до него
# дело не дошло, без возврата сервис остался бы остановленным, да ещё с именем в
# сертификате, разошедшимся с именем в конфиге.
restore_selfsigned_cert() {
    log WARN "Возврат прежнего сертификата..."
    if execute_remote "
        set -e
        cd ${INSTALL_DIR}/certs
        [ -f cert.pem.prev ] && [ -f key.pem.prev ]
        mv key.pem.prev key.pem
        mv cert.pem.prev cert.pem
        chmod 600 key.pem
        chmod 644 cert.pem
    " "Восстановление прежней пары" 1 && restart_container; then
        log SUCCESS "Прежнее имя ${XRAY_REALITY_SNI} восстановлено, сервис работает"
        return 0
    fi
    log ERROR "Прежний сертификат восстановить не удалось — сервис остановлен"
    log ERROR "Поднять вручную: cd ${INSTALL_DIR} && docker compose up -d $(compose_service)"
    return 1
}

make_vless_link() {
    local uuid="$1" name="$2"
    if [[ "$TRANSPORT" == "tcp" ]]; then
        echo "vless://${uuid}@${PUBLIC_IP}:${XRAY_PORT}?security=reality&sni=${XRAY_REALITY_SNI}&fp=${CURRENT_FINGERPRINT}&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${name}"
        return
    fi
    # XHTTP (Reality или TLS): path берём из конфига, кодируем для URI
    local xhttp_path encoded_path
    xhttp_path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path // "/download"' "${CURRENT_CONFIG_TMP:-/dev/null}" 2>/dev/null) || xhttp_path="/download"
    [[ -z "$xhttp_path" || "$xhttp_path" == "null" ]] && xhttp_path="/download"
    encoded_path=$(python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$xhttp_path" 2>/dev/null || echo "$xhttp_path")
    if [[ "$TRANSPORT" == "tls" ]]; then
        local domain="${TLS_DOMAIN:-${PUBLIC_IP}}"
        echo "vless://${uuid}@${domain}:443?security=tls&sni=${domain}&fp=${CURRENT_FINGERPRINT}&type=xhttp&path=${encoded_path}&host=${domain}&mode=auto#${name}"
    else
        echo "vless://${uuid}@${PUBLIC_IP}:${XRAY_PORT}?security=reality&sni=${XRAY_REALITY_SNI}&fp=${CURRENT_FINGERPRINT}&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=xhttp&path=${encoded_path}&mode=auto#${name}"
    fi
}

# Ссылка пользователя с индексом $1 из текущего конфига — единая точка для обоих ядер.
# У sing-box поля зависят от протокола: uuid для VLESS и TUIC, пароль для Hysteria2 и TUIC.
make_user_link() {   # $1 = индекс пользователя (с нуля)
    local i="$1" cfg="${CURRENT_CONFIG_TMP:-/dev/null}"
    local name uuid pass
    if ! is_singbox; then
        name=$(jq -r ".inbounds[0].settings.clients[$i].email" "$cfg" 2>/dev/null)
        uuid=$(jq -r ".inbounds[0].settings.clients[$i].id"    "$cfg" 2>/dev/null)
        make_vless_link "$uuid" "$name"
        return
    fi
    name=$(jq -r ".inbounds[0].users[$i].name // \"user\""   "$cfg" 2>/dev/null)
    uuid=$(jq -r ".inbounds[0].users[$i].uuid // empty"      "$cfg" 2>/dev/null)
    pass=$(jq -r ".inbounds[0].users[$i].password // empty"  "$cfg" 2>/dev/null)
    case "$TRANSPORT" in
        vless-reality)
            echo "vless://${uuid}@${PUBLIC_IP}:${XRAY_PORT}?security=reality&sni=${XRAY_REALITY_SNI}&fp=${CURRENT_FINGERPRINT}&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&flow=xtls-rprx-vision#${name}" ;;
        hysteria2)
            # insecure=1: сертификат самоподписанный, клиент проверяет только имя
            echo "hysteria2://${pass}@${PUBLIC_IP}:${XRAY_PORT}/?sni=${XRAY_REALITY_SNI}&insecure=1#${name}" ;;
        tuic)
            echo "tuic://${uuid}:${pass}@${PUBLIC_IP}:${XRAY_PORT}?sni=${XRAY_REALITY_SNI}&alpn=h3&congestion_control=bbr&allow_insecure=1#${name}" ;;
        *)
            log ERROR "Неизвестный протокол sing-box: ${TRANSPORT}"; return 1 ;;
    esac
}

# Глобальный путь к локальной копии конфига
CURRENT_CONFIG_TMP=""

get_clients_from_config() {
    CURRENT_CONFIG_TMP=$(mktemp)
    TEMP_FILES+=("$CURRENT_CONFIG_TMP")
    get_remote_file "$(cfg_path)" "$CURRENT_CONFIG_TMP" "Чтение конфига" || return 1
}

# ============================================
# 1. ПРОСМОТР ПОЛЬЗОВАТЕЛЕЙ И ССЫЛОК
# ============================================

view_links() {
    print_header "Пользователи и ссылки"

    get_clients_from_config || return 1
    local tmp_cfg="$CURRENT_CONFIG_TMP"
    local cnt; cnt=$(users_count "$tmp_cfg")

    if [[ "$cnt" -eq 0 ]]; then
        log WARN "Пользователей не найдено"; return 0
    fi

    echo -e "${BLUE}Установка:${NC}"
    echo -e "  Контейнер:  ${GREEN}${CONTAINER_NAME}${NC}"
    echo -e "  Ядро:       ${GREEN}$(core_label)${NC}"
    echo -e "  Протокол:   ${GREEN}$(transport_label)${NC}"
    if [[ "$TRANSPORT" == "tls" ]]; then
        echo -e "  Домен:      ${GREEN}${TLS_DOMAIN}${NC}"
    else
        echo -e "  IP:Порт:    ${GREEN}${PUBLIC_IP}:${XRAY_PORT}${NC}"
        if is_reality; then
            echo -e "  SNI:        ${GREEN}${XRAY_REALITY_SNI}${NC}"
            echo -e "  Public Key: ${GREEN}${REALITY_PUBLIC_KEY}${NC}"
            echo -e "  Short ID:   ${GREEN}${REALITY_SHORT_ID}${NC}"
        else
            echo -e "  SNI:        ${GREEN}${XRAY_REALITY_SNI}${NC} ${CYAN}(имя в самоподписанном сертификате)${NC}"
        fi
    fi
    echo -e "  Образ:      ${GREEN}${XRAY_IMAGE}${NC}"
    echo
    echo -e "${BLUE}Пользователи (${cnt}):${NC}"
    echo -e "${BLUE}------------------------------------------${NC}"

    local i
    for ((i=0; i<cnt; i++)); do
        local name link
        name=$(user_name_at "$tmp_cfg" "$i")
        link=$(make_user_link "$i")
        echo
        echo -e "  ${GREEN}${name}${NC}"
        if is_singbox; then
            local uuid pass
            uuid=$(jq -r ".inbounds[0].users[$i].uuid // empty"     "$tmp_cfg" 2>/dev/null)
            pass=$(jq -r ".inbounds[0].users[$i].password // empty" "$tmp_cfg" 2>/dev/null)
            [[ -n "$uuid" ]] && echo -e "  UUID:   ${CYAN}${uuid}${NC}"
            [[ -n "$pass" ]] && echo -e "  Пароль: ${CYAN}${pass}${NC}"
        else
            local uuid; uuid=$(jq -r ".inbounds[0].settings.clients[$i].id" "$tmp_cfg" 2>/dev/null)
            echo -e "  UUID: ${CYAN}${uuid}${NC}"
        fi
        echo -e "  ${YELLOW}${link}${NC}"
    done
    echo
    echo -e "${BLUE}------------------------------------------${NC}"
}

# ============================================
# 2. ДОБАВИТЬ ПОЛЬЗОВАТЕЛЯ
# ============================================

add_users() {
    print_header "Добавление пользователей"

    local count
    get_input "Количество пользователей" "count" "1" "validate_count" "Введите число от 1 до 12"

    get_clients_from_config || return 1
    local tmp_cfg="$CURRENT_CONFIG_TMP"
    local users_json; users_json=$(jq "$(users_jq)" "$tmp_cfg")

    local i
    for ((i=1; i<=count; i++)); do
        local uname
        get_input "Имя пользователя $i" "uname" "" "validate_user" "Только a-z A-Z 0-9 _ -"

        local exists
        exists=$(echo "$users_json" | jq --arg e "$uname" --arg f "$(name_field)" \
            '[.[] | select(.[$f] == $e)] | length') || exists=0
        if [[ "$exists" -gt 0 ]]; then
            log WARN "Пользователь '${uname}' уже существует — пропускаем"
            continue
        fi

        local uuid=""
        # UUID нужен для VLESS (оба ядра) и для TUIC; Hysteria2 работает только по паролю
        if [[ "$TRANSPORT" != "hysteria2" ]]; then
            uuid=$(execute_remote_output "cat /proc/sys/kernel/random/uuid" | tr -d '[:space:]')
            [[ -z "$uuid" ]] && { log ERROR "Не удалось сгенерировать UUID"; continue; }
        fi

        if is_singbox; then
            local pass=""
            if is_quic; then
                pass=$(execute_remote_output "openssl rand -base64 24 | tr -d '=+/' | cut -c1-24" | tr -d '[:space:]')
                [[ -z "$pass" ]] && { log ERROR "Не удалось сгенерировать пароль"; continue; }
            fi
            case "$TRANSPORT" in
                vless-reality) users_json=$(echo "$users_json" | jq --arg n "$uname" --arg u "$uuid" \
                                   '. += [{"name": $n, "uuid": $u, "flow": "xtls-rprx-vision"}]') ;;
                hysteria2)     users_json=$(echo "$users_json" | jq --arg n "$uname" --arg p "$pass" \
                                   '. += [{"name": $n, "password": $p}]') ;;
                tuic)          users_json=$(echo "$users_json" | jq --arg n "$uname" --arg u "$uuid" --arg p "$pass" \
                                   '. += [{"name": $n, "uuid": $u, "password": $p}]') ;;
                *) log ERROR "Неизвестный протокол sing-box: ${TRANSPORT}"; return 1 ;;
            esac
            log SUCCESS "Добавлен: ${uname}${uuid:+ (${uuid})}"
        else
            if [[ "$TRANSPORT" == "tcp" ]]; then
                users_json=$(echo "$users_json" | jq --arg id "$uuid" --arg email "$uname" \
                    '. += [{"id": $id, "email": $email, "flow": "xtls-rprx-vision"}]')
            else
                users_json=$(echo "$users_json" | jq --arg id "$uuid" --arg email "$uname" \
                    '. += [{"id": $id, "email": $email}]')
            fi
            log SUCCESS "Добавлен: ${uname} (${uuid})"
        fi
    done

    apply_clients_update "$tmp_cfg" "$users_json"
}

# ============================================
# 3. УДАЛИТЬ ПОЛЬЗОВАТЕЛЯ
# ============================================

delete_users() {
    print_header "Удаление пользователей"

    get_clients_from_config || return 1
    local tmp_cfg="$CURRENT_CONFIG_TMP"
    local cnt; cnt=$(users_count "$tmp_cfg")

    if [[ "$cnt" -eq 0 ]]; then log WARN "Нет пользователей для удаления"; return 0; fi
    if [[ "$cnt" -eq 1 ]]; then log WARN "Нельзя удалить единственного пользователя"; return 0; fi

    echo -e "${CYAN}Пользователи:${NC}"; echo
    local i
    for ((i=0; i<cnt; i++)); do
        echo -e "  ${GREEN}$((i+1)))${NC} $(user_name_at "$tmp_cfg" "$i")"
    done
    echo

    local choice
    while true; do
        read -r -p "Удалить пользователя (1-${cnt}): " choice
        [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= cnt)) && break
        log WARN "Введите число от 1 до ${cnt}"
    done

    local idx=$((choice-1)) nm
    nm=$(user_name_at "$tmp_cfg" "$idx")

    ask_yn "Удалить '${nm}'?" || { log INFO "Отменено"; return 0; }

    local users_json
    users_json=$(jq --argjson i "$idx" "$(users_jq) | del(.[\$i])" "$tmp_cfg") \
        || { log ERROR "Не удалось изменить список пользователей (jq)"; return 1; }

    apply_clients_update "$tmp_cfg" "$users_json" || { log ERROR "Удаление не применено"; return 1; }
    log SUCCESS "Пользователь '${nm}' удалён"
}

# ============================================
# АТОМАРНОЕ ОБНОВЛЕНИЕ КОНФИГА
# ============================================

apply_clients_update() {
    local tmp_cfg="$1" new_users="$2"
    local new_cfg
    new_cfg=$(jq --argjson users "$new_users" "$(users_jq) = \$users" "$tmp_cfg") \
        || { log ERROR "Не удалось собрать конфиг (jq)"; return 1; }
    local tmp_new; tmp_new=$(create_temp)
    echo "$new_cfg" > "$tmp_new"
    push_and_apply_config "$tmp_new"
}

# ============================================
# 4. СМЕНИТЬ ИМЯ СЕРВЕРА (SNI)
# ============================================

change_sni() {
    print_header "Смена имени сервера (SNI)"
    if [[ "$TRANSPORT" == "tls" ]]; then
        log WARN "SNI не применимо для XHTTP+TLS+Domain: имя берётся из домена и сертификата Let's Encrypt"
        return 0
    fi

    local default_sni
    if is_quic; then
        default_sni="$SELFSIGNED_SNI_DEFAULT"
        echo -e "  ${CYAN}Протокол:${NC} ${GREEN}$(transport_label)${NC}"
        echo -e "  ${CYAN}Имя в сертификате сейчас:${NC} ${GREEN}${XRAY_REALITY_SNI}${NC}"
        echo -e "  ${YELLOW}Сертификат будет перевыпущен на новое имя, старые ссылки перестанут подходить.${NC}"
    else
        default_sni="$XRAY_REALITY_SNI_DEFAULT"
        echo -e "  ${CYAN}Текущий SNI:${NC} ${GREEN}${XRAY_REALITY_SNI}${NC}"
    fi

    # Имя принимается, только пройдя все ступени проверки. Продолжить с непрошедшим
    # именем нельзя: с нерабочей целью протокол не заработает.
    local new_sni=""
    while true; do
        echo
        echo -e "  ${GREEN}1)${NC} ${default_sni}"
        echo -e "  ${GREEN}2)${NC} Ввести своё имя"
        echo -e "  ${RED}0)${NC} Назад"
        echo
        local choice; read -r -p "Выберите (0-2): " choice
        case $choice in
            1) new_sni="$default_sni" ;;
            2) get_input "Имя сервера" "new_sni" "" "validate_domain" "Некорректное имя" ;;
            0) return 0 ;;
            *) log WARN "Введите 0, 1 или 2"; continue ;;
        esac
        [[ "$new_sni" == "$XRAY_REALITY_SNI" ]] && { log INFO "Уже используется ${new_sni}"; return 0; }

        if is_reality; then
            if ! check_sni_target "$new_sni"; then
                ask_retry_or_cancel && continue
                log INFO "Отменено"; return 0
            fi
            if [[ -n "$REALITY_PRIVATE_KEY" ]]; then
                if ! probe_reality "$new_sni"; then
                    ask_retry_or_cancel && continue
                    log INFO "Отменено"; return 0
                fi
            else
                log WARN "Приватный ключ не прочитан — Reality-проверка цели пропущена"
            fi
        else
            if ! check_cert_name "$new_sni"; then
                ask_retry_or_cancel && continue
                log INFO "Отменено"; return 0
            fi
        fi
        break
    done

    local tmp_new; tmp_new=$(create_temp)
    local new_config sni_cert_swapped=0

    if is_reality; then
        get_clients_from_config || return 1
        if is_singbox; then
            new_config=$(jq --arg sni "$new_sni" \
                '.inbounds[0].tls.server_name = $sni |
                 .inbounds[0].tls.reality.handshake.server = $sni' "$CURRENT_CONFIG_TMP")
        else
            new_config=$(jq --arg sni "$new_sni" \
                '.inbounds[0].streamSettings.realitySettings.serverNames = [$sni] |
                 .inbounds[0].streamSettings.realitySettings.dest = ($sni + ":443")' "$CURRENT_CONFIG_TMP")
        fi
        [[ -z "$new_config" ]] && { log ERROR "Не удалось изменить конфиг (jq)"; return 1; }
        echo "$new_config" > "$tmp_new"
    else
        # Hysteria2 и TUIC: имя зашито в самоподписанный сертификат — перевыпускаем.
        # Конфиг готовим ДО перевыпуска: пока пара ключ/сертификат не подменена, любой
        # отказ здесь ничего на сервере не меняет и возвращать нечего.
        ask_yn "Перевыпустить сертификат на ${new_sni}?" || { log INFO "Отменено"; return 0; }

        get_clients_from_config || return 1
        # У Hysteria2 то же имя стоит в параметре masquerade. Меняем оба поля, иначе
        # masquerade остаётся на прежнем имени. У TUIC поля masquerade нет.
        new_config=$(jq --arg sni "$new_sni" \
            '.inbounds[0].tls.server_name = $sni
             | if .inbounds[0].masquerade
               then .inbounds[0].masquerade.url = ("https://" + $sni)
               else . end' "$CURRENT_CONFIG_TMP") \
            || { log ERROR "Не удалось изменить конфиг (jq)"; return 1; }
        [[ -z "$new_config" ]] && { log ERROR "Не удалось изменить конфиг (jq)"; return 1; }
        echo "$new_config" > "$tmp_new"

        # Дальше точка невозврата: контейнер останавливается, файлы подменяются
        reissue_selfsigned_cert "$new_sni" || { log ERROR "Сертификат не перевыпущен — конфиг не тронут"; return 1; }
        sni_cert_swapped=1
    fi

    if ! push_and_apply_config "$tmp_new"; then
        log ERROR "Имя сервера не изменено"
        [[ $sni_cert_swapped -eq 1 ]] && restore_selfsigned_cert
        return 1
    fi
    if [[ $sni_cert_swapped -eq 1 ]]; then
        execute_remote "rm -f ${INSTALL_DIR}/certs/cert.pem.prev ${INSTALL_DIR}/certs/key.pem.prev" "" 1 || true
    fi

    # Обновляем файл с данными — из него менеджер читает SNI при следующем запуске
    execute_remote "sed -i 's|^SNI:.*|SNI:         ${new_sni}|' $(info_file)" "Обновление $(basename "$(info_file)")" 1 \
        || log WARN "Файл данных не обновлён — при следующем запуске может показаться прежнее имя"

    XRAY_REALITY_SNI="$new_sni"
    log SUCCESS "Имя сервера изменено на: ${new_sni}"
    run_selftest || log WARN "С новым именем клиент не подключается — проверьте цель или верните прежнее"
    echo
    echo -e "${YELLOW}Внимание: имя изменилось и в ссылках.${NC}"
    echo -e "${YELLOW}Выдайте пользователям новые ссылки (пункт 1).${NC}"
}

# ============================================
# 5. СТАТУС
# ============================================

check_status() {
    print_header "Статус установки"

    echo -e "${BLUE}Контейнер:${NC}"
    execute_remote \
        "docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' \
         | grep -E 'NAMES|${CONTAINER_NAME}' || echo 'Не найден'" "" 1

    echo
    echo -e "${BLUE}Последние логи:${NC}"
    execute_remote "docker logs --tail 15 ${CONTAINER_NAME} 2>&1" "" 1

    echo
    echo -e "${BLUE}Использование ресурсов:${NC}"
    execute_remote \
        "docker stats ${CONTAINER_NAME} --no-stream --format \
         'CPU: {{.CPUPerc}}  RAM: {{.MemUsage}}' 2>/dev/null || echo 'Нет данных (контейнер не запущен)'" "" 1
}

# ============================================
# 6. ПЕРЕЗАПУСК
# ============================================

restart_xray() {
    print_header "Перезапуск $(core_label)"
    restart_container || return 1
    execute_remote \
        "docker ps -a --format '{{.Names}} {{.Status}}' | grep ${CONTAINER_NAME}" \
        "Проверка статуса" 1
}

# ============================================
# 7. ОБНОВЛЕНИЕ XRAY
# ============================================

update_compose_image() {
    local install_dir="$1" new_image="$2" desc="${3:-Обновление docker-compose.yml}" retries="${4:-$SSH_RETRIES}"
    local tmp_py; tmp_py=$(create_temp)
    cat > "$tmp_py" << 'PYEOF'
import sys, json, re
path, new_img, svc = sys.argv[1], sys.argv[2], sys.argv[3]
c = open(path).read()
try:
    d = json.loads(c)
    d['services'][svc]['image'] = new_img
    open(path, 'w').write(json.dumps(d, indent=2))
except Exception:
    # Compose генерируется через jq, то есть это JSON, и сюда попадают только файлы,
    # правленные руками. Слепая замена всех полей image опасна: в схеме с доменом служб
    # две, и образ Xray встал бы контейнеру Caddy. Меняем только когда поле одно и
    # двусмысленности нет, иначе отказываемся.
    hits = re.findall(r'"image":\s*"[^"]*"', c)
    if len(hits) != 1:
        sys.stderr.write('docker-compose.yml не разобран как JSON, полей image: %d. '
                         'Какое относится к службе %s — определить нельзя, образ не изменён\n'
                         % (len(hits), svc))
        sys.exit(1)
    open(path, 'w').write(re.sub(r'"image":\s*"[^"]*"', '"image": "' + new_img + '"', c))
PYEOF
    copy_to_remote "$tmp_py" "/tmp/_upd_compose.py" "" || return 1
    execute_remote "python3 /tmp/_upd_compose.py '${install_dir}/docker-compose.yml' '${new_image}' '$(compose_service)' && rm -f /tmp/_upd_compose.py" "$desc" "$retries"
}


upgrade_xray() {
    print_header "Версия $(core_label) (обновление версии)"

    # Реальный образ из docker-compose.yml на сервере (compose сгенерирован jq → это JSON)
    local real_image
    real_image=$(execute_remote_output \
        "jq -r '.services.\"$(compose_service)\".image // empty' ${INSTALL_DIR}/docker-compose.yml 2>/dev/null || grep 'image:' ${INSTALL_DIR}/docker-compose.yml | head -1 | awk '{print \$2}'" \
        | tr -d '[:space:]"') || true
    [[ -n "${real_image:-}" ]] && XRAY_IMAGE="$real_image"

    local image_base="${XRAY_IMAGE%%:*}"
    local current_tag="${XRAY_IMAGE##*:}"
    local running_ver
    if is_singbox; then
        running_ver=$(execute_remote_output "docker exec ${CONTAINER_NAME} sing-box version 2>/dev/null | head -1 | awk '{print \$3}'" | tr -d '[:space:]') || true
    else
        running_ver=$(execute_remote_output "docker exec ${CONTAINER_NAME} xray version 2>/dev/null | head -1 | awk '{print \$2}'" | tr -d '[:space:]') || true
    fi

    echo -e "  ${CYAN}Образ в compose:${NC}  ${GREEN}${XRAY_IMAGE}${NC}"
    echo -e "  ${CYAN}Версия в контейнере:${NC} ${GREEN}${running_ver:-неизвестно}${NC}"
    echo
    log STEP "Запрос версий: реестр ${image_base} и релизы GitHub $(core_github_repo)..."
    local newest stable
    newest=$(registry_newest_tag "$image_base") || newest=""
    stable=$(github_stable_release "$(core_github_repo)") || stable=""
    # У Xray теги образов без префикса «v», у sing-box — с ним
    is_singbox || stable="${stable#v}"
    echo -e "  ${CYAN}Новейшая в реестре:${NC} ${GREEN}${newest:-не удалось получить}${NC}"
    echo -e "  ${CYAN}Стабильный релиз:${NC}   ${GREEN}${stable:-не удалось получить}${NC}"
    if is_singbox; then
        echo -e "  ${CYAN}Версии alpha, beta и rc в sing-box — тестовые, могут быть нестабильны.${NC}"
    else
        echo -e "  ${CYAN}Тег latest у official указывает на стабильный релиз, у teddysun — на новейшую версию.${NC}"
    fi
    echo
    echo -e "  ${GREEN}1)${NC} Новейшая версия в реестре${newest:+ (${newest})}"
    echo -e "  ${GREEN}2)${NC} Стабильный релиз${stable:+ (${stable})}"
    local ver_example; if is_singbox; then ver_example="${DEFAULT_SINGBOX_IMAGE##*:}"; else ver_example="$DEFAULT_XRAY_VERSION"; fi
    echo -e "  ${GREEN}3)${NC} Указать версию вручную (например: ${ver_example})"
    echo -e "  ${RED}0)${NC} Назад"
    echo

    local ver_choice new_tag new_image
    while true; do
        read -r -p "Выберите (0-3): " ver_choice
        case "$ver_choice" in
            0) return 0 ;;
            1)
                [[ -z "$newest" ]] && { log WARN "Список тегов реестра недоступен — выберите другой вариант"; continue; }
                new_tag="$newest"; break ;;
            2)
                [[ -z "$stable" ]] && { log WARN "GitHub недоступен — выберите другой вариант"; continue; }
                new_tag="$stable"; break ;;
            3)
                get_input "Введите тег версии" "new_tag" "" "validate_tag" "Недопустимый тег"; break ;;
            *) log WARN "Введите число от 0 до 3" ;;
        esac
    done
    new_image="${image_base}:${new_tag}"

    [[ "$new_tag" == "$current_tag" ]] && { log INFO "Уже установлена версия ${current_tag}"; return 0; }

    # Существование тега в реестре — до любых изменений
    if ! execute_remote_output "docker manifest inspect ${new_image} >/dev/null 2>&1 && echo OK" | grep -q OK; then
        log ERROR "Тег ${new_tag} не найден в реестре ${image_base}"; return 1
    fi

    # Понижение версии — отдельное предупреждение
    if [[ "$current_tag" =~ ^[0-9] && "$new_tag" =~ ^[0-9] ]] && version_lt "$new_tag" "$current_tag"; then
        log WARN "Это ПОНИЖЕНИЕ версии: ${current_tag} → ${new_tag}"
        ask_yes_no_word "Понизить версию?" || { log INFO "Отменено"; return 0; }
    fi

    # Xray ≥ 26.7: Reality по умолчанию требует клиент Xray-core ≥ 26.3.27 — sing-box и другие
    # не-Xray клиенты отклоняются («reality verification failed»), если в конфиге нет minClientVer.
    if ! is_singbox && [[ "$TRANSPORT" != "tls" && "$new_tag" =~ ^[0-9] ]] && ! version_lt "$new_tag" "26.7.0"; then
        log WARN "Xray ${new_tag}: сервер Reality по умолчанию принимает только клиентов на ядре Xray-core ≥ 26.3.27 (проверка версии клиента в рукопожатии)."
        log WARN "Клиенты с собственной реализацией Reality (Shadowrocket, sing-box и др.) будут отвергаться — «нет интернета». Решение: задать realitySettings.minClientVer."
    fi

    log STEP "Обновление: ${XRAY_IMAGE} → ${new_image}"
    ask_yn "Продолжить?" || { log INFO "Отменено"; return 0; }

    execute_remote "docker pull -q ${new_image}" "Загрузка ${new_image}" 1 || { log ERROR "Образ не загружен — compose не изменён"; return 1; }

    # Текущий конфиг должен проходить проверку новой версией
    log STEP "Проверка текущего конфига версией ${new_tag}..."
    core_test_remote "$(cfg_path)" "$new_image" || { log ERROR "Конфиг несовместим с ${new_tag} — обновление отменено"; return 1; }
    log SUCCESS "Конфиг совместим с ${new_tag}"

    local old_image="$XRAY_IMAGE"
    update_compose_image "${INSTALL_DIR}" "${new_image}" "Обновление docker-compose.yml" 1 || return 1
    execute_remote "cd ${INSTALL_DIR} && docker compose up -d --force-recreate $(compose_service)" "Применение новой версии" 1 || true

    sleep "$WAIT_CLIENT_READY"
    local actual running
    actual=$(execute_remote_output "docker inspect -f '{{.Config.Image}}' ${CONTAINER_NAME} 2>/dev/null" | tr -d '[:space:]') || true
    running=$(execute_remote_output "docker inspect -f '{{.State.Running}}' ${CONTAINER_NAME} 2>/dev/null" | tr -d '[:space:]') || true

    if [[ "$running" == "true" && "$actual" == "$new_image" ]]; then
        XRAY_IMAGE="$new_image"; CONTAINER_STATUS="Up"
        log SUCCESS "Обновлено до ${new_image} (в контейнере: $(image_version "$new_image"))"
        run_selftest || log WARN "После обновления клиент не подключается — рассмотрите откат (пункт 7, укажите ${current_tag})"
        [[ "$TRANSPORT" != "tls" ]] && execute_remote "sed -i 's|^Image:.*|Image:       ${new_image}|' $(info_file)" "" 1 || true
        execute_remote "docker rmi ${old_image} 2>/dev/null; docker image prune -f >/dev/null 2>&1 || true" "" 1 || true
    else
        log ERROR "Контейнер не работает на новом образе (running=${running:-?}, image=${actual:-?}) — откат"
        execute_remote "docker logs --tail 20 ${CONTAINER_NAME} 2>&1" "" 1 || true
        update_compose_image "${INSTALL_DIR}" "${old_image}" "Откат docker-compose.yml" 1 || true
        execute_remote "cd ${INSTALL_DIR} && docker compose up -d --force-recreate $(compose_service)" "Откат" 1 || true
        sleep "$WAIT_CLIENT_READY"
        # Об успехе отката судим не по тому, что команды запущены, а по фактически
        # запущенному образу — тем же способом, что и прямой путь выше.
        local back_img back_run
        back_img=$(execute_remote_output "docker inspect -f '{{.Config.Image}}' ${CONTAINER_NAME} 2>/dev/null" | tr -d '[:space:]') || true
        back_run=$(execute_remote_output "docker inspect -f '{{.State.Running}}' ${CONTAINER_NAME} 2>/dev/null" | tr -d '[:space:]') || true
        if [[ "$back_run" == "true" && "$back_img" == "$old_image" ]]; then
            log SUCCESS "Восстановлена версия ${old_image}"
        else
            log ERROR "Откат не удался (running=${back_run:-?}, image=${back_img:-?}) — сервис не работает"
            log ERROR "Поднять вручную: cd ${INSTALL_DIR} && docker compose up -d --force-recreate $(compose_service)"
        fi
        return 1
    fi
}

# ============================================
# 8. ГЕНЕРАТОР SING-BOX ПРОФИЛЯ
# Формат sing-box 1.12+ (проверяется на 1.14): новые DNS-серверы (type/server),
# route.default_domain_resolver, действия sniff/hijack-dns/reject вместо legacy-полей.
# Только VLESS+TCP+Reality: у sing-box нет транспорта XHTTP (его "http" — это h2 v2fly,
# XHTTP-сервер отвечает ему 404 — проверено на 1.14.0).
# ============================================

readonly -a SB_RU_DOMAINS=(
    ".ru" ".xn--p1ai" ".su"
    "yandex.ru" "yandex.net" "yandex.com" "ya.ru" "yastatic.net"
    "vk.com" "vk.me" "vkontakte.ru" "userapi.com"
    "mail.ru" "ok.ru" "odnoklassniki.ru"
    "sber.ru" "sberbank.ru" "gosuslugi.ru" "mos.ru" "nalog.ru" "nalog.gov.ru"
    "cdnvideo.ru" "rutube.ru" "2ip.ru" "2ip.io"
    "avito.ru" "hh.ru" "ozon.ru" "wildberries.ru" "tinkoff.ru"
    "alfabank.ru" "vtb.ru" "megafon.ru" "mts.ru" "beeline.ru"
    "rt.ru" "1tv.ru" "rbc.ru" "lenta.ru" "ria.ru" "rg.ru" "aeroflot.ru" "rzd.ru"
)
# Подсети для раздельной маршрутизации: только блоки, выделенные организациям из RU, в пределах
# прежних диапазонов. Источник — статистика распределения RIPE NCC
# (delegated-ripencc-extended-latest) на 2026-10-05. Прежние широкие агрегаты захватывали
# иностранные сети (Meta, Telegram, Hetzner и др.).
readonly -a SB_RU_CIDRS=(
    "2.56.24.0/22" "2.56.88.0/22" "2.56.180.0/22" "2.56.240.0/23" "2.57.0.0/24" "2.57.36.0/22"
    "2.57.52.0/22" "2.57.80.0/22" "2.57.112.0/22" "2.57.184.0/22" "2.58.68.0/22" "2.58.98.0/24"
    "2.58.124.0/22" "2.58.212.0/24" "2.59.51.0/24" "2.59.76.0/22" "2.59.80.0/22" "2.59.160.0/22"
    "2.59.216.0/22" "2.59.240.0/22" "5.8.0.0/20" "5.8.16.0/21" "5.8.28.0/22" "5.8.36.0/22"
    "5.8.42.0/23" "5.8.44.0/22" "5.8.48.0/20" "5.8.64.0/22" "5.8.69.0/24" "5.8.72.0/21"
    "5.8.80.0/21" "5.8.88.0/22" "5.8.160.0/20" "5.8.176.0/21" "5.8.192.0/19" "5.8.224.0/20"
    "5.16.0.0/16" "5.45.192.0/18" "5.101.0.0/19" "5.101.32.0/20" "5.101.48.0/22" "5.101.60.0/22"
    "5.101.64.0/19" "5.101.128.0/21" "5.101.152.0/21" "5.101.192.0/20" "5.101.208.0/21" "5.101.218.0/24"
    "5.101.224.0/19" "5.128.0.0/14" "5.133.76.0/22" "5.134.216.0/21" "5.136.0.0/13" "5.144.64.0/20"
    "5.144.96.0/19" "5.145.160.0/21" "5.145.192.0/18" "5.149.144.0/20" "5.149.200.0/21" "5.149.208.0/20"
    "5.153.128.0/18" "5.158.96.0/19" "5.158.232.0/21" "5.159.96.0/20" "5.159.112.0/21" "5.164.0.0/14"
    "5.172.0.0/19" "5.172.178.0/24" "5.175.88.0/21" "5.175.96.0/19" "5.178.24.0/21" "5.178.80.0/21"
    "5.180.92.0/22" "5.180.101.0/24" "5.180.174.0/23" "5.180.240.0/22" "5.181.0.0/22" "5.181.12.0/24"
    "5.181.60.0/22" "5.181.108.0/22" "5.181.168.0/22" "5.181.208.0/22" "5.181.252.0/22" "5.182.4.0/22"
    "5.182.36.0/22" "5.182.52.0/22" "5.182.64.0/22" "5.182.84.0/22" "5.182.92.0/22" "5.182.224.0/22"
    "5.183.28.0/22" "5.183.64.0/21" "5.183.144.0/22" "5.183.156.0/22" "5.183.180.0/22" "5.183.188.0/22"
    "5.183.232.0/22" "5.183.252.0/22" "5.187.40.0/21" "5.187.64.0/19" "5.188.2.0/23" "5.188.7.0/24"
    "5.188.8.0/22" "5.188.24.0/21" "5.188.35.0/24" "5.188.37.0/24" "5.188.38.0/23" "5.188.40.0/21"
    "5.188.48.0/20" "5.188.68.0/23" "5.188.72.0/21" "5.188.80.0/21" "5.188.88.0/22" "5.188.96.0/21"
    "5.188.104.0/22" "5.188.112.0/21" "5.188.121.0/24" "5.188.128.0/22" "5.188.136.0/21" "5.188.144.0/22"
    "5.188.149.0/24" "5.188.150.0/24" "5.188.156.0/22" "5.188.160.0/21" "5.188.170.0/23" "5.188.176.0/22"
    "5.188.184.0/22" "5.188.192.0/20" "5.188.208.0/22" "5.188.212.0/24" "5.188.216.0/21" "5.188.224.0/24"
    "5.188.229.0/24" "5.188.232.0/22" "5.188.236.0/23" "5.189.0.0/17" "5.189.192.0/21" "5.189.201.0/24"
    "5.189.205.0/24" "5.189.208.0/21" "5.189.216.0/22" "5.189.223.0/24" "5.189.224.0/19" "31.13.16.0/21"
    "31.13.32.0/19" "31.13.128.0/21" "31.13.144.0/21" "31.13.176.0/21" "31.28.0.0/18" "31.28.96.0/19"
    "31.28.192.0/18" "31.29.128.0/17" "31.31.64.0/21" "31.31.192.0/20" "31.128.32.0/20" "31.128.48.0/21"
    "31.128.56.0/22" "31.128.61.0/24" "31.128.62.0/23" "31.128.128.0/19" "31.128.192.0/19" "37.9.0.0/20"
    "37.9.36.0/22" "37.9.40.0/21" "37.9.48.0/21" "37.9.64.0/18" "37.9.128.0/21" "37.9.144.0/20"
    "37.9.240.0/21" "37.140.0.0/17" "37.140.128.0/18" "37.140.192.0/21" "37.140.241.0/24" "37.140.248.0/24"
    "46.36.0.0/19" "46.46.0.0/18" "46.46.128.0/18" "77.37.128.0/17" "77.220.32.0/19" "77.220.128.0/18"
    "77.220.192.0/22" "77.220.208.0/22" "77.220.216.0/21" "78.36.0.0/15" "78.108.64.0/19" "78.108.192.0/20"
    "80.73.16.0/20" "80.73.64.0/19" "80.73.160.0/20" "80.73.192.0/20" "80.237.0.0/17" "81.24.80.0/20"
    "81.24.112.0/20" "81.24.128.0/20" "81.24.176.0/20" "81.25.0.0/20" "81.25.48.0/20" "81.25.64.0/22"
    "81.26.80.0/20" "81.26.128.0/20" "81.26.144.0/21" "81.26.152.0/22" "81.26.157.0/24" "81.26.176.0/20"
    "81.27.48.0/20" "81.27.144.0/20" "81.27.240.0/20" "82.97.194.0/23" "82.97.198.0/24" "82.97.201.0/24"
    "82.97.202.0/24" "82.97.207.0/24" "85.21.0.0/16" "87.224.128.0/17" "87.225.0.0/17" "87.226.128.0/17"
    "87.228.0.0/17" "87.229.128.0/17" "87.236.8.0/21" "87.236.16.0/20" "87.236.37.0/24" "87.236.40.0/21"
    "87.236.80.0/21" "87.236.184.0/21" "87.237.40.0/21" "87.237.112.0/21" "87.237.136.0/21" "87.238.96.0/21"
    "87.238.232.0/21" "87.239.0.0/21" "87.239.24.0/21" "87.239.32.0/21" "87.239.104.0/21" "87.239.144.0/21"
    "88.204.0.0/17" "88.205.128.0/17" "88.206.0.0/17" "89.108.64.0/18" "89.109.0.0/18" "89.109.128.0/17"
    "89.110.0.0/18" "89.111.128.0/18" "89.175.0.0/16" "90.156.128.0/20" "90.156.148.0/22" "90.156.152.0/21"
    "90.156.168.0/21" "90.156.176.0/20" "90.156.200.0/21" "90.156.208.0/21" "90.156.216.0/22" "90.156.224.0/19"
    "91.108.168.0/21" "91.108.187.0/24" "91.109.64.0/19" "91.109.128.0/19" "91.109.200.0/21" "91.109.224.0/21"
    "91.215.16.0/21" "91.215.28.0/22" "91.215.36.0/22" "91.215.40.0/22" "91.215.60.0/22" "91.215.76.0/22"
    "91.215.84.0/23" "91.215.88.0/22" "91.215.108.0/22" "91.215.112.0/22" "91.215.120.0/22" "91.215.128.0/22"
    "91.215.140.0/22" "91.215.168.0/21" "91.215.188.0/22" "91.215.192.0/20" "91.215.208.0/21" "91.215.220.0/22"
    "91.215.224.0/22" "91.215.232.0/22" "91.215.244.0/22" "91.215.248.0/21" "92.42.6.0/24" "92.42.8.0/21"
    "92.42.24.0/21" "92.42.40.0/22" "92.42.88.0/21" "92.42.96.0/24" "92.42.128.0/21" "92.42.160.0/21"
    "92.42.208.0/21" "92.223.4.0/23" "92.223.6.0/24" "92.223.8.0/23" "92.223.14.0/24" "92.223.32.0/22"
    "92.223.36.0/24" "92.223.38.0/24" "92.223.41.0/24" "92.223.43.0/24" "92.223.49.0/24" "92.223.60.0/24"
    "92.223.64.0/23" "92.223.67.0/24" "92.223.72.0/24" "92.223.80.0/24" "92.223.87.0/24" "92.223.91.0/24"
    "92.223.103.0/24" "92.223.106.0/24" "92.223.108.0/22" "92.223.114.0/23" "92.223.122.0/23" "93.153.128.0/17"
    "94.25.0.0/16" "94.154.11.0/24" "94.154.64.0/19" "95.30.0.0/16" "95.105.0.0/17" "95.173.128.0/19"
    "176.59.0.0/16" "176.96.0.0/19" "176.96.64.0/21" "176.96.80.0/21" "176.96.184.0/21" "176.215.0.0/16"
    "178.65.0.0/16" "178.154.128.0/17" "178.248.64.0/21" "178.248.80.0/21" "178.248.232.0/21" "178.249.56.0/21"
    "178.249.64.0/20" "178.249.128.0/21" "178.249.240.0/21" "178.250.152.0/21" "178.250.240.0/21" "178.251.96.0/21"
    "178.251.136.0/21" "178.251.216.0/21" "185.10.0.0/22" "185.10.44.0/22" "185.10.60.0/22" "185.10.94.0/24"
    "185.10.128.0/22" "185.10.152.0/22" "185.10.172.0/22" "185.10.180.0/22" "185.10.184.0/22" "185.12.28.0/22"
    "185.12.52.0/22" "185.12.68.0/22" "185.12.84.0/22" "185.12.92.0/22" "185.12.124.0/22" "185.12.152.0/22"
    "185.12.208.0/22" "185.12.224.0/21" "185.12.252.0/22" "185.71.52.0/22" "185.71.64.0/21" "185.71.76.0/22"
    "185.71.80.0/22" "185.71.96.0/22" "185.71.144.0/22" "185.71.196.0/22" "185.71.212.0/22" "188.64.112.0/21"
    "188.64.128.0/21" "188.64.136.0/23" "188.64.144.0/21" "188.64.160.0/23" "188.64.163.0/24" "188.64.164.0/22"
    "188.64.168.0/21" "188.64.216.0/21" "188.65.8.0/21" "188.65.48.0/21" "188.65.104.0/21" "188.65.128.0/21"
    "188.65.208.0/21" "188.65.232.0/21" "188.65.240.0/21" "188.66.32.0/21" "193.232.0.0/16" "194.8.47.0/24"
    "194.8.55.0/24" "194.8.70.0/23" "194.8.72.0/23" "194.8.84.0/23" "194.8.128.0/22" "194.8.136.0/22"
    "194.8.152.0/22" "194.8.160.0/19" "194.8.224.0/23" "194.8.228.0/22" "194.8.232.0/22" "194.8.246.0/23"
    "194.67.0.0/18" "194.67.64.0/20" "194.67.84.0/22" "194.67.88.0/21" "194.67.96.0/19" "194.67.128.0/18"
    "194.67.224.0/19" "194.165.0.0/23" "194.165.18.0/23" "194.165.20.0/22" "194.165.30.0/23" "194.165.50.0/24"
    "194.165.57.0/24" "194.165.61.0/24" "195.34.0.0/18" "195.34.192.0/22" "195.34.224.0/19" "195.35.68.0/22"
    "195.35.116.0/23" "195.58.0.0/19" "212.48.32.0/19" "212.48.128.0/19" "212.48.192.0/19" "212.48.224.0/20"
    "212.57.96.0/19" "212.57.128.0/18" "213.24.0.0/16" "213.87.0.0/16" "217.69.128.0/20" "217.69.192.0/19"
    "217.118.64.0/19" "217.118.176.0/20"
)

# QR-код кодирует VLESS-ссылку, а не JSON-профиль: в QR помещается до ~2953 байт,
# а «умный» профиль занимает около 5.5 КБ. Ссылку (около 220 байт) сканирует любой клиент.
offer_qr() {   # $1 = vless-ссылка, $2 = путь к файлу профиля (без расширения)
    echo
    if ! command -v qrencode &>/dev/null; then
        log INFO "QR-код недоступен: не установлен qrencode"
        log INFO "Установка: macOS — brew install qrencode; Linux — apt install qrencode"
        return 0
    fi
    # Без умолчания: Enter ничего не выбирает, нужен явный ответ
    if ask_yn "Показать QR-код ссылки в терминале?"; then
        echo
        qrencode -t ANSIUTF8 -m 1 "$1"
        echo -e "${CYAN}Сканируйте камерой клиента (v2rayNG, Streisand, V2Box, Happ, Shadowrocket).${NC}"
    fi
    if ask_yn "Сохранить QR-код в PNG-файл?"; then
        local png="${2}.png"
        if qrencode -o "$png" -s 8 -m 2 "$1"; then
            log SUCCESS "QR-код сохранён: ${png}"
        else
            log ERROR "Не удалось сохранить QR-код"
        fi
    else
        log INFO "QR-код в файл не сохранён"
    fi
}

# Общая часть пунктов «QR-код» и «JSON для sing-box»: выбрать ссылку и отпечаток.
# Результат кладётся в GEN_URI, GEN_NAME, GEN_FP. Возврат 1 — пользователь отменил.
GEN_URI="" GEN_NAME="proxy" GEN_FP="chrome"
pick_link_for_generator() {
    GEN_URI="" GEN_NAME="proxy" GEN_FP="chrome"
    echo -e "${CYAN}Источник ссылки:${NC}"
    echo -e "  ${GREEN}1)${NC} Взять из текущей установки"
    echo -e "  ${GREEN}2)${NC} Вставить вручную"
    echo -e "  ${RED}0)${NC} Отмена"
    echo
    local src_choice
    while true; do
        read -r -p "Выберите (0-2): " src_choice
        case "$src_choice" in
            1|2) break ;;
            0)   log INFO "Отменено"; return 1 ;;
            *)   log WARN "Введите 0, 1 или 2" ;;
        esac
    done

    if [[ "$src_choice" == "1" ]]; then
        get_clients_from_config || return 1
        local tmp_cfg="$CURRENT_CONFIG_TMP"
        local cnt; cnt=$(users_count "$tmp_cfg")
        [[ "${cnt:-0}" -eq 0 ]] && { log ERROR "Нет пользователей"; return 1; }

        echo; echo -e "${CYAN}Пользователи:${NC}"
        local i
        for ((i=0; i<cnt; i++)); do
            echo -e "  ${GREEN}$((i+1)))${NC} $(user_name_at "$tmp_cfg" "$i")"
        done; echo

        local unum
        while true; do
            read -r -p "Выберите пользователя (1-${cnt}): " unum
            [[ "$unum" =~ ^[0-9]+$ ]] && ((unum >= 1 && unum <= cnt)) && break
            log WARN "Введите число от 1 до ${cnt}"
        done
        local idx=$((unum-1))
        GEN_NAME=$(user_name_at "$tmp_cfg" "$idx")
        GEN_URI=$(make_user_link "$idx") || return 1
    else
        echo
        echo -e "${CYAN}Поддерживаются: vless:// (Reality), hysteria2://, tuic://${NC}"
        read -r -p "Вставьте ссылку: " GEN_URI
        case "$GEN_URI" in
            vless://*|hysteria2://*|tuic://*) ;;
            *) log ERROR "Некорректная ссылка"; return 1 ;;
        esac
        GEN_NAME=$(printf '%s' "$GEN_URI" | sed -n 's/.*#//p')
        GEN_NAME=$(python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.argv[1]) or 'proxy')" "$GEN_NAME" 2>/dev/null || echo proxy)
    fi

    # Отпечаток uTLS применим только к VLESS+Reality; у Hysteria2 и TUIC его нет
    if [[ "$GEN_URI" == vless://* ]]; then
        echo
        echo -e "${CYAN}Fingerprint браузера для репликации структуры ClientHello (uTLS):${NC}"
        echo -e "  ${GREEN}1)${NC} chrome     — Google Chrome"
        echo -e "  ${GREEN}2)${NC} firefox    — Mozilla Firefox"
        echo -e "  ${GREEN}3)${NC} safari     — Safari на macOS"
        echo -e "  ${GREEN}4)${NC} ios        — Safari на iOS (другой набор TLS-расширений, чем у macOS)"
        echo -e "  ${GREEN}5)${NC} edge       — Microsoft Edge"
        echo -e "  ${GREEN}6)${NC} random     — случайный из списка выше при каждом запуске"
        echo -e "  ${GREEN}7)${NC} randomized — случайно сгенерированный отпечаток"
        echo
        local fp_choice
        while true; do
            read -r -p "Fingerprint (1-7, по умолчанию: 1): " fp_choice
            case ${fp_choice:-1} in
                1) GEN_FP="chrome"; break ;; 2) GEN_FP="firefox"; break ;; 3) GEN_FP="safari"; break ;;
                4) GEN_FP="ios"; break ;; 5) GEN_FP="edge"; break ;; 6) GEN_FP="random"; break ;;
                7) GEN_FP="randomized"; break ;;
                *) log WARN "Введите число от 1 до 7" ;;
            esac
        done
        log SUCCESS "Fingerprint: ${GEN_FP}"
        # Выбранный отпечаток должен попасть и в саму ссылку, иначе вопрос бессмыслен
        GEN_URI=$(printf '%s' "$GEN_URI" | sed "s/\([?&]fp=\)[^&#]*/\1${GEN_FP}/")
    fi
    return 0
}

# ============================================
# 8. ГЕНЕРАТОР QR-КОДА
# ============================================

generate_qr_code() {
    print_header "Генератор QR-кода"
    pick_link_for_generator || return 0
    echo
    echo -e "${CYAN}Ссылка для клиента:${NC}"
    echo -e "  ${YELLOW}${GEN_URI}${NC}"
    local safe_name; safe_name=$(echo "$GEN_NAME" | tr -cd '[:alnum:]_-')
    local qr_dir="./vless-json"
    mkdir -p "$qr_dir"
    offer_qr "$GEN_URI" "${qr_dir}/qr-${safe_name:-proxy}-$(date +%Y%m%d)"
    echo
}

# Формат клиентского профиля определяется установкой: у ядра sing-box нет транспорта
# XHTTP (его «http» — это HTTP/2 из v2fly, XHTTP-сервер отвечает 404, проверено на 1.14),
# поэтому для XHTTP и для схемы с доменом выдаём конфиг Xray-core. Пункт меню один и
# работает для всех установок.
generate_client_json() {
    if is_singbox || [[ "$TRANSPORT" == "tcp" ]]; then
        generate_singbox_json
    else
        generate_xray_json
    fi
}

# Клиентский профиль для ядра Xray: те же два типа, что у sing-box, и те же встроенные списки.
generate_xray_json() {
    print_header "Генератор JSON"
    echo -e "  ${YELLOW}Формат: Xray-core${NC}"
    echo -e "  ${YELLOW}Подходит приложениям на ядре Xray${NC}"
    echo -e "  ${RED}Ядро sing-box не поддерживает транспорт XHTTP${NC}"

    pick_link_for_generator || return 0
    local uri="$GEN_URI" name="$GEN_NAME"

    echo
    echo -e "${CYAN}Тип профиля:${NC}"
    echo -e "  ${GREEN}1)${NC} Простой    — весь трафик через туннель"
    echo -e "  ${GREEN}2)${NC} Раздельная маршрутизация: адреса из встроенного списка — напрямую, остальной трафик — через туннель."
    echo
    local profile_type
    while true; do
        read -r -p "Тип (1/2, по умолчанию: 2): " profile_type
        profile_type=${profile_type:-2}
        [[ "$profile_type" == "1" || "$profile_type" == "2" ]] && break
        log WARN "Введите 1 или 2"
    done

    local outbound
    outbound=$(xray_outbound_from_link "$uri" "proxy") \
        || { log ERROR "Не удалось разобрать ссылку"; return 1; }

    # Списки те же, что у профиля sing-box. У Xray домен задаётся как domain:<имя> и
    # совпадает с именем и всеми поддоменами, поэтому ведущая точка из списка снимается.
    local ru_domains_json ru_cidrs_json
    ru_domains_json=$(printf '%s\n' "${SB_RU_DOMAINS[@]}" | sed 's/^\.//; s/^/domain:/' | jq -R . | jq -s .)
    ru_cidrs_json=$(printf '%s\n' "${SB_RU_CIDRS[@]}" | jq -R . | jq -s .)

    local profile_json
    profile_json=$(jq -n \
        --argjson outbound "$outbound" \
        --argjson smart "$([[ "$profile_type" == "2" ]] && echo true || echo false)" \
        --argjson ru_domains "$ru_domains_json" \
        --argjson ru_cidrs "$ru_cidrs_json" \
        '{
            "log": {"loglevel": "warning"},
            "inbounds": [
                {"tag": "socks", "listen": "127.0.0.1", "port": 10808, "protocol": "socks",
                 "settings": {"udp": true},
                 "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"]}},
                {"tag": "http", "listen": "127.0.0.1", "port": 10809, "protocol": "http"}
            ],
            "outbounds": [
                $outbound,
                {"tag": "direct", "protocol": "freedom"},
                {"tag": "block",  "protocol": "blackhole"}
            ],
            "routing": {
                "domainStrategy": "IPIfNonMatch",
                "rules": ([
                    {"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"}
                ] + (if $smart then [
                    {"type": "field", "domain": $ru_domains, "outboundTag": "direct"},
                    {"type": "field", "ip": $ru_cidrs, "outboundTag": "direct"}
                ] else [] end))
            }
        }') || { log ERROR "Не удалось собрать профиль (jq)"; return 1; }

    local safe_name; safe_name=$(echo "$name" | tr -cd '[:alnum:]_-')
    local type_label; [[ "$profile_type" == "1" ]] && type_label="simple" || type_label="split"
    local json_dir="./vless-json"
    mkdir -p "$json_dir"
    local filepath; filepath="${json_dir}/xray-${safe_name:-proxy}-${type_label}-$(date +%Y%m%d).json"
    echo "$profile_json" > "$filepath"

    echo
    log SUCCESS "Файл сохранён: ${filepath}"
    echo -e "  ${CYAN}После запуска клиент слушает SOCKS 127.0.0.1:10808 и HTTP 127.0.0.1:10809${NC}"
    echo
}

generate_singbox_json() {
    print_header "Генератор JSON"
    echo -e "  ${YELLOW}Формат: sing-box, version 1.12+${NC}"
    echo -e "  ${YELLOW}Подходит приложениям на ядре sing-box${NC}"

    pick_link_for_generator || return 0
    local uri="$GEN_URI" name="$GEN_NAME" p_fp="$GEN_FP"

    echo
    echo -e "${CYAN}Тип профиля:${NC}"
    echo -e "  ${GREEN}1)${NC} Простой    — весь трафик через туннель"
    echo -e "  ${GREEN}2)${NC} Раздельная маршрутизация: адреса из встроенного списка — напрямую, остальной трафик — через туннель."
    echo
    local profile_type
    while true; do
        read -r -p "Тип (1/2, по умолчанию: 2): " profile_type
        profile_type=${profile_type:-2}
        [[ "$profile_type" == "1" || "$profile_type" == "2" ]] && break
        log WARN "Введите 1 или 2"
    done

    # Outbound строится из самой ссылки — один разбор на все три протокола
    local outbound
    outbound=$(sb_outbound_from_link "$uri" "$p_fp") \
        || { log ERROR "Не удалось разобрать ссылку"; return 1; }

    local ru_domains_json ru_cidrs_json
    ru_domains_json=$(printf '%s\n' "${SB_RU_DOMAINS[@]}" | jq -R . | jq -s .)
    ru_cidrs_json=$(printf '%s\n' "${SB_RU_CIDRS[@]}" | jq -R . | jq -s .)

    local profile_json
    profile_json=$(jq -n \
        --argjson outbound "$outbound" \
        --argjson smart "$([[ "$profile_type" == "2" ]] && echo true || echo false)" \
        --argjson ru_domains "$ru_domains_json" \
        --argjson ru_cidrs "$ru_cidrs_json" \
        '{
            "log": {"level": "info", "timestamp": true},
            "dns": {
                "servers": [
                    {"type": "https", "tag": "dns-proxy",  "server": "8.8.8.8", "detour": "proxy"},
                    {"type": "udp",   "tag": "dns-direct", "server": "77.88.8.8"}
                ],
                "rules": (if $smart then [{"domain_suffix": $ru_domains, "server": "dns-direct"}] else [] end),
                "final": "dns-proxy",
                "strategy": "prefer_ipv4"
            },
            "inbounds": [{
                "type": "tun", "tag": "tun-in",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                "auto_route": true, "strict_route": true, "stack": "system"
            }],
            "outbounds": [
                $outbound,
                {"type": "direct", "tag": "direct"}
            ],
            "route": {
                "rules": ([
                    {"action": "sniff"},
                    {"protocol": "dns", "action": "hijack-dns"},
                    {"ip_is_private": true, "outbound": "direct"}
                ] + (if $smart then [
                    {"domain_suffix": $ru_domains, "outbound": "direct"},
                    {"ip_cidr": $ru_cidrs, "outbound": "direct"}
                ] else [] end)),
                "final": "proxy",
                "auto_detect_interface": true,
                "default_domain_resolver": {"server": "dns-direct"}
            },
            "experimental": {
                "cache_file": {"enabled": true},
                "clash_api": {"external_controller": "127.0.0.1:9090"}
            }
        }') || { log ERROR "Не удалось собрать профиль (jq)"; return 1; }

    local safe_name; safe_name=$(echo "$name" | tr -cd '[:alnum:]_-')
    local type_label; [[ "$profile_type" == "1" ]] && type_label="simple" || type_label="split"
    local json_dir="./vless-json"
    mkdir -p "$json_dir"
    local filepath; filepath="${json_dir}/singbox-${safe_name:-proxy}-${type_label}-$(date +%Y%m%d).json"
    echo "$profile_json" > "$filepath"

    echo
    log SUCCESS "Файл сохранён: ${filepath}"
    echo
}

# Outbound sing-box из ссылки: vless:// (Reality), hysteria2://, tuic://
sb_outbound_from_link() {   # $1 = ссылка, $2 = отпечаток uTLS (только для vless)
    python3 - "$1" "${2:-chrome}" <<'PY'
import sys, json, urllib.parse

uri = sys.argv[1].strip()
fp = sys.argv[2] or "chrome"
scheme, _, rest = uri.partition("://")
body = rest.split("#")[0]
userinfo, _, hostpart = body.partition("@")
hostport, _, qs = hostpart.partition("?")
hostport = hostport.rstrip("/")
host, _, port = hostport.rpartition(":")
q = {k: v[0] for k, v in urllib.parse.parse_qs(qs, keep_blank_values=True).items()}
insecure = q.get("insecure", q.get("allow_insecure", "0")) == "1"

if scheme == "vless":
    if q.get("security") != "reality" or q.get("type", "tcp") != "tcp":
        print("sing-box поддерживает только VLESS+Reality поверх TCP", file=sys.stderr)
        sys.exit(1)
    if not q.get("pbk") or not q.get("sni"):
        print("в ссылке нет pbk или sni — Reality-профиль невозможен", file=sys.stderr)
        sys.exit(1)
    out = {"type": "vless", "tag": "proxy", "server": host, "server_port": int(port),
           "uuid": userinfo, "flow": q.get("flow", "xtls-rprx-vision"),
           "tls": {"enabled": True, "server_name": q["sni"],
                   "utls": {"enabled": True, "fingerprint": fp},
                   "reality": {"enabled": True, "public_key": q["pbk"], "short_id": q.get("sid", "")}}}
elif scheme == "hysteria2":
    out = {"type": "hysteria2", "tag": "proxy", "server": host, "server_port": int(port),
           "password": urllib.parse.unquote(userinfo),
           "tls": {"enabled": True, "server_name": q.get("sni", host),
                   "alpn": ["h3"], "insecure": insecure}}
elif scheme == "tuic":
    uuid, _, password = userinfo.partition(":")
    out = {"type": "tuic", "tag": "proxy", "server": host, "server_port": int(port),
           "uuid": uuid, "password": urllib.parse.unquote(password),
           "congestion_control": q.get("congestion_control", "bbr"),
           "tls": {"enabled": True, "server_name": q.get("sni", host),
                   "alpn": ["h3"], "insecure": insecure}}
else:
    print("неизвестная схема ссылки: " + scheme, file=sys.stderr)
    sys.exit(1)

print(json.dumps(out))
PY
}

# ============================================
# 10. ФАЙЛЫ И КОМАНДЫ НА СЕРВЕРЕ
# ============================================

# Печатает строку «путь — есть/нет — размер», проверяя фактическое наличие на сервере
# Все пути проверяются одним SSH-вызовом: результат кладётся в PATH_PROBE_OUT
# строками «путь<TAB>размер» (или «путь<TAB>-», если пути нет).
PATH_PROBE_OUT=""

probe_paths() {   # $@ = проверяемые пути; попутно считает резервные копии установки
    PATH_PROBE_OUT=""
    local list; list=$(printf "'%s' " "$@")
    PATH_PROBE_OUT=$(_ssh_cmd "for p in ${list}; do
            if [ -e \"\$p\" ]; then printf '%s\t%s\n' \"\$p\" \"\$(du -sh \"\$p\" 2>/dev/null | cut -f1)\"
            else printf '%s\t-\n' \"\$p\"; fi
        done
        printf '%s\t%s\n' '__BAKS__' \"\$(ls -d ${INSTALL_DIR}.bak.* 2>/dev/null | wc -l | tr -d ' ')\"" 2>/dev/null) || return 1
}

# Печатает строку «метка — путь — размер», данные берёт из уже полученного PATH_PROBE_OUT
_ls_mark() {   # $1 = метка, $2 = путь
    # ширину считаем в символах (${#…}), а не в байтах: printf %-Ns ломает выравнивание на кириллице
    local label="$1" path="$2" sz pad
    sz=$(printf '%s\n' "$PATH_PROBE_OUT" | awk -F'\t' -v p="$path" '$1==p{print $2; exit}')
    pad=$(( 16 - ${#label} )); (( pad < 1 )) && pad=1
    if [[ -n "$sz" && "$sz" != "-" ]]; then
        printf "  %s%*s${GREEN}%s${NC}  ${CYAN}(%s)${NC}\n" "$label" "$pad" "" "$path" "$sz"
    else
        printf "  %s%*s${YELLOW}%s${NC}  ${RED}(нет)${NC}\n" "$label" "$pad" "" "$path"
    fi
}

show_server_paths() {
    print_header "Файлы и команды на сервере"

    local cfg; cfg="$(cfg_path)"
    local svc; svc="$(compose_service)"

    echo -e "${BLUE}Установка:${NC}"
    echo -e "  Контейнер:     ${GREEN}${CONTAINER_NAME}${NC}  (${CONTAINER_STATUS:-статус неизвестен})"
    echo -e "  Ядро:          ${GREEN}$(core_label)${NC}"
    echo -e "  Протокол:      ${GREEN}$(transport_label)${NC}"
    echo -e "  Образ:         ${GREEN}${XRAY_IMAGE}${NC}"
    if [[ "$TRANSPORT" == "tls" ]]; then
        echo -e "  Домен:         ${GREEN}${TLS_DOMAIN:-—}${NC}"
    else
        echo -e "  IP:Порт:       ${GREEN}${PUBLIC_IP}:${XRAY_PORT}${NC}"
    fi
    echo
    echo -e "${BLUE}Файлы на сервере:${NC}"
    log STEP "Проверка наличия файлов (один запрос к серверу)..."

    # Список путей зависит от ядра и протокола; проверяем все разом
    local paths=("${INSTALL_DIR}" "${cfg}" "${INSTALL_DIR}/docker-compose.yml" "${INSTALL_DIR}/users.txt")
    if is_singbox; then
        paths+=("$(info_file)")
        is_quic && paths+=("${INSTALL_DIR}/certs/cert.pem" "${INSTALL_DIR}/certs/key.pem")
    elif [[ "$TRANSPORT" == "tls" ]]; then
        paths+=("${INSTALL_DIR}/config/Caddyfile" "${INSTALL_DIR}/certs" "${INSTALL_DIR}/site"
                "${INSTALL_DIR}/log/xray" "${INSTALL_DIR}/log/caddy" "/root/.acme.sh")
    else
        paths+=("$(info_file)" "${INSTALL_DIR}/log")
    fi
    probe_paths "${paths[@]}" || log WARN "Не удалось проверить файлы на сервере"

    _ls_mark "Каталог:"   "${INSTALL_DIR}"
    _ls_mark "Конфиг:"    "${cfg}"
    _ls_mark "Compose:"   "${INSTALL_DIR}/docker-compose.yml"
    _ls_mark "Ссылки:"    "${INSTALL_DIR}/users.txt"
    if is_singbox; then
        _ls_mark "Данные:"      "$(info_file)"
        if is_quic; then
            _ls_mark "Сертификат:" "${INSTALL_DIR}/certs/cert.pem"
            _ls_mark "Ключ:"       "${INSTALL_DIR}/certs/key.pem"
        fi
    elif [[ "$TRANSPORT" == "tls" ]]; then
        _ls_mark "Caddyfile:"   "${INSTALL_DIR}/config/Caddyfile"
        _ls_mark "Сертификаты:" "${INSTALL_DIR}/certs"
        _ls_mark "Сайт:"        "${INSTALL_DIR}/site"
        _ls_mark "Логи Xray:"   "${INSTALL_DIR}/log/xray"
        _ls_mark "Логи Caddy:"  "${INSTALL_DIR}/log/caddy"
        _ls_mark "acme.sh:"     "/root/.acme.sh"
    else
        _ls_mark "Ключи:"       "$(info_file)"
        _ls_mark "Логи Xray:"   "${INSTALL_DIR}/log"
    fi
    # Счётчик резервных копий пришёл тем же ответом, отдельный запрос не нужен
    local baks
    baks=$(printf '%s\n' "$PATH_PROBE_OUT" | awk -F'\t' '$1=="__BAKS__"{print $2; exit}')
    [[ -n "$baks" && "$baks" != "0" ]] && echo -e "  ${CYAN}Резервные копии прежних установок: ${baks} шт. (${INSTALL_DIR}.bak.*)${NC}"

    echo
    echo -e "${BLUE}Команды на сервере${NC} ${CYAN}(выполнять по SSH: ssh ${SSH_USER}@${PUBLIC_IP})${NC}:"
    echo
    echo -e "${CYAN}  Просмотр:${NC}"
    echo -e "    Ссылки и данные:    ${YELLOW}cat ${INSTALL_DIR}/users.txt${NC}"
    [[ "$TRANSPORT" != "tls" ]] && \
    echo -e "    Данные сервера:     ${YELLOW}sudo cat $(info_file)${NC}"
    echo -e "    Конфиг:             ${YELLOW}sudo cat ${cfg}${NC}   ${CYAN}(права 640/600 — нужен root)${NC}"
    echo -e "    Логи (последние):   ${YELLOW}docker logs --tail 50 ${CONTAINER_NAME}${NC}"
    echo -e "    Логи (поток):       ${YELLOW}docker logs -f ${CONTAINER_NAME}${NC}   ${CYAN}(выход — Ctrl+C)${NC}"
    echo -e "    Статус контейнеров: ${YELLOW}docker ps -a${NC}"
    echo -e "    Нагрузка:           ${YELLOW}docker stats --no-stream${NC}"
    if is_quic; then
        echo -e "    Занятые порты:      ${YELLOW}ss -ulnp${NC}   ${CYAN}(протокол работает поверх UDP)${NC}"
    else
        echo -e "    Занятые порты:      ${YELLOW}ss -tlnp${NC}"
    fi
    echo
    echo -e "${CYAN}  Управление:${NC}"
    echo -e "    Остановить:         ${YELLOW}cd ${INSTALL_DIR} && docker compose down${NC}"
    echo -e "    Запустить:          ${YELLOW}cd ${INSTALL_DIR} && docker compose up -d${NC}"
    echo -e "    Перезапустить:      ${YELLOW}cd ${INSTALL_DIR} && docker compose restart${NC}"
    echo -e "    Применить конфиг:   ${YELLOW}cd ${INSTALL_DIR} && docker compose up -d --force-recreate ${svc}${NC}"
    echo
    echo -e "${CYAN}  Проверка:${NC}"
    if is_singbox; then
        echo -e "    Валидность конфига: ${YELLOW}docker run --rm -v ${cfg}:/c.json:ro -v ${INSTALL_DIR}/certs:/etc/sing-box/certs:ro ${XRAY_IMAGE} check -c /c.json${NC}"
        echo -e "    Версия в контейнере: ${YELLOW}docker exec ${CONTAINER_NAME} sing-box version${NC}"
        is_quic && echo -e "    Срок сертификата:   ${YELLOW}openssl x509 -in ${INSTALL_DIR}/certs/cert.pem -noout -dates${NC}"
    else
        echo -e "    Валидность конфига: ${YELLOW}docker run --rm -v ${cfg}:/c.json:ro ${XRAY_IMAGE} run -test -config /c.json${NC}"
        echo -e "    Версия в контейнере: ${YELLOW}docker exec ${CONTAINER_NAME} xray version${NC}"
        if [[ "$TRANSPORT" == "tls" ]]; then
            echo -e "    Ответ сайта:        ${YELLOW}curl -sI https://${TLS_DOMAIN:-домен}/ | head -1${NC}"
            echo -e "    Срок сертификата:   ${YELLOW}openssl x509 -in ${INSTALL_DIR}/certs/fullchain.pem -noout -dates${NC}"
            echo -e "    Сертификаты acme:   ${YELLOW}/root/.acme.sh/acme.sh --list${NC}"
            echo -e "    Обновить сертификат: ${YELLOW}/root/.acme.sh/acme.sh --renew -d ${TLS_DOMAIN:-домен} --ecc --force${NC}"
        fi
    fi
    echo
    echo -e "${CYAN}  Логи Docker ротируются автоматически: не более 10 МБ × 3 файла на контейнер.${NC}"
    echo
}

# ============================================
# 11. УДАЛЕНИЕ УСТАНОВКИ
# ============================================

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

uninstall_installation() {
    print_header "Удаление установки ${CONTAINER_NAME}"
    local dom="" repo="${XRAY_IMAGE%%:*}"
    [[ "$CORE" == "xray" && "$TRANSPORT" == "tls" ]] && dom="${TLS_DOMAIN:-}"

    # Что реально есть на сервере (проверяем, а не предполагаем)
    local baks imgs acme_present="" caddy_img=""
    baks=$(execute_remote_output "ls -d ${INSTALL_DIR}.bak.* 2>/dev/null" | tr -d '\r') || true
    imgs=$(execute_remote_output "docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^${repo}:'" | tr -d '\r') || true
    if [[ -n "$dom" ]]; then
        caddy_img=$(execute_remote_output "docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep '^caddy:'" | tr -d '\r') || true
        acme_present=$(execute_remote_output "[ -d /root/.acme.sh ] && echo yes" | tr -d '[:space:]') || true
    fi

    echo -e "${YELLOW}Вариант 1 — удалить установку, каталог сохранить:${NC}"
    echo -e "  • контейнеры compose-проекта в ${INSTALL_DIR} (с их томами) и сеть проекта"
    echo -e "  • каталог ${INSTALL_DIR} → ${INSTALL_DIR}.bak.ДАТА"
    echo
    echo -e "${RED}Вариант 2 — удалить полностью (чистый лист, остаётся только Docker):${NC}"
    echo -e "  • контейнеры, тома, сеть проекта и каталог ${INSTALL_DIR}"
    if [[ -n "$baks" ]]; then echo -e "  • резервные копии прежних установок:"; while IFS= read -r _l; do echo "      $_l"; done <<< "$baks"; else echo -e "  • резервных копий ${INSTALL_DIR}.bak.* нет"; fi
    if [[ -n "$imgs" ]]; then echo -e "  • образы Docker:"; while IFS= read -r _l; do echo "      $_l"; done <<< "$imgs"; else echo -e "  • образов ${repo} нет"; fi
    if [[ "$TRANSPORT" == "tls" ]]; then
        [[ -n "$caddy_img" ]] && { echo -e "  • образы Caddy:"; while IFS= read -r _l; do echo "      $_l"; done <<< "$caddy_img"; }
        if [[ "$acme_present" == "yes" ]]; then echo -e "  • acme.sh целиком (/root/.acme.sh: сертификат ${dom:-?}, токен Cloudflare, cron-задание)"; else echo -e "  • acme.sh не установлен"; fi
    fi
    echo
    echo -e "  ${GREEN}1)${NC} Удалить, каталог сохранить как ${INSTALL_DIR}.bak.ДАТА"
    echo -e "  ${RED}2)${NC} Удалить полностью (чистый лист)"
    echo -e "  ${RED}0)${NC} Назад"
    echo
    local choice
    while true; do
        read -r -p "Выберите (0-2): " choice
        case "$choice" in 0) log INFO "Отменено"; return 0 ;; 1|2) break ;; *) log WARN "Введите 0, 1 или 2" ;; esac
    done
    ask_yes_no_word "Подтвердить удаление '${CONTAINER_NAME}'$([[ "$choice" == 2 ]] && echo ' ПОЛНОСТЬЮ')?" || { log INFO "Отменено"; return 0; }

    execute_remote "
        if [ -f '${INSTALL_DIR}/docker-compose.yml' ]; then cd '${INSTALL_DIR}' && docker compose down -v --remove-orphans 2>/dev/null || true; fi
        docker rm -f -v '${CONTAINER_NAME}' 2>/dev/null || true" "Остановка и удаление контейнеров" 1

    if [[ "$choice" == "1" ]]; then
        local bak
        bak=$(execute_remote_output "if [ -d '${INSTALL_DIR}' ]; then b='${INSTALL_DIR}.bak.'\$(date +%Y%m%d_%H%M%S); mv '${INSTALL_DIR}' \"\$b\" && echo \"\$b\"; fi" | tr -d '[:space:]') || true
        if [[ -n "$bak" ]]; then log SUCCESS "Каталог сохранён: ${bak}"; else log WARN "Каталог ${INSTALL_DIR} не найден"; fi
        if [[ -n "$dom" ]]; then
            detach_acme_cert "$dom"
            log INFO "Сертификат ${dom} сохранён — следующая установка с доменом привяжет его заново"
        fi
    else
        execute_remote "rm -rf '${INSTALL_DIR}'" "Удаление ${INSTALL_DIR}" 1
        if [[ -n "$baks" ]]; then
            execute_remote "rm -rf ${INSTALL_DIR}.bak.* && echo 'удалено: $(echo "$baks" | wc -l | tr -d ' ') шт.'" "Удаление резервных копий" 1 || true
        fi
        if [[ -n "$imgs" ]]; then
            # без -f: образ, занятый другой установкой (тот же репозиторий), Docker не отдаст — это правильно
            execute_remote "for i in \$(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^${repo}:'); do docker rmi \"\$i\" >/dev/null 2>&1 && echo \"удалён: \$i\" || echo \"оставлен (используется другой установкой): \$i\"; done" "Удаление образов ${repo}" 1 || true
        fi
        if [[ "$TRANSPORT" == "tls" ]]; then
            [[ -n "$caddy_img" ]] && execute_remote "docker images --format '{{.Repository}}:{{.Tag}}' | grep '^caddy:' | xargs -r docker rmi >/dev/null 2>&1; echo ok" "Удаление образов Caddy" 1 || true
            if [[ "$acme_present" == "yes" ]]; then
                execute_remote "[ -x /root/.acme.sh/acme.sh ] && /root/.acme.sh/acme.sh --uninstall >/dev/null 2>&1; rm -rf /root/.acme.sh; crontab -l 2>/dev/null | grep -v '.acme.sh' | crontab - 2>/dev/null || true; echo 'acme.sh удалён'" "Удаление acme.sh" 1 || true
            fi
        fi
        # только «висячие» слои образов; тома и сети других проектов не трогаем
        execute_remote "docker image prune -f >/dev/null 2>&1; echo ok" "Очистка висячих слоёв образов" 1 || true
    fi
    # Сообщение об удалении — по факту, а не по факту запуска команд
    local left
    left=$(execute_remote_output "[ -e '${INSTALL_DIR}' ] && echo ЕСТЬ" | tr -d '[:space:]') || true
    if [[ "$choice" == "2" && "$left" == "ЕСТЬ" ]]; then
        log ERROR "Каталог ${INSTALL_DIR} удалить не удалось — установка удалена не полностью"
    else
        log SUCCESS "Установка ${CONTAINER_NAME} удалена"
    fi
    log INFO "Менеджер завершает работу"
    exit 0
}

# ============================================
# ГЛАВНОЕ МЕНЮ
# ============================================

show_menu() {
    print_header "Менеджер установок"
    echo -e "  ${CYAN}Сервер:${NC}      ${GREEN}${PUBLIC_IP}:${XRAY_PORT}${NC}"
    echo -e "  ${CYAN}Контейнер:${NC}   ${GREEN}${CONTAINER_NAME}${NC}"
    echo -e "  ${CYAN}Ядро:${NC}        ${GREEN}$(core_label)${NC}"
    echo -e "  ${CYAN}Протокол:${NC}    ${GREEN}$(transport_label)${NC}"
    echo -e "  ${CYAN}Образ:${NC}       ${GREEN}${XRAY_IMAGE}${NC}"

    echo
    echo -e "  ${GREEN}1)${NC} Просмотреть пользователей и ссылки"
    echo -e "  ${GREEN}2)${NC} Добавить пользователя"
    echo -e "  ${GREEN}3)${NC} Удалить пользователя"
    if [[ "$TRANSPORT" != "tls" ]]; then
        echo -e "  ${GREEN}4)${NC} Сменить SNI"
    else
        echo -e "  ${GREEN}4)${NC} Сменить SNI ${CYAN}(н/д для TLS+Domain)${NC}"
    fi
    echo -e "  ${GREEN}5)${NC} Проверить статус"
    echo -e "  ${GREEN}6)${NC} Перезапустить сервер"
    echo -e "  ${GREEN}7)${NC} Версия $(core_label) (обновление версии)"
    echo -e "  ${GREEN}8)${NC} Генерировать QR-код"
    echo -e "  ${GREEN}9)${NC} Генерировать JSON"
    echo -e "  ${GREEN}10)${NC} Сквозная проверка подключения (self-test)"
    echo -e "  ${GREEN}11)${NC} Файлы и команды на сервере"
    echo -e "  ${RED}12)${NC} Удалить установку"
    echo -e "  ${RED}0)${NC} Выход"
    echo -e "${BLUE}==========================================${NC}"
    echo
}

# ============================================
# MAIN
# ============================================

main() {
    clear
    print_header "Менеджер установок"
    echo -e "  ${CYAN}Менеджер настройки и комплексного управления${NC}"
    echo -e "  ${CYAN}протоколами на базе Xray и Sing-box${NC}"
    echo

    # Проверка зависимостей
    local missing=()
    for dep in ssh scp jq python3 sshpass; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log ERROR "Отсутствуют зависимости: ${missing[*]}"
        log INFO "macOS: brew install ${missing[*]}"
        # sshpass в основном репозитории Homebrew отсутствует — нужен отдельный tap
        [[ " ${missing[*]} " == *" sshpass "* ]] && \
            log INFO "sshpass на macOS: brew install hudochenkov/sshpass/sshpass"
        exit 1
    fi

    connect_to_server

    while true; do
        echo
        show_menu
        local choice
        read -r -p "Выберите действие: " choice
        echo
        case $choice in
            1) view_links ;;
            2) add_users ;;
            3) delete_users ;;
            4) change_sni ;;
            5) check_status ;;
            6) restart_xray ;;
            7) upgrade_xray ;;
            8) generate_qr_code ;;
            9) generate_client_json ;;
            10) run_selftest ;;
            11) show_server_paths ;;
            12) uninstall_installation ;;
            0) echo; log INFO "До свидания!"; exit 0 ;;
            *) log WARN "Неверный выбор: $choice" ;;
        esac
        echo
        read -r -p "Нажмите Enter для продолжения..." _
    done
}

main "$@"
