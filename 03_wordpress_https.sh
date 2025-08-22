#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] 03_wordpress_https.sh falló en la línea $LINENO"; exit 1' ERR

# --- Resolver ruta del env ---
ENV_FILE="${WP_ENV_FILE:-}"
if [[ -z "$ENV_FILE" || ! -f "$ENV_FILE" ]]; then
  # buscar env automáticamente
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
[[ -f "$ENV_FILE" ]] || { echo "Falta archivo de variables (.env)"; exit 1; }
set -a; source "$ENV_FILE"; set +a

export DEBIAN_FRONTEND=noninteractive

DOMAIN="${DOMAIN:?}"
WEB_ROOT="/var/www/${DOMAIN}/public"

# Detectar versión de PHP
PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
if [[ -z "$PHP_VERSION" ]]; then
  PHP_VERSION="$(ls -1 /etc/php/*/fpm/php.ini 2>/dev/null | sed -E 's#.*/php/([0-9]+\.[0-9]+)/.*#\1#' | head -n1)"
fi

# Crear directorios
mkdir -p "$WEB_ROOT"
chown -R www-data:www-data "/var/www/${DOMAIN}"
chmod -R 755 "/var/www/${DOMAIN}"

# Instalar WP-CLI si no existe
if ! command -v wp >/dev/null 2>&1; then
  curl -fsSL -o /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x /usr/local/bin/wp
fi

# Descargar WordPress y crear configuración
sudo -u www-data wp core download --path="$WEB_ROOT" --locale="${WP_LOCALE:-es_ES}" --force
sudo -u www-data wp config create --path="$WEB_ROOT" \
  --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$DB_PASS" --dbhost="127.0.0.1" --skip-check --force
sudo -u www-data wp config shuffle-salts --path="$WEB_ROOT"

# Instalar WordPress
sudo -u www-data wp core install --path="$WEB_ROOT" \
  --url="https://${DOMAIN}" --title="$WP_TITLE" \
  --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASS" --admin_email="$WP_ADMIN_EMAIL"

# Asegurar que DB_HOST sea 127.0.0.1 (por si acaso)
sed -ri 's/(define\(\s*"DB_HOST"\s*,\s*)"[^"]+"/\1"127.0.0.1"/' "$WEB_ROOT/wp-config.php"

# Establecer permisos prudentes
chmod 640 "$WEB_ROOT/wp-config.php" || true
find "$WEB_ROOT" -type d -exec chmod 755 {} \;
find "$WEB_ROOT" -type f -exec chmod 644 {} \;
# Asegurar que www-data tenga acceso de escritura a wp-content
setfacl -R -m g:www-data:rwx "$WEB_ROOT/wp-content" || true
setfacl -dR -m g:www-data:rwx "$WEB_ROOT/wp-content" || true

# Crear archivo de host virtual para HTTP
SERVER_NAMES="$DOMAIN"
[[ -n "${WWW_ALIAS:-}" ]] && SERVER_NAMES="$SERVER_NAMES ${WWW_ALIAS}"

VHOST="/etc/nginx/sites-available/${DOMAIN}.conf"
cat > "$VHOST" <<NGINX
server {
    listen 80;
    server_name ${SERVER_NAMES};

    root ${WEB_ROOT};
    index index.php index.html index.htm;

    client_max_body_size 64M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg)$ {
        try_files \$uri \$uri/ /index.php?\$args;
        access_log off;
        expires max;
    }

    location ~* \/\.ht {
        deny all;
    }
}
NGINX

ln -sf "$VHOST" "/etc/nginx/sites-enabled/${DOMAIN}.conf"
if [ -e /etc/nginx/sites-enabled/default ]; then rm -f /etc/nginx/sites-enabled/default; fi
nginx -t && systemctl reload nginx

# Instalar y configurar Certbot
if ! command -v certbot >/dev/null 2>&1; then
  apt-get install -y snapd || true
  systemctl enable --now snapd.socket || true
  snap install core && snap refresh core
  snap install --classic certbot
  ln -sf /snap/bin/certbot /usr/bin/certbot
fi

DOMAINS=("-d" "${DOMAIN}")
[[ -n "${WWW_ALIAS:-}" ]] && DOMAINS+=("-d" "${WWW_ALIAS}")
KEY_TYPE="${CERT_KEY_TYPE:-rsa}"

certbot --nginx "${DOMAINS[@]}" \
  -m "${ADMIN_EMAIL}" --agree-tos --no-eff-email --redirect \
  --key-type "$KEY_TYPE" --non-interactive

systemctl reload nginx

echo "[OK] WordPress operativo en https://${DOMAIN}"
