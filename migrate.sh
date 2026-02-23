#!/bin/bash

# ==========================================
# PTERODACTYL MIGRATOR v5.0
# Support: Single Domain + Dual Domain (Panel & Wings terpisah)
# ==========================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[*]${NC} $1"; }

clear
echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  PTERODACTYL DOMAIN MIGRATOR v5.0              ║${NC}"
echo -e "${BLUE}║  Support: Single & Dual Domain Setup           ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"
echo ""

[ "$EUID" -ne 0 ] && error "Run as root (sudo)"

# ==========================================
# DETECT CURRENT DOMAINS
# ==========================================
info "Scanning current configuration..."

# Detect Panel domain (dari .env)
PANEL_OLD=""
if [ -f /var/www/pterodactyl/.env ]; then
    PANEL_OLD=$(grep APP_URL /var/www/pterodactyl/.env 2>/dev/null | sed -E 's|.*https?://||g' | tr -d '/' | head -1)
fi

# Detect Wings domain (dari config.yml atau database)
WINGS_OLD=""
if [ -f /etc/pterodactyl/config.yml ]; then
    WINGS_OLD=$(grep "remote:" /etc/pterodactyl/config.yml 2>/dev/null | sed -E 's|.*https?://||g' | awk '{print $1}')
fi

# Kalau sama, tampilin sekali aja
if [ "$PANEL_OLD" = "$WINGS_OLD" ] && [ -n "$PANEL_OLD" ]; then
    echo -e "  Current Domain (Panel + Wings): ${YELLOW}$PANEL_OLD${NC}"
    SETUP_TYPE="single"
else
    [ -n "$PANEL_OLD" ] && echo -e "  Current Panel: ${YELLOW}$PANEL_OLD${NC}"
    [ -n "$WINGS_OLD" ] && echo -e "  Current Wings: ${YELLOW}$WINGS_OLD${NC}"
    SETUP_TYPE="dual"
fi

# ==========================================
# INPUT NEW DOMAINS
# ==========================================
echo ""
echo -e "${CYAN}Select Setup Type:${NC}"
echo "1. Single Domain (Panel & Wings pakai domain sama)"
echo "2. Dual Domain (Panel & Wings domain terpisah)"
echo ""
read -p "Pilih (1/2) [default: 1]: " SETUP_CHOICE
SETUP_CHOICE=${SETUP_CHOICE:-1}

if [ "$SETUP_CHOICE" = "1" ]; then
    # SINGLE DOMAIN
    echo ""
    read -p "Enter NEW Domain (Panel + Wings): " NEW_DOMAIN
    [ -z "$NEW_DOMAIN" ] && error "Domain required!"
    
    PANEL_NEW="$NEW_DOMAIN"
    WINGS_NEW="$NEW_DOMAIN"
    
    log "Mode: Single Domain ($NEW_DOMAIN)"
else
    # DUAL DOMAIN
    echo ""
    read -p "Enter NEW Panel Domain (e.g., panel.baru.com): " PANEL_NEW
    read -p "Enter NEW Wings Domain (e.g., node1.baru.com): " WINGS_NEW
    
    [ -z "$PANEL_NEW" ] && error "Panel domain required!"
    [ -z "$WINGS_NEW" ] && error "Wings domain required!"
    
    log "Mode: Dual Domain"
    log "Panel: $PANEL_NEW"
    log "Wings: $WINGS_NEW"
fi

SERVER_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')
info "Server IP: $SERVER_IP"

echo ""
read -p "Continue? (y/n): " confirm
[ "$confirm" != "y" ] && exit 0

# ==========================================
# UPDATE PANEL (APP_URL)
# ==========================================
info "Updating Panel configuration..."
cd /var/www/pterodactyl

cp .env .env.backup.$(date +%Y%m%d_%H%M%S)
sed -i "s|APP_URL=.*|APP_URL=https://$PANEL_NEW|g" .env

php artisan config:clear >/dev/null 2>&1
php artisan cache:clear >/dev/null 2>&1
log "Panel URL updated to https://$PANEL_NEW"

# ==========================================
# UPDATE DATABASE (WINGS FQDN)
# ==========================================
info "Updating Database nodes..."

DB_HOST=$(grep DB_HOST .env | cut -d= -f2)
DB_PORT=$(grep DB_PORT .env | cut -d= -f2)
DB_NAME=$(grep DB_DATABASE .env | cut -d= -f2)
DB_USER=$(grep DB_USERNAME .env | cut -d= -f2)
DB_PASS=$(grep DB_PASSWORD .env | cut -d= -f2)

# Update FQDN di database ke Wings domain baru
mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" <<EOF 2>/dev/null
UPDATE nodes SET fqdn='$WINGS_NEW', scheme='https', behind_proxy=0 WHERE fqdn='$WINGS_OLD' OR fqdn='$PANEL_OLD';
UPDATE nodes SET fqdn='$WINGS_NEW', scheme='https' WHERE id=1;
EOF

log "Wings FQDN in database updated to $WINGS_NEW"

# ==========================================
# UPDATE NGINX (PANEL DOMAIN)
# ==========================================
info "Updating Nginx for Panel..."

NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"
if [ -f "$NGINX_CONF" ]; then
    cp "$NGINX_CONF" "$NGINX_CONF.backup.$(date +%Y%m%d)"
    
    # Replace domain lama ke Panel domain baru
    if [ "$SETUP_TYPE" = "single" ] && [ -n "$PANEL_OLD" ]; then
        sed -i "s/$PANEL_OLD/$PANEL_NEW/g" "$NGINX_CONF"
    else
        # Kalau dual domain, ganti semua domain lama ke Panel domain
        sed -i "s/server_name .*/server_name $PANEL_NEW;/g" "$NGINX_CONF"
    fi
    
    # Update SSL paths ke Panel domain
    sed -i "s|ssl_certificate /etc/letsencrypt/live/[^/]*/fullchain.pem|ssl_certificate /etc/letsencrypt/live/$PANEL_NEW/fullchain.pem|g" "$NGINX_CONF"
    sed -i "s|ssl_certificate_key /etc/letsencrypt/live/[^/]*/privkey.pem|ssl_certificate_key /etc/letsencrypt/live/$PANEL_NEW/privkey.pem|g" "$NGINX_CONF"
    
    log "Nginx config updated"
fi

# ==========================================
# SSL CERTIFICATES
# ==========================================
info "Setting up SSL Certificates..."

apt install -y certbot python3-certbot-nginx >/dev/null 2>&1 || true

# Dapatkan cert untuk Panel (selalu)
systemctl stop nginx
certbot certonly --standalone -d "$PANEL_NEW" --agree-tos --non-interactive --email admin@$PANEL_NEW >/dev/null 2>&1 && \
    log "SSL for Panel ($PANEL_NEW) obtained" || \
    warn "SSL for Panel failed (cek DNS)"

# Kalau Dual Domain, dapatkan cert untuk Wings juga
if [ "$SETUP_CHOICE" = "2" ] && [ "$WINGS_NEW" != "$PANEL_NEW" ]; then
    certbot certonly --standalone -d "$WINGS_NEW" --agree-tos --non-interactive --email admin@$WINGS_NEW >/dev/null 2>&1 && \
        log "SSL for Wings ($WINGS_NEW) obtained" || \
        warn "SSL for Wings failed (cek DNS A record: $WINGS_NEW → $SERVER_IP)"
fi

systemctl start nginx

# ==========================================
# UPDATE WINGS CONFIG
# ==========================================
info "Rebuilding Wings configuration..."

systemctl stop wings
rm -rf /var/lib/pterodactyl/certificates/*
rm -rf /root/.local/share/pterodactyl/*

# Backup
[ -f /etc/pterodactyl/config.yml ] && cp /etc/pterodactyl/config.yml /etc/pterodactyl/config.yml.bak.$(date +%Y%m%d)

# Rebuild config via Panel
php artisan p:node:reconfigure --node=1 > /tmp/wings_reconfig.txt 2>&1

# Jalankan configure command
CONFIGURE_CMD=$(grep -o "./wings configure.*" /tmp/wings_reconfig.txt | head -1)
if [ -n "$CONFIGURE_CMD" ]; then
    cd /usr/local/bin 2>/dev/null || cd /etc/pterodactyl
    eval "$CONFIGURE_CMD" 2>/dev/null || warn "Auto-configure failed"
else
    warn "Configure command not found"
fi

# Update SSL paths di config.yml Wings
if [ -f /etc/pterodactyl/config.yml ]; then
    # Remote URL ke Panel
    sed -i "s|remote: https://.*|remote: https://$PANEL_NEW|g" /etc/pterodactyl/config.yml
    
    # SSL cert ke Wings domain (kalau dual) atau Panel domain (kalau single)
    if [ "$SETUP_CHOICE" = "2" ]; then
        sed -i "s|/etc/letsencrypt/live/[^/]*/fullchain.pem|/etc/letsencrypt/live/$WINGS_NEW/fullchain.pem|g" /etc/pterodactyl/config.yml
        sed -i "s|/etc/letsencrypt/live/[^/]*/privkey.pem|/etc/letsencrypt/live/$WINGS_NEW/privkey.pem|g" /etc/pterodactyl/config.yml
    else
        sed -i "s|/etc/letsencrypt/live/[^/]*/fullchain.pem|/etc/letsencrypt/live/$PANEL_NEW/fullchain.pem|g" /etc/pterodactyl/config.yml
        sed -i "s|/etc/letsencrypt/live/[^/]*/privkey.pem|/etc/letsencrypt/live/$PANEL_NEW/privkey.pem|g" /etc/pterodactyl/config.yml
    fi
fi

log "Wings config rebuilt"

# ==========================================
# RESTART SERVICES
# ==========================================
info "Restarting services..."

nginx -t && systemctl reload nginx || systemctl restart nginx
systemctl restart php8.1-fpm 2>/dev/null || systemctl restart php8.2-fpm 2>/dev/null || true
systemctl restart wings

php artisan queue:restart >/dev/null 2>&1 || true
php artisan up >/dev/null 2>&1 || true

# ==========================================
# SUMMARY
# ==========================================
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║        MIGRATION COMPLETE!                     ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo ""

if [ "$SETUP_CHOICE" = "1" ]; then
    echo -e "🌐 Panel URL:  ${CYAN}https://$PANEL_NEW${NC}"
    echo -e "🖥️  Wings FQDN: ${CYAN}$WINGS_NEW${NC} (same as Panel)"
else
    echo -e "🌐 Panel URL:  ${CYAN}https://$PANEL_NEW${NC}"
    echo -e "🖥️  Wings FQDN: ${CYAN}$WINGS_NEW${NC} (separate domain)"
fi

echo ""
sleep 2
systemctl is-active --quiet wings && \
    echo -e "✅ Wings Status: ${GREEN}Running${NC}" || \
    echo -e "⚠️  Wings Status: ${RED}Check logs: journalctl -u wings -f${NC}"

echo ""
echo -e "${YELLOW}Note:${NC} Tunggu 2-5 menit untuk heartbeat hijau di Panel"
