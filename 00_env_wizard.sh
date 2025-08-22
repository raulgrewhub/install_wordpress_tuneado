#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] 00_env_wizard.sh falló en la línea $LINENO"; exit 1' ERR

# Crea /etc/wp-provision si no existe
install -d -m 700 /etc/wp-provision

# Generador de contraseñas portable
rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 22; echo; }

read -rp "Dominio principal (ej. ejemplo.com): " DOMAIN
[[ -z "$DOMAIN" ]] && { echo "Dominio requerido"; exit 2; }
if ! [[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then echo "Formato de dominio no válido"; exit 2; fi

DEFAULT_WWW="www.${DOMAIN}"
read -rp "Alias WWW (ENTER para ${DEFAULT_WWW}, o vacío para ninguno): " WWW_ALIAS
[[ -z "${WWW_ALIAS}" ]] && WWW_ALIAS="${DEFAULT_WWW}"

read -rp "Email admin (Certbot/alerts): " ADMIN_EMAIL
[[ -z "$ADMIN_EMAIL" ]] && { echo "Email requerido"; exit 2; }

read -rp "Zona horaria [Europe/Madrid]: " TZ
TZ="${TZ:-Europe/Madrid}"

# DB defaults derivan del dominio
DB_NAME="wp_$(echo "$DOMAIN" | tr '.-' '_' | tr '[:upper:]' '[:lower:]')"
DB_USER="$(echo "$DB_NAME" | cut -c1-16)"
DB_PASS="$(rand)"

read -rp "WP admin user [wpadmin]: " WP_ADMIN_USER
WP_ADMIN_USER="${WP_ADMIN_USER:-wpadmin}"
WP_ADMIN_PASS="$(rand)"
read -rp "WP admin email [admin@${DOMAIN}]: " WP_ADMIN_EMAIL
WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-admin@${DOMAIN}}"

read -rp "Título del sitio [Sitio WordPress]: " WP_TITLE
WP_TITLE="${WP_TITLE:-Sitio WordPress}"
read -rp "Locale WP [es_ES]: " WP_LOCALE
WP_LOCALE="${WP_LOCALE:-es_ES}"

read -rp "¿Bloquear xmlrpc.php? [S/n]: " A; A=${A:-S}; BLOCK_XMLRPC="$([[ "$A" =~ ^[Nn]$ ]] && echo false || echo true)"
read -rp "¿HSTS con preload+includeSubDomains? [n/S]: " H; H=${H:-n}; HSTS_PRELOAD="$([[ "$H" =~ ^[Ss]$ ]] && echo true || echo false)"
read -rp "Rate-limit login (req/min) [10]: " RATE; RATE_LIMIT_RPM="${RATE:-10}"
read -rp "PHP-FPM pm.max_children [10]: " PMC; PHP_PM_MAX_CHILDREN="${PMC:-10}"
read -rp "Tipo de clave TLS (rsa|ecdsa) [rsa]: " KT; CERT_KEY_TYPE="${KT:-rsa}"

read -rp "Crear usuario sudo adicional (ENTER para omitir): " ADMIN_USER
ADMIN_SSH_PUBKEY=""
if [[ -n "$ADMIN_USER" ]]; then
  read -rp "Pega la clave SSH pública de ${ADMIN_USER} (ENTER para omitir): " ADMIN_SSH_PUBKEY
fi

ENV_OUT="/etc/wp-provision/${DOMAIN}.env"
if [[ -f "$ENV_OUT" ]]; then
  read -rp "El archivo ${ENV_OUT} ya existe. ¿Sobrescribir? [s/N]: " O; O=${O:-N}
  [[ "$O" =~ ^[sS]$ ]] || { echo "Abortado para no sobrescribir."; exit 3; }
fi

umask 077
cat >"$ENV_OUT.tmp" <<EOF_CONF
DOMAIN="${DOMAIN}"
WWW_ALIAS="${WWW_ALIAS}"
ADMIN_USER="${ADMIN_USER}"
ADMIN_SSH_PUBKEY="${ADMIN_SSH_PUBKEY}"
ADMIN_EMAIL="${ADMIN_EMAIL}"
TZ="${TZ}"

DB_NAME="${DB_NAME}"
DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"

WP_TITLE="${WP_TITLE}"
WP_ADMIN_USER="${WP_ADMIN_USER}"
WP_ADMIN_PASS="${WP_ADMIN_PASS}"
WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL}"
WP_LOCALE="${WP_LOCALE}"

HARDEN_SSH="false"
HSTS_PRELOAD="${HSTS_PRELOAD}"
ENABLE_RATE_LIMIT="true"
RATE_LIMIT_RPM="${RATE_LIMIT_RPM}"
BLOCK_XMLRPC="${BLOCK_XMLRPC}"
PHP_PM_MAX_CHILDREN="${PHP_PM_MAX_CHILDREN}"
WP_DISALLOW_FILE_MODS="false"
MOVE_WP_CONFIG="false"
ENABLE_FAIL2BAN="true"
CERT_KEY_TYPE="${CERT_KEY_TYPE}"
EOF_CONF
# eliminar CRLF si existieran
ttr=$(tr -d '\r' < "$ENV_OUT.tmp")
echo "$ttr" > "$ENV_OUT"
rm -f "$ENV_OUT.tmp"
chmod 600 "$ENV_OUT"

echo
echo "[OK] Env creado: $ENV_OUT"
echo "export WP_ENV_FILE=\"$ENV_OUT\""
echo
cat <<EOF_MSG
Credenciales generadas (guárdalas de forma segura):
  DB_NAME=${DB_NAME}
  DB_USER=${DB_USER}
  DB_PASS=${DB_PASS}
  WP_ADMIN_USER=${WP_ADMIN_USER}
  WP_ADMIN_PASS=${WP_ADMIN_PASS}
EOF_MSG
