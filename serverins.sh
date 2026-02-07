#!/bin/bash

# Скрипт для преобразования Ubuntu Desktop 22.04 LTS в сервер для Home Assistant
# Создано для автоматической установки и настройки

set -e

echo "=========================================="
echo " Начинаем преобразование в сервер"
echo "=========================================="

# Обновление системы
echo "Обновление пакетов системы..."
sudo apt update && sudo apt upgrade -y

# Установка необходимых пакетов
echo "Установка необходимых пакетов..."
sudo apt install -y \
    curl \
    wget \
    git \
    net-tools \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    build-essential \
    libssl-dev \
    libffi-dev \
    libudev-dev \
    autoconf \
    automake \
    libtool \
    libusb-1.0-0-dev \
    jq \
    avahi-daemon \
    dbus \
    bluez \
    bluez-tools \
    network-manager

# Установка Docker
echo "Установка Docker..."
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
rm get-docker.sh

# Добавление текущего пользователя в группу docker
sudo usermod -aG docker $USER

# Установка Docker Compose
echo "Установка Docker Compose..."
DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep tag_name | cut -d '"' -f 4)
sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

# Установка SSH сервера (если не установлен)
echo "Установка и настройка SSH..."
sudo apt install -y openssh-server
sudo systemctl enable ssh
sudo systemctl start ssh

# Создание пользователя для сервисов (опционально)
echo "Создание пользователя homeassistant..."
sudo useradd -rm homeassistant -G docker

# Установка Mosquitto MQTT брокера
echo "Установка Mosquitto MQTT брокера..."
sudo apt install -y mosquitto mosquitto-clients

# Включение и запуск Mosquitto
sudo systemctl enable mosquitto
sudo systemctl start mosquitto

# Создание конфигурационного файла для Mosquitto
echo "Настройка Mosquitto..."
sudo tee /etc/mosquitto/conf.d/default.conf > /dev/null << EOF
listener 1883
allow_anonymous true

listener 9001
protocol websockets

log_type all
connection_messages true
log_timestamp true
EOF

# Перезапуск Mosquitto с новой конфигурацией
sudo systemctl restart mosquitto

# Создание структуры каталогов для Home Assistant
echo "Создание структуры каталогов..."
sudo mkdir -p /opt/homeassistant
sudo mkdir -p /opt/nodered
sudo mkdir -p /opt/zigbee2mqtt
sudo mkdir -p /opt/esphome
sudo mkdir -p /opt/fileeditor

# Настройка прав доступа
sudo chown -R $USER:$USER /opt/homeassistant
sudo chown -R $USER:$USER /opt/nodered
sudo chown -R $USER:$USER /opt/zigbee2mqtt
sudo chown -R $USER:$USER /opt/esphome
sudo chown -R $USER:$USER /opt/fileeditor

# Создание docker-compose.yml для всех сервисов
echo "Создание docker-compose.yml..."
cat > /opt/docker-compose.yml << 'EOF'
version: '3.8'

services:
  homeassistant:
    container_name: homeassistant
    image: "ghcr.io/home-assistant/home-assistant:stable"
    volumes:
      - /opt/homeassistant:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:ro
    restart: unless-stopped
    privileged: true
    network_mode: host
    environment:
      - TZ=Europe/Moscow

  nodered:
    container_name: nodered
    image: nodered/node-red:latest
    volumes:
      - /opt/nodered:/data
    restart: unless-stopped
    network_mode: host
    environment:
      - TZ=Europe/Moscow

  zigbee2mqtt:
    container_name: zigbee2mqtt
    image: koenkk/zigbee2mqtt:latest
    restart: unless-stopped
    network_mode: host
    volumes:
      - /opt/zigbee2mqtt:/app/data
      - /run/udev:/run/udev:ro
    devices:
      - /dev/ttyUSB0:/dev/ttyUSB0
      - /dev/ttyACM0:/dev/ttyACM0
    environment:
      - TZ=Europe/Moscow

  esphome:
    container_name: esphome
    image: ghcr.io/esphome/esphome:latest
    restart: unless-stopped
    network_mode: host
    volumes:
      - /opt/esphome:/config
      - /etc/localtime:/etc/localtime:ro
    privileged: true
    environment:
      - TZ=Europe/Moscow

  fileeditor:
    container_name: fileeditor
    image: filebrowser/filebrowser:latest
    restart: unless-stopped
    ports:
      - "8080:80"
    volumes:
      - /opt:/srv
      - /opt/fileeditor/filebrowser.db:/database/filebrowser.db
      - /opt/fileeditor/settings.json:/config/settings.json
    environment:
      - TZ=Europe/Moscow
EOF

# Создание конфигурации для FileBrowser
echo "Создание конфигурации FileBrowser..."
cat > /opt/fileeditor/settings.json << 'EOF'
{
  "port": 80,
  "baseURL": "",
  "address": "",
  "log": "stdout",
  "database": "/database/filebrowser.db",
  "root": "/srv"
}
EOF

# Запуск всех сервисов через Docker Compose
echo "Запуск всех сервисов..."
cd /opt
docker-compose -f docker-compose.yml up -d

