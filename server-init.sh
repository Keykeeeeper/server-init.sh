#!/bin/bash
# ══════════════════════════════════════════════════════════
# server-init.sh — первичная настройка Ubuntu сервера
# Идемпотентный: можно запускать много раз — не сломает
# Запуск: sudo bash server-init.sh
# ══════════════════════════════════════════════════════════

# ─── ЦВЕТА ────────────────────────────────────────────────
GREEN='\033[1;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
step() { echo -e "\n${BLUE}══ $1 ══${NC}"; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

# ─── ПРОВЕРКА ROOT ────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    err "Запусти от root: sudo bash server-init.sh"
    exit 1
fi

# ══════════════════════════════════════════════════════════
# БЛОК 1: ДИАГНОСТИКА СИСТЕМЫ
# ══════════════════════════════════════════════════════════
step "Диагностика системы"

EXISTING_USERS=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1}' /etc/passwd)
USER_COUNT=$(echo "$EXISTING_USERS" | grep -c . 2>/dev/null || echo 0)

info "Пользователей в системе: $USER_COUNT"

# ─── ФУНКЦИЯ: полная проверка настройки пользователя ──────
check_user_setup() {
    local USER=$1
    local STATUS=0

    if [ -f "/home/$USER/.ssh/authorized_keys" ] && \
       [ -s "/home/$USER/.ssh/authorized_keys" ]; then
        ok "  $USER: SSH ключ настроен"
    else
        warn "  $USER: SSH ключ НЕ настроен"
        STATUS=1
    fi

    if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config; then
        ok "  SSH: вход по паролю отключён"
    else
        warn "  SSH: вход по паролю ещё разрешён"
        STATUS=1
    fi

    if grep -q "^PermitRootLogin no" /etc/ssh/sshd_config; then
        ok "  SSH: вход под root отключён"
    else
        warn "  SSH: вход под root ещё разрешён"
        STATUS=1
    fi

    return $STATUS
}

# ─── ЛОГИКА: что делать с пользователями ──────────────────
SETUP_NEW_USER=false
SELECTED_USER=""
UPDATE_KEYS=false

if [ "$USER_COUNT" -gt 0 ]; then
    warn "Найдены существующие пользователи:"
    echo ""

    for USER in $EXISTING_USERS; do
        if groups "$USER" 2>/dev/null | grep -q sudo; then
            echo -e "  ${CYAN}→ $USER${NC} (sudo)"
        else
            echo -e "  → $USER (без sudo)"
        fi
    done

    echo ""
    echo "Что хочешь сделать?"
    echo "  1) Проверить и дополнить настройку существующего пользователя"
    echo "  2) Создать нового пользователя"
    echo "  3) Обновить SSH ключ существующего пользователя"
    echo ""
    read -p "Выбери (1/2/3): " USER_ACTION

    case $USER_ACTION in
        1)
            echo ""
            read -p "Имя пользователя для проверки: " SELECTED_USER

            if ! id "$SELECTED_USER" &>/dev/null; then
                err "Пользователь $SELECTED_USER не найден!"
                exit 1
            fi

            echo ""
            step "Проверка настройки пользователя $SELECTED_USER"
            check_user_setup "$SELECTED_USER"
            CHECK_STATUS=$?

            if [ $CHECK_STATUS -eq 0 ]; then
                ok "Пользователь $SELECTED_USER полностью настроен!"
                info "Пропускаем создание пользователя..."
                SETUP_NEW_USER=false
            else
                warn "Некоторые настройки отсутствуют — исправим"
                SETUP_NEW_USER=false
                UPDATE_KEYS=true
            fi
            ;;
        2)
            SETUP_NEW_USER=true
            ;;
        3)
            read -p "Имя пользователя для обновления ключа: " SELECTED_USER
            if ! id "$SELECTED_USER" &>/dev/null; then
                err "Пользователь $SELECTED_USER не найден!"
                exit 1
            fi
            UPDATE_KEYS=true
            SETUP_NEW_USER=false
            ;;
        *)
            err "Неверный выбор"
            exit 1
            ;;
    esac
else
    info "Существующих пользователей нет — создадим нового"
    SETUP_NEW_USER=true
fi

