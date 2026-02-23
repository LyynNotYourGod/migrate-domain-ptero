#!/bin/bash

# ============================================
# Auto Migration Script: Pterodactyl → Reviactyl
# Based on: https://reviactyl.dev/docs/panel/getting-started/migrating-from-pterodactyl
# ============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PTERO_DIR="/var/www/pterodactyl"
BACKUP_DIR="/root/pterodactyl-backup-$(date +%Y%m%d-%H%M%S)"
WEBSERVER="nginx"

echo -e "${YELLOW}=== Reviactyl Migration Script ===${NC}"
echo -e "${YELLOW}Starting migration from Pterodactyl to Reviactyl...${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root${NC}"
    exit 1
fi

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    ID=$ID
else
    echo -e "${RED}Cannot detect OS${NC}"
    exit 1
fi

echo -e "${GREEN}Detected OS: $OS${NC}"

# Step 1: Backup .env file (Precaution)
echo -e "${YELLOW}[1/7] Backing up .env file...${NC}"
mkdir -p "$BACKUP_DIR"
if [ -f "$PTERO_DIR/.env" ]; then
    cp "$PTERO_DIR/.env" "$BACKUP_DIR/"
    echo -e "${GREEN}✓ .env backed up to $BACKUP_DIR/.env${NC}"
else
    echo -e "${RED}✗ Warning: .env not found in $PTERO_DIR${NC}"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Also backup database just in case
echo -e "${YELLOW}[1.5/7] Creating database backup...${NC}"
if command -v mysqldump &> /dev/null; then
    DB_NAME=$(grep DB_DATABASE "$PTERO_DIR/.env" 2>/dev/null | cut -d '=' -f2 || echo "panel")
    mysqldump -u root "$DB_NAME" > "$BACKUP_DIR/database-backup.sql" 2>/dev/null && echo -e "${GREEN}✓ Database backed up${NC}" || echo -e "${YELLOW}! Database backup skipped${NC}"
fi

# Step 2: Remove old files (Exact command from docs)
echo -e "${YELLOW}[2/7] Removing old Pterodactyl files...${NC}"
cd "$PTERO_DIR" || exit 1
rm -rf *
echo -e "${GREEN}✓ Old files removed${NC}"

# Step 3: Download and extract Reviactyl (Exact command from docs)
echo -e "${YELLOW}[3/7] Downloading Reviactyl panel...${NC}"
cd "$PTERO_DIR"
curl -Lo panel.tar.gz https://github.com/reviactyl/panel/releases/latest/download/panel.tar.gz
tar -xzvf panel.tar.gz
chmod -R 755 storage/* bootstrap/cache/
echo -e "${GREEN}✓ Reviactyl downloaded and extracted${NC}"

# Restore .env from backup
echo -e "${YELLOW}[3.5/7] Restoring .env configuration...${NC}"
cp "$BACKUP_DIR/.env" "$PTERO_DIR/"
echo -e "${GREEN}✓ .env restored${NC}"

# Step 4: Composer install (Exact command from docs)
echo -e "${YELLOW}[4/7] Running composer install...${NC}"
cd "$PTERO_DIR"
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
echo -e "${GREEN}✓ Composer dependencies installed${NC}"

# Step 5: Database migration (Exact command from docs)
echo -e "${YELLOW}[5/7] Running database migrations...${NC}"
cd "$PTERO_DIR"
php artisan migrate --seed --force
echo -e "${GREEN}✓ Database migrated${NC}"

# Step 6: Fix permissions (Exact command from docs, nginx focused)
echo -e "${YELLOW}[6/7] Setting permissions for $WEBSERVER...${NC}"
cd "$PTERO_DIR"

# Detect correct user based on OS and Web Server
if [[ "$ID" == "centos" || "$ID" == "rhel" || "$ID" == "rocky" || "$ID" == "almalinux" ]]; then
    # RHEL / Rocky Linux / AlmaLinux
    if [ "$WEBSERVER" == "nginx" ]; then
        chown -R nginx:nginx /var/www/pterodactyl/*
        echo -e "${GREEN}✓ Permissions set to nginx:nginx (RHEL-based)${NC}"
    else
        chown -R apache:apache /var/www/pterodactyl/*
        echo -e "${GREEN}✓ Permissions set to apache:apache (RHEL-based)${NC}"
    fi
else
    # Debian / Ubuntu / Others (www-data)
    chown -R www-data:www-data /var/www/pterodactyl/*
    echo -e "${GREEN}✓ Permissions set to www-data:www-data${NC}"
fi

# Step 7: Restart queue worker (Exact command from docs)
echo -e "${YELLOW}[7/7] Restarting pteroq service...${NC}"
systemctl restart pteroq.service
echo -e "${GREEN}✓ pteroq.service restarted${NC}"

# Bonus: Restart nginx to be safe
echo -e "${YELLOW}[7.5/7] Restarting nginx...${NC}"
systemctl restart nginx
echo -e "${GREEN}✓ nginx restarted${NC}"

echo ""
echo -e "${GREEN}====================================${NC}"
echo -e "${GREEN}🎉 Migration Complete!${NC}"
echo -e "${GREEN}====================================${NC}"
echo -e "${YELLOW}Backup location: $BACKUP_DIR${NC}"
echo -e "${YELLOW}Panel URL: Check your previous Pterodactyl URL${NC}"
echo ""
echo -e "${RED}Note: If you face any issues, backup is at: $BACKUP_DIR${NC}"
