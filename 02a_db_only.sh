#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] 02a_db_only.sh falló en la línea $LINENO"; exit 1' ERR

ENV_FILE="${WP_ENV_FILE:-${1:-}}"
if [[ -z "$ENV_FILE" || ! -f "$ENV_FILE" ]]; then
  if [[ -n "${DOMAIN:-}" && -f "/etc/wp-provision/${DOMAIN}.env" ]]; then
    ENV_FILE="/etc/wp-provision/${DOMAIN}.env"
  else
    shopt -s nullglob
    CANDIDATES=(/etc/wp-provision/*.env)
    shopt -u nullglob
    if (( ${#CANDIDATES[@]} == 1 )); then
      ENV_FILE="${CANDIDATES[0]}"
    else
      for C in "./wp.env" "$HOME/wp.env" "/root/wp.env"; do
        if [[ -f "$C" ]]; then ENV_FILE="$C"; break; fi
      done
    fi
  fi
fi
[[ -f "$ENV_FILE" ]] || { echo "Falta env. Usa WP_ENV_FILE=/ruta/env o pásalo como argumento."; exit 1; }
set -a; source "$ENV_FILE"; set +a

export DEBIAN_FRONTEND=noninteractive
systemctl enable --now mariadb

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

echo "[OK] Base de datos creada/asegurada: ${DB_NAME} (usuario ${DB_USER})."