# ══════════════════════════════════════════════════════════
# БЛОК 2: СБОР ДАННЫХ
# ══════════════════════════════════════════════════════════
if [ "$SETUP_NEW_USER" = true ] || [ "$UPDATE_KEYS" = true ]; then
    step "Настройка пользователя"

    if [ "$SETUP_NEW_USER" = true ]; then
        read -p "Имя нового пользователя: " SELECTED_USER

        if [ -z "$SELECTED_USER" ]; then
            err "Имя не может быть пустым!"
            exit 1
        fi

        if id "$SELECTED_USER" &>/dev/null; then
            err "Пользователь $SELECTED_USER уже существует!"
            exit 1
        fi

        read -s -p "Пароль для $SELECTED_USER: " PASSWORD1
        echo
        read -s -p "Повтори пароль: " PASSWORD2
        echo

        if [ "$PASSWORD1" != "$PASSWORD2" ]; then
            err "Пароли не совпадают!"
            exit 1
        fi
    fi

    echo ""
    warn "Нужен публичный SSH ключ!"
    echo "  Termius: Settings → Keys → New Key → Public Key"
    echo "  PuTTYgen: Generate → скопируй верхнее поле"
    echo ""
    read -p "Вставь публичный ключ: " SSH_KEY

    if [[ ! "$SSH_KEY" =~ ^ssh-(ed25519|rsa|ecdsa) ]]; then
        err "Неверный формат! Должен начинаться с ssh-ed25519 или ssh-rsa"
        exit 1
    fi
fi

# ─── Порт SSH ─────────────────────────────────────────────
CURRENT_PORT=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}')
CURRENT_PORT=${CURRENT_PORT:-22}

echo ""
info "Текущий порт SSH: $CURRENT_PORT"
read -p "Новый порт SSH (Enter = оставить $CURRENT_PORT): " NEW_PORT
NEW_PORT=${NEW_PORT:-$CURRENT_PORT}

if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || \
   [ "$NEW_PORT" -lt 1024 ] || \
   [ "$NEW_PORT" -gt 65535 ]; then
    err "Неверный порт! Нужно число от 1024 до 65535"
    exit 1
fi

# ─── Подтверждение ────────────────────────────────────────
echo ""
step "Итоговый план действий"
[ "$SETUP_NEW_USER" = true ] && info "Создать пользователя:    $SELECTED_USER"
[ "$UPDATE_KEYS"    = true ] && info "Обновить ключ для:       $SELECTED_USER"
info "Порт SSH:                $NEW_PORT"
info "Установить/проверить:    все необходимые программы"
echo ""
read -p "Начать? (yes/no): " CONFIRM
[ "$CONFIRM" != "yes" ] && { warn "Отменено"; exit 0; }

# ══════════════════════════════════════════════════════════
# БЛОК 3: ОБНОВЛЕНИЕ СИСТЕМЫ
# ══════════════════════════════════════════════════════════
step "Обновление системы"
export DEBIAN_FRONTEND=noninteractive
apt update -q && apt upgrade -y -q
ok "Система обновлена"

# ══════════════════════════════════════════════════════════
# БЛОК 4: УСТАНОВКА ПРОГРАММ
# ══════════════════════════════════════════════════════════
step "Проверка и установка программ"

# Функция: проверяет установлен ли пакет
# Если нет — устанавливает. Если да — пропускает.
check_and_install() {
    local PKG=$1
    local NAME=$2

    # dpkg -l = список пакетов, ^ii = установлен
    if dpkg -l "$PKG" 2>/dev/null | grep -q "^ii"; then
        ok "$NAME уже установлен — пропускаем"
    else
        info "Устанавливаем $NAME..."
        apt install -y -q "$PKG"
        ok "$NAME установлен"
    fi
}

check_and_install "curl"      "curl (скачивание файлов)"
check_and_install "wget"      "wget (скачивание файлов)"
check_and_install "git"       "git (контроль версий)"
check_and_install "ufw"       "ufw (файрвол)"
check_and_install "fail2ban"  "fail2ban (защита SSH)"
check_and_install "htop"      "htop (мониторинг)"
check_and_install "nano"      "nano (редактор)"
check_and_install "net-tools" "net-tools (сетевые утилиты)"

# ══════════════════════════════════════════════════════════
# БЛОК 5: СОЗДАНИЕ / ОБНОВЛЕНИЕ ПОЛЬЗОВАТЕЛЯ
# ══════════════════════════════════════════════════════════
if [ "$SETUP_NEW_USER" = true ]; then
    step "Создание пользователя $SELECTED_USER"
    useradd -m -s /bin/bash "$SELECTED_USER"
    echo "$SELECTED_USER:$PASSWORD1" | chpasswd
    usermod -aG sudo "$SELECTED_USER"
    echo "$SELECTED_USER ALL=(ALL) NOPASSWD:ALL" \
        >> /etc/sudoers.d/90-cloud-init-users
    ok "Пользователь создан"
fi

if [ "$SETUP_NEW_USER" = true ] || [ "$UPDATE_KEYS" = true ]; then
    step "Настройка SSH ключа для $SELECTED_USER"
    mkdir -p "/home/$SELECTED_USER/.ssh"
    echo "$SSH_KEY" > "/home/$SELECTED_USER/.ssh/authorized_keys"
    chown -R "$SELECTED_USER:$SELECTED_USER" \
        "/home/$SELECTED_USER/.ssh"
    chmod 700 "/home/$SELECTED_USER/.ssh"
    chmod 600 "/home/$SELECTED_USER/.ssh/authorized_keys"
    ok "SSH ключ настроен"
