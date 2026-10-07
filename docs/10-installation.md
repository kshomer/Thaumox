# Установка

Скрипты запускаются на рабочей машине и подключаются к серверу по SSH. Поддерживаются
macOS и Linux; в Windows скрипты работают внутри Ubuntu через WSL.

**Сервер:** Ubuntu 22.04 или новее, доступ по SSH с правами root, свободный порт под
выбранную конфигурацию. Docker устанавливается скриптом.

---

## macOS

1. Инструменты разработчика (git, python3, ssh) — если ещё не установлены:

   ```sh
   xcode-select --install
   ```

2. [Homebrew](https://brew.sh) — если ещё не установлен.

3. Зависимости:

   ```sh
   brew install jq qrencode
   brew install hudochenkov/sshpass/sshpass
   ```

4. Загрузка репозитория:

   ```sh
   git clone https://github.com/kshomer/Thaumox.git
   cd Thaumox/scripts
   ```

5. Запуск скрипта:

   ```sh
   bash ./<скрипт>.sh
   ```

   Пример — установщик конфигурации `01`:

   ```sh
   bash ./01-vless-tcp-reality-official.sh
   ```

---

## Windows (WSL)

1. PowerShell от имени администратора — установка WSL с Ubuntu, затем перезагрузка:

   ```powershell
   wsl --install
   ```

   При первом запуске Ubuntu создаётся пользователь Linux.

2. Зависимости — в терминале Ubuntu:

   ```sh
   sudo apt update
   sudo apt install -y git jq python3 sshpass qrencode openssh-client
   ```

3. Загрузка репозитория — в домашний каталог Ubuntu, а не в `/mnt/c/…`:

   ```sh
   cd ~
   git clone https://github.com/kshomer/Thaumox.git
   cd Thaumox/scripts
   ```

4. Запуск скрипта:

   ```sh
   bash ./<скрипт>.sh
   ```

   Пример — установщик конфигурации `01`:

   ```sh
   bash ./01-vless-tcp-reality-official.sh
   ```

PowerShell нужен только на шаге 1 — для установки WSL. Шаги 2–4 выполняются в терминале
Ubuntu: скрипты работают в среде Linux, а не в PowerShell или командной строке Windows.
Те же шаги подходят для Ubuntu и Debian без WSL.

---

## Выбор скрипта

| Конфигурация | Скрипт | Документ |
|---|---|---|
| Xray: VLESS + Reality, TCP | `01`, `02` или `03` | [01](01-xray-reality-tcp.md) |
| Xray: VLESS + Reality, XHTTP | `04`, `05` или `06` | [02](02-xray-reality-xhttp.md) |
| Xray: VLESS + XHTTP + TLS на собственном домене | `07` | [05](05-xray-xhttp-tls-domain.md) |
| sing-box: VLESS + Reality, Hysteria2, TUIC v5 | `08` | [06](06-singbox.md) |
| WireGuard с веб-панелью wg-easy | `09` | [07](07-wg-easy.md) |
| Менеджер установленных конфигураций | `00` | [08](08-manager.md) |

Полные имена файлов — в [оглавлении](00-roadmap.md#скрипты).
