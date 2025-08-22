#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] 04_nginx_tls_rate.sh falló en la línea $LINENO"; exit 1' ERR

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
[[ -f "$ENV_FILE" ]] || { echo "Falta archivo .env (no se encontró WP_ENV_FILE ni .env usable)."; exit 1; }
set -a; source "$ENV_FILE"; set +a
DOMAIN="${DOMAIN:?Falta DOMAIN en el env}"

VHOST="/etc/nginx/sites-available/${DOMAIN}.conf"
[[ -f "$VHOST" ]] || { echo "No existe vhost $VHOST. Ejecuta 03_wordpress_https.sh primero."; exit 1; }

# Detectar versión PHP-FPM
PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
if [[ -z "$PHP_VERSION" ]]; then
  PHP_VERSION="$(ls -1 /etc/php/*/fpm/php.ini 2>/dev/null | sed -E 's#.*/php/([0-9]+\.[0-9]+)/.*#\1#' | head -n1)"
fi
[[ -n "$PHP_VERSION" ]] || { echo "No pude detectar PHP_VERSION. Instala php-fpm"; exit 1; }

RATE="${RATE_LIMIT_RPM:-10}"
HSTS_PRELOAD="${HSTS_PRELOAD:-false}"

# --- Limpieza de restos que causaban duplicados SSL ---
BACKUP_DIR="/etc/nginx/.wp-harden-backups/$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"
for F in \
  /etc/nginx/conf.d/ssl_params.conf \
  /etc/nginx/conf.d/ssl-params.conf \
  /etc/nginx/snippets/ssl-params.conf \
  /etc/nginx/conf.d/security-headers.conf \
  /etc/nginx/conf.d/hsts.conf
  do
    if [[ -f "$F" ]]; then
      mv "$F" "$BACKUP_DIR/$(basename "$F").bak"
      echo "[CLEANUP] Movido: $F -> $BACKUP_DIR"
    fi
  done

# --- Zona global de rate-limit (http{}) ---
cat > /etc/nginx/conf.d/ratelimit.conf <<EOF_RT
limit_req_zone \$binary_remote_addr zone=wp_login_zone:10m rate=${RATE}r/m;
EOF_RT

# --- Snippets de cabeceras y HSTS ---
install -d /etc/nginx/snippets
cat > /etc/nginx/snippets/security-headers.conf <<'EOF_SEC'
add_header X-Content-Type-Options nosniff always;
add_header X-Frame-Options SAMEORIGIN always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
EOF_SEC

if [[ "$HSTS_PRELOAD" == "true" ]]; then
  cat > /etc/nginx/snippets/hsts.conf <<'EOF_HSTS'
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
EOF_HSTS
else
  cat > /etc/nginx/snippets/hsts.conf <<'EOF_HSTS'
add_header Strict-Transport-Security "max-age=31536000" always;
EOF_HSTS
fi

# --- Insertar includes y reglas en el vhost ---
# 1) security-headers + server_tokens off en cada server {}
if ! grep -q 'include snippets/security-headers.conf' "$VHOST"; then
  sed -ri '/server_name[[:space:]].*;/a \\    server_tokens off;\n    include snippets/security-headers.conf;' "$VHOST"
fi
# 2) HSTS solo en server 443
if grep -Eq 'listen[[:space:]]+443' "$VHOST"; then
  if ! grep -q 'include snippets/hsts.conf' "$VHOST"; then
    sed -ri '/listen[[:space:]]+443/ a \\    include snippets/hsts.conf;' "$VHOST"
  fi
else
  echo "[WARN] No hay listen 443 en $VHOST; ¿ya corriste Certbot? HSTS no se insertó." >&2
fi
# 3) rate-limit y xmlrpc
if ! grep -q 'location = /wp-login.php' "$VHOST"; then
  sed -i '/location ~ \\\.php\\$/i \\    location = /wp-login.php {\n        limit_req zone=wp_login_zone burst=10 nodelay;\n        include snippets/fastcgi-php.conf;\n        fastcgi_pass unix:/run/php/php'"$PHP_VERSION"'-fpm.sock;\n    }\n' "$VHOST"
fi
if [[ "${BLOCK_XMLRPC:-true}" == "true" ]] && ! grep -q 'location = /xmlrpc.php' "$VHOST"; then
  sed -i '/location ~ \\\.php\\$/i \\    location = /xmlrpc.php {\n        deny all;\n        access_log off;\n        log_not_found off;\n    }\n' "$VHOST"
fi

# --- Validar y recargar ---
if ! nginx -t; then
  echo "[ERROR] nginx -t falló. Revisa posibles duplicados ssl_ o errores de sintaxis." >&2
  exit 1
fi
systemctl reload nginx
echo "[OK] Nginx endurecido sin duplicados. Headers + HSTS + rate-limit activos."
