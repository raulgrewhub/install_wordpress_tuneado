#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] 09_add_site.sh falló en la línea $LINENO"; exit 1' ERR

ARG="${1:-}" 
ENV_FILE=""

# 1) Si es ruta a .env, usarlo
if [[ -n "$ARG" && -f "$ARG" ]]; then
  ENV_FILE="$ARG"
else
  # 2) Si es dominio y existe su env, usarlo
  if [[ -n "$ARG" && "$ARG" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ && -f "/etc/wp-provision/${ARG}.env" ]]; then
    ENV_FILE="/etc/wp-provision/${ARG}.env"
  else
    # 3) Si WP_ENV_FILE ya está, usarlo
    if [[ -n "${WP_ENV_FILE:-}" && -f "$WP_ENV_FILE" ]]; then
      ENV_FILE="$WP_ENV_FILE"
    else
      # 4) Si hay único .env en /etc/wp-provision, usarlo
      shopt -s nullglob
      CANDIDATES=(/etc/wp-provision/*.env)
      shopt -u nullglob
      if (( ${#CANDIDATES[@]} == 1 )); then
        ENV_FILE="${CANDIDATES[0]}"
      else
        echo "Uso: $0 <dominio|/ruta/a/env>"
        echo " - Si pasas un dominio, buscaré /etc/wp-provision/<dominio>.env"
        echo " - O pasa la ruta completa a tu .env"
        exit 2
      fi
    fi
  fi
fi

# exportar y cargar
export WP_ENV_FILE="$ENV_FILE"
set -a; source "$ENV_FILE"; set +a
DOMAIN="${DOMAIN:-desconocido}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/02_lemp.sh"
bash "$SCRIPT_DIR/03_wordpress_https.sh"
bash "$SCRIPT_DIR/04_nginx_tls_rate.sh"
bash "$SCRIPT_DIR/05_php_fpm_hardening.sh"
bash "$SCRIPT_DIR/06_wp_fail2ban_wpverify.sh"
bash "$SCRIPT_DIR/07_verificacion.sh"

echo "[OK] Sitio desplegado y verificado."
