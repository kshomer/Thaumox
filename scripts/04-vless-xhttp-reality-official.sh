#!/bin/bash

if [ -z "${BASH_VERSION:-}" ]; then
    echo "Ошибка: требуется bash. Запустите: bash $0" >&2
    exit 1
fi

#######################################
# Script Name: 04-vless-xhttp-reality-official.sh
# Description: VLESS + XHTTP + Reality.
#              Образ: ghcr.io/xtls/xray-core (официальный).
# Author:      kshomer
# Version:     1.0
# Date:        09.09.2026
#######################################

set -o errexit
set -o nounset
set -o pipefail

# ============================================
# ВЕРСИЯ ЯДРА
# ============================================

# Ставится стабильная версия. У Xray-core почти все релизы помечены как
# предварительные (prerelease), и единственное место, где видно стабильный, —
# GitHub releases/latest. Номер выясняется при запуске, поэтому установщик всегда
# берёт текущую стабильную версию, а уже работающий сервер остаётся на своей:
# в docker-compose.yml записан конкретный номер, а не «latest».
#
# У teddysun собственной пометки стабильности нет — его теги повторяют апстрим
# один в один, поэтому берём тот же номер и качаем образ из его Docker Hub.
# Тег latest там указывает на новейший релиз, включая предварительные, и потому
# для «стабильной версии» не годится.
#
# Константа ниже используется только как запасной вариант, если GitHub недоступен.
readonly FALLBACK_XRAY_VERSION="26.3.27"
readonly XRAY_STABLE_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly XRAY_REPO="ghcr.io/xtls/xray-core"
readonly IMAGE_SOURCE="xtls"
XRAY_VERSION="" XRAY_IMAGE=""

# ============================================
# КОНСТАНТЫ
# ============================================

readonly INSTALL_DIR="/opt/xray-xhttp-reality"
readonly CONTAINER_NAME="xray-xhttp-reality"
readonly XRAY_REALITY_SNI_DEFAULT="www.nvidia.com"
readonly TRANSPORT_LABEL="XHTTP + Reality (H2/auto)"
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
readonly HTTP_TIMEOUT_API=20         # таймаут обращения к GitHub за номером версии
readonly HTTP_TIMEOUT_TUNNEL=20      # таймаут проверки через туннель
readonly HTTP_TIMEOUT_PROBE=15       # таймаут Reality-пробы
readonly LOCK_FILE="/tmp/vless-xhttp-reality-install.lock"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Runtime
SERVER_IP="" SSH_PORT_SSH="22" SSH_USER="root" SSH_PASSWORD=""
PUBLIC_IP="" XRAY_PORT=443
XRAY_REALITY_SNI="www.nvidia.com"
REALITY_PRIVATE_KEY="" REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID="" USER_COUNT=1
declare -a USER_NAMES=() USER_UUIDS=()
declare -a TEMP_FILES=()
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
# ОБРАЗ ФИКСИРОВАН: ghcr.io/xtls/xray-core
# ============================================

select_image_and_version() {
    print_step 3 "Образ Xray"
    log INFO "Образ зафиксирован: ${XRAY_IMAGE} (${IMAGE_SOURCE})"
}
# ============================================
# ГЕНЕРАЦИЯ КЛЮЧЕЙ
# ============================================

