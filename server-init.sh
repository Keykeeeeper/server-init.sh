#!/bin/bash
# ══════════════════════════════════════════════════════════
# server-init.sh — первичная настройка любого Ubuntu сервера
# Запускать: sudo bash server-init.sh
# ══════════════════════════════════════════════════════════

# ─── ЦВЕТА ДЛЯ КРАСИВОГО ВЫВОДА ───────────────────────────
# \033[1;32m = зелёный жирный, \033[0m = сброс цвета
# Профи используют цвета чтобы сразу видеть ок/ошибка
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # NC = No Color = сброс

# ─── ФУНКЦИИ ──────────────────────────────────────────────
# Функция = блок кода с именем, можно вызывать много раз
# Профи выносят повторяющийся код в функции

# Функция: печатает зелёное сообщение об успехе
ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
# Функция: печатает красную ошибку
err()  { echo -e "${RED}[✗]${NC} $1"; }
# Функция: печатает жёлтое предупреждение
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
# Функция: печатает синий заголовок шага
step() { echo -e "\n${BLUE}══ $1 ══${NC}"; }

# ─── ПРОВЕРКА: запущен ли скрипт от root ──────────────────
# $EUID = переменная окружения, хранит ID текущего пользователя
# root всегда имеет ID = 0
# -ne = not equal = не равно
if [ "$EUID" -ne 0 ]; then
    err "Запусти скрипт от root: sudo bash server-init.sh"
    exit 1  # exit 1 = выйти с ошибкой (0 = успех, не 0 = ошибка)
fi

# ─── ШАГ 0: ДИАГНОСТИКА СИСТЕМЫ ───────────────────────────
step "Диагностика системы"

# Показываем сколько пользователей уже есть
# /etc/passwd = файл где хранятся все пользователи
# awk -F: '$3 >= 1000' = берём только обычных юзеров (ID >= 1000)
# wc -l = считаем количество строк
EXISTING_USERS=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd)
USER_COUNT=$(echo "$EXISTING_USERS" | grep -c .)

echo "Пользователей в системе: $USER_COUNT"

if [ "$USER_COUNT" -gt 0 ]; then
    warn "Уже существуют пользователи:"
    # Выводим каждого пользователя
    echo "$EXISTING_USERS" | while read u; do
        # Проверяем есть ли у пользователя sudo права
        if groups "$u" 2>/dev/null | grep -q sudo; then
            echo "  → $u (есть sudo)"
        else
            echo "  → $u (без sudo)"
        fi
    done
fi

# Проверяем базовую настройку SSH
step "Проверка текущей конфигурации SSH"

# grep -q = тихий поиск (q = quiet), возвращает 0 если нашёл
if grep -q "PermitRootLogin no" /etc/ssh/sshd_config; then
    ok "Root логин уже отключён"
else
    warn "Root логин ещё разрешён — исправим"
fi

if grep -q "PasswordAuthentication no" /etc/ssh/sshd_config; then
    ok "Вход по паролю уже отключён"
else
    warn "Вход по паролю ещё разрешён — исправим"
fi

# Показываем текущий порт SSH
# grep = ищем строку, awk = берём второе слово
CURRENT_PORT=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}')
# Если порт не задан явно — стандартный 22
CURRENT_PORT=${CURRENT_PORT:-22}
echo "Текущий порт SSH: $CURRENT_PORT"

# ─── ШАГ 1: СБОР ДАННЫХ ───────────────────────────────────
step "Настройка — отвечай на вопросы"

# read -p = показать подсказку и ждать ввода
# -p = prompt = подсказка
read -p "Имя нового пользователя: " USERNAME

# Проверяем что имя не пустое
# -z = zero = пустая строка
if [ -z "$USERNAME" ]; then
    err "Имя пользователя не может быть пустым!"
    exit 1
fi

# Проверяем что такого пользователя ещё нет
# id = команда проверки существования пользователя
# &>/dev/null = скрыть весь вывод (и stdout и stderr)
if id "$USERNAME" &>/dev/null; then
    warn "Пользователь $USERNAME уже существует!"
    read -p "Продолжить настройку для него? (yes/no): " CONTINUE
    if [ "$CONTINUE" != "yes" ]; then
        exit 0
    fi
    USER_EXISTS=true
