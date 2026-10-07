#!/bin/bash

if [ -z "${BASH_VERSION:-}" ]; then
    echo "Ошибка: требуется bash. Запустите: bash $0" >&2
    exit 1
fi

#######################################
# Script Name: 09-wg-easy.sh
# Description: Установка WG-Easy (WireGuard + веб-панель) через docker compose.
#              Управление клиентами полностью в веб-панели; этот скрипт только
#              разворачивает и обновляет контейнер.
# Author:      kshomer
# Version:     1.0
# Date:        09.09.2026
#######################################

set -o errexit
set -o nounset
set -o pipefail

# ============================================
# ВЕРСИЯ ОБРАЗА
# ============================================

# Плавающий тег мажорной версии: внутри него всегда свежий стабильный релиз
# (сейчас 15.4.0), а несовместимый переход на v16 сам собой не случится.
#
# ВНИМАНИЕ: тег latest у wg-easy указывает НЕ на новейшую версию.
# Проверено по дайджестам GHCR: latest == 14 (сборка 2025-06-03),
# тогда как 15 == 15.4.0 (сборка 2026-08-14). Использовать latest нельзя —
# это откат на предыдущее поколение с несовместимыми настройками.
readonly WG_EASY_REPO="ghcr.io/wg-easy/wg-easy"
readonly WG_EASY_TAG="15"
readonly WG_EASY_IMAGE="${WG_EASY_REPO}:${WG_EASY_TAG}"

# ============================================
# КОНСТАНТЫ
# ============================================

readonly INSTALL_DIR="/opt/wg-easy"
readonly CONTAINER_NAME="wg-easy"
# Каталог данных прошлой версии этого скрипта (bind-mount ~/.wg-easy)
readonly LEGACY_DATA_DIR="/root/.wg-easy"

readonly WG_NET_SUBNET="10.42.42.0/24"
readonly WG_NET_SUBNET_V6="fdcc:ad94:bacf:61a3::/64"
readonly WG_CONTAINER_IP="10.42.42.42"
readonly WG_CONTAINER_IP_V6="fdcc:ad94:bacf:61a3::2a"

readonly SSH_TIMEOUT=30
readonly SSH_RETRIES=3
readonly SSH_RETRY_DELAY=5

