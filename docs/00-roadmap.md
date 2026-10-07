# Обзор проекта и оглавление документации

## О проекте

Десять скриптов на bash: девять установщиков под разные конфигурации и менеджер для
администрирования установленного. Установщик запускается на рабочей машине и через одно
SSH-соединение готовит сервер и разворачивает выбранную конфигурацию в Docker Compose.

```
рабочая машина                       сервер (VPS)
──────────────                       ────────────
установщик
  │
  ├─ вопросы в терминале
  ├─ генерация конфигурации локально
  │
  └─ одно SSH-соединение ──────────► apt, Docker, docker compose up
                                       │
                                     сквозная проверка: временный клиент
                                     на сервере подключается по выданной
                                     ссылке и выполняет HTTPS-запрос
```

Краткое описание проекта — в [README](../README.md).

---

## С чего начать

| Задача | Документ |
|---|---|
| Установка скриптов на рабочую машину | [10. Установка](10-installation.md) |
| Конфигурация без домена, транспорт TCP | [01. Xray: VLESS + Reality, TCP](01-xray-reality-tcp.md) |
| Конфигурация без домена, транспорт XHTTP | [02. Xray: VLESS + Reality, XHTTP](02-xray-reality-xhttp.md) |
| Собственный домен и сертификат Let's Encrypt | [03](03-domain-prerequisites.md) → [04](04-cloudflare-setup.md) → [05](05-xray-xhttp-tls-domain.md) |
| Протоколы на базе QUIC (UDP) | [06. sing-box](06-singbox.md) |
| WireGuard с веб-панелью | [07. wg-easy](07-wg-easy.md) |
| Администрирование установленного | [08. Менеджер](08-manager.md) |
| Вход на сервер по ключу и короткому имени | [09. Настройка SSH](09-ssh-access.md) |

---

## Оглавление

### Начало работы

- [10. Установка: macOS и Windows](10-installation.md)

### Конфигурации без домена

- [01. Xray: VLESS + Reality поверх TCP](01-xray-reality-tcp.md)
- [02. Xray: VLESS + Reality поверх XHTTP](02-xray-reality-xhttp.md)

### Конфигурация с доменом

- [03. Что нужно и в каком порядке](03-domain-prerequisites.md)
- [04. Подключение домена к Cloudflare и API-токен](04-cloudflare-setup.md)
- [05. Xray: VLESS + XHTTP + TLS на собственном домене](05-xray-xhttp-tls-domain.md)

### Другие ядра и протоколы

- [06. sing-box: VLESS + Reality, Hysteria2, TUIC v5](06-singbox.md)
- [07. WireGuard с веб-панелью wg-easy](07-wg-easy.md)

### Администрирование и доступ

- [08. Менеджер: пункты меню](08-manager.md)
- [09. Настройка SSH-доступа](09-ssh-access.md)

---

## Скрипты

| Файл | Описание |
|---|---|
| [`00-manager.sh`](../scripts/00-manager.sh) | Менеджер: администрирование установленных конфигураций Xray и sing-box |
| [`01-vless-tcp-reality-official.sh`](../scripts/01-vless-tcp-reality-official.sh) | Xray, VLESS + Reality, транспорт TCP; официальный образ XTLS |
| [`02-vless-tcp-reality-teddy.sh`](../scripts/02-vless-tcp-reality-teddy.sh) | Xray, VLESS + Reality, транспорт TCP; образ teddysun |
| [`03-vless-tcp-reality-choice.sh`](../scripts/03-vless-tcp-reality-choice.sh) | Xray, VLESS + Reality, транспорт TCP; образ выбирается при установке |
| [`04-vless-xhttp-reality-official.sh`](../scripts/04-vless-xhttp-reality-official.sh) | Xray, VLESS + Reality, транспорт XHTTP; официальный образ XTLS |
| [`05-vless-xhttp-reality-teddy.sh`](../scripts/05-vless-xhttp-reality-teddy.sh) | Xray, VLESS + Reality, транспорт XHTTP; образ teddysun |
| [`06-vless-xhttp-reality-choice.sh`](../scripts/06-vless-xhttp-reality-choice.sh) | Xray, VLESS + Reality, транспорт XHTTP; образ выбирается при установке |
| [`07-vless-xhttp-tls-domain.sh`](../scripts/07-vless-xhttp-tls-domain.sh) | Xray, VLESS + XHTTP + TLS; Caddy и сертификат Let's Encrypt на собственном домене |
| [`08-singbox.sh`](../scripts/08-singbox.sh) | sing-box: VLESS + Reality, Hysteria2 или TUIC v5 |
| [`09-wg-easy.sh`](../scripts/09-wg-easy.sh) | WireGuard с веб-панелью wg-easy |

---

## Проектные решения

- **Самостоятельные установщики** — одна конфигурация, один скрипт, без общих подключаемых
  файлов.
- **Пароль не попадает в аргументы процессов** — передаётся `sshpass` через переменную
  окружения; поддерживается вход по SSH-ключу (см. [09](09-ssh-access.md)).
- **Проверка до применения** — конфигурация проверяется ядром (`xray -test`,
  `sing-box check`) и заменяет рабочую атомарно.
- **Минимальные привилегии** — контейнеры с `cap_drop: ALL` и `no-new-privileges`,
  официальный образ Xray без root; файлы с ключами и UUID — права 600 или 640.
- **Ротация журналов** — `json-file`, до 10 МБ × 3 файла.
- **Администрирование через менеджер** — пользователи, ссылки, SNI, версия ядра и удаление
  из одного меню, без ручной правки конфигураций на сервере.