generate_reality_keys() {
    log STEP "Генерация X25519 ключей для Reality..."

    # teddysun/xray:26.x: нет ENTRYPOINT, CMD = ["/usr/bin/xray", "-config", "..."]
    # Поэтому нужно --entrypoint xray чтобы переопределить CMD
    # ghcr.io/xtls/xray-core: ENTRYPOINT ["xray"], команда просто x25519
    local cmd
    if [[ "$IMAGE_SOURCE" == "teddysun" ]]; then
        cmd="docker run --rm --entrypoint xray ${XRAY_IMAGE} x25519 2>&1"
    else
        cmd="docker run --rm ${XRAY_IMAGE} x25519 2>&1"
    fi

    local out
    out=$(execute_remote_output "$cmd") || true
    [[ -z "$out" ]] && {
        log ERROR "Пустой вывод от xray x25519"
        exit 1
    }
    out=$(echo "$out" | tr -d '\r')

    REALITY_PRIVATE_KEY=$(parse_x25519_private "$out")
    REALITY_PUBLIC_KEY=$(parse_x25519_public "$out")
    # Слепой fallback («первые две длинные строки») убран: при смене формата вывода
    # он мог молча поменять ключи местами. Теперь — явная ошибка с полным выводом.
    if [[ -z "$REALITY_PRIVATE_KEY" || -z "$REALITY_PUBLIC_KEY" ]]; then
        log ERROR "Не удалось распознать вывод xray x25519 (формат изменился?). Вывод:"
        echo "$out"; exit 1
    fi

    # Проверка пары: публичный ключ, выведенный из приватного (x25519 -i), должен совпасть
    local vcmd vout derived
    if [[ "$IMAGE_SOURCE" == "teddysun" ]]; then
        vcmd="docker run --rm --entrypoint xray ${XRAY_IMAGE} x25519 -i '${REALITY_PRIVATE_KEY}' 2>&1"
    else
        vcmd="docker run --rm ${XRAY_IMAGE} x25519 -i '${REALITY_PRIVATE_KEY}' 2>&1"
    fi
    vout=$(execute_remote_output "$vcmd" | tr -d '\r') || true
    derived=$(parse_x25519_public "$vout")
    if [[ -z "$derived" ]]; then
        log WARN "Не удалось проверить пару ключей (x25519 -i вернул неожиданный вывод) — продолжаем"
    elif [[ "$derived" != "$REALITY_PUBLIC_KEY" ]]; then
        log ERROR "Ключи не образуют пару: из приватного выводится ${derived}, распознан ${REALITY_PUBLIC_KEY}"
        exit 1
    else
        log SUCCESS "Пара ключей проверена (x25519 -i)"
    fi

    log SUCCESS "Private Key: ${REALITY_PRIVATE_KEY:0:12}..."
    log SUCCESS "Public Key:  ${REALITY_PUBLIC_KEY:0:12}..."
}

# Форматы вывода x25519:
#   A (1.x):        "Private key: X" / "Public key: X"
#   B:              "PrivateKey = X" / "PublicKey = X"
#   C (25.x–26.x):  "PrivateKey: X" / "Password (PublicKey): X" / "Hash32: X"
parse_x25519_private() {
    echo "$1" | grep -iE '^(private key|privatekey)[[:space:]]*[:=]' | head -1 | awk '{print $NF}'
}
parse_x25519_public() {
    echo "$1" | grep -iE '^(public key|publickey|password \(publickey\))[[:space:]]*[:=]' | head -1 | awk '{print $NF}'
}

generate_uuid()     { execute_remote_output "cat /proc/sys/kernel/random/uuid" | tr -d '[:space:]'; }
generate_short_id() { execute_remote_output "openssl rand -hex 8" | tr -d '[:space:]'; }

# ============================================
# ГЕНЕРАЦИЯ КОНФИГА (jq)
# ============================================

generate_xray_config() {
    # XHTTP: flow не используется (только для TCP+Vision)
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
        --arg port "$XRAY_PORT" \
        --arg sni  "$XRAY_REALITY_SNI" \
        --arg priv "$REALITY_PRIVATE_KEY" \
        --arg sid  "$REALITY_SHORT_ID" \
        '{
            "log": {"loglevel": "warning"},
            "inbounds": [{
                "port": ($port | tonumber),
                "protocol": "vless",
                "settings": {
                    "clients": $clients,
                    "decryption": "none"
                },
                "streamSettings": {
                    "network": "xhttp",
                    "security": "reality",
                    "realitySettings": {
                        "dest": ($sni + ":443"),
                        "serverNames": [$sni],
                        "privateKey": $priv,
                        "shortIds": [$sid]
                    },
                    "xhttpSettings": {
                        "mode": "auto",
                        "path": "/download",
                        "extra": {
                            "scMaxConcurrentPosts": 100,
                            "scMaxEachPostBytes": "1000000",
                            "scMinPostsIntervalMs": 10,
                            "xPaddingBytes": "100-1000"
                        }
                    },
                    "sockopt": {"trustedXForwardedFor": []}
                }
            }],
            "outbounds": [{"protocol": "freedom", "tag": "direct"}],
            "routing": {"domainStrategy": "AsIs", "rules": []}
        }'
}