readonly WAIT_CONTAINER_START=5   # пауза перед проверкой, что контейнер поднялся
readonly WAIT_AUTH_RETRY=3        # пауза между попытками SSH-аутентификации
readonly WAIT_APT_LOCK_STEP=3     # шаг ожидания снятия блокировки apt
readonly HTTP_TIMEOUT=10
readonly LOCK_FILE="/tmp/wg-easy-install.lock"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Runtime
SERVER_IP="" SSH_PORT_SSH="22" SSH_USER="root" SSH_PASSWORD=""
PUBLIC_IP=""
WG_PORT=51820          # WireGuard, UDP
WG_WEB_PORT=51821      # веб-панель, TCP
WEB_BIND=""            # пусто = панель наружу; 127.0.0.1 = только через SSH-туннель
EXISTING_ACTION="none" # none | replace | purge
BACKUP_DIR=""
MIGRATE_LEGACY="no"
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
    return 1
}
validate_port() { [[ $1 =~ ^[0-9]+$ ]] && ((${1} >= 1 && ${1} <= 65535)); }
validate_user() { [[ $1 =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; }

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
        # printf -v вместо eval: ввод не интерпретируется как код
        printf -v "$var" '%s' "$val"
        return 0
    done
}

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

ask_yes_no_word() {   # подтверждение необратимого действия: только слово целиком
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

# Одно соединение на весь запуск (ControlMaster): пароль проверяется один раз,
# остальные команды идут по уже открытому каналу.
SSH_CM_DIR=""
_ssh_opts() {
    # Короткий путь обязателен: лимит длины пути unix-сокета — 104 байта
    [[ -z "$SSH_CM_DIR" ]] && SSH_CM_DIR=$(mktemp -d /tmp/wge-ssh.XXXXXX)
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
    # Пароль через переменную окружения (sshpass -e), а не аргументом -p: -p виден в ps
    SSHPASS="$SSH_PASSWORD" sshpass -e ssh "${SSH_OPTS[@]}" -o BatchMode=no -p "$SSH_PORT_SSH" "${SSH_USER}@${SERVER_IP}" "$@"
}

_scp_cmd() {
    _ssh_opts
    SSHPASS="$SSH_PASSWORD" sshpass -e scp "${SSH_OPTS[@]}" -P "$SSH_PORT_SSH" "$@"
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
# УСТАНОВКА DOCKER
# ============================================

install_docker() {
    execute_remote "
        i=0
        while fuser /var/lib/apt/lists/lock /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
            i=\$((i+1))
            [ \$i -gt 60 ] && break
            sleep ${WAIT_APT_LOCK_STEP}
        done
    " "Ожидание снятия блокировки apt"
    execute_remote "DEBIAN_FRONTEND=noninteractive apt-get update -qq" "Обновление списка пакетов"
    # Полный upgrade выполняется только если есть что обновлять; неинтерактивно,
    # чтобы установка не встала на диалоге настройки пакета
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
# ПРОВЕРКА ПОРТОВ
# ============================================

# Слушатели порта $1 по протоколу $2 (tcp|udp); пустой вывод — порт свободен
port_listeners() {
    local flag="-tlnp"; [[ "$2" == "udp" ]] && flag="-ulnp"
    local info
    info=$(execute_remote_output "ss ${flag} 2>/dev/null | grep ':${1} ' || echo __free__") || info="__free__"
    [[ "$info" == *__free__* ]] && return 1
    echo "$info"; return 0
}

# Контейнер, опубликовавший порт $1 по протоколу $2. Протокол в шаблоне обязателен:
# docker печатает «0.0.0.0:51820->51820/udp», и без него под ':51820->' попал бы
# контейнер, слушающий тот же номер порта по другому протоколу.
port_container() {
    execute_remote_output \
        "docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null | grep -E ':${1}->[0-9]+/${2}' | awk '{print \$1}' | head -1" \
        | tr -d '[:space:]'
}

check_one_port() {   # $1 = tcp|udp, $2 = имя переменной, в которой лежит порт
    local proto="$1" var="$2" label info owner port choice
    # tr, а не ${proto^^}: на macOS bash 3.2, где такой подстановки нет
    label=$(echo "$proto" | tr '[:lower:]' '[:upper:]')
    while true; do
        port="${!var}"
        if ! info=$(port_listeners "$port" "$proto"); then
            log SUCCESS "Порт ${port}/${label} свободен"
            return 0
        fi
        owner=$(port_container "$port" "$proto")
        # Свой же контейнер — это прежняя установка, её разбирает check_existing
        if [[ "$owner" == "$CONTAINER_NAME" ]]; then
            log INFO "Порт ${port}/${label} занят прежней установкой '${CONTAINER_NAME}'"
            return 0
        fi
        echo; log WARN "Порт ${port}/${label} занят:"; echo "$info"
        [[ -n "$owner" ]] && echo -e "  ${CYAN}Занят контейнером: ${owner}${NC}"
        echo
        echo -e "  ${GREEN}1)${NC} Указать другой порт"
        echo -e "  ${RED}0)${NC} Отменить установку"
        echo
        read -r -p "Выберите (0-1): " choice
        case "$choice" in
            1) get_input "Другой порт" "$var" "" "validate_port" "Порт 1-65535" ;;
            0) log INFO "Установка отменена — сервер не изменён"; exit 0 ;;
            *) log WARN "Введите 0 или 1" ;;
        esac
    done
}


# Панель wg-easy говорит только по HTTP: TLS внутри контейнера нет, а INSECURE=true
# его и отключает. Значит вопрос один — кто вообще может до неё дотянуться.
#
# Важно: закрыть опубликованный Docker-ом порт через ufw НЕ получится. Docker кладёт
# правило DNAT в цепочку nat/DOCKER, а трафик идёт через FORWARD → DOCKER-USER →
# DOCKER-FORWARD, минуя цепочки ufw. Проверено на сервере: правило ufw на такой порт
# не действует. Единственный надёжный способ — вообще не публиковать порт наружу,
# а привязать его к 127.0.0.1 и ходить через SSH-туннель.
choose_web_access() {
    echo -e "${CYAN}Доступ к веб-панели:${NC}"
    echo
    echo -e "  ${GREEN}1)${NC} Только через SSH-туннель ${CYAN}(порт слушает 127.0.0.1)${NC}"
    echo -e "     ${CYAN}·${NC} Снаружи панель недоступна вообще"
    echo -e "     ${CYAN}·${NC} Туннель поднимается сам при подключении к серверу, если разрешить запись в ~/.ssh/config"
    echo
    echo -e "  ${YELLOW}2)${NC} Открыть в интернет ${CYAN}(порт слушает 0.0.0.0)${NC}"
    echo -e "     ${YELLOW}·${NC} Панель работает по HTTP: логин, пароль и сессия идут открытым текстом"
    echo -e "     ${YELLOW}·${NC} Закрыть такой порт через ufw не выйдет — его публикует Docker в обход ufw"
    echo
    local c
    while true; do
        read -r -p "Выберите (1/2, по умолчанию: 1): " c
        case "${c:-1}" in
            1) WEB_BIND="127.0.0.1"; log SUCCESS "Панель будет доступна только через SSH-туннель"; return 0 ;;
            2) WEB_BIND="";          log WARN "Панель будет открыта в интернет по HTTP"; return 0 ;;
            *) log WARN "Введите 1 или 2" ;;
        esac
    done
}

