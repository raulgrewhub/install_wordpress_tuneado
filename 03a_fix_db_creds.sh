#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] 03a_fix_db_creds.sh falló en la línea $LINENO"; exit 1' ERR

ENV_FILE="${1:-${WP_ENV_FILE:-}}"
[[ -f "$ENV_FILE" ]] || { echo "Uso: $0 /ruta/env"; exit 2; }
set -a; source "$ENV_FILE"; set +a

systemctl enable --now mariadb

# (Re)crear BD y grants coherentes
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

WP_ROOT="/var/www/${DOMAIN}/public"
[[ -f "$WP_ROOT/wp-config.php" ]] || { echo "No existe $WP_ROOT/wp-config.php"; exit 3; }

# Fijar DB_HOST=127.0.0.1
if grep -q "define('DB_HOST'" "$WP_ROOT/wp-config.php"; then
  sed -ri 's/(define\(\s*\'"'"'DB_HOST'"'"'\s*,\s*)\'"'"'[^'"'"']+\'"'"'(\s*\)\s*;)/\1\'"'"'127.0.0.1\'"'"'\2/' "$WP_ROOT/wp-config.php"
else
  sed -i "/DB_NAME/a define('DB_HOST', '127.0.0.1');" "$WP_ROOT/wp-config.php"
fi

mysql -h 127.0.0.1 -u"$DB_USER" -p"$DB_PASS" -e "USE \`${DB_NAME}\`; SELECT 1;" >/dev/null

echo "[OK] DB y credenciales verificados. DB_HOST fijado a 127.0.0.1 en wp-config.php"
