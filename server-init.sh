#!/bin/bash

# === Первоначальная настройка сервера ===
# Безопасность + Docker + базовые утилиты

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Проверка root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Запустите скрипт от root!${NC}"
    exit 1
fi

echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     Настройка сервера с нуля               ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
echo ""

# === 1. ОБНОВЛЕНИЕ СИСТЕМЫ ===
echo -e "${YELLOW}[1/7] Обновление системы...${NC}"
apt-get update -qq
apt-get upgrade -y -qq
echo -e "${GREEN}[OK]${NC}"

# === 2. УСТАНОВКА БАЗОВЫХ УТИЛИТ ===
echo -e "${YELLOW}[2/7] Установка утилит...${NC}"
apt-get install -y -qq \
    curl wget git htop nano vim \
    ufw fail2ban \
    net-tools iptables-persistent netfilter-persistent \
    qrencode ca-certificates gnupg lsb-release \
    unattended-upgrades apt-listchanges
echo -e "${GREEN}[OK]${NC}"

# === 3. НАСТРОЙКА SSH ===
echo -e "${YELLOW}[3/7] Настройка SSH...${NC}"

# Бэкап конфига
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Запрос нового SSH порта
read -p "Новый SSH порт (Enter = оставить 22): " NEW_SSH_PORT
NEW_SSH_PORT=${NEW_SSH_PORT:-22}

# Применение настроек
cat > /etc/ssh/sshd_config.d/hardening.conf << EOF
# Порт
Port $NEW_SSH_PORT

# Безопасность
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 5
ClientAliveInterval 300
ClientAliveCountMax 2

# Логирование
LogLevel VERBOSE
EOF

echo -e "${GREEN}[OK] SSH порт: $NEW_SSH_PORT${NC}"

# === 4. НАСТРОЙКА FIREWALL (UFW) ===
echo -e "${YELLOW}[4/7] Настройка Firewall...${NC}"

ufw --force reset > /dev/null
ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow $NEW_SSH_PORT/tcp comment 'SSH'

# Веб (если нужно)
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# Для MTProto прокси
ufw allow 8443/tcp comment 'MTProto alt'

# Включаем UFW
echo "y" | ufw enable > /dev/null

echo -e "${GREEN}[OK] Firewall настроен${NC}"
ufw status numbered

# === 5. НАСТРОЙКА FAIL2BAN ===
echo -e "${YELLOW}[5/7] Настройка Fail2Ban...${NC}"

cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = $NEW_SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
EOF

systemctl enable fail2ban > /dev/null 2>&1
systemctl restart fail2ban

echo -e "${GREEN}[OK] Fail2Ban активен${NC}"

# === 6. УСТАНОВКА DOCKER ===
echo -e "${YELLOW}[6/7] Установка Docker...${NC}"

if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    echo -e "${GREEN}[OK] Docker установлен${NC}"
else
    echo -e "${GREEN}[OK] Docker уже установлен${NC}"
fi

# === 7. ОПТИМИЗАЦИЯ СЕТИ ===
echo -e "${YELLOW}[7/7] Оптимизация сети (BBR)...${NC}"

cat >> /etc/sysctl.conf << 'EOF'

# === Network Optimization ===
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF

sysctl -p > /dev/null 2>&1

echo -e "${GREEN}[OK] BBR активирован${NC}"

# === ПЕРЕЗАПУСК SSHD ===
echo ""
echo -e "${YELLOW}Перезапуск SSH...${NC}"
systemctl restart sshd

# === ИТОГОВАЯ ИНФОРМАЦИЯ ===
SERVER_IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 api.ipify.org || echo "не определён")

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              СЕРВЕР НАСТРОЕН!                              ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  IP сервера:    ${CYAN}$SERVER_IP${NC}"
echo -e "  SSH порт:      ${CYAN}$NEW_SSH_PORT${NC}"
echo -e "  SSH команда:   ${YELLOW}ssh root@$SERVER_IP -p $NEW_SSH_PORT${NC}"
echo ""
echo -e "${YELLOW}Открытые порты:${NC}"
ufw status | grep -E "^\[" | head -10
echo ""
echo -e "${RED}ВАЖНО: Запомни SSH порт $NEW_SSH_PORT !${NC}"
echo -e "${RED}       Иначе потеряешь доступ к серверу!${NC}"
echo ""
echo -e "${CYAN}Следующий шаг — установить прокси скрипты:${NC}"
echo -e "  MTProto:  ${YELLOW}wget -O mtproxy.sh 'ССЫЛКА' && chmod +x mtproxy.sh && ./mtproxy.sh${NC}"
echo -e "  Каскад:   ${YELLOW}wget -O kaskad.sh 'ССЫЛКА' && chmod +x kaskad.sh && ./kaskad.sh${NC}"
echo ""
