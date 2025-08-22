# Instalación WordPress Tuneada

¡Bienvenido! Este repositorio contiene un conjunto de scripts sencillos que te ayudan a preparar un servidor Ubuntu para alojar un sitio WordPress rápido y seguro, sin complicaciones ni comandos misteriosos.

## ¿Qué hacen estos scripts?

1. **Sistema base (`01_sistema.sh`)** – Actualiza el sistema, instala los paquetes básicos, configura la zona horaria, crea un usuario administrador y habilita el firewall.
2. **LEMP (`02_lemp.sh`)** – Instala Nginx, PHP y MariaDB, ajusta PHP-FPM y crea tu base de datos.
3. **WordPress y HTTPS (`03_wordpress_https.sh`)** – Descarga WordPress con WP​‑CLI, configura tu sitio y obtiene un certificado Let’s Encrypt con Nginx.
4. **Seguridad de Nginx (`04_nginx_tls_rate.sh`)** – Añade cabeceras de seguridad, HSTS, límites de acceso al login y bloquea `xmlrpc.php`.
5. **Ajustes PHP-FPM (`05_php_fpm_hardening.sh`)** – Oculta la versión de PHP y optimiza el rendimiento.
6. **Hardening de WordPress y Fail2ban (`06_wp_fail2ban_wpverify.sh`)** – Activa constantes de seguridad, fija permisos y configura Fail2ban.
7. **Verificación (`07_verificacion.sh`)** – Comprueba que todo está funcionando: servicios, cabeceras, certificados y reglas de firewall.
8. **Asistente (`00_env_wizard.sh`)** – Genera un archivo de variables `.env` con tus datos (dominio, usuario, contraseñas, etc.) para que no tengas que editar scripts.
9. **Orquestador (`09_add_site.sh`)** – Crea un nuevo sitio de principio a fin con un solo comando.

## Paso a paso para dummies

1. **Prepara tu servidor**. Arranca una máquina Ubuntu (22.04/24.04) nueva y conéctate por SSH como `root`.
2. **Descarga este repositorio**:
   ```bash
   git clone https://github.com/raulgrewhub/install_wordpress_tuneado.git
   cd install_wordpress_tuneado
   ```
3. **Crea tu archivo de variables**. Ejecuta el asistente e introduce tu dominio, email y contraseñas:
   ```bash
   bash 00_env_wizard.sh
   ```
   Esto creará `/etc/wp-provision/tu-dominio.env` y te mostrará tus credenciales. **Guárdalas en un lugar seguro.**
4. **Exporta la variable** para que los scripts sepan dónde está tu env:
   ```bash
   export WP_ENV_FILE=/etc/wp-provision/tu-dominio.env
   ```
5. **Ejecuta los scripts en orden**:
   ```bash
   bash 01_sistema.sh         # Instala paquetes básicos y configura el sistema
   bash 02_lemp.sh            # Instala Nginx, PHP-FPM y MariaDB
   bash 03_wordpress_https.sh # Descarga WordPress y configura HTTPS
   bash 04_nginx_tls_rate.sh  # Refuerza Nginx (TLS, cabeceras y límites)
   bash 05_php_fpm_hardening.sh # Optimiza PHP-FPM
   bash 06_wp_fail2ban_wpverify.sh # Endurece WP y configura Fail2ban
   bash 07_verificacion.sh    # Revisa que todo esté OK
   ```
6. **Apunta tu dominio**. Asegúrate de que los registros DNS A/AAAA del dominio y `www.` apuntan a la IP de tu servidor. Certbot usará este paso para obtener el certificado.
7. **Accede a tu sitio**. Abre `https://tu-dominio` en un navegador, inicia sesión con el usuario y contraseña de WordPress que definiste y empieza a personalizar tu web.

## Añadir más sitios

¿Quieres alojar otro dominio en el mismo servidor? Solo tienes que repetir los pasos 3–7 con un nuevo archivo `.env`, o usar el orquestador:

```bash
bash 00_env_wizard.sh            # genera otro env
bash 09_add_site.sh midominio.com # crea todo de golpe
```

## Consejos finales

- Mantén tu servidor actualizado. Los scripts habilitan actualizaciones automáticas de seguridad.
- Cambia las contraseñas generadas por algo aún más fuerte y único.
- Revisa los logs (`/var/log/nginx/`, `/var/log/mysql/`, `/var/log/fail2ban.log`) si algo no funciona como esperas.

¡Y listo! Con estos scripts tendrás un WordPress listo para producción en unos minutos, sin complicaciones ni dolores de cabeza.
