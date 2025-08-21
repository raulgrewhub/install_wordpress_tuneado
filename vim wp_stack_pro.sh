#!/usr/bin/env bash
# ==============================================================================
# WordPress + Nginx + PHP-FPM + MariaDB + HTTPS (Let's Encrypt)
# "wp_stack_pro.sh" — Ubuntu 22.04/24.04
#
# - Idempotente, multi-sitio (ejecútalo varias veces con distintos dominios)
# - Solicita datos interactivamente si no se proporcionan por flags
# - Autotuning dinámico: MariaDB, PHP-FPM (pm.max_children), OPcache
# - Compatible con MariaDB 10.11 (sin claves obsoletas)
# - Permisos WP seguros (dirs 755, files 644, wp-config.php 640)
# - HTTPS con certbot (redirect + HSTS + OCSP stapling)
# - Redis opcional (solo si WITH_REDIS=true), swap opcional (por defecto ON)
# - UFW + fail2ban básicos
# ==============================================================================

set -Eeuo pipefail
shopt -s lastpipe
IFS=$'\n\t'
export DEBIAN_FRONTEND=noninteractive

# ------------------ Parámetros/flags por defecto ------------------
MODE="${MODE:-auto}"               # auto | bootstrap | site
DOMAIN="${DOMAIN:-}"
LE_EMAIL="${LE_EMAIL:-}"
WP_TITLE="${WP_TITLE:-}"
WP_ADMIN_USER="${WP_ADMIN_USER:-}"
WP_ADMIN_PASS="${WP_ADMIN_PASS:-}"
WP_ADMIN_EMAIL="${WP_ADMIN_EMAIL:-}"
TIMEZONE="${TIMEZONE:-Europe/Madrid}"

UPLOAD_MAX="${UPLOAD_MAX:-16M}"    # Tamaño máximo de subida (Nginx + PHP)
NON_WWW="${NON_WWW:-false}"        # true = no incluye www.<dominio>
SKIP_UFW="${SKIP_UFW:-false}"
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-true}"
ENABLE_SWAP="${ENABLE_SWAP:-true}"  # crea swap 2G si no existe
WITH_REDIS="${WITH_REDIS:-true}"    # instala y habilita redis
LE_STAGING="${LE_STAGING:-false}"   # certificados de prueba
PHP_PROC_MB="${PHP_PROC_MB:-}"      # MB estimados por proceso PHP (auto si vacío)

STACK_MARK="/etc/wp_stack_pro_bootstrapped"
LOGFILE="/root/wp_stack_pro.log"

