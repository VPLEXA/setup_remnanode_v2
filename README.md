# ssl-remnanode — Remnawave Node + nginx + certbot

Автоматизированная настройка ноды Remnawave с SSL-сертификатом Let's Encrypt.

Документация: [Remnawave Node](https://docs.rw/docs/install/remnawave-node)

## 🚀 Однокомандная установка (чистый сервер)

Одна команда на чистом Ubuntu/Debian сервере — без ручной установки Docker,
без ручного создания пользователя `admin`, без ручного `git clone`. Скрипт сам
делает всё, что описано ниже в разделе "Предварительные настройки сервера",
и в конце прогоняет `setup-remnanode.sh`.

**Перед первым запуском на новой ноде — скачайте и просмотрите скрипт, не
запускайте `curl | bash` вслепую:**

```bash
curl -o install.sh -fsSL https://raw.githubusercontent.com/VPLEXA/setup_remnanode_v2/<tag>/install.sh
less install.sh   # убедитесь, что содержимое ожидаемое
sudo bash install.sh --domain node1.example.com --email you@example.com \
  --secret-key-file /root/secret_key.txt --panel-ip 1.2.3.4 --protocols all
```

Замените `<tag>` на конкретный релизный тег (не `main` — форс-пуш или
компрометация репозитория не должны незаметно подменить скрипт на проде).

Флаги:

| Флаг | Обязателен | Описание |
|------|------------|----------|
| `--domain` | да | Домен ноды (A/AAAA должна уже указывать на этот сервер) |
| `--email` | да | Email для Let's Encrypt |
| `--secret-key` / `--secret-key-file` / env `SECRET_KEY` | да | SECRET_KEY из панели Remnawave. `--secret-key-file`/переменная окружения безопаснее bare-флага — он виден в `ps` и истории шелла |
| `--panel-ip` | нет | Ограничить порт API только этим IP (иначе остаётся открыт всем) |
| `--protocols all\|none\|<список>` | нет | Список кодов через запятую: `xhttp,hy2,tcpr,grpcr,trojan,bridge`. **Не передан** — выбор протоколов остаётся интерактивным, как при обычном ручном запуске (нужен реальный терминал, не голый `curl \| bash` без сессии) |
| `--node-port`, `--repo`, `--ref`, `--install-dir`, `--dns-timeout` | нет | Тонкая настройка, см. `install.sh --help` |
| `--dry-run` | нет | Только показать план действий, ничего не менять в системе — полезно перед первым запуском на новой VDS |

Скрипт идемпотентен: повторный запуск на уже настроенной ноде обновляет
репозиторий и переиспользует существующий `.env`, не ломая рабочую конфигурацию.

<details>
<summary><h2>Предварительные настройки сервера перед использованием скрипта</h2></summary>

*(то, что `install.sh` делает автоматически — этот раздел актуален для ручной
установки без единого скрипта)*

# Подготовка сервера перед запуском setup-remnanode.sh

## Требования к серверу

- ОС: Ubuntu 22.04 LTS (рекомендуется) или Debian 11/12
- RAM: минимум 1 ГБ
- Порты 80 и 443 должны быть свободны и доступны из интернета

---

## Шаг 1 — Обновить систему

```bash
sudo apt update && sudo apt upgrade -y
```

---

## Шаг 2 — Установить Docker

Установить зависимости:

```bash
sudo apt install -y ca-certificates curl gnupg lsb-release git
```

Добавить официальный GPG-ключ и репозиторий Docker:

```bash
sudo mkdir -p /etc/apt/keyrings

curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
```

Установить Docker и плагин Compose:

```bash
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
```

Запустить Docker и добавить в автозагрузку:

```bash
sudo systemctl start docker
sudo systemctl enable docker
```

Проверить установку:

```bash
docker --version
docker compose version
```

---

## Шаг 3 — Создать пользователя `admin`

Проверить, существует ли пользователь, и создать если нет:

```bash
id admin 2>/dev/null || sudo useradd -m -s /bin/bash admin
```

Добавить пользователя в группу `docker` (чтобы не нужен был `sudo` для Docker):

```bash
sudo usermod -aG docker admin
```

Установить пароль (запомните его):

```bash
sudo passwd admin
```

---

## Шаг 4 — Настроить `sudo` без пароля для пользователя `admin`

> Это нужно, чтобы скрипт мог настроить UFW автоматически.

```bash
echo "admin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/admin
```

---

## Шаг 5 — Настроить DNS (у регистратора домена)

> ⚠️ Домен должен указывать на IP сервера **до** запуска скрипта — иначе Let's Encrypt не выдаст SSL-сертификат.

**1. Узнать IP сервера:**

```bash
curl -4 ifconfig.me
```

**2. У регистратора домена создать A-запись:**

| Поле   | Значение               |
|--------|------------------------|
| Имя    | `node1.example.com`    |
| Тип    | `A`                    |
| Адрес  | IP вашего сервера      |
| TTL    | `300` (или минимальный)|

**3. Подождать 5–15 минут, затем проверить что DNS обновился:**

```bash
nslookup node1.example.com
```

Команда должна вернуть IP вашего сервера.

---

## Шаг 6 — Скачать репозиторий на сервер

```bash
sudo mkdir -p /opt/remnanode
sudo git clone https://github.com/m1han1k/setup_remnanode.git /opt/remnanode
sudo chown -R admin:admin /opt/remnanode
chmod +x /opt/remnanode/setup-remnanode.sh
chmod +x /opt/remnanode/scripts/*.sh
```

---

## Шаг 7 — Подготовить данные для скрипта

Перед запуском скрипта нужно знать следующие параметры:

| Параметр     | Где взять                                                                 |
|--------------|---------------------------------------------------------------------------|
| `Домен`      | Тот, что настроили в шаге 5                                               |
| `Email`      | Любой — на него придут уведомления об истечении SSL-сертификата           |
| `SECRET_KEY` | Панель Remnawave → Ноды → «Добавить ноду» → скопировать `SECRET_KEY`     |
| `IP панели`  | IP сервера, где установлена панель Remnawave (нужен для ограничения порта 8080) |

---

## Шаг 8 — Запустить скрипт

Если вы работаете под `root`, сначала переключитесь на пользователя `admin`:

```bash
su - admin
```

Перейти в папку и запустить скрипт:

```bash
cd /opt/remnanode
./setup-remnanode.sh
```

---

## Что скрипт делает автоматически

Следующее делать **вручную не нужно** — скрипт выполнит всё сам:

- Настроит UFW: откроет порты `22`, `80`, `443`, `8080`
- Получит SSL-сертификат от Let's Encrypt
- Создаст `.env`-файл с конфигурацией
- Запустит Docker-контейнер ноды
- Настроит автоматическое обновление сертификата через `cron`
- Предложит настроить протоколы Xray (см. раздел [Настройка протоколов Xray](#настройка-протоколов-xray)) — можно пропустить

---

## После запуска — ограничить доступ к порту 8080

> ⚠️ По умолчанию скрипт открывает порт `8080` для всех IP. Если нужно разрешить доступ только с IP панели Remnawave — выполните следующие команды:

Удалить правило «открыто для всех»:

```bash
sudo ufw delete allow 8080/tcp
```

Разрешить доступ только с IP вашей панели:

```bash
sudo ufw allow from <IP_ПАНЕЛИ> to any port 8080 proto tcp
```

Применить изменения:

```bash
sudo ufw reload
```
</details>

## 🚀 Быстрый старт (сервер уже подготовлен вручную)

> Если сервер ещё чистый — используйте `install.sh` из раздела выше, он сделает
> всё это автоматически. Раздел ниже — для случая, когда Docker/admin/клонирование
> уже сделаны вручную и остаётся только прогнать сам скрипт настройки ноды.

**Новая нода? Используйте автоматизированный скрипт:**

```bash
# На сервере (пользователь admin):
cd /opt/remnanode
./setup-remnanode.sh
```

Скрипт автоматически:
- ✅ Запросит конфигурацию (DOMAIN, EMAIL, SECRET_KEY)
- ✅ Настроит UFW файрвол
- ✅ Получит SSL-сертификат от Let's Encrypt
- ✅ Запустит контейнер ноды
- ✅ Настроит автоматическое продление сертификата
- ✅ Предложит настроить протоколы Xray (все включены по умолчанию, можно пропустить)

**📖 [Полная инструкция по развертыванию](DEPLOYMENT.md)**

---

## Настройка протоколов Xray

В конце установки скрипт предложит настроить протоколы (все включены по умолчанию,
на любой вопрос можно ответить `n`):

| Протокол | Порт по умолчанию |
|----------|-------------------|
| VLESS XHTTP + Reality | 443/tcp |
| Hysteria2 | 443/udp |
| VLESS TCP + Reality | 4443/tcp |
| VLESS gRPC + Reality | 8443/tcp |
| Trojan WS + TLS | 2096/tcp |
| Bridge-inbound (каскад) | 9999/tcp |

Скрипт сам сгенерирует Reality-ключи (свой keypair на каждый Reality-протокол —
XHTTP, TCP, gRPC) и shortIds, откроет порты в UFW, соберёт готовый конфиг
`xray-multiconfig.json` и проверит его через `xray -test` внутри контейнера.
Останется вставить содержимое файла в панель Remnawave (Config ноды).

Перенастроить протоколы можно в любой момент:

```bash
./scripts/setup-protocols.sh
```

### Обновление ноды, установленной старой версией скрипта

На уже работающей ноде достаточно обновить репозиторий и запустить настройку
протоколов — скрипт сам починит docker-compose.yml (mount `letsencrypt/archive`,
без которого Xray не видел сертификаты), при необходимости пересоздаст контейнер
и добавит новые протоколы:

```bash
cd /opt/remnanode
git pull
./scripts/setup-protocols.sh
```

**⚠️ Проблемы с установкой Docker?**
- Быстрое решение: `sudo bash docker-fix.sh`

---

## Порты

**Базовые (открывает `setup-remnanode.sh`):**

| Порт | Роль |
|------|------|
| **22** | SSH (управление сервером) |
| **80** | HTTP — только для Let's Encrypt HTTP-01 валидации |
| **443/tcp** | HTTPS — Xray (VLESS XHTTP + Reality) |
| **8080** | API ноды для панели (открыть только IP панели!) |

**Протоколы (открывает `scripts/setup-protocols.sh` для выбранных протоколов):**

| Порт | Протокол |
|------|----------|
| **443/tcp** | VLESS XHTTP + Reality |
| **443/udp** | Hysteria2 |
| **4443/tcp** | VLESS TCP + Reality |
| **8443/tcp** | VLESS gRPC + Reality |
| **2096/tcp** | Trojan WS + TLS |
| **9999/tcp** | Bridge-inbound (каскад) |

> Порты протоколов настраиваются при запуске скрипта — значения по умолчанию можно изменить.

Сертификаты в контейнере: `/var/lib/remnawave/configs/xray/ssl/` — см. [XRay SSL cert for Node](https://docs.rw/docs/install/remnawave-node#xray-ssl-cert-for-node). Для **REALITY** сертификаты не требуются.

---

## 📋 Для ручной настройки (опционально)

Если нужна ручная настройка без скрипта:

```bash
cd /opt/remnanode
cp .env.example .env && nano .env   # Задайте DOMAIN, EMAIL, NODE_PORT, SECRET_KEY
./scripts/issue-cert.sh
./scripts/up.sh
./scripts/setup-protocols.sh        # (опционально) настроить протоколы Xray
```

---

## 📅 Автоматическое продление сертификата

Скрипт автоматически добавляет Cron job:

```bash
# Выполняется 1-го числа каждого месяца в 04:00
0 4 1 * * /opt/remnanode/scripts/renew-cert.sh >> /var/log/ssl-remnanode-acme.log 2>&1
```

Проверить:
```bash
crontab -l | grep renew-cert
```

---

## 📁 Структура проекта

```
/opt/remnanode/
├── install.sh                  # Однокомандный установщик чистого сервера (root -> admin)
├── setup-remnanode.sh          # Главный скрипт установки ноды
├── .env                        # Конфигурация (создается скриптом)
├── .env.example                # Шаблон
├── docker-compose.yml          # Конфигурация контейнеров
├── docker-fix.sh               # Быстрое решение проблем с Docker
├── xray-multiconfig.json       # Готовый конфиг Xray (создается setup-protocols.sh)
├── README.md                   # Эта инструкция
├── DEPLOYMENT.md               # Подробное руководство
├── scripts/
│   ├── bootstrap.sh            # Инициализация .env
│   ├── issue-cert.sh           # Получение SSL-сертификата
│   ├── renew-cert.sh           # Продление сертификата (Cron)
│   ├── up.sh                   # Запуск контейнера
│   └── setup-protocols.sh      # Интерактивная настройка протоколов Xray
├── nginx/
│   └── conf.d/00-acme.conf     # Конфиг для Let's Encrypt
├── certbot/                    # Данные certbot
└── letsencrypt/                # Сертификаты (создается скриптом)
```

> `xray-multiconfig.json` содержит приватные Reality-ключи и добавлен в `.gitignore` — в репозиторий не попадает.

---

## 🛠️ Полезные команды

```bash
# Логи контейнера
docker compose logs -f remnanode

# Статус
docker compose ps

# Остановка/перезапуск
docker compose down
docker compose restart remnanode

# Проверка сертификата
openssl x509 -in letsencrypt/live/<DOMAIN>/cert.pem -noout -dates
```

---

**Начните с [DEPLOYMENT.md](DEPLOYMENT.md) для полной инструкции!**