# ============================================
# ГЕНЕРАЦИЯ DOCKER-COMPOSE
# Учитывает отличия между образами
# ============================================

generate_docker_compose() {
    if [[ "$IMAGE_SOURCE" == "xtls" ]]; then
        # Официальный образ: монтируем в /etc/xray/, запускаем с явным -config
        # без root, с hardening
        jq -n \
            --arg image     "$XRAY_IMAGE" \
            --arg container "$CONTAINER_NAME" \
            --arg port      "$XRAY_PORT" \
            '{
                "services": {
                    "xray": {
                        "image": $image,
                        "container_name": $container,
                        "restart": "unless-stopped",
                        "ports": [($port + ":" + $port + "/tcp")],
                        "volumes": [
                            "./config/config.json:/etc/xray/config.json:ro",
                            "./log:/var/log/xray",
                            "xray-etc:/usr/local/etc/xray"
                        ],
                        "command": ["run", "-config", "/etc/xray/config.json"],
                        "security_opt": ["no-new-privileges:true"],
                        "cap_drop": ["ALL"],
                        "cap_add": ["NET_BIND_SERVICE"],
                        "logging": {
                            "driver": "json-file",
                            "options": {"max-size": "10m", "max-file": "3"}
                        },
                        "networks": ["xray-net"]
                    }
                },
                "networks": {"xray-net": {"driver": "bridge"}},
                "volumes": {"xray-etc": {}}
            }'
    else
        # teddysun: те же security параметры что и у официального
        # (teddysun запускается от root внутри, но cap_drop и no-new-privileges всё равно полезны)
        jq -n \
            --arg image     "$XRAY_IMAGE" \
            --arg container "$CONTAINER_NAME" \
            --arg port      "$XRAY_PORT" \
            '{
                "services": {
                    "xray": {
                        "image": $image,
                        "container_name": $container,
                        "restart": "unless-stopped",
                        "ports": [($port + ":" + $port + "/tcp")],
                        "volumes": [
                            "xray-etc:/etc/xray",
                            "./config/config.json:/etc/xray/config.json:ro",
                            "./log:/var/log/xray"
                        ],
                        "security_opt": ["no-new-privileges:true"],
                        "cap_drop": ["ALL"],
                        "cap_add": ["NET_BIND_SERVICE"],
                        "logging": {
                            "driver": "json-file",
                            "options": {"max-size": "10m", "max-file": "3"}
                        },
                        "networks": ["xray-net"]
                    }
                },
                "networks": {"xray-net": {"driver": "bridge"}},
                "volumes": {"xray-etc": {}}
            }'
    fi
}

# ============================================
# ATOMIC CONFIG UPDATE + XRAY TEST
# ============================================

upload_and_validate_config() {
    local local_config="$1"
    local remote_tmp="/tmp/xray-config-new.$$.json"
    log STEP "Загрузка и валидация конфига..."
    execute_remote "rm -f ${remote_tmp}" "" 1 || true
    copy_to_remote "$local_config" "$remote_tmp" "Загрузка конфига"

    # Права: конфиг содержит приватный ключ Reality — не должен быть читаем всеми.
    # Официальный образ работает от UID 65532 → владелец 65532, режим 640.
    # teddysun работает от root → 600.
    local owner mode
    if [[ "$IMAGE_SOURCE" == "xtls" ]]; then owner="65532:65532"; mode="640"; else owner="root:root"; mode="600"; fi
    execute_remote "chown ${owner} ${remote_tmp} && chmod ${mode} ${remote_tmp}" "" 1

    # xray test через exit code — с учётом разных entrypoint
    local test_rc=0 test_out
    if [[ "$IMAGE_SOURCE" == "teddysun" ]]; then
        test_out=$(_ssh_cmd "docker run --rm --entrypoint xray \
            -v ${remote_tmp}:/etc/xray/config.json:ro \
            ${XRAY_IMAGE} run -test -config /etc/xray/config.json 2>&1") || test_rc=$?
    else
        test_out=$(_ssh_cmd "docker run --rm \
            -v ${remote_tmp}:/etc/xray/config.json:ro \
            ${XRAY_IMAGE} run -test -config /etc/xray/config.json 2>&1") || test_rc=$?
    fi

    if [[ $test_rc -ne 0 ]]; then
        log ERROR "Конфиг не прошёл xray test (exit: $test_rc):"
        echo "$test_out"
        execute_remote "rm -f ${remote_tmp}" "" 1 || true
        return 1
    fi
    log SUCCESS "xray test пройден"

    execute_remote \
        "mkdir -p ${INSTALL_DIR}/config && \
         mv ${remote_tmp} ${INSTALL_DIR}/config/config.json && \
         chown ${owner} ${INSTALL_DIR}/config/config.json && \
         chmod ${mode} ${INSTALL_DIR}/config/config.json" \
        "Применение конфига (atomic)"
}