check_ports() {
    log STEP "Проверка портов..."
    check_one_port "udp" "WG_PORT"
    check_one_port "tcp" "WG_WEB_PORT"
}

# ============================================
# СУЩЕСТВУЮЩАЯ УСТАНОВКА
# ============================================

# Определяет прежнюю установку и запоминает выбранное действие.
# Само действие выполняется в apply_existing_action() — уже после подтверждения.
check_existing() {
    log STEP "Поиск прежней установки..."
    local state
    state=$(execute_remote_output "
        [ -d '${INSTALL_DIR}' ] && echo DIR
        [ -d '${LEGACY_DATA_DIR}' ] && echo LEGACY
        docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx '${CONTAINER_NAME}' && echo CONTAINER
        true") || true

    local has_dir=no has_legacy=no has_container=no
    [[ "$state" == *DIR* ]]       && has_dir=yes
    [[ "$state" == *LEGACY* ]]    && has_legacy=yes
    [[ "$state" == *CONTAINER* ]] && has_container=yes

    if [[ "$has_dir" == "no" && "$has_legacy" == "no" && "$has_container" == "no" ]]; then
        log SUCCESS "Прежней установки нет — будет чистая установка"
        return 0
    fi

    echo
    [[ "$has_container" == "yes" ]] && echo -e "  ${CYAN}Найден контейнер:${NC} ${CONTAINER_NAME}"
    [[ "$has_dir" == "yes" ]]       && echo -e "  ${CYAN}Найден каталог:${NC}   ${INSTALL_DIR}"
    if [[ "$has_legacy" == "yes" ]]; then
        echo -e "  ${CYAN}Найдены данные прежней версии скрипта:${NC} ${LEGACY_DATA_DIR}"
        echo -e "  ${CYAN}   (тогда данные лежали в домашнем каталоге, теперь — в ${INSTALL_DIR}/data)${NC}"
    fi
    echo
    echo -e "${YELLOW}Варианты:${NC}"
    echo
    echo -e "  ${GREEN}1)${NC} Обновить: сохранить клиентов и настройки, обновить образ до свежего"
    echo -e "     ${CYAN}   Копия каталога данных перед обновлением: ${INSTALL_DIR}.bak.ДАТА${NC}"
    echo
    echo -e "  ${RED}2)${NC} Установить заново, стерев все данные"
    echo -e "     ${RED}   ⚠  Клиенты, ключи и учётная запись панели будут удалены безвозвратно${NC}"
    echo
    echo -e "  ${RED}0)${NC} Отменить установку"
    echo
    echo -e "${CYAN}Выбранное действие будет выполнено только после подтверждения установки.${NC}"
    echo

    while true; do
        local choice
        read -r -p "Выберите (0-2): " choice
        case "$choice" in
            1) EXISTING_ACTION="replace"
               [[ "$has_legacy" == "yes" && "$has_dir" == "no" ]] && MIGRATE_LEGACY="yes"
               log INFO "Запланировано: обновление с сохранением данных"
               return 0 ;;
            2) log WARN "Удаление данных необратимо"
               if ask_yes_no_word "Подтвердить установку заново с потерей всех клиентов?"; then
                   EXISTING_ACTION="purge"
                   log INFO "Запланировано: полное удаление данных и чистая установка"
                   return 0
               fi
               log WARN "Отменено" ;;
            0) log INFO "Установка отменена — сервер не изменён"; exit 0 ;;
            *) log WARN "Введите 0, 1 или 2" ;;
        esac
    done
}

