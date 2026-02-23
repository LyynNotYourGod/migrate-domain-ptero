#!/bin/bash

# ==========================================
# PTERODACTYL MIGRATOR v4.0
# Auto-detect | Zero Manual Config | Installer.se Support
# ==========================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ==========================================
# UTILS
# ==========================================
log() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[*]${NC} $1"; }

# ==========================================
# DETECT DOMAIN (MULTI-SOURCE)
# ==========================================
detect_domain() {
    local detected=""
    
    # 1. Dari .env Panel
    if [ -f /var/www/pterodactyl/.env ]; then
        detected=$(grep APP_URL /var/www/pterodactyl/.env 2>/dev/null | sed -E 's|.*https?://||g' | tr -d '/' | head -1)
        [ -n "$detected" ] && { echo "$detected"; return; }
    fi
    
    # 2. Dari Wings config
    if [ -f /etc/pterodactyl/config.yml ]; then
        detected=$(grep "remote:" /etc/pterodactyl/config.yml 2>/dev/null | sed -E 's|.*https?://||g' | awk '{print $1}')
        [ -n "$detected" ] && { echo "$detected"; return; }
    fi
    
    # 3. Dari Nginx server_name
    local nginx_conf="/etc/nginx/sites-available/pterodactyl.conf"
    if [ -f "$nginx_conf" ]; then
        detected=$(grep "server_name" "$nginx_conf" | head -1 | sed 's/.*server_name \(.*\);/\1/' | awk '{print $1}')
        [ -n "$detected" ] && { echo "$detected"; return; }
    fi
    
    # 4. Dari Database
    if [ -f /var/www/pterodactyl/.env ]; then
        cd /var/www/pterodactyl
        local db_user=$(grep DB_USERNAME .env | cut -d= -f2)
        local db_pass=$(grep DB_PASSWORD .env | cut -d= -f2)
        local db_name=$(grep DB_DATABASE .env | cut -d= -f2)
        detected=$(mysql -u"$db_user" -p"$db_pass" "$db_name" -N -e "SELECT fqdn FROM nodes WHERE fqdn IS NOT NULL LIMIT 1" 2>/dev/null || echo "")
        [ -n "$detected" ] && { echo "$detected"; return; }
    fi
    
    echo ""
}

# ==========================================
# MAIN
# ==========================================
clear
echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     PTERODACTYL DOMAIN MIGRATOR v4.0           ║${NC}"
echo -e "${BLUE}║  Auto-detect • Zero-config • Installer.se      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"
echo ""

[ "$EUID" -ne 0 ] && error "Run as root (sudo)"

# Detect old domain
info "Detecting current domain..."
OLD_DOMAIN=$(detect_domain)

if [ -z "$OLD_DOMAIN" ]; then
    warn "Cannot auto-detect domain!"
    read -p "Enter current domain: " OLD_DOMAIN
    [ -z "$OLD_DOMAIN" ] && error "Domain required!"
else
    log "Found: $OLD_DOMAIN"
fi

# Input new domain
echo ""
read -p "Enter NEW domain: " NEW_DOMAIN
[ -z "$NEW_DOMAIN" ] && error "New domain required!"

# Detect IP
SERVER_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
info "Server IP: $SERVER_IP"

echo ""
echo -e "${YELLOW}Migration:${NC} ${RED}$OLD_DOMAIN${NC} → ${GREEN}$NEW_DOMAIN${NC}"
read -p "Continue? (y/n): " confirm
[ "$confirm" != "y" ] && exit 0

# ==========================================
# STEP 1: Panel Config
# ==========================================
info "Step 1/6: Updating Panel configuration..."
cd /var/www/pterodactyl

cp .env .env.backup.$(date +%Y%m%d_%H%M%S)
sed -i "s|APP_URL=.*|APP_URL=https://$NEW_DOMAIN|g" .env

# Clear caches
php artisan config:clear >/dev/null 2>&1
php artisan cache:clear >/dev/null 2>&1
php artisan view:clear >/dev/null 2>&1

log "Panel config updated"

# ==========================================
# STEP 2: Database
# ==========================================
info "Step 2/6: Updating Database..."

DB_HOST=$(grep DB_HOST .env | cut -d= -f2)
DB_PORT=$(grep DB_PORT .env | cut -d= -f2)
DB_NAME=$(grep DB_DATABASE .env | cut -d= -f2)
DB_USER=$(grep DB_USERNAME .env | cut -d= -f2)
DB_PASS=$(grep DB_PASSWORD .env | cut -d= -f2)

mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" <<EOF 2>/dev/null
UPDATE nodes SET fqdn='$NEW_DOMAIN', scheme='https', behind_proxy=0 WHERE fqdn='$OLD_DOMAIN';
UPDATE nodes SET fqdn='$NEW_DOMAIN', scheme='https' WHERE id=1;
EOF

log "Database nodes updated"

# ==========================================
# STEP 3: Nginx
# ==========================================
info "Step 3/6: Updating Web Server..."

NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"
if [ -f "$NGINX_CONF" ]; then
    cp "$NGINX_CONF" "$NGINX_CONF.backup.$(date +%Y%m%d)"
    
    # Replace domain
    sed -i "s/$OLD_DOMAIN/$NEW_DOMAIN/g" "$NGINX_CONF"
    
    # Update SSL paths
    sed -i "s|ssl_certificate /etc/letsencrypt/live/[^/]*/fullchain.pem|ssl_certificate /etc/letsencrypt/live/$NEW_DOMAIN/fullchain.pem|g" "$NGINX_CONF"
    sed -i "s|ssl_certificate_key /etc/letsencrypt/live/[^/]*/privkey.pem|ssl_certificate_key /etc/letsencrypt/live/$NEW_DOMAIN/privkey.pem|g" "$NGINX_CONF"
    
    log "Nginx updated"
else
    warn "Nginx config not found!"
fi

# ==========================================
# STEP 4: SSL Certificate
# ==========================================
info "Step 4/6: Generating SSL Certificate..."

apt install -y certbot python3-certbot-nginx snapd >/dev/null 2>&1 || true

# Stop nginx to free port 80
systemctl stop nginx

# Get cert
if certbot certonly --standalone -d "$NEW_DOMAIN" --agree-tos --non-interactive --email admin@$NEW_DOMAIN >/dev/null 2>&1; then
    log "SSL certificate obtained"
else
    systemctl start nginx
    error "SSL failed! Check DNS A record: $NEW_DOMAIN → $SERVER_IP"
fi

systemctl start nginx

# ==========================================
# STEP 5: Wings (FULL RESET)
# ==========================================
info "Step 5/6: Rebuilding Wings..."

# Stop and clear
systemctl stop wings
rm -rf /var/lib/pterodactyl/certificates/*
rm -rf /root/.local/share/pterodactyl/*
rm -rf /tmp/pterodactyl/*

# Backup old config
if [ -f /etc/pterodactyl/config.yml ]; then
    cp /etc/pterodactyl/config.yml /etc/pterodactyl/config.yml.bak.$(date +%Y%m%d)
fi

# Generate new wings config
cd /var/www/pterodactyl
php artisan p:node:reconfigure --node=1 > /tmp/wings_reconfig.txt 2>&1

# Extract and run configure command
CONFIGURE_CMD=$(grep -o "./wings configure.*" /tmp/wings_reconfig.txt | head -1)

if [ -n "$CONFIGURE_CMD" ]; then
    cd /usr/local/bin || cd /etc/pterodactyl
    eval "$CONFIGURE_CMD" 2>/dev/null || {
        warn "Auto-configure failed, attempting manual..."
        wings configure --panel-url "https://$NEW_DOMAIN" --token "$(cd /var/www/pterodactyl && php artisan tinker --execute="echo app('encrypter')->encryptString('1');" 2>/dev/null || echo "manual-setup-required")" --node 1 2>/dev/null || true
    }
else
    warn "Could not extract configure command"
fi

# Ensure SSL paths correct in config
if [ -f /etc/pterodactyl/config.yml ]; then
    sed -i "s|/etc/letsencrypt/live/[^/]*/fullchain.pem|/etc/letsencrypt/live/$NEW_DOMAIN/fullchain.pem|g" /etc/pterodactyl/config.yml
    sed -i "s|/etc/letsencrypt/live/[^/]*/privkey.pem|/etc/letsencrypt/live/$NEW_DOMAIN/privkey.pem|g" /etc/pterodactyl/config.yml
fi

log "Wings rebuilt"

# ==========================================
# STEP 6: Restart Everything
# ==========================================
info "Step 6/6: Finalizing..."

# Test nginx
nginx -t && systemctl reload nginx || systemctl restart nginx

# Restart PHP-FPM (detect version)
PHP_FPM=$(systemctl list-units --type=service | grep -oP 'php[0-9.]+-fpm' | head -1)
[ -n "$PHP_FPM" ] && systemctl restart "$PHP_FPM"

# Restart wings
systemctl restart wings

# Clear queues
cd /var/www/pterodactyl
php artisan queue:restart >/dev/null 2>&1 || true
php artisan up >/dev/null 2>&1 || true

log "All services restarted"

# ==========================================
# DONE
# ==========================================
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        MIGRATION COMPLETE!                     ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "🌐 Panel URL: ${CYAN}https://$NEW_DOMAIN${NC}"
echo -e "🖥️  Wings:     ${CYAN}Reconfigured${NC}"
echo ""

# Status check
sleep 2
if systemctl is-active --quiet wings; then
    echo -e "✅ Wings Status: ${GREEN}Running${NC}"
    echo -e "⏳ Wait 2-5 minutes for 'Heartbeat' to turn green in Panel"
else
    echo -e "⚠️  Wings Status: ${RED}Check needed${NC}"
    echo -e "   Debug: ${YELLOW}journalctl -u wings -n 20${NC}"
fi

echo ""
echo -e "${YELLOW}Note:${NC} If Wings stays red, go to Admin → Nodes → Configuration"
echo -e "      and click 'Reset Daemon Token', then run this script again."
