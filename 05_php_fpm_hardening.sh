#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] 05_php_fpm_hardening.sh falló en la línea $LINENO"; exit 1' ERR

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
[[ -f "$ENV_FILE" ]] || { echo "Falta archivo de variables (.env)"; exit 1; }
set -a; source "$ENV_FILE"; set +a

# Detectar versión de PHP
PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
if [[ -z "$PHP_VERSION" ]]; then
  PHP_VERSION="$(ls -1 /etc/php/*/fpm/php.ini 2>/dev/null | sed -E 's#.*/php/([0-9]+\.[0-9]+)/.*#\1#' | head -n1)"
fi
[[ -n "$PHP_VERSION" ]] || { echo "No se pudo detectar la versión de PHP"; exit 1; }

PHP_INI_FPM="/etc/php/${PHP_VERSION}/fpm/php.ini"
PHP_INI_CLI="/etc/php/${PHP_VERSION}/cli/php.ini"
POOL="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"

# Ajustes php.ini (CLI y FPM)
for INI in "$PHP_INI_FPM" "$PHP_INI_CLI"; do
  [[ -f "$INI" ]] || continue
  sed -ri 's@^;?\s*expose_php\s*=.*@expose_php = Off@' "$INI"
  sed -ri 's@^;?\s*memory_limit\s*=.*@memory_limit = 256M@' "$INI"
  sed -ri 's@^;?\s*upload_max_filesize\s*=.*@upload_max_filesize = 64M@' "$INI"
  sed -ri 's@^;?\s*post_max_size\s*=.*@post_max_size = 64M@' "$INI"
  sed -ri 's@^;?\s*max_execution_time\s*=.*@max_execution_time = 120@' "$INI"
  sed -ri 's@^;?\s*max_input_vars\s*=.*@max_input_vars = 3000@' "$INI"
  sed -ri 's@^;?\s*cgi\.fix_pathinfo\s*=.*@cgi.fix_pathinfo = 0@' "$INI"
done

# Ajustar OPcache solo para FPM
if [[ -f "$PHP_INI_FPM" ]]; then
  sed -ri 's@^;?\s*opcache\.enable\s*=.*@opcache.enable = 1@' "$PHP_INI_FPM"
  sed -ri 's@^;?\s*opcache\.memory_consumption\s*=.*@opcache.memory_consumption = 128@' "$PHP_INI_FPM"
  sed -ri 's@^;?\s*opcache\.max_accelerated_files\s*=.*@opcache.max_accelerated_files = 20000@' "$PHP_INI_FPM"
  sed -ri 's@^;?\s*opcache\.validate_timestamps\s*=.*@opcache.validate_timestamps = 1@' "$PHP_INI_FPM"
fi

# Pool FPM tuning
if [[ -f "$POOL" ]]; then
  sed -ri 's@^;?\s*security\.limit_extensions\s*=.*@security.limit_extensions = .php@' "$POOL"
  sed -ri 's@^;?\s*pm\s*=.*@pm = dynamic@' "$POOL"
  sed -ri 's@^;?\s*pm\.max_children\s*=.*@pm.max_children = ${PHP_PM_MAX_CHILDREN:-10}@' "$POOL"
  sed -ri 's@^;?\s*pm\.start_servers\s*=.*@pm.start_servers = 2@' "$POOL"
  sed -ri 's@^;?\s*pm\.min_spare_servers\s*=.*@pm.min_spare_servers = 2@' "$POOL"
  sed -ri 's@^;?\s*pm\.max_spare_servers\s*=.*@pm.max_spare_servers = 5@' "$POOL"
  sed -ri 's@^;?\s*pm\.max_requests\s*=.*@pm.max_requests = 500@' "$POOL"
fi

systemctl restart "php${PHP_VERSION}-fpm"
systemctl reload nginx || true
echo "[OK] PHP-FPM endurecido y ajustado."
