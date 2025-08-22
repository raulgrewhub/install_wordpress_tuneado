#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] 00_quickwrap.sh falló en la línea $LINENO"; exit 1' ERR

# Pregunta mínima para un wrap rápido
read -rp "Dominio principal (ej. ejemplo.com): " DOMAIN
[[ -z "$DOMAIN" ]] && { echo "Dominio requerido"; exit 2; }
read -rp "Email admin: " ADMIN_EMAIL
[[ -z "$ADMIN_EMAIL" ]] && { echo "Email requerido"; exit 2; }
read -rsp "Contraseña DB: " DB_PASS; echo
read -rsp "Contraseña WP admin: " WP_ADMIN_PASS; echo

DB_NAME="wp_$(echo "$DOMAIN" | tr '.-' '_' | tr '[:upper:]' '[:lower:]')"
DB_USER="$(echo "$DB_NAME" | cut -c1-16)"
WP_ADMIN_USER="wpadmin"
WP_ADMIN_EMAIL="admin@${DOMAIN}"

TMP_ENV="/tmp/wp_${DOMAIN}.env"
cat >"$TMP_ENV" <<EOF_ENV
DOMAIN="${DOMAIN}"
WWW_ALIAS="www.${DOMAIN}"
ADMIN_EMAIL="${ADMIN_EMAIL}"
TZ="Europe/Madrid"

DB_NAME="${DB_NAME}"
DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"

WP_TITLE="Sitio ${DOMAIN}"
WP_ADMIN_USER="${WP_ADMIN_USER}"
WP_ADMIN_PASS="${WP_ADMIN_PASS}"
WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL}"
WP_LOCALE="es_ES"

HARDEN_SSH="false"
HSTS_PRELOAD="false"
ENABLE_RATE_LIMIT="true"
RATE_LIMIT_RPM="10"
BLOCK_XMLRPC="true"
PHP_PM_MAX_CHILDREN="10"
WP_DISALLOW_FILE_MODS="false"
MOVE_WP_CONFIG="false"
ENABLE_FAIL2BAN="true"
CERT_KEY_TYPE="rsa"
EOF_ENV
chmod 600 "$TMP_ENV"
export WP_ENV_FILE="$TMP_ENV"

echo
printf "[OK] Env temporal creado: %s\n" "$TMP_ENV"
echo "export WP_ENV_FILE=$TMP_ENV"
echo "Ahora ejecuta:"
echo "  bash 01_sistema.sh"
echo "  bash 02_lemp.sh"
echo "  bash 03_wordpress_https.sh"
echo "  bash 04_nginx_tls_rate.sh"
echo "  bash 05_php_fpm_hardening.sh"
echo "  bash 06_wp_fail2ban_wpverify.sh"
echo "  bash 07_verificacion.sh"
echo
echo "Al terminar, puedes eliminar el env con: shred -u $TMP_ENV"
