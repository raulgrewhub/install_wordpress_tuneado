#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] 01_sistema.sh falló en la línea $LINENO"; exit 1' ERR

# --- Resolver ruta del env ---
# Este script intenta localizar un archivo de variables (env) sin necesidad de
# especificar una ruta cada vez. Se prioriza WP_ENV_FILE, luego cualquier
# fichero en /etc/wp-provision si sólo hay uno, y finalmente wp.env en el
# directorio actual, en $HOME o en /root.
ENV_FILE="${WP_ENV_FILE:-}"
if [[ -z "$ENV_FILE" || ! -f "$ENV_FILE" ]]; then
  shopt -s nullglob
  CANDIDATES=(/etc/wp-provision/*.env)
  shopt -u nullglob
  if (( ${#CANDIDATES[@]} == 1 )); then
    ENV_FILE="${CANDIDATES[0]}"
  else
    for C in "./wp.env" "$HOME/wp.env" "/root/wp.env"; do
      [[ -f "$C" ]] && ENV_FILE="$C" && break
    done
  fi
fi
[[ -f "$ENV_FILE" ]] || { echo "Falta archivo de variables (.env). Exporta WP_ENV_FILE o colócalo en /etc/wp-provision."; exit 1; }
set -a; source "$ENV_FILE"; set +a

export DEBIAN_FRONTEND=noninteractive

# Actualizar el sistema
apt-get update -y
apt-get upgrade -y

# Paquetes base
apt-get install -y software-properties-common curl git ufw unzip acl ca-certificates gnupg lsb-release unattended-upgrades

# Zona horaria
timedatectl set-timezone "${TZ:-UTC}"

# Usuario administrador (opcional)
if [[ -n "${ADMIN_USER:-}" ]]; then
  if ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$ADMIN_USER"
  fi
  usermod -aG sudo "$ADMIN_USER"
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
  if [[ -n "${ADMIN_SSH_PUBKEY:-}" ]]; then
    echo "$ADMIN_SSH_PUBKEY" > "/home/$ADMIN_USER/.ssh/authorized_keys"
    chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"
  fi
  chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
fi

# (Opcional) endurecer SSH
if [[ "${HARDEN_SSH:-false}" == "true" ]]; then
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
  systemctl reload sshd
fi

# Firewall básico
ufw allow OpenSSH
ufw --force enable

# Configurar actualizaciones automáticas de seguridad
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF_CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF_CONF
systemctl restart unattended-upgrades || true

echo "[OK] Sistema base y seguridad mínima listos."