# ============================================
# ПРОВЕРКА ПОРТА
# ============================================

check_sni_target() {
    # Первая, быстрая ступень: цель Reality обязана отвечать по TLS 1.3 + HTTP/2.
    # Окончательный ответ даёт probe_reality_target — настоящее рукопожатие;
    # эта проверка его не заменяет, но отсеивает заведомо негодные имена сразу.
    log STEP "Проверка SNI-цели ${XRAY_REALITY_SNI} (TLS 1.3 / HTTP/2)..."
    local hv
    hv=$(execute_remote_output \
        "curl -sS -o /dev/null --tlsv1.3 --http2 --max-time ${HTTP_TIMEOUT} -w '%{http_version}' https://${XRAY_REALITY_SNI}/ 2>/dev/null") || true
    hv=$(echo "${hv:-}" | tr -d '[:space:]')
    if [[ "$hv" == "2" ]]; then
        log SUCCESS "SNI-цель отвечает по TLS 1.3 + HTTP/2"; return 0
    fi
    log ERROR "SNI-цель ${XRAY_REALITY_SNI} не отвечает по TLS 1.3/HTTP-2 (http_version='${hv:-нет ответа}')"
    log INFO "С такой целью Reality не заработает — нужно другое имя"
    return 1
}

# Выбор SNI с мягкой проверкой (TLS 1.3 + HTTP/2); при отказе — возврат к выбору, а не выход
# Имя не прошло проверку. Продолжать с ним нельзя: с нерабочей целью протокол
# не заработает, и брать её незачем. Поэтому выбор только из двух вариантов.
ask_retry_or_cancel() {   # 0 = выбрать другое имя; отмена завершает скрипт
    local a
    echo
    echo -e "  ${GREEN}1)${NC} Выбрать другое имя"
    echo -e "  ${RED}0)${NC} Отменить установку"
    echo
    while true; do
        read -r -p "Выберите (0-1): " a
        case "$a" in
            1) return 0 ;;
            0) log INFO "Установка отменена — сервер не изменён"; exit 0 ;;
            *) log WARN "Введите 0 или 1" ;;
        esac
    done
}

choose_sni() {
    while true; do
        echo
        echo -e "  ${GREEN}1)${NC} ${XRAY_REALITY_SNI_DEFAULT}"
        echo -e "  ${GREEN}2)${NC} Ввести свой домен"
        echo -e "  ${RED}0)${NC} Отменить установку"
        echo
        local sni_choice
        read -r -p "SNI (0-2, по умолчанию: 1): " sni_choice
        case "${sni_choice:-1}" in
            1) XRAY_REALITY_SNI="$XRAY_REALITY_SNI_DEFAULT" ;;
            2) get_input "SNI домен" "XRAY_REALITY_SNI" "" "validate_domain" "Некорректный домен" ;;
            0) log INFO "Установка отменена — сервер не изменён"; exit 0 ;;
            *) log WARN "Выберите 0, 1 или 2"; continue ;;
        esac
        log SUCCESS "SNI: $XRAY_REALITY_SNI"
        check_sni_target && return 0
        ask_retry_or_cancel
    done
}

