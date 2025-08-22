#!/usr/bin/env bash
set -euo pipefail

# --- Resolver ruta del env ---
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
if [[ -f "$ENV_FILE" ]]; then
  set -a; source "$ENV_FILE" 2>/dev/null; set +a
fi
DOMAIN="${DOMAIN:-${2:-}}"
if [[ -z "$DOMAIN" ]]; then
  echo "Uso: $0 [envfile] [dominio] (o define DOMAIN en el env)"; exit 2
fi

printf "== Servicios ==\n"
systemctl --no-pager --full status nginx | sed -n '1,5p' || true
systemctl --no-pager --full status php*-fpm | sed -n '1,5p' || true

printf "== Nginx config ==\n"
nginx -t

printf "== HTTPS (curl headers) ==\n"
curl -sSIL "https://$DOMAIN" | grep -Ei 'HTTP/|strict-transport-security|content-type-options|x-frame-options|referrer-policy|permissions-policy' || true

printf "== OCSP stapling (si aplica) ==\n"
echo | openssl s_client -connect "$DOMAIN:443" -status 2>/dev/null | grep -A2 'OCSP response' || true

printf "== Certbot timers ==\n"
systemctl list-timers | grep -i certbot || echo "(snap.certbot.renew no detectado)"

printf "== WP-CLI ==\n"
sudo -u www-data wp core is-installed --path=/var/www/$DOMAIN/public && echo "WP instalado OK" || echo "WP no instalado"
sudo -u www-data wp core verify-checksums --path=/var/www/$DOMAIN/public || echo "Checksum con diferencias (plugins/temas alterados)"

printf "== PHP info breve ==\n"
php -v | head -n1
php -i | grep -E 'expose_php|memory_limit|opcache.enable|upload_max_filesize|post_max_size|max_input_vars|cgi.fix_pathinfo' || true

printf "== FPM pool (resumen) ==\n"
grep -E 'security.limit_extensions|pm.max_children|pm.max_requests' /etc/php/*/fpm/pool.d/*.conf || true

printf "== Firewall ==\n"
ufw status verbose || true

printf "== Fail2ban ==\n"
fail2ban-client status 2>/dev/null || echo "(Fail2ban no instalado)"