else
    USER_EXISTS=false
fi

# Запрашиваем пароль (дважды для проверки)
# -s = silent = скрывает ввод (пароль не видно)
read -s -p "Пароль для $USERNAME: " PASSWORD1
echo  # просто перенос строки после скрытого ввода
read -s -p "Повтори пароль: " PASSWORD2
echo

# Сравниваем два пароля
if [ "$PASSWORD1" != "$PASSWORD2" ]; then
    err "Пароли не совпадают!"
    exit 1
fi

# Инструкция по генерации ключей
echo ""
warn "Сейчас нужен публичный SSH ключ!"
echo "Как получить ключ:"
echo "  Termius: Settings → Keys → New Key → скопируй Public Key"
echo "  PuTTYgen: Generate → скопируй всё из поля 'Public key'"
echo ""

# Запрашиваем публичный ключ
read -p "Вставь публичный ключ (ssh-ed25519 или ssh-rsa ...): " SSH_KEY

# Проверяем что ключ начинается правильно
if [[ ! "$SSH_KEY" =~ ^ssh-(ed25519|rsa|ecdsa) ]]; then
    err "Неверный формат ключа! Должен начинаться с ssh-ed25519 или ssh-rsa"
    exit 1
fi

# Запрашиваем новый порт SSH
echo ""
echo "Текущий порт SSH: $CURRENT_PORT"
warn "Выбери порт от 1024 до 65535 (нестандартный — безопаснее)"
read -p "Новый порт SSH (Enter = оставить $CURRENT_PORT): " NEW_PORT

# Если ничего не ввели — оставляем текущий
NEW_PORT=${NEW_PORT:-$CURRENT_PORT}

# Проверяем что порт это число в допустимом диапазоне
# =~ = проверка регулярным выражением
# ^[0-9]+$ = только цифры
if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || \
   [ "$NEW_PORT" -lt 1024 ] || \
   [ "$NEW_PORT" -gt 65535 ]; then
    err "Неверный порт! Нужно число от 1024 до 65535"
    exit 1
fi

# Итоговое подтверждение — показываем что будет сделано
echo ""
step "Проверь настройки перед запуском"
echo "  Пользователь:  $USERNAME"
echo "  Порт SSH:      $NEW_PORT"
echo "  SSH ключ:      ${SSH_KEY:0:40}..." # показываем первые 40 символов
echo ""
read -p "Всё верно? Начать настройку? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    warn "Отменено пользователем"
    exit 0
fi

# ─── ШАГ 2: ОБНОВЛЕНИЕ СИСТЕМЫ ────────────────────────────
step "Обновление системы"

# DEBIAN_FRONTEND=noninteractive = не задавать вопросов при установке
# apt update = обновить список доступных пакетов
# apt upgrade -y = установить все обновления (-y = yes на все вопросы)
export DEBIAN_FRONTEND=noninteractive
apt update -q && apt upgrade -y -q
ok "Система обновлена"

# ─── ШАГ 3: УСТАНОВКА ПРОГРАММ ────────────────────────────
step "Установка необходимых программ"

# Список программ:
# curl, wget  = скачивание файлов
# git         = система контроля версий
# ufw         = файрвол (uncomplicated firewall)
# fail2ban    = защита от брутфорса
# htop        = мониторинг процессов
# nano        = текстовый редактор
# net-tools   = сетевые утилиты (netstat и др.)
apt install -y curl wget git ufw fail2ban htop nano net-tools
ok "Программы установлены"

# ─── ШАГ 4: СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ ─────────────────────────
step "Создание пользователя $USERNAME"

if [ "$USER_EXISTS" = false ]; then
    # useradd -m = создать домашнюю папку (-m = make home)
    # -s /bin/bash = установить bash как оболочку по умолчанию
    useradd -m -s /bin/bash "$USERNAME"

    # chpasswd = изменить пароль (читает из stdin формат user:pass)
    echo "$USERNAME:$PASSWORD1" | chpasswd
    ok "Пользователь $USERNAME создан"
fi

# usermod -aG sudo = добавить в группу sudo
# -a = append (добавить, не заменить)
# -G = Group (группа)
usermod -aG sudo "$USERNAME"

# Даём права sudo без пароля для автоматизации
# >> = дописать в конец файла (не перезаписать)
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" \
    >> /etc/sudoers.d/90-cloud-init-users