apply_existing_action() {
    [[ "$EXISTING_ACTION" == "none" ]] && return 0

    # Контейнер снимаем в любом случае: compose поднимет новый
    execute_remote "
        if [ -f '${INSTALL_DIR}/docker-compose.yml' ]; then
            cd '${INSTALL_DIR}' && docker compose down --remove-orphans 2>/dev/null || true
        fi
        docker stop '${CONTAINER_NAME}' 2>/dev/null || true
        docker rm -v '${CONTAINER_NAME}' 2>/dev/null || true" \
        "Остановка прежнего контейнера" 1

    if [[ "$EXISTING_ACTION" == "replace" ]]; then
        local bak
        bak=$(execute_remote_output \
            "if [ -d '${INSTALL_DIR}' ] && [ -n \"\$(ls -A '${INSTALL_DIR}' 2>/dev/null)\" ]; then \
                b='${INSTALL_DIR}.bak.'\$(date +%Y%m%d_%H%M%S); cp -a '${INSTALL_DIR}' \"\$b\" && echo \"\$b\"; fi") || true
        bak=$(echo "${bak:-}" | tr -d '[:space:]')
        if [[ -n "$bak" ]]; then
            BACKUP_DIR="$bak"
            log SUCCESS "Резервная копия: ${BACKUP_DIR}"
        fi
        if [[ "$MIGRATE_LEGACY" == "yes" ]]; then
            # Отказ копирования обязан быть виден. Прежде «|| true» стоял ВНУТРИ удалённой
            # команды, поэтому она всегда возвращала ноль: при неудачном cp панель
            # поднималась пустой — без единого прежнего клиента, — а установка сообщала об
            # успехе. Теперь проверяем и код возврата cp, и что в каталоге назначения
            # оказалось не меньше элементов, чем было в источнике.
            log STEP "Перенос данных из ${LEGACY_DATA_DIR}..."
            local mig rc src dst
            mig=$(execute_remote_output "
                src=\$(find '${LEGACY_DATA_DIR}' -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
                mkdir -p '${INSTALL_DIR}/data'
                cp -a '${LEGACY_DATA_DIR}/.' '${INSTALL_DIR}/data/' 2>/dev/null; rc=\$?
                dst=\$(find '${INSTALL_DIR}/data' -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
                echo \"CODE=\${rc} BEFORE=\${src} AFTER=\${dst}\"") || mig=""
            # Метки не должны быть подстроками друг друга: с парой RC/SRC жадная «.*» в sed
            # доходила до последнего вхождения «RC=» — то есть до «SRC=» — и код возврата
            # подменялся числом файлов.
            rc=$(echo "${mig:-}"  | sed -n 's/.*CODE=\([0-9]*\).*/\1/p'   | tail -1)
            src=$(echo "${mig:-}" | sed -n 's/.*BEFORE=\([0-9]*\).*/\1/p' | tail -1)
            dst=$(echo "${mig:-}" | sed -n 's/.*AFTER=\([0-9]*\).*/\1/p'  | tail -1)
            if [[ -z "$rc" || "$rc" != "0" || -z "$src" || -z "$dst" || "$dst" -lt "$src" ]]; then
                log ERROR "Данные из ${LEGACY_DATA_DIR} перенесены не полностью (код: ${rc:-нет ответа}, было: ${src:-?}, стало: ${dst:-?})"
                log ERROR "Прежние данные целы в ${LEGACY_DATA_DIR} — установка прервана"
                exit 1
            fi
            log SUCCESS "Перенесено из ${LEGACY_DATA_DIR}: ${dst} элементов"
            log INFO "Прежний каталог ${LEGACY_DATA_DIR} оставлен на месте — удалите его сами, когда убедитесь, что всё работает"
        fi
    else
        # Полная очистка: каталог, его резервные копии и данные прежней версии скрипта
        execute_remote "rm -rf '${INSTALL_DIR}' '${INSTALL_DIR}'.bak.* '${LEGACY_DATA_DIR}' 2>/dev/null || true" \
            "Удаление данных прежней установки" 1
    fi
}

# ============================================
# DOCKER COMPOSE
# ============================================

# YAML — надмножество JSON, docker compose принимает JSON напрямую.
# Собираем через jq, а не склейкой строк: значения экранируются сами.
generate_docker_compose() {
    jq -n \
        --arg image     "$WG_EASY_IMAGE" \
        --arg container "$CONTAINER_NAME" \
        --arg wgport    "${WG_PORT}:51820/udp" \
        --arg webport   "${WEB_BIND:+${WEB_BIND}:}${WG_WEB_PORT}:51821/tcp" \
        --arg ip4       "$WG_CONTAINER_IP" \
        --arg ip6       "$WG_CONTAINER_IP_V6" \
        --arg subnet4   "$WG_NET_SUBNET" \
        --arg subnet6   "$WG_NET_SUBNET_V6" \
        '{
            "services": {
                "wg-easy": {
                    "image": $image,
                    "container_name": $container,
                    "restart": "unless-stopped",
                    "environment": ["INSECURE=true"],
                    "ports": [$wgport, $webport],
                    "volumes": [
                        "./data:/etc/wireguard",
                        "/lib/modules:/lib/modules:ro"
                    ],
                    "cap_add": ["NET_ADMIN", "SYS_MODULE"],
                    "sysctls": [
                        "net.ipv4.ip_forward=1",
                        "net.ipv4.conf.all.src_valid_mark=1",
                        "net.ipv6.conf.all.disable_ipv6=0",
                        "net.ipv6.conf.all.forwarding=1",
                        "net.ipv6.conf.default.forwarding=1"
                    ],
                    "logging": {
                        "driver": "json-file",
                        "options": {"max-size": "10m", "max-file": "3"}
                    },
                    "networks": {"wg": {"ipv4_address": $ip4, "ipv6_address": $ip6}}
                }
            },
            "networks": {
                "wg": {
                    "driver": "bridge",
                    "enable_ipv6": true,
                    "ipam": {"driver": "default", "config": [{"subnet": $subnet4}, {"subnet": $subnet6}]}
                }
            }
        }'
}

deploy() {
    local tmp; tmp=$(create_temp)
    generate_docker_compose > "$tmp"
    log SUCCESS "docker-compose.yml сгенерирован (jq)"

    execute_remote "mkdir -p ${INSTALL_DIR}/data" "Создание каталогов"
    copy_to_remote "$tmp" "${INSTALL_DIR}/docker-compose.yml" "Загрузка docker-compose.yml"
    # В каталоге лежат ключи WireGuard и база панели — доступ только владельцу
    execute_remote "chmod 700 ${INSTALL_DIR} ${INSTALL_DIR}/data && chmod 600 ${INSTALL_DIR}/docker-compose.yml" "" 1

    # Проверяем файл до запуска: битый compose должен отвалиться здесь, а не после pull
    execute_remote "cd ${INSTALL_DIR} && docker compose config -q" "Проверка docker-compose.yml"

    # pull отдельной командой: docker run/up берёт локальный образ, если он уже есть,
    # и без этого повторный запуск скрипта поднимал бы старую версию молча
    execute_remote "cd ${INSTALL_DIR} && docker compose pull" "Загрузка свежего образа ${WG_EASY_IMAGE}"
    execute_remote "cd ${INSTALL_DIR} && docker compose up -d" "Запуск WG-Easy"
}

# ============================================
# ПРОВЕРКИ ПОСЛЕ ЗАПУСКА
# ============================================

verify() {
    sleep "$WAIT_CONTAINER_START"

    local state
    state=$(execute_remote_output "docker inspect ${CONTAINER_NAME} --format '{{.State.Status}}'" | tr -d '[:space:]') || true
    if [[ "$state" != "running" ]]; then
        log ERROR "Контейнер не запущен (состояние: ${state:-неизвестно})"
        execute_remote_output "docker logs --tail 30 ${CONTAINER_NAME} 2>&1" || true
        return 1
    fi
    log SUCCESS "Контейнер запущен"

    # Версия берётся из метки образа, а не из константы: показываем то, что реально стоит
    local ver
    ver=$(execute_remote_output \
        "docker inspect ${CONTAINER_NAME} --format '{{index .Config.Labels \"org.opencontainers.image.version\"}}'" \
        | tr -d '[:space:]') || true
    [[ -n "$ver" && "$ver" != "<novalue>" ]] && log SUCCESS "Установленная версия: ${ver}"

    # Ротация логов: подтверждаем не по конфигу, а по тому, что видит докер
    local logcfg
    logcfg=$(execute_remote_output \
        "docker inspect ${CONTAINER_NAME} --format '{{.HostConfig.LogConfig.Type}} {{.HostConfig.LogConfig.Config}}'") || true
    log INFO "Логи: ${logcfg:-неизвестно}"

    # Панель отвечает? До завершения мастера настройки это редирект на /setup
    local code
    code=$(execute_remote_output \
        "curl -s -o /dev/null -w '%{http_code}' --max-time ${HTTP_TIMEOUT} http://127.0.0.1:${WG_WEB_PORT}/ 2>/dev/null || true")
    code=$(echo "${code:-000}" | tr -d '[:space:]')
    if [[ "$code" =~ ^(200|30[0-9])$ ]]; then
        log SUCCESS "Веб-панель отвечает (HTTP ${code})"
    else
        log WARN "Веб-панель пока не отвечает (ответ: ${code}) — дайте контейнеру 1-2 минуты"
    fi

    # healthcheck образа проверяет наличие интерфейса WireGuard, а он появляется
    # только после того, как мастер настройки в панели будет пройден
    local health
    health=$(execute_remote_output "docker inspect ${CONTAINER_NAME} --format '{{.State.Health.Status}}'" | tr -d '[:space:]') || true
    if [[ "$health" == "healthy" ]]; then
        log SUCCESS "Healthcheck: healthy (интерфейс WireGuard поднят)"
    else
        log INFO "Healthcheck: ${health:-нет} — это нормально до завершения первичной настройки в панели"
    fi
    return 0
}

# ============================================
# ИТОГОВАЯ ИНФОРМАЦИЯ
# ============================================

# ============================================
# ЗАПИСЬ ПРОБРОСА В ЛОКАЛЬНЫЙ ~/.ssh/config
# ============================================
# Проброс порта устанавливает клиентская сторона, поэтому «прописать один раз на сервере»
# невозможно: сервер к пробросу непричастен. Тот же результат даёт запись в локальном
# ~/.ssh/config — после неё обычный «ssh root@IP» поднимает туннель сам. Файл принадлежит
# текущему пользователю (права 600), скрипт работает от него же, повышение прав не нужно.

ssh_config_block() {
    echo "# --- wg-easy ${PUBLIC_IP} (добавлено установщиком wg-easy) ---"
    echo "Host ${PUBLIC_IP}"
    echo "    LocalForward ${WG_WEB_PORT} 127.0.0.1:${WG_WEB_PORT}"
    echo "# --- конец блока wg-easy ${PUBLIC_IP} ---"
}

# Маркеры привязаны к IP: повторная установка на тот же сервер заменяет свой блок (в том
# числе порт, если он сменился), блоки других серверов не трогаются — wg-easy может стоять
# на нескольких машинах, и каждой нужна своя запись.
write_ssh_config_block() {
    local cfg="${HOME}/.ssh/config" dir="${HOME}/.ssh"
    # Начало блока ищем по префиксу, без хвоста подписи: так находится и блок, записанный
    # прежней версией установщика («установщиком 09»), — иначе он остался бы в файле, а
    # рядом появился бы второй Host для того же адреса.
    local ms="# --- wg-easy ${PUBLIC_IP} (добавлено установщиком "
    local me="# --- конец блока wg-easy ${PUBLIC_IP} ---"
    mkdir -p "$dir" || { log ERROR "Не удалось создать ${dir}"; return 1; }
    chmod 700 "$dir" 2>/dev/null || true
    if [[ ! -e "$cfg" ]]; then
        : > "$cfg" || { log ERROR "Не удалось создать ${cfg}"; return 1; }
        chmod 600 "$cfg"
        log INFO "Создан ${cfg} с правами 600"
    else
        local bak; bak="${cfg}.bak.$(date +%Y%m%d_%H%M%S)"
        cp -p "$cfg" "$bak" || { log ERROR "Не удалось сделать копию ${cfg}"; return 1; }
        log SUCCESS "Копия прежнего файла: ${bak}"
    fi
    local tmp; tmp=$(create_temp)
    # Вырезаем прежний блок этого же IP, остальное переносится как есть; второй проход
    # срезает хвостовые пустые строки, иначе при повторных запусках они копятся
    awk -v s="$ms" -v e="$me" '
        index($0, s) == 1 { skip = 1 }
        skip != 1 { print }
        $0 == e { skip = 0 }
    ' "$cfg" \
      | awk '{ b[NR] = $0 } END { last = 0; for (i = 1; i <= NR; i++) if (b[i] != "") last = i; for (i = 1; i <= last; i++) print b[i] }' \
      > "$tmp" || { log ERROR "Не удалось разобрать ${cfg}"; return 1; }
    [[ -s "$tmp" ]] && printf '\n' >> "$tmp"
    ssh_config_block >> "$tmp"
    # cat, а не mv: так сохраняются владелец и права уже существующего файла
    cat "$tmp" > "$cfg" || { log ERROR "Не удалось записать ${cfg}"; return 1; }
    log SUCCESS "Блок записан в ${cfg}"
}

offer_ssh_config_block() {
    local cfg="${HOME}/.ssh/config"
    echo -e "  ${CYAN}Для корректной работы необходимо один раз прописать проброс в локальном${NC}"
    echo -e "  ${CYAN}${cfg} — тогда обычный «ssh ${SSH_USER}@${PUBLIC_IP}» поднимет туннель сам.${NC}"
    echo
    echo -e "  ${CYAN}Для этого на выбор даётся два варианта:${NC}"
    echo -e "  ${CYAN}1. Автоматический — программа сама выполнит все необходимые действия.${NC}"
    echo -e "  ${CYAN}2. Ручная настройка — даётся пошаговая инструкция для самостоятельной настройки.${NC}"
    echo
    echo -e "  ${GREEN}1)${NC} Автоматическая настройка в ${cfg}"
    echo -e "  ${GREEN}2)${NC} Ручная настройка — пошаговая инструкция"
    echo
    local a
    while true; do
        read -r -p "Выберите (1/2): " a
        case "$a" in
            1) if ask_yes_no_word "Изменить ${cfg}?"; then
                   write_ssh_config_block || log WARN "Файл не изменён — впишите блок вручную"
               else
                   log INFO "Файл не изменён"
               fi
               return 0 ;;
            2) echo
               echo -e "${YELLOW}Пошаговая инструкция:${NC}"
               echo
               echo -e "  ${CYAN}1.${NC} nano ${cfg}"
               echo -e "  ${CYAN}2.${NC} Вставьте в конец файла блок, показанный ниже:"
               echo
               ssh_config_block | sed 's/^/       /'
               echo
               echo -e "  ${CYAN}3.${NC} Сохраните: Ctrl+O, Enter, затем Ctrl+X"
               echo -e "  ${CYAN}4.${NC} Если файл создан только что: chmod 600 ${cfg}"
               return 0 ;;
            *) log WARN "Введите 1 или 2" ;;
        esac
    done
}