port_listeners() {
    # Вывод ss для порта $1 или пустая строка, если свободен
    local info
    info=$(execute_remote_output "ss -tlnp | grep ':${1} ' || echo __free__") || info="__free__"
    [[ "$info" == *__free__* ]] && return 1
    echo "$info"; return 0
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
    echo -e "  ${GREEN}1)${NC} Использовать другой порт"
    echo
    if [[ -n "$conflict_container" ]]; then
        echo -e "  ${YELLOW}2)${NC} Заменить '${conflict_container}' — данные сохранить в резервную копию"
        echo -e "     ${CYAN}   Каталог установки будет перемещён в <каталог>.bak.ДАТА${NC}"
        echo
        echo -e "  ${RED}3)${NC} Удалить '${conflict_container}' полностью и установить новый на порт ${XRAY_PORT}"
        echo -e "     ${RED}   ⚠  Каталог установки, его резервные копии .bak.* и образы Docker${NC}"
        echo -e "     ${RED}      этого контейнера будут удалены безвозвратно, отката нет!${NC}"
    else
        echo -e "  ${YELLOW}2)${NC} Принудительно освободить порт (fuser -k)"
    fi
    echo
    echo -e "  ${RED}0)${NC} Отменить установку"; echo
    echo -e "${CYAN}Выбранное действие будет выполнено только после подтверждения установки.${NC}"; echo

    local max_choice=2
    [[ -n "$conflict_container" ]] && max_choice=3
    local choice
    while true; do
        read -r -p "Выберите (0-${max_choice}): " choice
        case $choice in
            1)
                echo -e "  ${CYAN}Можно указать любой свободный порт 1-65535 (Enter — 8443).${NC}"
                get_input "Другой порт" "XRAY_PORT" "8443" "validate_port" "Порт 1-65535"
                check_port; return $?
                ;;
            2)
                if [[ -n "$conflict_container" ]]; then
                    queue_port_release "$conflict_container" backup
                    log INFO "Запланировано: остановить '${conflict_container}' и сохранить его данные в резервную копию"
                else
                    PORT_KILL_SPECS+=("${XRAY_PORT}/tcp")
                    log INFO "Запланировано: принудительно освободить порт ${XRAY_PORT}"
                fi
                return 0
                ;;
            3)
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
    execute_remote "systemctl start docker && systemctl enable docker" "Запуск Docker"
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
    local errors=0

    if _ssh_cmd "docker ps --format '{{.Names}}' | grep -q '^${CONTAINER_NAME}$'" 2>/dev/null; then
        log SUCCESS "Контейнер ${CONTAINER_NAME} работает"
    else
        log ERROR "Контейнер не запущен"
        log INFO "Логи:"
        execute_remote "docker logs --tail 20 ${CONTAINER_NAME} 2>&1" "" 1 || true
        errors=$((errors+1))
    fi

    if _ssh_cmd "ss -tlnp | grep -q ':${XRAY_PORT} '" 2>/dev/null; then
        log SUCCESS "Порт TCP ${XRAY_PORT} слушается"
    else
        log ERROR "Порт не слушается"; errors=$((errors+1))
    fi

    return $errors
}