ok "Права sudo выданы"

# ─── ШАГ 5: НАСТРОЙКА SSH КЛЮЧА ───────────────────────────
step "Настройка SSH ключа для $USERNAME"

# mkdir -p = создать папку (и все родительские если нужно)
# -p = parents = не ругаться если уже существует
mkdir -p "/home/$USERNAME/.ssh"

# Записываем ключ в authorized_keys
# > = перезаписать файл (было бы >> = дописать)
echo "$SSH_KEY" > "/home/$USERNAME/.ssh/authorized_keys"

# chown -R = сменить владельца рекурсивно
# username:username = пользователь:группа
# -R = recursive = включая все вложенные файлы
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"

# chmod 700 = только владелец может читать/писать/заходить в папку
# chmod 600 = только владелец может читать/писать файл
# SSH требует именно такие права — иначе откажет!
chmod 700 "/home/$USERNAME/.ssh"
chmod 600 "/home/$USERNAME/.ssh/authorized_keys"

ok "SSH ключ настроен"

# ─── ШАГ 6: НАСТРОЙКА SSH ─────────────────────────────────
step "Настройка безопасности SSH"

# Делаем резервную копию оригинального конфига
# cp = copy, .bak = backup (соглашение об именовании)
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
ok "Резервная копия sshd_config создана"

# sed -i = редактировать файл на месте (i = in-place)
# 's/СТАРОЕ/НОВОЕ/' = заменить СТАРОЕ на НОВОЕ
# Меняем порт SSH
sed -i "s/^#*Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config

# Запрещаем вход под root
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' \
    /etc/ssh/sshd_config

# Запрещаем вход по паролю (только по ключу)
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' \
    /etc/ssh/sshd_config

# Перезапускаем SSH чтобы применить настройки
# systemctl = управление сервисами системы
systemctl restart ssh
ok "SSH настроен: порт $NEW_PORT, только ключи, без root"

# ─── ШАГ 7: НАСТРОЙКА UFW (ФАЙРВОЛ) ──────────────────────
step "Настройка файрвола UFW"

# Политика по умолчанию: запретить всё входящее
# Профи начинают с "запретить всё" → потом открывают нужное
ufw default deny incoming
ufw default allow outgoing

# Открываем только наш новый порт SSH
# Синтаксис: ufw allow ПОРТ/ПРОТОКОЛ
ufw allow "$NEW_PORT/tcp"

# Открываем порты для веб-сервера (нужны для Cloudflare)
ufw allow 80/tcp   # HTTP
ufw allow 443/tcp  # HTTPS

# --force = не спрашивать подтверждение
ufw --force enable
ok "UFW включён: открыты порты $NEW_PORT, 80, 443"

# ─── ШАГ 8: НАСТРОЙКА FAIL2BAN ────────────────────────────
step "Настройка fail2ban"

# Создаём конфиг (jail.local переопределяет jail.conf)
# Профи никогда не редактируют .conf — только .local
# Потому что .conf перезаписывается при обновлении!
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
# bantime = время блокировки (10m = 10 минут)
bantime  = 10m
# findtime = окно поиска попыток
findtime = 10m
# maxretry = максимум попыток перед баном
maxretry = 5

[sshd]
enabled  = true
port     = PORT_PLACEHOLDER
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
EOF

# Подставляем наш порт в конфиг
sed -i "s/PORT_PLACEHOLDER/$NEW_PORT/" /etc/fail2ban/jail.local

# Перезапускаем fail2ban
systemctl enable fail2ban
systemctl restart fail2ban
ok "fail2ban настроен"

# ─── ФИНАЛ ────────────────────────────────────────────────
step "Настройка завершена!"

# Получаем IP сервера
SERVER_IP=$(curl -s https://ifconfig.me)

echo ""
ok "Все шаги выполнены успешно!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Подключение к серверу:"
echo "  ssh -p $NEW_PORT $USERNAME@$SERVER_IP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
warn "ВАЖНО: НЕ ЗАКРЫВАЙ эту сессию!"
warn "Сначала открой НОВОЕ окно и проверь подключение:"
echo "  ssh -p $NEW_PORT $USERNAME@$SERVER_IP"
warn "Только после успешного входа закрывай это окно!"