# Создание скрипта управления сервисами
echo "Создание скрипта управления..."
cat > /usr/local/bin/homelab << 'EOF'
#!/bin/bash
case "$1" in
    start)
        cd /opt && docker-compose -f docker-compose.yml up -d
        ;;
    stop)
        cd /opt && docker-compose -f docker-compose.yml down
        ;;
    restart)
        cd /opt && docker-compose -f docker-compose.yml restart
        ;;
    status)
        cd /opt && docker-compose -f docker-compose.yml ps
        ;;
    logs)
        cd /opt && docker-compose -f docker-compose.yml logs -f
        ;;
    update)
        cd /opt && docker-compose -f docker-compose.yml pull
        cd /opt && docker-compose -f docker-compose.yml up -d
        ;;
    *)
        echo "Использование: $0 {start|stop|restart|status|logs|update}"
        exit 1
        ;;
esac
EOF

sudo chmod +x /usr/local/bin/homelab

# Настройка автоматического обновления Docker образов (раз в неделю)
echo "Настройка автоматического обновления..."
sudo tee /etc/cron.weekly/docker-update > /dev/null << 'EOF'
#!/bin/bash
cd /opt && docker-compose -f docker-compose.yml pull
cd /opt && docker-compose -f docker-compose.yml up -d --remove-orphans
docker system prune -af --volumes
EOF

sudo chmod +x /etc/cron.weekly/docker-update

# Отключение GUI (графического интерфейса)
echo "Отключение графического интерфейса..."
sudo systemctl set-default multi-user.target
sudo systemctl stop gdm3 2>/dev/null || sudo systemctl stop lightdm 2>/dev/null
sudo systemctl disable gdm3 2>/dev/null || sudo systemctl disable lightdm 2>/dev/null

# Отключение неиспользуемых сервисов для экономии ресурсов
echo "Оптимизация системных сервисов..."
sudo systemctl disable cups 2>/dev/null
sudo systemctl disable cups-browsed 2>/dev/null
sudo systemctl disable avahi-daemon 2>/dev/null
sudo systemctl disable bluetooth 2>/dev/null
sudo systemctl disable ModemManager 2>/dev/null

# Настройка firewall
echo "Настройка firewall..."
sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp        # SSH
sudo ufw allow 1883/tcp      # MQTT
sudo ufw allow 8123/tcp      # Home Assistant
sudo ufw allow 1880/tcp      # Node-RED
sudo ufw allow 8080/tcp      # File Editor
sudo ufw allow 80/tcp        # HTTP (если понадобится)
sudo ufw allow 443/tcp       # HTTPS (если понадобится)
sudo ufw --force enable



# Настройка прав на последовательные порты для Zigbee
echo "Настройка прав на USB устройства..."
sudo tee /etc/udev/rules.d/99-zigbee.rules > /dev/null << 'EOF'
SUBSYSTEM=="tty", ATTRS{idVendor}=="0451", ATTRS{idProduct}=="16a8", MODE="0666"
SUBSYSTEM=="tty", ATTRS{idVendor}=="0451", ATTRS{idProduct}=="16a8", SYMLINK+="zigbee"
SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6015", MODE="0666"
SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", MODE="0666"
SUBSYSTEM=="tty", ATTRS{idVendor}=="1cf1", ATTRS{idProduct}=="0030", MODE="0666"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger

# Создание README файла с инструкциями
echo "Создание документации..."
cat > /opt/README.md << 'EOF'
# Домашний сервер автоматизации

Установленные сервисы:

1. **Home Assistant** - основная платформа автоматизации
   - Доступ: http://localhost:8123
   - Конфигурация: /opt/homeassistant

2. **Node-RED** - визуальное программирование
   - Доступ: http://localhost:1880
   - Конфигурация: /opt/nodered

3. **Zigbee2MQTT** - шлюз для Zigbee устройств
   - Конфигурация: /opt/zigbee2mqtt
   - USB адаптер: /dev/ttyUSB0 или /dev/ttyACM0

4. **ESPHome** - прошивка для ESP устройств
   - Доступ: http://localhost:6052
   - Конфигурация: /opt/esphome

5. **File Editor** - веб-редактор файлов
   - Доступ: http://localhost:8080
   - Конфигурация: /opt/fileeditor

6. **Mosquitto MQTT** - MQTT брокер
   - Порт: 1883 (MQTT), 9001 (WebSocket)
   - Конфигурация: /etc/mosquitto/conf.d/default.conf


## Управление сервисами

Используйте команду: `homelab {start|stop|restart|status|logs|update}`

## SSH доступ
SSH сервер включен. Для подключения используйте:
ssh ваш_пользователь@IP_адрес_сервера

## Важные каталоги
- Все конфигурации находятся в /opt/
- Docker образы управляются через Portainer

## Следующие шаги
1. Настройте Home Assistant через веб-интерфейс
2. Настройте Zigbee2MQTT для вашего адаптера
3. Добавьте устройства в ESPHome
4. Создайте автоматизации в Node-RED
EOF

# Перезагрузка системы
echo "=========================================="
echo " Установка завершена!"
echo "=========================================="
echo ""
echo "Доступ к сервисам:"
echo "Home Assistant:  http://ваш_ip:8123"
echo "Node-RED:        http://ваш_ip:1880"
echo "File Editor:     http://ваш_ip:8080"
echo ""
echo "Для управления используйте команду: homelab"
echo ""
read -p "Перезагрузить систему сейчас? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]
then
    echo "Перезагрузка через 5 секунд..."
    sleep 5
    sudo reboot
fi
