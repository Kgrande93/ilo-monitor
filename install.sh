#!/bin/bash
# ============================================================
# iLO Monitor - Installation script
# Run inside a fresh Debian LXC as root
# ============================================================
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
[[ $EUID -ne 0 ]] && error "Run as root"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ ! -f "$SCRIPT_DIR/config.env" ]] && error "Fill in config.env first"
info "Installing dependencies..."
apt-get update -qq
apt-get install -y -qq ipmitool curl
info "Creating directory structure..."
mkdir -p /opt/ilo-monitor /var/lib/ilo-monitor
touch /var/log/ilo-monitor.log
chmod 640 /var/log/ilo-monitor.log
info "Copying files..."
cp "$SCRIPT_DIR/ilo_monitor.sh" /opt/ilo-monitor/ilo_monitor.sh
cp "$SCRIPT_DIR/config.env"     /opt/ilo-monitor/config.env
chmod 750 /opt/ilo-monitor/ilo_monitor.sh
chmod 600 /opt/ilo-monitor/config.env
info "Setting up cron (every 5 minutes)..."
echo '*/5 * * * * root /opt/ilo-monitor/ilo_monitor.sh >> /var/log/ilo-monitor.log 2>&1' \
    > /etc/cron.d/ilo-monitor
chmod 644 /etc/cron.d/ilo-monitor
systemctl restart cron
echo ""
echo -e "${GREEN}Installation complete!${NC}"
echo ""
echo "Test that everything works:"
echo "  bash /opt/ilo-monitor/ilo_monitor.sh test"
