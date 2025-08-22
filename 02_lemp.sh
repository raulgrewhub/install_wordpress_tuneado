#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] 02_lemp.sh falló en la línea $LINENO"; exit 1' ERR

# --- Resolver ruta del env ---
ENV_FILE="${WP_ENV_FILE:-}"
if [[ -z "$ENV_FILE" || ! -f "$ENV_FILE" ]]; then
  # Buscar automáticamente un archivo env
  shopt -s nullglob
  CANDIDATES=(/etc/wp-provision/*.env)
  shopt -u nullglob
  if (( ${#CANDIDATES[@]} == 1 )); then
    ENV_FILE="${CANDIDATES[0]}"
  else
    for C in "./wp.env" "$HOME/wp.env" "/root/wp.env"; do
      if [[ -f "$C" ]]; then
        ENV_FILE="$C"
        break
      fi
    done
  fi
fi

[[ -f "$ENV_FILE" ]] || { echo "Falta archivo de variables (.env)"; exit 1; }
set -a; source "$ENV_FILE"; set +a

# Validar variables esenciales
for v in DB_NAME DB_USER DB_PASS DOMAIN ADMIN_EMAIL; do
  [[ -n "${!v:-}" ]] || { echo "[ERROR] Falta variable $v en $ENV_FILE"; exit 1; }
 done

export DEBIAN_FRONTEND=noninteractive

# Instalar LEMP
apt-get update -y
apt-get install -y nginx mariadb-server \
  php-fpm php-mysql php-cli php-curl php-xml php-mbstring php-zip php-gd php-imagick php-intl

systemctl enable --now nginx

# Detectar versión de PHP
PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
if [[ -z "$PHP_VERSION" ]]; then
  PHP_VERSION="$(ls -1 /etc/php/*/fpm/php.ini 2>/dev/null | sed -E 's#.*/php/([0-9]+\.[0-9]+)/.*#\1#' | head -n1)"
fi
systemctl enable --now "php${PHP_VERSION}-fpm"
systemctl enable --now mariadb

# Ajustes básicos de PHP-FPM
PHP_INI="/etc/php/${PHP_VERSION}/fpm/php.ini"
sed -ri 's/^;?memory_limit\s*=.*/memory_limit = 256M/' "$PHP_INI"
sed -ri 's/^;?upload_max_filesize\s*=.*/upload_max_filesize = 64M/' "$PHP_INI"
sed -ri 's/^;?post_max_size\s*=.*/post_max_size = 64M/' "$PHP_INI"
sed -ri 's/^;?max_execution_time\s*=.*/max_execution_time = 120/' "$PHP_INI"
sed -ri 's/^;?max_input_vars\s*=.*/max_input_vars = 3000/' "$PHP_INI"

systemctl restart "php${PHP_VERSION}-fpm"

# Crear base de datos y usuario con privilegios en localhost y 127.0.0.1
mysql --protocol=socket -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL

# Configurar UFW para Nginx
ufw allow 'Nginx Full' || true

echo "[OK] LEMP instalado (Nginx + PHP ${PHP_VERSION} + MariaDB) y DB '${DB_NAME}' lista para '${DB_USER}'."