fi

# ══════════════════════════════════════════════════════════
# БЛОК 6: НАСТРОЙКА SSH
# ══════════════════════════════════════════════════════════
step "Проверка и настройка SSH"

# Резервная копия — только если ещё не делали
[ ! -f /etc/ssh/sshd_config.bak ] && \
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak && \
    ok "Резервная копия sshd_config создана"

SSH_CHANGED=false

ACTUAL_PORT=$(grep "^Port " /etc/ssh/sshd_config | awk '{print $2}')
ACTUAL_PORT=${ACTUAL_PORT:-22}

if [ "$ACTUAL_PORT" != "$NEW_PORT" ]; then
    sed -i "s/^#*Port .*/Port $NEW_PORT/" /etc/ssh/sshd_config
    ok "Порт SSH изменён: $ACTUAL_PORT → $NEW_PORT"
    SSH_CHANGED=true
else
    ok "Порт SSH уже $NEW_PORT — пропускаем"
fi

if grep -q "^PermitRootLogin no" /etc/ssh/sshd_config; then
    ok "Root логин уже отключён — пропускаем"
else
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' \
        /etc/ssh/sshd_config
    ok "Root логин отключён"
    SSH_CHANGED=true
fi

if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config; then
    ok "Вход по паролю уже отключён — пропускаем"
else
    sed -i \
        's/^#*PasswordAuthentication.*/PasswordAuthentication no/' \
        /etc/ssh/sshd_config
    ok "Вход по паролю отключён"
    SSH_CHANGED=true
fi

if [ "$SSH_CHANGED" = true ]; then
    systemctl restart ssh
    ok "SSH перезапущен с новыми настройками"
else
    ok "SSH уже настроен правильно — перезапуск не нужен"
fi

# ══════════════════════════════════════════════════════════
# БЛОК 7: UFW
# ══════════════════════════════════════════════════════════
step "Проверка и настройка UFW"

if ufw status | grep -q "Status: active"; then
    ok "UFW уже активен"

    if ! ufw status | grep -q "$NEW_PORT/tcp"; then
        ufw allow "$NEW_PORT/tcp"
        ok "Добавлено правило: порт $NEW_PORT"
    else
        ok "Порт $NEW_PORT уже открыт — пропускаем"
    fi

    if ! ufw status | grep -q "80/tcp"; then
        ufw allow 80/tcp
        ok "Добавлен порт 80"
    else
        ok "Порт 80 уже открыт — пропускаем"
    fi

    if ! ufw status | grep -q "443/tcp"; then
        ufw allow 443/tcp
        ok "Добавлен порт 443"
    else
        ok "Порт 443 уже открыт — пропускаем"
    fi
else
    info "Настраиваем UFW с нуля..."
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$NEW_PORT/tcp"
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
    ok "UFW настроен и включён"
fi

# ══════════════════════════════════════════════════════════
# БЛОК 8: FAIL2BAN
# ══════════════════════════════════════════════════════════
step "Проверка и настройка fail2ban"

if [ -f /etc/fail2ban/jail.local ]; then
    if grep -q "port.*=.*$NEW_PORT" /etc/fail2ban/jail.local; then
        ok "fail2ban уже настроен с портом $NEW_PORT — пропускаем"
    else
        warn "fail2ban настроен с другим портом — обновляем"
        sed -i "s/^port.*/port     = $NEW_PORT/" \
            /etc/fail2ban/jail.local
        systemctl restart fail2ban
        ok "fail2ban обновлён"
    fi
else
    info "Создаём конфиг fail2ban..."
    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 10m
findtime = 10m
maxretry = 5

[sshd]
enabled  = true
port     = $NEW_PORT
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
EOF
    systemctl enable fail2ban
    systemctl restart fail2ban
    ok "fail2ban настроен"
fi

# ══════════════════════════════════════════════════════════
# ФИНАЛ
# ══════════════════════════════════════════════════════════
SERVER_IP=$(curl -s https://ifconfig.me)

echo ""
echo -e "${GREEN}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ Настройка завершена!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${NC}"
echo "  Подключение к серверу:"
echo "  ssh -p $NEW_PORT $SELECTED_USER@$SERVER_IP"
echo ""
echo -e "${YELLOW}  ⚠ НЕ ЗАКРЫВАЙ это окно!"
echo "  Открой НОВОЕ окно Termius и проверь вход."
echo "  Только после успешного входа закрывай это!${NC}"
echo ""