# ------------------ Utilidades y manejo de errores -----------------
log(){ printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$LOGFILE" >&2; }
warn(){ printf '[%s] WARN: %s\n' "$(date -Is)" "$*" | tee -a "$LOGFILE" >&2; }
die(){ printf '[%s] ERROR: %s\n' "$(date -Is)" "$*" | tee -a "$LOGFILE" >&2; exit 1; }

err_handler() {
  local code=$? line=${BASH_LINENO[0]}
  warn "Fallo en línea $line (código $code). Últimas 50 líneas de $LOGFILE:"
  tail -n 50 "$LOGFILE" || true
  exit $code
}
trap err_handler ERR

# Volcado de stdout/err al log
exec > >(tee -a "$LOGFILE") 2>&1

require_root() { [[ $EUID -eq 0 ]] || die "Ejecuta como root."; }

apt_wait() {
  # Espera educadamente a que apt/dpkg liberen los locks
  local locks=(
    /var/lib/dpkg/lock-frontend
    /var/lib/apt/lists/lock
    /var/cache/apt/archives/lock
  )
  local i=0
  while fuser "${locks[@]}" >/dev/null 2>&1; do
    ((i++))
    [[ $i -gt 120 ]] && die "Timeout esperando locks de apt/dpkg."
    sleep 1
  done
}

apt_safe() {
  apt_wait
  apt-get update -y
  apt-get -o Dpkg::Options::="--force-confold" -y upgrade
}

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

# ------------------ Prompts y validación ---------------------------
prompt_domain() {
  local domain re='^([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$'
  while true; do
    read -rp "Dominio (ej. midominio.com): " domain
    [[ $domain =~ $re ]] && printf '%s' "$domain" && return
    echo "Formato de dominio no válido."
  done
}

prompt_email() {
  local email re='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
  while true; do
    read -rp "Email para Let's Encrypt / admin WP: " email
    [[ $email =~ $re ]] && printf '%s' "$email" && return
    echo "Formato de email no válido."
  done
}

prompt_text() {
  local label="$1" default="${2:-}"
  local val
  if [[ -n "$default" ]]; then
    read -rp "$label [$default]: " val
    printf '%s' "${val:-$default}"
  else
    read -rp "$label: " val
    [[ -n "$val" ]] && printf '%s' "$val" || prompt_text "$label" "$default"
  fi
}

init_inputs() {
  if [[ -z "$DOMAIN" ]]; then DOMAIN=$(prompt_domain); fi
  if [[ -z "$LE_EMAIL" ]]; then LE_EMAIL=$(prompt_email); fi
  if [[ -z "$WP_TITLE" ]]; then WP_TITLE=$(prompt_text "Título del sitio WP" "Mi Sitio"); fi
  if [[ -z "$WP_ADMIN_USER" ]]; then WP_ADMIN_USER=$(prompt_text "Usuario admin WP" "admin"); fi
  if [[ -z "$WP_ADMIN_PASS" ]]; then
    have_cmd openssl || (apt_wait && apt-get install -y openssl)
    WP_ADMIN_PASS=$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!@#%+=' | head -c 24)
    log "Se generó contraseña admin WP."
  fi
  if [[ -z "$WP_ADMIN_EMAIL" ]]; then WP_ADMIN_EMAIL="$LE_EMAIL"; fi
}

# ------------------ Cálculo de tuning dinámico ---------------------
calc_tuning() {
  MEM_KB=$(grep -i MemTotal /proc/meminfo | awk '{print $2}')
  MEM_MB=$(( MEM_KB / 1024 ))
  CPUS=$(nproc --all || echo 1)

  # Reserva para SO+Nginx
  if   (( MEM_MB < 1500 )); then OS_NGINX_MB=256
  elif (( MEM_MB < 3500 )); then OS_NGINX_MB=512
  elif (( MEM_MB < 7000 )); then OS_NGINX_MB=768
  else                           OS_NGINX_MB=1024
  fi

  # Buffer pool MariaDB ≈ 25% RAM (mín 256, máx 8192)
  DB_BUF_MB=$(( MEM_MB * 25 / 100 ))
  (( DB_BUF_MB < 256 )) && DB_BUF_MB=256
  (( DB_BUF_MB > 8192 )) && DB_BUF_MB=8192

  SAFETY_MB=128

  # Estimación MB por proceso PHP
  if [[ -z "${PHP_PROC_MB}" ]]; then
    if   (( MEM_MB < 1500 )); then PHP_PROC_MB=80
    elif (( MEM_MB < 6000 )); then PHP_PROC_MB=96
    elif (( MEM_MB < 16000 )); then PHP_PROC_MB=110
    else                           PHP_PROC_MB=120
    fi
  fi

  PHP_AVAIL_MB=$(( MEM_MB - OS_NGINX_MB - DB_BUF_MB - SAFETY_MB ))
  (( PHP_AVAIL_MB < 256 )) && PHP_AVAIL_MB=256

  MAX_CHILDREN=$(( PHP_AVAIL_MB / PHP_PROC_MB ))
  (( MAX_CHILDREN < 8 )) && MAX_CHILDREN=8
  (( MAX_CHILDREN > 150 )) && MAX_CHILDREN=150

  # OPcache (~4% RAM; 64–256M)
  OPCACHE_MB=$(( MEM_MB * 4 / 100 ))
  (( OPCACHE_MB < 64 )) && OPCACHE_MB=64
  (( OPCACHE_MB > 256 )) && OPCACHE_MB=256

  # tmp_table_size / max_heap_table_size
  if   (( MEM_MB < 1500 )); then TMP_HEAP_MB=32
  elif (( MEM_MB < 3500 )); then TMP_HEAP_MB=64
  elif (( MEM_MB < 7000 )); then TMP_HEAP_MB=128
  else                           TMP_HEAP_MB=256
  fi

  # max_connections ≈ max_children + colchón (100–400)
  if   (( MAX_CHILDREN + 50 < 100 )); then MAX_CONN=100
  elif (( MAX_CHILDREN + 50 > 400 )); then MAX_CONN=400
  else MAX_CONN=$(( MAX_CHILDREN + 50 ))
  fi

  log "Auto-tuning: RAM=${MEM_MB}MB, vCPU=${CPUS}, SO+Nginx=${OS_NGINX_MB}MB, DB.buf=${DB_BUF_MB}MB, PHP.disp=${PHP_AVAIL_MB}MB (~${PHP_PROC_MB}/proc => max_children=${MAX_CHILDREN}), OPcache=${OPCACHE_MB}MB, tmp/heap=${TMP_HEAP_MB}MB, DB max_conn=${MAX_CONN}"
}

# ------------------ MariaDB helpers -------------------------------
mariadb_restart_or_fix() {
  if systemctl restart mariadb; then
    systemctl is-active --quiet mariadb && return 0
  fi
  warn "Reinicio de MariaDB falló. Probando fix de redo-logs..."
  systemctl stop mariadb || true
  rm -f /var/lib/mysql/ib_logfile0 /var/lib/mysql/ib_logfile1 2>/dev/null || true
  chown -R mysql:mysql /var/lib/mysql
  systemctl start mariadb
  systemctl is-active --quiet mariadb || {
    journalctl -xeu mariadb --no-pager | tail -n 100
    die "MariaDB no pudo arrancar tras el fix de redo-logs."
  }
}

# ------------------ Bootstrap del stack ---------------------------
bootstrap_stack() {
  log "Bootstrap del stack..."
  apt_safe

  # Parches tempranos
  apt_wait
  apt-get install -y openssl cron ca-certificates curl unzip gnupg2 lsb-release apt-transport-https
  systemctl enable --now cron

  # Swap opcional 2G
  if [[ "${ENABLE_SWAP}" == "true" ]]; then
    if ! swapon --show | grep -qE '.' ; then
      fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      if ! grep -qE '^\s*/swapfile\s' /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
      fi
      sysctl vm.swappiness=10
      echo "vm.swappiness=10" > /etc/sysctl.d/99-wp-stack-swap.conf
    fi
  fi

  # Servicios principales
  apt_wait
  apt-get install -y nginx mariadb-server mariadb-client
  # Extensiones PHP (incluye EXIF)
  apt-get install -y php-fpm php-mysql php-cli php-curl php-xml php-gd php-mbstring php-zip php-bcmath php-intl php-imagick php-opcache php-igbinary php-exif
  apt-get install -y certbot python3-certbot-nginx

  # Redis solo si se pide
  if [[ "${WITH_REDIS}" == "true" ]]; then
    apt-get install -y redis-server php-redis
  fi

  systemctl enable --now nginx
  systemctl enable --now mariadb

  # Seguridad
  if [[ "${SKIP_UFW}" != "true" ]]; then
    apt-get install -y ufw
    ufw allow OpenSSH
    ufw allow "Nginx Full"
    ufw --force enable
  fi
  if [[ "${INSTALL_FAIL2BAN}" == "true" ]]; then
    apt-get install -y fail2ban
    cat >/etc/fail2ban/jail.d/sshd.local <<'JAIL'
[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
JAIL
    systemctl enable --now fail2ban || true
  fi

  # Endurecimiento básico MariaDB
  mysql <<'SQL' || true
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\_%';
FLUSH PRIVILEGES;
SQL

  # Tuning MariaDB (compatible con 10.11)
  calc_tuning
  cat >/etc/mysql/mariadb.conf.d/60-wp-tuning.cnf <<EOF
[mysqld]
# Memoria y log
innodb_buffer_pool_size = ${DB_BUF_MB}M
innodb_log_file_size    = 128M
innodb_flush_method     = O_DIRECT
innodb_flush_log_at_trx_commit = 1

# Concurrencia
max_connections   = ${MAX_CONN}
table_open_cache  = 2048
tmp_table_size    = ${TMP_HEAP_MB}M
max_heap_table_size = ${TMP_HEAP_MB}M
thread_cache_size = 50

# Slow log
slow_query_log    = ON
long_query_time   = 1

# Seguridad: solo conexiones locales
bind-address = 127.0.0.1

# Notas:
# - 'innodb_buffer_pool_instances' eliminado en MariaDB 10.11 (no se usa)
# - 'log_error_verbosity' no está soportado en MariaDB (no se usa)
EOF

  mariadb_restart_or_fix

  # WP-CLI
  if ! have_cmd wp; then
    curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
    chmod +x /usr/local/bin/wp
  fi

  # Nginx global: workers + gzip + hardening
  if grep -q "^worker_processes" /etc/nginx/nginx.conf; then
    sed -i 's/^worker_processes.*/worker_processes auto;/' /etc/nginx/nginx.conf
  else
    sed -i '1i worker_processes auto;' /etc/nginx/nginx.conf
  fi
  if grep -q "events {" /etc/nginx/nginx.conf; then
    sed -i '/events {/,/}/{s/worker_connections.*/worker_connections 2048;/}' /etc/nginx/nginx.conf
  else
    sed -i '/http {/i events { worker_connections 2048; }' /etc/nginx/nginx.conf
  fi
  cat >/etc/nginx/conf.d/wordpress_tuning.conf <<'NGX'
server_tokens off;
gzip on;
gzip_comp_level 5;
gzip_min_length 256;
gzip_types text/plain text/css application/javascript application/json application/xml image/svg+xml;
NGX

  # Redis opcional: habilitar servicio si existe
  if [[ "${WITH_REDIS}" == "true" ]]; then
    systemctl enable --now redis-server || true
  fi

  # Actualizaciones automáticas
  apt-get install -y unattended-upgrades
  dpkg-reconfigure -f noninteractive unattended-upgrades

  date -Is > "${STACK_MARK}"
  log "Bootstrap completado."
}

# ------------------ Instalación de un sitio -----------------------
install_site() {
  init_inputs
  calc_tuning

  # Derivados del sitio
  SAFE_NAME="$(echo "${DOMAIN}" | tr '.-' '__')"
  SITE_USER="wp_${SAFE_NAME}"
  SITE_DIR="/var/www/${DOMAIN}"
  DB_NAME="wp_$(echo "${DOMAIN//[^A-Za-z0-9]/_}")"
  DB_USER="${DB_NAME}"
  DB_PASS="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9!@#%+=' | head -c 24)"
  WWW_DOMAIN="www.${DOMAIN}"
  SERVER_NAMES="${DOMAIN}"; [[ "${NON_WWW}" != "true" ]] && SERVER_NAMES="${DOMAIN} ${WWW_DOMAIN}"

  LE_FLAGS="--non-interactive --agree-tos -m ${LE_EMAIL} --no-eff-email --redirect --hsts --staple-ocsp"
  [[ "${LE_STAGING}" == "true" ]] && LE_FLAGS="${LE_FLAGS} --staging"

  # PHP version y servicio
  PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
  [[ -z "${PHP_VER}" ]] && PHP_VER="$(ls -1 /etc/php | sort -V | tail -n1)"
  PHP_FPM_SERVICE="php${PHP_VER}-fpm"
  systemctl enable --now "${PHP_FPM_SERVICE}"

  # Usuario SO y carpeta
  id -u "${SITE_USER}" >/dev/null 2>&1 || useradd -m -d "${SITE_DIR}" -s /usr/sbin/nologin "${SITE_USER}"
  mkdir -p "${SITE_DIR}"
  chown -R "${SITE_USER}:www-data" "${SITE_DIR}"

  # DB y usuario
  mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS \`${DB_USER}\`@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO \`${DB_USER}\`@'localhost';
FLUSH PRIVILEGES;
SQL

  # Prefijo aleatorio de tablas (evitar sustitución dentro del bash -c)
  TABLE_PREFIX="$(tr -dc 'a-z0-9' </dev/urandom | head -c5)"

  # WP core (con arreglo de sintaxis y set con ';')
  sudo -u "${SITE_USER}" -s -- bash -c "
    set -Eeuo pipefail;
    if [[ ! -f '${SITE_DIR}/wp-load.php' ]]; then
      wp core download --locale=es_ES --path='${SITE_DIR}'
    fi
    if [[ ! -f '${SITE_DIR}/wp-config.php' ]]; then
      wp config create --dbname='${DB_NAME}' --dbuser='${DB_USER}' --dbpass='${DB_PASS}' \
        --dbhost='localhost' --dbprefix='${TABLE_PREFIX}_' \
        --path='${SITE_DIR}' --skip-check
      wp config set FS_METHOD direct --type=constant --path='${SITE_DIR}'
      wp config set WP_MEMORY_LIMIT '256M' --type=constant --path='${SITE_DIR}'
      wp config set DISALLOW_FILE_EDIT true --type=constant --raw --path='${SITE_DIR}'
      wp config set DISABLE_WP_CRON true --type=constant --raw --path='${SITE_DIR}'
      wp config set WP_ENVIRONMENT_TYPE 'production' --type=constant --path='${SITE_DIR}'
      wp config shuffle-salts --path='${SITE_DIR}'
    fi
  "

  # PHP-FPM: pool dedicado
  POOL_FILE="/etc/php/${PHP_VER}/fpm/pool.d/${SITE_USER}.conf"
  cat > "${POOL_FILE}" <<EOF
[${SITE_USER}]
user = ${SITE_USER}
group = www-data
listen = /run/php/php${PHP_VER}-fpm-${SITE_USER}.sock
listen.owner = www-data
listen.group = www-data

pm = ondemand
pm.max_children = ${MAX_CHILDREN}
pm.process_idle_timeout = 15s
pm.max_requests = 500

request_slowlog_timeout = 5s
slowlog = /var/log/php${PHP_VER}-fpm-${SITE_USER}-slow.log

php_admin_value[upload_max_filesize] = ${UPLOAD_MAX}
php_admin_value[post_max_size]       = ${UPLOAD_MAX}
php_admin_value[memory_limit]        = 256M
php_admin_value[max_execution_time]  = 180
EOF

  # PHP ini global (OPcache y ajustes)
  cat >"/etc/php/${PHP_VER}/fpm/conf.d/90-wordpress.ini" <<EOF
; OPcache
opcache.enable=1
opcache.memory_consumption=${OPCACHE_MB}
opcache.interned_strings_buffer=16
opcache.max_accelerated_files=20000
opcache.validate_timestamps=1
opcache.revalidate_freq=2
opcache.save_comments=1

; Límites y zona horaria
file_uploads=On
upload_max_filesize=${UPLOAD_MAX}
post_max_size=${UPLOAD_MAX}
max_execution_time=180
max_input_vars=3000
date.timezone=${TIMEZONE}
EOF

  systemctl reload "${PHP_FPM_SERVICE}"

  # Snippet fastcgi por si falta
  if [[ ! -f /etc/nginx/snippets/fastcgi-php.conf ]]; then
    cat > /etc/nginx/snippets/fastcgi-php.conf <<'SNIP'
include fastcgi_params;
fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
fastcgi_index index.php;
SNIP
  fi

  # Nginx vhost
  NGINX_FILE="/etc/nginx/sites-available/${DOMAIN}.conf"
  cat > "${NGINX_FILE}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SERVER_NAMES};
    root ${SITE_DIR};
    index index.php index.html index.htm;

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log  /var/log/nginx/${DOMAIN}.error.log;

    # ACME
    location ~ ^/\.well-known/acme-challenge/ {
        allow all;
    }

    client_max_body_size ${UPLOAD_MAX};

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm-${SITE_USER}.sock;
        fastcgi_read_timeout 120s;
    }

    # Estáticos con caché
    location ~* \.(?:css|js|jpg|jpeg|gif|png|svg|webp|ico|woff2?)\$ {
        expires 30d;
        add_header Cache-Control "public";
        try_files \$uri \$uri/ =404;
        access_log off;
    }

    # Bloqueos básicos
    location ~* /(?:uploads|files)/.*\.php\$ { deny all; }
    location ~ /\.(?!well-known/) { deny all; }
}
EOF

  ln -sf "${NGINX_FILE}" "/etc/nginx/sites-enabled/${DOMAIN}.conf"
  rm -f /etc/nginx/sites-enabled/default || true
  nginx -t
  systemctl reload nginx

  # Instalar WP en DB
  WP_URL="https://${DOMAIN}"
  sudo -u "${SITE_USER}" -s -- bash -c "
    set -Eeuo pipefail;
    if ! wp core is-installed --path='${SITE_DIR}'; then
      wp core install --url='${WP_URL}' --title='${WP_TITLE}' \
        --admin_user='${WP_ADMIN_USER}' --admin_password='${WP_ADMIN_PASS}' \
        --admin_email='${WP_ADMIN_EMAIL}' --skip-email --path='${SITE_DIR}'
      wp rewrite structure '/%postname%/' --hard --path='${SITE_DIR}'
      wp option update timezone_string '${TIMEZONE}' --path='${SITE_DIR}'
    fi
  "

  # Certificado TLS
  DOMAINS_ARGS="-d ${DOMAIN}"; [[ "${NON_WWW}" != "true" ]] && DOMAINS_ARGS="${DOMAINS_ARGS} -d ${WWW_DOMAIN}"
  if ! certbot --nginx ${DOMAINS_ARGS} ${LE_FLAGS}; then
    warn "No se pudo emitir el certificado (DNS/puerto 80). Reintenta luego con:
      certbot --nginx ${DOMAINS_ARGS} ${LE_FLAGS}"
  fi

  # Cron real para WP (cada 5 minutos)
  CRONLINE="*/5 * * * * cd ${SITE_DIR} && /usr/local/bin/wp --path=${SITE_DIR} cron event run --due-now >/dev/null 2>&1"
  ( crontab -l -u "${SITE_USER}" 2>/dev/null | grep -v "wp cron event run" || true ; echo "${CRONLINE}" ) | crontab -u "${SITE_USER}" -

  # Redis opcional
  if [[ "${WITH_REDIS}" == "true" ]]; then
    sudo -u "${SITE_USER}" -s -- bash -c "
      set -Eeuo pipefail;
      wp plugin install redis-cache --activate --path='${SITE_DIR}' || true
      wp redis enable --path='${SITE_DIR}' || true
    "
    systemctl reload "${PHP_FPM_SERVICE}"
  fi

  # Permisos recomendados
  find "${SITE_DIR}" -type d -exec chmod 755 {} \;
  find "${SITE_DIR}" -type f -exec chmod 644 {} \;
  [[ -f "${SITE_DIR}/wp-config.php" ]] && chmod 640 "${SITE_DIR}/wp-config.php"

  # Resumen
  CREDS="/root/wp_${DOMAIN}_credenciales.txt"
  cat > "${CREDS}" <<EOF
== WordPress desplegado (${DOMAIN}) ==
Fecha: $(date -Is)
URL            : ${WP_URL}
Ruta del sitio : ${SITE_DIR}

Usuario SO     : ${SITE_USER}
PHP            : ${PHP_VER}
PHP-FPM pool   : /etc/php/${PHP_VER}/fpm/pool.d/${SITE_USER}.conf
Socket PHP     : /run/php/php${PHP_VER}-fpm-${SITE_USER}.sock
Subida máx     : ${UPLOAD_MAX}

RAM total      : ${MEM_MB} MB
CPUs           : ${CPUS}
SO+Nginx MB    : ${OS_NGINX_MB}
DB buffer MB   : ${DB_BUF_MB}
PHP disp MB    : ${PHP_AVAIL_MB}
PHP/proceso MB : ${PHP_PROC_MB}
max_children   : ${MAX_CHILDREN}
OPcache MB     : ${OPCACHE_MB}
tmp/heap MB    : ${TMP_HEAP_MB}
DB conexiones  : ${MAX_CONN}

Base de datos  : ${DB_NAME}
DB Usuario     : ${DB_USER}
DB Password    : ${DB_PASS}

Admin WP       : ${WP_ADMIN_USER}
Admin Email    : ${WP_ADMIN_EMAIL}
Admin Pass     : ${WP_ADMIN_PASS}

Cron WP        : ${CRONLINE}

Comandos útiles:
  sudo -u ${SITE_USER} -s
  cd ${SITE_DIR} && wp plugin list
  nginx -t && systemctl reload nginx
  systemctl status ${PHP_FPM_SERVICE} nginx mariadb
  certbot renew --dry-run
EOF
  chmod 600 "${CREDS}"

  log "Sitio ${DOMAIN} desplegado. Credenciales: ${CREDS}"
}

# ------------------ Parser de flags -------------------------------
usage() {
  cat <<EOF
Uso:
  $0 [--mode auto|bootstrap|site] \\
     [--domain ejemplo.com] [--email admin@ejemplo.com] \\
     [--wp-title "Mi Sitio"] [--wp-admin-user admin] \\
     [--wp-admin-pass 'P4ss'] [--wp-admin-email admin@ejemplo.com] \\
     [--upload-max 16M] [--non-www] [--skip-ufw] [--no-fail2ban] \\
     [--no-swap] [--no-redis] [--le-staging] [--php-proc-mb 96] \\
     [--timezone Europe/Madrid]

Ejemplos:
  $0 --domain ejemplo.com --email admin@ejemplo.com \\
     --wp-title "Blog" --wp-admin-user admin --wp-admin-pass 'P4ss' \\
     --wp-admin-email admin@ejemplo.com

Notas:
 - Si no pasas --domain/--email/etc., el script te los pedirá interactivamente.
 - Ejecuta varias veces con distintos --domain para múltiples sitios.
EOF
}

parse_flags() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode) MODE="$2"; shift 2;;
      --domain) DOMAIN="$2"; shift 2;;
      --email) LE_EMAIL="$2"; shift 2;;
      --wp-title) WP_TITLE="$2"; shift 2;;
      --wp-admin-user) WP_ADMIN_USER="$2"; shift 2;;
      --wp-admin-pass) WP_ADMIN_PASS="$2"; shift 2;;
      --wp-admin-email) WP_ADMIN_EMAIL="$2"; shift 2;;
      --timezone) TIMEZONE="$2"; shift 2;;
      --upload-max) UPLOAD_MAX="$2"; shift 2;;
      --non-www) NON_WWW=true; shift 1;;
      --skip-ufw) SKIP_UFW=true; shift 1;;
      --no-fail2ban) INSTALL_FAIL2BAN=false; shift 1;;
      --no-swap|--without-swap) ENABLE_SWAP=false; shift 1;;
      --no-redis|--without-redis) WITH_REDIS=false; shift 1;;
      --with-redis) WITH_REDIS=true; shift 1;;
      --php-proc-mb) PHP_PROC_MB="$2"; shift 2;;
      --le-staging) LE_STAGING=true; shift 1;;
      -h|--help) usage; exit 0;;
      *) die "Flag desconocida: $1";;
    esac
  done
}

# ------------------ Flujo principal --------------------------------
main() {
  require_root
  parse_flags "$@"

  log "Inicio: mode=${MODE}, domain=${DOMAIN:-<interactive>}, email=${LE_EMAIL:-<interactive>}"
  if [[ "${MODE}" == "bootstrap" ]]; then
    bootstrap_stack
    log "Bootstrap completado. Ejecuta de nuevo con --mode site o sin --mode para crear un sitio."
    exit 0
  fi

  if [[ ! -f "${STACK_MARK}" ]]; then
    log "No hay bootstrap previo. Ejecutando bootstrap..."
    bootstrap_stack
  fi

  # Alta del sitio
  install_site
  log "Todo listo."
}

main "$@"
