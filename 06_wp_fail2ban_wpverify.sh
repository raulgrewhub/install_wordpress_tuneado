#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] 06_wp_fail2ban_wpverify.sh falló en la línea $LINENO"; exit 1' ERR

# --- Resolver ruta del env ---
ENV_FILE="${WP_ENV_FILE:-}"
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
[[ -f "$ENV_FILE" ]] || { echo "Falta archivo .env"; exit 1; }
set -a; source "$ENV_FILE"; set +a

DOMAIN="${DOMAIN:?}"
WEB_ROOT="/var/www/${DOMAIN}/public"

command -v wp >/dev/null 2>&1 || { echo "WP-CLI no encontrado"; exit 1; }

# Verificar que WordPress esté instalado
sudo -u www-data wp --path="$WEB_ROOT" core is-installed || { echo "WordPress no está instalado en $WEB_ROOT"; exit 1; }

# Establecer constantes de seguridad
sudo -u www-data wp --path="$WEB_ROOT" config set FORCE_SSL_ADMIN true --type=constant --raw
sudo -u www-data wp --path="$WEB_ROOT" config set DISALLOW_FILE_EDIT true --type=constant --raw
if [[ "${WP_DISALLOW_FILE_MODS:-false}" == "true" ]]; then
  sudo -u www-data wp --path="$WEB_ROOT" config set DISALLOW_FILE_MODS true --type=constant --raw
fi
sudo -u www-data wp --path="$WEB_ROOT" config set WP_MEMORY_LIMIT '256M' --type=constant

# Permisos
if [[ -f "$WEB_ROOT/wp-config.php" ]]; then
  chmod 640 "$WEB_ROOT/wp-config.php" || true
fi
chown -R www-data:www-data "/var/www/${DOMAIN}"

# Mover wp-config.php un nivel arriba si se desea
if [[ "${MOVE_WP_CONFIG:-false}" == "true" && -f "$WEB_ROOT/wp-config.php" ]]; then
  mv "$WEB_ROOT/wp-config.php" "/var/www/${DOMAIN}/wp-config.php"
  chmod 440 "/var/www/${DOMAIN}/wp-config.php"
fi

# Configurar Fail2ban
if [[ "${ENABLE_FAIL2BAN:-true}" == "true" ]]; then
  apt-get update -y
  apt-get install -y fail2ban
  # Filtro para limit_req
  cat > /etc/fail2ban/filter.d/nginx-limit-req.conf <<'EOF_FILTER'
[Definition]
failregex = limiting requests, .* by zone "wp_login_zone", client: <HOST>,
ignoreregex =
EOF_FILTER
  # Jails
  cat > /etc/fail2ban/jail.d/nginx-hardening.local <<'EOF_JAIL'
[nginx-http-auth]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/error.log
maxretry = 3
findtime = 10m
bantime  = 1h

[nginx-limit-req]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/error.log
maxretry = 5
findtime = 10m
bantime  = 1h
EOF_JAIL
  systemctl enable --now fail2ban
fi

# Prueba de renovación de certificados (dry-run)
if command -v certbot >/dev/null 2>&1; then
  certbot renew --dry-run || echo "[WARN] La prueba de renovación ha fallado. Revisa puertos 80/443 y DNS."
else
  echo "[WARN] certbot no está disponible en PATH."
fi

echo "[OK] WordPress endurecido; Fail2ban configurado; prueba de renovación ejecutada."