print_result() {
    print_header "Установка WG-Easy завершена"

    if [[ -n "$WEB_BIND" ]]; then
        echo -e "${CYAN}Веб-панель — доступ через SSH-туннель:${NC}"
        echo
        echo -e "  ${CYAN}Снаружи панель не отвечает: порт слушает только 127.0.0.1 на сервере.${NC}"
        echo
        offer_ssh_config_block
    else
        echo -e "${CYAN}Веб-панель:${NC}"
        echo -e "  ${GREEN}http://${PUBLIC_IP}:${WG_WEB_PORT}${NC}"
        echo
        echo -e "${RED}Панель открыта в интернет и работает по HTTP, без шифрования.${NC}"
        echo -e "  ${YELLOW}Логин, пароль и сессия передаются открытым текстом — их видит любой узел на пути.${NC}"
        echo
        echo -e "  ${YELLOW}Закрыть этот порт через ufw не получится:${NC} Docker публикует его правилом"
        echo -e "  DNAT в цепочке nat/DOCKER, а трафик идёт мимо цепочек ufw. Чтобы закрыть доступ"
        echo -e "  снаружи, переустановите с вариантом «только через SSH-туннель» — тогда порт"
        echo -e "  будет слушать 127.0.0.1, и снаружи до него не дотянуться."
        echo
        echo -e "  ${CYAN}HTTPS у самой панели нет:${NC} wg-easy отдаёт только HTTP, шифрование"
        echo -e "  добавляется снаружи — обратным прокси на своём домене (Caddy, nginx, Traefik)"
        echo -e "  с сертификатом Let's Encrypt."
    fi
    echo

    # Напоминание о порядке подключения — только для варианта с туннелем: при панели,
    # открытой наружу, адрес 127.0.0.1 никуда не ведёт.
    if [[ -n "$WEB_BIND" ]]; then
        echo -e "${CYAN}Теперь для подключения к веб-панели wg-easy каждый раз нужно:${NC}"
        echo -e "  ${CYAN}в терминале выполнить${NC} ${GREEN}ssh ${SSH_USER}@${PUBLIC_IP}${NC}"
        echo -e "  ${CYAN}и, не закрывая окно, открыть в браузере${NC} ${GREEN}http://127.0.0.1:${WG_WEB_PORT}/${NC}"
        echo
    fi

    if [[ "$EXISTING_ACTION" != "replace" || -z "$BACKUP_DIR" ]]; then
        # Экраны мастера — как они выглядят в v15. Вопрос мастера идёт обычным
        # цветом, что именно вводить — зелёным, чтобы одно не путалось с другим.
        echo -e "${CYAN}Первичная настройка (один раз, в браузере):${NC}"
        echo -e "  ${CYAN}1.${NC} Экран «Welcome to your first setup of wg-easy»"
        echo -e "     ${GREEN}нажмите Continue${NC}"
        echo -e "  ${CYAN}2.${NC} Экран «Please first enter an admin username and a strong secure password»"
        echo -e "     ${GREEN}задайте логин и пароль администратора панели${NC}"
        echo -e "  ${CYAN}3.${NC} Вопрос «Do you have an existing setup?»"
        echo -e "     ${GREEN}выберите No${NC}"
        echo -e "  ${CYAN}4.${NC} Экран «Please enter the host and port information»"
        echo -e "     ${GREEN}host: ${PUBLIC_IP}${NC}"
        echo -e "     ${GREEN}port: ${WG_PORT} (обычно уже подставлен)${NC}"
        echo
    fi

    echo -e "${CYAN}Порты:${NC}"
    echo -e "  WireGuard: ${GREEN}${WG_PORT}/udp${NC}    Панель: ${GREEN}${WG_WEB_PORT}/tcp${NC}"
    echo

    echo -e "${CYAN}Файлы на сервере:${NC}"
    echo -e "  Каталог установки: ${GREEN}${INSTALL_DIR}${NC}"
    echo -e "  Данные и ключи:    ${GREEN}${INSTALL_DIR}/data${NC}"
    echo -e "  Compose-файл:      ${GREEN}${INSTALL_DIR}/docker-compose.yml${NC}"
    [[ -n "$BACKUP_DIR" ]] && echo -e "  Резервная копия:   ${GREEN}${BACKUP_DIR}${NC}"
    echo

    echo -e "${CYAN}Управление (на сервере, из ${INSTALL_DIR}):${NC}"
    echo -e "  Логи:        ${GREEN}docker compose logs -f${NC}"
    echo -e "  Статус:      ${GREEN}docker compose ps${NC}"
    echo -e "  Перезапуск:  ${GREEN}docker compose restart${NC}"
    echo -e "  Обновление:  ${GREEN}docker compose pull && docker compose up -d${NC}"
    echo -e "  Остановка:   ${GREEN}docker compose down${NC}"
    echo

    echo -e "${CYAN}Логи ограничены по размеру:${NC} json-file, до 10 MB × 3 файла (максимум 30 MB)."
    echo -e "  ${CYAN}Образ по умолчанию пишет подробный отладочный лог, поэтому ротация важна.${NC}"
    echo
}