# Единая точка формирования VLESS-ссылки (используется в выводе, файле users.txt и self-test)
make_link() {   # $1 = uuid, $2 = имя
    echo "vless://${1}@${PUBLIC_IP}:${XRAY_PORT}?security=reality&sni=${XRAY_REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=xhttp&path=%2Fdownload&mode=auto#${2}"
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

# ============================================
# ВЫВОД РЕЗУЛЬТАТА
# ============================================

print_result() {
    print_header "Установка завершена"

    local source_label
    [[ "$IMAGE_SOURCE" == "xtls" ]] && \
        source_label="официальный XTLS (без root)" || \
        source_label="teddysun (совместимый)"

    echo -e "${BLUE}Сервер:${NC}"
    echo -e "  IP:         ${GREEN}${PUBLIC_IP}${NC}"
    echo -e "  Порт:       ${GREEN}${XRAY_PORT}/TCP${NC}"
    echo -e "  Transport:  ${GREEN}XHTTP + Reality (H2/auto)${NC}"
    echo -e "  Security:   ${GREEN}Reality (SNI: ${XRAY_REALITY_SNI})${NC}"
    echo -e "  Public Key: ${GREEN}${REALITY_PUBLIC_KEY}${NC}"
    echo -e "  Short ID:   ${GREEN}${REALITY_SHORT_ID}${NC}"
    echo -e "  Образ:      ${GREEN}${XRAY_IMAGE}${NC}"
    echo -e "  Тип образа: ${GREEN}${source_label}${NC}"
    echo
    echo -e "${BLUE}Пользователи:${NC}"
    echo -e "${BLUE}------------------------------------------${NC}"
    for ((i=0; i<USER_COUNT; i++)); do
        local link; link=$(make_link "${USER_UUIDS[$i]}" "${USER_NAMES[$i]}")
        echo
        echo -e "  ${GREEN}${USER_NAMES[$i]}${NC}"
        echo -e "  UUID: ${CYAN}${USER_UUIDS[$i]}${NC}"
        echo -e "  ${YELLOW}${link}${NC}"
    done
    echo
    echo -e "${BLUE}------------------------------------------${NC}"
    echo -e "${CYAN}Файлы на сервере:${NC}"
    echo -e "  Конфиг: ${INSTALL_DIR}/config/config.json"
    echo -e "  Ключи:  ${INSTALL_DIR}/reality-keys.txt"
    echo -e "  Ссылки: ${INSTALL_DIR}/users.txt"
    echo -e "${CYAN}Логи ограничены по размеру:${NC} json-file, до 10 MB × 3 файла (максимум 30 MB)."
    echo
    echo -e "${CYAN}Управление:${NC}"
    echo -e "  Логи:   ssh ${SSH_USER}@${PUBLIC_IP} 'docker logs ${CONTAINER_NAME}'"
    echo -e "  Стоп:   ssh ${SSH_USER}@${PUBLIC_IP} 'cd ${INSTALL_DIR} && docker compose down'"
    echo
}

# ============================================
# СОХРАНЕНИЕ ДАННЫХ
# ============================================

save_server_data() {
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')

    local tmp_keys; tmp_keys=$(create_temp)
    {
        echo "VLESS+XHTTP+Reality — Ключи сервера"
        echo "============================================"
        echo "Дата:        $ts"
        echo "IP:          $PUBLIC_IP"
        echo "Порт:        $XRAY_PORT"
        echo "Transport:   xhttp"
        echo "SNI:         $XRAY_REALITY_SNI"
        echo "Image:       $XRAY_IMAGE"
        echo "Private Key: $REALITY_PRIVATE_KEY"
        echo "Public Key:  $REALITY_PUBLIC_KEY"
        echo "Short ID:    $REALITY_SHORT_ID"
        echo "============================================"
    } > "$tmp_keys"
    copy_to_remote "$tmp_keys" "/tmp/reality-keys.txt" "Загрузка ключей"
    execute_remote \
        "mv /tmp/reality-keys.txt ${INSTALL_DIR}/reality-keys.txt && \
         chmod 600 ${INSTALL_DIR}/reality-keys.txt" \
        "Сохранение ключей"

    local tmp_users; tmp_users=$(create_temp)
    {
        echo "VLESS+XHTTP+Reality — Пользователи"
        echo "============================================"
        echo "Дата: $ts | IP: $PUBLIC_IP:$XRAY_PORT"
        for ((i=0; i<USER_COUNT; i++)); do
            echo "--------------------------------------------"
            echo "Пользователь: ${USER_NAMES[$i]}"
            echo "UUID: ${USER_UUIDS[$i]}"
            echo "Ссылка: $(make_link "${USER_UUIDS[$i]}" "${USER_NAMES[$i]}")"
        done
        echo "--------------------------------------------"
    } > "$tmp_users"
    copy_to_remote "$tmp_users" "/tmp/users.txt" "Загрузка пользователей"
    execute_remote \
        "mv /tmp/users.txt ${INSTALL_DIR}/users.txt && \
         chmod 600 ${INSTALL_DIR}/users.txt" \
        "Сохранение пользователей"
}

# ============================================
# MAIN
# ============================================

main() {
    clear
    print_header "VLESS + XHTTP + Reality · официальный образ Xray"
    echo -e "  ${CYAN}Сервер VLESS + Reality поверх XHTTP${NC}"
    echo
    acquire_lock

    # Проверка локальных зависимостей
    log STEP "Проверка локальных зависимостей..."
    local missing=()
    for dep in ssh scp jq python3 sshpass; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log ERROR "Отсутствуют зависимости: ${missing[*]}"
        log INFO "macOS: brew install ${missing[*]}"
        log INFO "Linux: apt-get install ${missing[*]}"
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
    # Только TCP-проверка — надёжнее ping (ping может быть заблокирован или требовать root)
    if bash -c "echo >/dev/tcp/${SERVER_IP}/${SSH_PORT_SSH}" 2>/dev/null; then
        log SUCCESS "Сервер доступен (TCP:${SSH_PORT_SSH})"
    else
        log ERROR "Сервер недоступен — проверьте IP и порт SSH"
        exit 1
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
        "curl -s --max-time ${HTTP_TIMEOUT} ifconfig.me || curl -s --max-time ${HTTP_TIMEOUT} ipinfo.io/ip || echo '${SERVER_IP}'" \
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

    # Шаг 3: Образ и версия
    select_image_and_version

    # Шаг 4: SNI
    print_step 4 "SNI сервера"

    echo -e "Если один вариант не работает — можно попробовать другой."
    echo -e "Примеры: www.nvidia.com, www.samsung.com, www.logitech.com,"
    echo -e "www.oracle.com, www.apple.com, www.bing.com, www.amazon.com, dl.google.com,"
    echo -e "www.cloudflare.com, gateway.icloud.com."
    echo -e "Выбранный SNI будет проверен настоящим Reality-рукопожатием перед развёртыванием."
    choose_sni

    # Шаг 5: Порт (только проверка; действия — после подтверждения)
    print_step 5 "Проверка порта"
    check_port

    # Шаг 6: Пользователи
    print_step 6 "Создание пользователей"
    get_input "Количество пользователей" "USER_COUNT" "1" "validate_count" "Введите число от 1 до 12"
    for ((i=1; i<=USER_COUNT; i++)); do
        local uname
        get_input "Имя пользователя $i" "uname" "" "validate_user" "Только a-z A-Z 0-9 _ -"
        USER_NAMES+=("$uname"); log SUCCESS "Добавлен: $uname"
    done

    # Подтверждение — ДО любых изменений на сервере (Docker, apt upgrade, освобождение порта)
    print_header "Параметры установки"
    local src_label
    [[ "$IMAGE_SOURCE" == "xtls" ]] && src_label="официальный XTLS" || src_label="teddysun"
    echo -e "  Сервер:      ${GREEN}${SSH_USER}@${SERVER_IP}:${SSH_PORT_SSH}${NC}"
    echo -e "  Публичный IP:${GREEN}${PUBLIC_IP}${NC}"
    echo -e "  Образ:       ${GREEN}${XRAY_IMAGE}${NC} (${src_label})"
    echo -e "  Transport:   ${GREEN}${TRANSPORT_LABEL}${NC}"
    echo -e "  SNI:         ${GREEN}${XRAY_REALITY_SNI}${NC}"
    echo -e "  Порт:        ${GREEN}${XRAY_PORT}/TCP${NC}"
    echo -e "  Пользователей:${GREEN}${USER_COUNT}${NC}"
    print_port_plan "Порт занят:  "
    echo -e "  Система:     ${YELLOW}будет выполнен apt-get update && apt-get upgrade, установлен/обновлён Docker${NC}"
    echo
    ask_yn "Начать установку?" || { log INFO "Отменено — сервер не изменён"; exit 0; }

    # Шаг 7: Освобождение порта (если требовалось)
    print_step 7 "Освобождение порта"
    apply_port_action
    backup_existing_install

    # Шаг 8: Docker
    print_step 8 "Установка и обновление Docker"
    install_docker

    # Шаг 9: Образ + ключи
    print_step 9 "Загрузка образа и генерация ключей"
    execute_remote "docker pull ${XRAY_IMAGE}" "Загрузка ${XRAY_IMAGE}"
    generate_reality_keys

    log STEP "Генерация Short ID..."
    REALITY_SHORT_ID=$(generate_short_id)
    [[ -z "$REALITY_SHORT_ID" ]] && { log ERROR "Не удалось сгенерировать Short ID"; exit 1; }
    log SUCCESS "Short ID: $REALITY_SHORT_ID"

    # Шаг 9.5: SNI-цель — настоящим Reality-рукопожатием (curl-проверки недостаточно)
    while ! probe_reality_target "$XRAY_REALITY_SNI" "$XRAY_IMAGE" "$IMAGE_SOURCE"; do
        echo
        echo -e "  ${GREEN}1)${NC} Ввести другой SNI"
        echo -e "  ${RED}0)${NC} Отменить установку"
        echo
        local pc; read -r -p "Выберите (0-1): " pc
        case "$pc" in
            1) choose_sni ;;
            0) log INFO "Установка прервана (каталог установки не менялся)"; exit 0 ;;
            *) log WARN "Введите 0 или 1" ;;
        esac
    done

    # Шаг 10: UUID
    print_step 10 "Генерация UUID"
    for ((i=0; i<USER_COUNT; i++)); do
        local uuid; uuid=$(generate_uuid)
        [[ -z "$uuid" ]] && { log ERROR "Не удалось сгенерировать UUID"; exit 1; }
        USER_UUIDS+=("$uuid"); log SUCCESS "${USER_NAMES[$i]}: $uuid"
    done

    # Шаг 11: Конфиг
    print_step 11 "Генерация и валидация конфига"
    local tmp_cfg; tmp_cfg=$(create_temp)
    generate_xray_config > "$tmp_cfg"
    log SUCCESS "Конфиг сгенерирован (jq)"

    # Шаг 12: Развёртывание
    print_step 12 "Развёртывание на сервере"
    execute_remote "mkdir -p ${INSTALL_DIR}/{config,log}" "Создание директорий"
    upload_and_validate_config "$tmp_cfg"

    local tmp_dc; tmp_dc=$(create_temp)
    generate_docker_compose > "$tmp_dc"
    copy_to_remote "$tmp_dc" "/tmp/docker-compose.yml" "Загрузка docker-compose"
    execute_remote \
        "mv /tmp/docker-compose.yml ${INSTALL_DIR}/docker-compose.yml" \
        "Размещение docker-compose"

    execute_remote "docker stop ${CONTAINER_NAME} 2>/dev/null || true" "" 1
    execute_remote "docker rm -v ${CONTAINER_NAME} 2>/dev/null || true" "" 1
    execute_remote "cd ${INSTALL_DIR} && docker compose up -d" "Запуск контейнера"

    # Шаг 13: Проверки
    print_step 13 "Проверка работоспособности"
    local SELFTEST_OK=1
    if health_check; then
        if selftest_connection "$(make_link "${USER_UUIDS[0]}" "${USER_NAMES[0]}")" "$XRAY_IMAGE" "$IMAGE_SOURCE"; then
            SELFTEST_OK=0; cleanup_old_images
        else
            log WARN "Сквозная проверка не прошла — старые образы не удаляю. Смотрите логи: docker logs ${CONTAINER_NAME}"
        fi
    else
        log WARN "Некоторые проверки не прошли — старые образы не удаляю"
    fi

    # Шаг 14: Сохранение
    print_step 14 "Сохранение данных"
    save_server_data

    print_result
    [[ -n "$BACKUP_DIR" ]] && echo -e "  ${YELLOW}Предыдущая установка сохранена в: ${BACKUP_DIR}${NC}"
    warn_non443
    if [[ "$SELFTEST_OK" -eq 0 ]]; then
        log SUCCESS "Установка завершена! Сквозная проверка подключения пройдена."
    else
        log WARN "Установка завершена, но сквозная проверка подключения НЕ пройдена — разберитесь до выдачи ссылок пользователям."
    fi
}

main "$@"