# ============================================
# ГЛАВНАЯ ФУНКЦИЯ
# ============================================

main() {
    clear
    print_header "WG-Easy · WireGuard с веб-панелью"
    echo -e "  ${CYAN}Установка wg-easy из официального репозитория проекта${NC}"
    echo -e "  ${CYAN}Образ:${NC} wg-easy (${WG_EASY_REPO})"
    echo
    acquire_lock

    log STEP "Проверка локальных зависимостей..."
    local missing=()
    for dep in ssh scp jq sshpass; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log ERROR "Отсутствуют зависимости: ${missing[*]}"
        log INFO "macOS: brew install ${missing[*]}"
        log INFO "sshpass на macOS: brew install hudochenkov/sshpass/sshpass"
        exit 1
    fi
    log SUCCESS "Все зависимости найдены"

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
    # Каталог сокета ControlMaster создаётся здесь, в родительской оболочке: вызовы ssh
    # внутри $(...) идут в подоболочках и иначе каждый заводил бы свой мастер
    SSH_CM_DIR=$(mktemp -d /tmp/wge-ssh.XXXXXX)

    # Шаг 2: Проверка сервера
    print_step 2 "Проверка доступности"
    log STEP "Проверка TCP:${SSH_PORT_SSH}..."
    # Только TCP-проверка: ping часто заблокирован у провайдера и даёт ложный отказ
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
        "curl -s --max-time ${HTTP_TIMEOUT} ifconfig.me || curl -s --max-time ${HTTP_TIMEOUT} ipinfo.io/ip || echo '${SERVER_IP}'") \
        || PUBLIC_IP="$SERVER_IP"
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
    # v15 не собирается под armv6/armv7 — на таких машинах образ просто не запустится
    if echo "${srv_info:-}" | grep -qiE "armv6|armv7"; then
        log ERROR "WG-Easy v15 не поддерживает armv6/armv7"
        exit 1
    fi
    if ! echo "${srv_info:-}" | grep -qiE "ubuntu.*(22|24|25|26)"; then
        log WARN "Рекомендуется Ubuntu 22.04+"
        ask_yn "Продолжить?" || exit 0
    fi

    # Шаг 3: Порты и прежняя установка (только проверка; действия — после подтверждения)
    print_step 3 "Проверка портов и прежней установки"
    choose_web_access
    echo
    check_ports
    check_existing

    # Подтверждение
    print_header "Параметры установки"
    echo -e "  Сервер:          ${GREEN}${SSH_USER}@${SERVER_IP}:${SSH_PORT_SSH}${NC}"
    echo -e "  Публичный IP:    ${GREEN}${PUBLIC_IP}${NC}"
    echo -e "  Образ:           ${GREEN}${WG_EASY_IMAGE}${NC} (будет загружен свежий)"
    echo -e "  Каталог:         ${GREEN}${INSTALL_DIR}${NC}"
    echo -e "  WireGuard:       ${GREEN}${WG_PORT}/udp${NC}"
    if [[ -n "$WEB_BIND" ]]; then
        echo -e "  Веб-панель:      ${GREEN}${WG_WEB_PORT}/tcp${NC} ${CYAN}(только 127.0.0.1, доступ через SSH-туннель)${NC}"
    else
        echo -e "  Веб-панель:      ${GREEN}${WG_WEB_PORT}/tcp${NC} ${YELLOW}(открыта в интернет, HTTP без шифрования)${NC}"
    fi
    case "$EXISTING_ACTION" in
        replace) echo -e "  Прежняя установка: ${YELLOW}данные сохраняются, будет сделана резервная копия${NC}" ;;
        purge)   echo -e "  Прежняя установка: ${RED}все данные будут УДАЛЕНЫ${NC}" ;;
    esac
    echo -e "  Система:         будет выполнен apt-get update && upgrade, установлен/обновлён Docker"
    echo
    ask_yn "Начать установку?" "n" || { log WARN "Установка отменена пользователем"; exit 0; }

    # Шаг 4: Прежняя установка
    print_step 4 "Подготовка"
    apply_existing_action

    # Шаг 5: Docker
    print_step 5 "Установка и обновление Docker"
    install_docker

    # Шаг 6: Развёртывание
    print_step 6 "Развёртывание WG-Easy"
    deploy

    # Шаг 7: Проверка
    print_step 7 "Проверка работоспособности"
    if ! verify; then
        log ERROR "Контейнер не поднялся — смотрите логи выше"
        exit 1
    fi

    print_result
    log SUCCESS "Готово. Откройте панель и завершите первичную настройку."
}

main "$@"
