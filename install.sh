#!/usr/bin/env bash
#===============================================================
# GenieACS Installer - Debian 12/13 y Ubuntu 22.04/24.04
# ACS TR-069 (CWMP) para gestion remota de CPEs/ONUs
# https://github.com/mtandazo35/genieacs-installer
#===============================================================
# No usamos 'set -e': en flujos con checks explicitos y trampas de
# rollback suele hacer mas dano que bien. Cada paso critico valida su
# propio estado con err().
set -o pipefail

GENIEACS_VERSION="1.2.16"
INSTALLER_VERSION="2.1.0"
NODE_MAJOR="22"               # LTS; Node 20 quedo EOL (abril 2026)
NODE_MIN="18"                 # minimo compatible con GenieACS 1.2.x
MONGO_VERSION="8.0"
MONGO_MAJOR="${MONGO_VERSION%%.*}"
ENV_CHANGED=0                 # lo marca reconcile_env si toca el .env

ENV_FILE="/opt/genieacs/genieacs.env"
EXT_DIR="/opt/genieacs/ext"
LOG_DIR="/var/log/genieacs"
INSTALL_LOG="/var/log/genieacs-install.log"
BACKUP_DIR="/root/backups/genieacs"
BACKUP_BIN="/usr/local/sbin/genieacs-backup.sh"
BACKUP_KEEP=14
TLS_DIR="/etc/genieacs/tls"
MONGOD_CONF="${MONGOD_CONF:-/etc/mongod.conf}"   # variable para poder testearlo

# --- flags (defaults) ---
PROD_MODE=0            # --prod: liga UI a localhost + reverse proxy TLS
NBI_LOCAL=0            # --nbi-local: liga NBI a 127.0.0.1 (rompe billing externo)
FS_LOCAL=0             # --fs-local: liga FS a 127.0.0.1 (requiere URL prefix)
DOMAIN=""              # --domain <fqdn>: nombre para el reverse proxy/cert
USE_LE=0               # --letsencrypt: certbot en vez de self-signed
WORKERS=""             # --workers <n>: procesos worker por servicio
BACKUP_REMOTE=""       # --backup-remote <dest rsync/scp>: copia off-box

# --- colores (solo si hay TTY) ---
if [ -t 1 ]; then
    R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
else
    R=''; G=''; Y=''; C=''; N=''
fi

msg()  { echo -e "${G}[OK]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }
log()  { echo "+ $*" >>"$INSTALL_LOG" 2>/dev/null; }
err()  {
    echo -e "${R}[ERROR]${N} $1"
    if [ -s "$INSTALL_LOG" ]; then
        echo -e "${Y}--- ultimas lineas de $INSTALL_LOG ---${N}"
        tail -n 15 "$INSTALL_LOG"
    fi
    exit 1
}
# run: ejecuta un comando registrando su salida en el log de instalacion
run() { log "$*"; "$@" >>"$INSTALL_LOG" 2>&1; }

log_init() { mkdir -p "$(dirname "$INSTALL_LOG")" 2>/dev/null; : >"$INSTALL_LOG" 2>/dev/null || true; }

banner() {
    echo -e "${C}"
    echo "==============================================="
    echo "   GenieACS ${GENIEACS_VERSION} · installer v${INSTALLER_VERSION}"
    echo "     ACS TR-069 para gestion de CPEs/ONUs"
    echo "==============================================="
    echo -e "${N}"
}

usage() {
    cat <<USAGE
GenieACS installer v${INSTALLER_VERSION}

Uso:
  install.sh [accion] [opciones]

Acciones:
  install            Instala GenieACS + MongoDB + Node + servicios
  update             Sube GenieACS a ${GENIEACS_VERSION} (respalda y reinicia)
  backup             Respaldo inmediato de la base
  restore <archivo>  Restaura un respaldo (mongorestore --drop)
  status             Auditoria PASS/WARN/FAIL de la instalacion
  uninstall          Elimina servicios (pregunta si purgar MongoDB+datos)

Opciones (install):
  --prod             Liga UI a localhost y publica por reverse proxy TLS (nginx)
  --nbi-local        Liga NBI a 127.0.0.1 (rompe acceso de billing externo)
  --fs-local         Liga FS a 127.0.0.1 (requiere URL prefix por proxy)
  --domain <fqdn>    Nombre para el reverse proxy / certificado
  --letsencrypt      Usa certbot en vez de certificado self-signed
  --workers <n>      Procesos worker por servicio (def: auto segun RAM)
  --backup-remote <dest>  Copia el respaldo a un destino rsync/scp

  -h, --help         Esta ayuda
  -v, --version      Version del instalador
USAGE
}

#---------------------------------------------------------------
# Comprobaciones basicas
#---------------------------------------------------------------
detect_ip() {
    local ip
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    [ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "$ip"
}

check_system() {
    [ "$(id -u)" -eq 0 ] || err "Ejecutar como root"
    command -v systemctl >/dev/null 2>&1 || err "Se requiere systemd"

    . /etc/os-release 2>/dev/null || err "No se pudo detectar el sistema operativo"
    OS_ID="$ID"
    CODENAME="${VERSION_CODENAME:-}"
    case "$OS_ID" in
        debian|ubuntu) ;;
        *) err "Solo soportado en Debian/Ubuntu (detectado: $OS_ID)" ;;
    esac

    ARCH=$(dpkg --print-architecture)
    [ "$ARCH" = "amd64" ] || [ "$ARCH" = "arm64" ] || err "Arquitectura no soportada: $ARCH"

    # MongoDB >= 5.0 exige AVX en x86_64. En Proxmox con CPU kvm64 no hay AVX.
    if [ "$ARCH" = "amd64" ] && ! grep -q avx /proc/cpuinfo; then
        err "La CPU no expone AVX (requerido por MongoDB ${MONGO_VERSION}).
    En Proxmox: poner CPU type 'host' en la VM y reiniciarla."
    fi

    RAM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    [ "$RAM_MB" -lt 1800 ] && warn "RAM detectada: ${RAM_MB}MB. Recomendado minimo 2GB (4GB en produccion)"
}

#---------------------------------------------------------------
# Dependencias: Node.js + MongoDB
#---------------------------------------------------------------
install_node() {
    local cur_major=""
    command -v node >/dev/null 2>&1 && cur_major=$(node -p "process.versions.node.split('.')[0]" 2>/dev/null)
    if [ -n "$cur_major" ]; then
        if [ "$cur_major" = "$NODE_MAJOR" ]; then
            msg "Node.js $(node -v) correcto"
            return
        fi
        if [ "$cur_major" -ge "$NODE_MIN" ] 2>/dev/null; then
            warn "Node.js $(node -v) presente (el stack fija ${NODE_MAJOR}.x). Compatible; NO se cambia el major automaticamente."
            return
        fi
        warn "Node.js $(node -v) es anterior a ${NODE_MIN}: demasiado viejo para GenieACS ${GENIEACS_VERSION}; instalando ${NODE_MAJOR}.x"
    fi
    echo "Instalando Node.js ${NODE_MAJOR}.x..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >>"$INSTALL_LOG" 2>&1
    run apt-get install -y nodejs || err "Fallo instalando Node.js"
    msg "Node.js $(node -v) instalado"
}

install_mongodb() {
    if systemctl is-active --quiet mongod; then
        local cur
        cur=$(mongod --version 2>/dev/null | awk '/db version/ {gsub("v","",$3); split($3,a,"."); print a[1]}')
        if [ -n "$cur" ] && [ "$cur" != "$MONGO_MAJOR" ]; then
            warn "MongoDB v${cur}.x ya activo (el stack fija ${MONGO_VERSION}); se conserva, NO se hace upgrade de major automatico"
        else
            msg "MongoDB $(mongod --version | head -1 | awk '{print $3}') ya instalado y activo"
        fi
        return
    fi
    # ACS-13: instalado pero DETENIDO no es lo mismo que no instalado. No corras
    # la instalacion de otro major sobre datos existentes: arranca el que hay.
    if command -v mongod >/dev/null 2>&1 || dpkg -l 'mongodb*' 2>/dev/null | grep -q '^ii'; then
        local ver; ver=$(mongod --version 2>/dev/null | awk '/db version/ {print $3}')
        warn "MongoDB (${ver:-desconocido}) instalado pero detenido; intento arrancarlo (NO reinstalo)"
        run systemctl enable --now mongod
        systemctl is-active --quiet mongod \
            && { msg "MongoDB arrancado"; return; } \
            || err "MongoDB instalado pero no arranca; diagnostica (journalctl -u mongod). No se instala otro major encima."
    fi
    echo "Instalando MongoDB ${MONGO_VERSION}..."

    # Codenames con repo oficial de MongoDB; el resto cae al mas cercano.
    # Debian 13: el repo 'trixie' existe pero esta VACIO (verificado 2026-08-22),
    # los paquetes de bookworm instalan sin problema sobre trixie.
    local repo_os="$OS_ID" repo_code="$CODENAME"
    case "$CODENAME" in
        bookworm|jammy|noble) ;;
        trixie) repo_code="bookworm" ;;
        *) if [ "$OS_ID" = "debian" ]; then repo_code="bookworm"; else repo_code="noble"; fi
           warn "Codename '$CODENAME' sin repo oficial; usando $repo_code" ;;
    esac

    curl -fsSL "https://www.mongodb.org/static/pgp/server-${MONGO_VERSION}.asc" \
        | gpg --dearmor -o /usr/share/keyrings/mongodb-server.gpg 2>>"$INSTALL_LOG"

    if [ "$repo_os" = "debian" ]; then
        echo "deb [signed-by=/usr/share/keyrings/mongodb-server.gpg] https://repo.mongodb.org/apt/debian ${repo_code}/mongodb-org/${MONGO_VERSION} main" \
            > /etc/apt/sources.list.d/mongodb-org.list
    else
        echo "deb [signed-by=/usr/share/keyrings/mongodb-server.gpg] https://repo.mongodb.org/apt/ubuntu ${repo_code}/mongodb-org/${MONGO_VERSION} multiverse" \
            > /etc/apt/sources.list.d/mongodb-org.list
    fi

    run apt-get update
    run apt-get install -y mongodb-org || err "Fallo instalando MongoDB"
    run systemctl enable --now mongod
    systemctl is-active --quiet mongod || err "mongod no arranco (revisar: journalctl -u mongod)"
    msg "MongoDB $(mongod --version | head -1 | awk '{print $3}') activo"
}

# mongodump/mongorestore vienen de mongodb-database-tools; si MongoDB preexistia
# sin ellas, el respaldo/restauracion fallaria. Aseguramos su presencia.
ensure_db_tools() {
    command -v mongodump >/dev/null 2>&1 && command -v mongorestore >/dev/null 2>&1 && return
    warn "mongodb-database-tools ausente (mongodump/mongorestore); instalando..."
    run apt-get install -y mongodb-database-tools \
        || warn "No se pudieron instalar las tools; el respaldo automatico no funcionara hasta instalarlas"
}

#---------------------------------------------------------------
# GenieACS
#---------------------------------------------------------------
compute_workers() {
    if [ -n "$WORKERS" ]; then echo "$WORKERS"; return; fi
    local ram; ram=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    # En VMs chicas, 4 servicios x (CPUs) workers ahogan la RAM; fijamos 2.
    if [ "$ram" -lt 4000 ]; then echo 2; else echo ""; fi
}

# --- .env idempotente: el instalador "posee" solo estas claves y las reconcilia
#     en cada corrida, para que reinstalar con flags SI cambie el archivo (ACS-06).
env_set() {   # key value  -> agrega o reemplaza, marca ENV_CHANGED si cambia
    local key="$1" val="$2"
    [ -f "$ENV_FILE" ] || return 1
    if grep -q "^${key}=" "$ENV_FILE"; then
        grep -qx "${key}=${val}" "$ENV_FILE" && return 0
        sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
        echo "${key}=${val}" >> "$ENV_FILE"
    fi
    ENV_CHANGED=1
}
env_del() {   # key  -> borra si existe
    [ -f "$ENV_FILE" ] || return 0
    grep -q "^${1}=" "$ENV_FILE" || return 0
    sed -i "/^${1}=/d" "$ENV_FILE"
    ENV_CHANGED=1
}
# Reconcilia las claves gestionadas al estado que piden los flags (set si aplica,
# del si no). No toca JWT/logs/ext/NODE_OPTIONS ni claves ajenas.
reconcile_env() {
    local workers s
    workers=$(compute_workers)
    for s in CWMP NBI FS UI; do
        if [ -n "$workers" ]; then env_set "GENIEACS_${s}_WORKER_PROCESSES" "$workers"
        else env_del "GENIEACS_${s}_WORKER_PROCESSES"; fi
    done
    if [ "$PROD_MODE" = "1" ]; then env_set GENIEACS_UI_INTERFACE 127.0.0.1; else env_del GENIEACS_UI_INTERFACE; fi
    if [ "$NBI_LOCAL" = "1" ]; then env_set GENIEACS_NBI_INTERFACE 127.0.0.1; else env_del GENIEACS_NBI_INTERFACE; fi
    if [ "$FS_LOCAL" = "1" ]; then env_set GENIEACS_FS_INTERFACE 127.0.0.1; else env_del GENIEACS_FS_INTERFACE; fi
    if [ "$FS_LOCAL" = "1" ] && [ -n "$DOMAIN" ]; then env_set GENIEACS_FS_URL_PREFIX "https://${DOMAIN}/fs/"; else env_del GENIEACS_FS_URL_PREFIX; fi
}

install_genieacs() {
    echo "Instalando GenieACS ${GENIEACS_VERSION} via npm..."
    run npm install -g "genieacs@${GENIEACS_VERSION}" || err "Fallo npm install genieacs"
    msg "GenieACS instalado: $(command -v genieacs-cwmp)"

    id genieacs >/dev/null 2>&1 || useradd --system --no-create-home --user-group genieacs

    mkdir -p "$EXT_DIR" "$LOG_DIR"
    chown genieacs:genieacs "$EXT_DIR" "$LOG_DIR"

    if [ ! -f "$ENV_FILE" ]; then
        local jwt
        jwt=$(node -e "console.log(require('crypto').randomBytes(64).toString('hex'))")
        {
            echo "GENIEACS_CWMP_ACCESS_LOG_FILE=${LOG_DIR}/genieacs-cwmp-access.log"
            echo "GENIEACS_NBI_ACCESS_LOG_FILE=${LOG_DIR}/genieacs-nbi-access.log"
            echo "GENIEACS_FS_ACCESS_LOG_FILE=${LOG_DIR}/genieacs-fs-access.log"
            echo "GENIEACS_UI_ACCESS_LOG_FILE=${LOG_DIR}/genieacs-ui-access.log"
            echo "NODE_OPTIONS=--enable-source-maps"
            echo "GENIEACS_EXT_DIR=${EXT_DIR}"
            echo "GENIEACS_UI_JWT_SECRET=${jwt}"
        } > "$ENV_FILE"
        chown genieacs:genieacs "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        msg "Config creada en $ENV_FILE (JWT secret generado)"
    else
        msg "Config existente en $ENV_FILE (se conserva JWT y claves ajenas)"
    fi
    # Reconciliar SIEMPRE las claves gestionadas por flags (idempotente).
    reconcile_env
    chown genieacs:genieacs "$ENV_FILE"; chmod 600 "$ENV_FILE"
    [ "$ENV_CHANGED" = "1" ] && msg "Config de interfaces/workers ajustada a los flags actuales"
}

create_services() {
    local svc bin changed=0 tmp target
    bin=$(dirname "$(command -v genieacs-cwmp)")
    for svc in cwmp nbi fs ui; do
        target="/etc/systemd/system/genieacs-${svc}.service"
        tmp=$(mktemp)
        cat > "$tmp" <<EOF
[Unit]
Description=GenieACS ${svc^^}
After=network.target mongod.service

[Service]
User=genieacs
Group=genieacs
EnvironmentFile=${ENV_FILE}
ExecStart=${bin}/genieacs-${svc}
Restart=on-failure
RestartSec=5

# Hardening prudente (no rompe extensiones/logs; sin ProtectSystem=strict)
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
UMask=0077
LimitNOFILE=65536
TasksMax=8192

[Install]
WantedBy=multi-user.target
EOF
        if ! cmp -s "$tmp" "$target" 2>/dev/null; then
            mv "$tmp" "$target"; changed=1
        else
            rm -f "$tmp"
        fi
    done

    cat > /etc/logrotate.d/genieacs <<'EOF'
/var/log/genieacs/*.log /var/log/genieacs/*.yaml {
    daily
    rotate 30
    maxsize 100M
    compress
    delaycompress
    copytruncate
    dateext
    missingok
    notifempty
}
EOF

    systemctl daemon-reload
    for svc in cwmp nbi fs ui; do
        systemctl enable --now "genieacs-${svc}" >>"$INSTALL_LOG" 2>&1
    done
    # Si el unit o el .env cambiaron y el servicio ya estaba activo, reiniciar
    # para que tomen la nueva definicion (enable --now NO reinicia lo ya activo).
    if [ "$changed" = "1" ] || [ "$ENV_CHANGED" = "1" ]; then
        for svc in cwmp nbi fs ui; do
            systemctl restart "genieacs-${svc}" >>"$INSTALL_LOG" 2>&1
        done
    fi
    sleep 2
    for svc in cwmp nbi fs ui; do
        systemctl is-active --quiet "genieacs-${svc}" \
            && msg "genieacs-${svc} activo" \
            || warn "genieacs-${svc} NO arranco (journalctl -u genieacs-${svc})"
    done
}

#---------------------------------------------------------------
# Respaldo automatico (mongodump comprimido + timer diario)
#---------------------------------------------------------------
setup_backup() {
    ensure_db_tools
    # ACS-18: preservar el destino remoto si se reinstala sin --backup-remote.
    if [ -z "$BACKUP_REMOTE" ] && [ -f "$BACKUP_BIN" ]; then
        BACKUP_REMOTE=$(sed -n 's/^REMOTE="\(.*\)"$/\1/p' "$BACKUP_BIN" 2>/dev/null | head -1)
        [ -n "$BACKUP_REMOTE" ] && warn "Conservando destino de copia remota previo: $BACKUP_REMOTE"
    fi
    cat > "$BACKUP_BIN" <<EOF
#!/bin/bash
# Respaldo de GenieACS (dump Mongo + bundle de config). Generado por el instalador.
set -u
DIR="${BACKUP_DIR}"
KEEP=${BACKUP_KEEP}
REMOTE="${BACKUP_REMOTE}"
ENV_FILE="${ENV_FILE}"
EXT_DIR="${EXT_DIR}"
TLS_DIR="${TLS_DIR}"
mkdir -p "\$DIR"
STAMP=\$(date +%F-%H%M%S)
OUT="\$DIR/genieacs-\$STAMP.archive.gz"
FILES="\$DIR/genieacs-\$STAMP-files.tar.gz"
rc=0
# --- dump Mongo (escritura atomica: .tmp -> mv al terminar) ---
if mongodump --db genieacs --gzip --archive="\$OUT.tmp" >/dev/null 2>&1; then
    mv -f "\$OUT.tmp" "\$OUT"
    echo "\$(date '+%F %T') backup DB OK: \$OUT (\$(du -h "\$OUT" | cut -f1))"
else
    rm -f "\$OUT.tmp"
    echo "\$(date '+%F %T') backup DB FALLO" >&2; exit 1
fi
# --- ACS-19: bundle de recuperacion (env, extensiones, units, TLS, logrotate) ---
tar -czf "\$FILES.tmp" \
    "\$ENV_FILE" "\$EXT_DIR" "\$TLS_DIR" \
    /etc/systemd/system/genieacs-*.service /etc/systemd/system/genieacs-backup.* \
    /etc/logrotate.d/genieacs 2>/dev/null && mv -f "\$FILES.tmp" "\$FILES" || rm -f "\$FILES.tmp"
# --- copia off-box opcional (ACS-18: su fallo deja estado degradado, exit 2) ---
if [ -n "\$REMOTE" ]; then
    if rsync -a "\$OUT" "\$FILES" "\$REMOTE"/ 2>/dev/null || scp -q "\$OUT" "\$FILES" "\$REMOTE" 2>/dev/null; then
        echo "\$(date '+%F %T') copia remota OK -> \$REMOTE"
    else
        echo "\$(date '+%F %T') copia remota FALLO (\$REMOTE); el dump local SI existe" >&2; rc=2
    fi
fi
# retencion: conservar los ultimos \$KEEP locales (dumps y bundles)
ls -1t "\$DIR"/genieacs-*.archive.gz 2>/dev/null | tail -n +\$((KEEP+1)) | xargs -r rm -f
ls -1t "\$DIR"/genieacs-*-files.tar.gz 2>/dev/null | tail -n +\$((KEEP+1)) | xargs -r rm -f
exit \$rc
EOF
    chmod 700 "$BACKUP_BIN"

    cat > /etc/systemd/system/genieacs-backup.service <<EOF
[Unit]
Description=Respaldo de la base GenieACS
After=mongod.service

[Service]
Type=oneshot
ExecStart=${BACKUP_BIN}
EOF
    cat > /etc/systemd/system/genieacs-backup.timer <<'EOF'
[Unit]
Description=Respaldo diario de GenieACS

[Timer]
OnCalendar=*-*-* 03:30:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now genieacs-backup.timer >>"$INSTALL_LOG" 2>&1
    msg "Respaldo diario configurado: ${BACKUP_DIR} (03:30, conserva ${BACKUP_KEEP})"
    [ -n "$BACKUP_REMOTE" ] && msg "Copia off-box a: ${BACKUP_REMOTE}"
}

#---------------------------------------------------------------
# Reverse proxy TLS (solo --prod)
#---------------------------------------------------------------
setup_reverse_proxy() {
    local server_name="${DOMAIN:-$(detect_ip)}"
    command -v nginx >/dev/null 2>&1 || { echo "Instalando nginx..."; run apt-get install -y nginx; }

    # ACS-15: si ya hay un cert Let's Encrypt emitido para el dominio, usarlo y
    # NO pisarlo con el self-signed al reinstalar.
    local crt key le_live="/etc/letsencrypt/live/${DOMAIN}"
    if [ -n "$DOMAIN" ] && [ -f "${le_live}/fullchain.pem" ]; then
        crt="${le_live}/fullchain.pem"; key="${le_live}/privkey.pem"
        msg "Usando certificado Let's Encrypt existente para ${DOMAIN}"
    else
        mkdir -p "$TLS_DIR"
        if [ ! -f "$TLS_DIR/acs.crt" ]; then
            run openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
                -keyout "$TLS_DIR/acs.key" -out "$TLS_DIR/acs.crt" -subj "/CN=${server_name}"
            chmod 600 "$TLS_DIR/acs.key"
        fi
        crt="$TLS_DIR/acs.crt"; key="$TLS_DIR/acs.key"
    fi

    # ACS-16: FS local necesita publicarse; si --fs-local se agrega location /fs/.
    local fs_block=""
    if [ "$FS_LOCAL" = "1" ]; then
        fs_block=$'    location /fs/ {\n        proxy_pass http://127.0.0.1:7567/;\n        proxy_set_header Host $host;\n        client_max_body_size 512m;\n    }\n'
    fi

    cat > /etc/nginx/sites-available/genieacs <<EOF
server {
    listen 80;
    server_name ${server_name};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl;
    server_name ${server_name};

    ssl_certificate     ${crt};
    ssl_certificate_key ${key};
    ssl_protocols TLSv1.2 TLSv1.3;

    # ACS-17: firmwares grandes por la UI (por defecto nginx corta en 1 MiB).
    client_max_body_size 512m;

${fs_block}    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 120s;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/genieacs /etc/nginx/sites-enabled/genieacs
    if nginx -t >>"$INSTALL_LOG" 2>&1; then
        run systemctl reload nginx
        msg "Reverse proxy TLS en https://${server_name} -> UI 127.0.0.1:3000"
    else
        warn "nginx -t fallo; revisa /etc/nginx/sites-available/genieacs y $INSTALL_LOG"
        return
    fi

    # ACS-15: emitir el cert real (no solo instalar certbot). Requiere que el
    # dominio resuelva a esta maquina y el :80 sea alcanzable (no aplica en LAN).
    if [ "$USE_LE" = "1" ] && [ -n "$DOMAIN" ]; then
        run apt-get install -y certbot python3-certbot-nginx
        if certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect >>"$INSTALL_LOG" 2>&1; then
            msg "Let's Encrypt: certificado emitido y renovacion automatica activa para ${DOMAIN}"
        else
            warn "Let's Encrypt NO pudo emitir (dominio no resoluble o :80 inalcanzable, tipico en LAN); queda el certificado self-signed"
        fi
    elif [ "$USE_LE" = "1" ]; then
        warn "--letsencrypt requiere --domain; queda self-signed"
    fi
}

configure_firewall() {
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active" || return
    ufw allow 7547/tcp comment 'GenieACS CWMP (CPEs)' >>"$INSTALL_LOG" 2>&1
    if [ "$PROD_MODE" = "1" ]; then
        ufw allow 443/tcp comment 'GenieACS UI (nginx TLS)' >>"$INSTALL_LOG" 2>&1
        ufw allow 80/tcp  comment 'GenieACS UI (redir)'     >>"$INSTALL_LOG" 2>&1
        msg "UFW: abiertos 7547 (CWMP), 80/443 (UI TLS). UI directa 3000 NO expuesta."
        [ "$NBI_LOCAL" != "1" ] && warn "NBI 7557 sigue en 0.0.0.0: restringela por firewall a IPs de confianza"
    else
        ufw allow 3000/tcp comment 'GenieACS UI' >>"$INSTALL_LOG" 2>&1
        msg "UFW: abiertos 7547 (CWMP) y 3000 (UI)"
        warn "NBI 7557 y FS 7567 NO se abrieron: exponerlos solo a IPs de confianza"
    fi
}

#---------------------------------------------------------------
# Auditoria PASS/WARN/FAIL (reusable: install.sh status)
#---------------------------------------------------------------
# Devuelve 0 si el bindIp de mongod es SOLO loopback (127.0.0.1/::1), 1 si no.
mongo_bind_localhost_only() {
    local bip
    bip=$(grep -E "^\s*bindIp:" "$MONGOD_CONF" 2>/dev/null | head -1 | sed 's/.*bindIp:[[:space:]]*//; s/#.*//; s/[[:space:]]//g')
    [ -n "$bip" ] || return 1
    # si hay algun token que NO sea loopback -> NO es solo-localhost (return 1)
    if echo "$bip" | tr ',' '\n' | grep -qvE '^(127\.0\.0\.1|::1)$'; then
        return 1
    fi
    return 0
}

do_status() {
    local p="${G}[PASS]${N}" w="${Y}[WARN]${N}" f="${R}[FAIL]${N}" fails=0
    echo -e "${C}--------- ESTADO GenieACS ---------${N}"

    # OJO: `genieacs-cwmp --version` NO imprime version, ARRANCA el servicio
    # (intenta bindear :7547). Leer la version por npm, que es read-only.
    if command -v genieacs-cwmp >/dev/null 2>&1; then
        local gver; gver=$(npm ls -g genieacs 2>/dev/null | awk -F@ '/genieacs@/{print $2; exit}')
        echo -e "$p GenieACS instalado (${gver:-version?})"
    else
        echo -e "$f GenieACS no instalado"; fails=$((fails+1))
    fi

    local nm; nm=$(node -p "process.versions.node.split('.')[0]" 2>/dev/null)
    [ "$nm" = "$NODE_MAJOR" ] \
        && echo -e "$p Node.js $(node -v)" \
        || echo -e "$w Node.js $(node -v 2>/dev/null) (el stack fija ${NODE_MAJOR}.x)"

    local mm; mm=$(mongod --version 2>/dev/null | awk '/db version/ {gsub("v","",$3); split($3,a,"."); print a[1]}')
    [ "$mm" = "$MONGO_MAJOR" ] \
        && echo -e "$p MongoDB v${mm}.x" \
        || echo -e "$w MongoDB v${mm:-?}.x (el stack fija ${MONGO_VERSION})"

    if mongo_bind_localhost_only; then
        echo -e "$p MongoDB escucha solo en localhost"
    else
        echo -e "$w MongoDB bind NO es solo localhost: revisar /etc/mongod.conf"
    fi

    local svc down=""
    for svc in cwmp nbi fs ui; do
        systemctl is-active --quiet "genieacs-${svc}" || down="$down $svc"
    done
    if [ -z "$down" ]; then echo -e "$p 4 servicios activos"
    else echo -e "$f Servicio(s) caido(s):${down} (journalctl -u genieacs-*)"; fails=$((fails+1)); fi

    if id genieacs >/dev/null 2>&1; then echo -e "$p usuario genieacs (no-root) existe"
    else echo -e "$f usuario genieacs ausente"; fails=$((fails+1)); fi

    # JWT debe existir Y tener valor (no vacio ni comentado)
    grep -qE "^GENIEACS_UI_JWT_SECRET=.+" "$ENV_FILE" 2>/dev/null \
        && echo -e "$p JWT de UI presente" \
        || { echo -e "$f JWT de UI ausente o vacio"; fails=$((fails+1)); }

    [ "$(stat -c '%a' "$ENV_FILE" 2>/dev/null)" = "600" ] \
        && echo -e "$p Permisos ${ENV_FILE} = 600" || echo -e "$w Permisos de ${ENV_FILE} != 600"

    [ -f /etc/logrotate.d/genieacs ] && command -v logrotate >/dev/null 2>&1 \
        && echo -e "$p logrotate instalado y configurado" \
        || echo -e "$w logrotate ausente o sin binario"

    systemctl is-enabled --quiet genieacs-backup.timer 2>/dev/null \
        && echo -e "$p Respaldo diario activo (${BACKUP_DIR})" || echo -e "$w Respaldo diario no activo"

    # bind anclado y sin comentar (una linea '#...' NO cuenta como aplicado)
    if grep -qE "^GENIEACS_UI_INTERFACE=127\.0\.0\.1" "$ENV_FILE" 2>/dev/null; then
        echo -e "$p UI ligada a localhost (reverse proxy)"
    else
        echo -e "$w UI en 0.0.0.0 (ok en red local; --prod si se expone)"
    fi

    # datos operativos si mongosh esta disponible
    if command -v mongosh >/dev/null 2>&1; then
        local d t fa
        d=$(mongosh --quiet genieacs --eval 'db.devices.countDocuments({})' 2>/dev/null)
        t=$(mongosh --quiet genieacs --eval 'db.tasks.countDocuments({})' 2>/dev/null)
        fa=$(mongosh --quiet genieacs --eval 'db.faults.countDocuments({})' 2>/dev/null)
        echo -e "${C}--- Mongo: devices=${d:-?} tasks=${t:-?} faults=${fa:-?} ---${N}"
    fi
    if [ "$fails" -eq 0 ]; then
        echo -e "${C}--- estado: OK (0 FAIL) ---${N}"; return 0
    fi
    echo -e "${R}--- estado: ${fails} FAIL ---${N}"; return 1
}

show_summary() {
    local ip; ip=$(detect_ip)
    echo ""
    echo -e "${C}===============================================${N}"
    echo -e "${G} GenieACS ${GENIEACS_VERSION} instalado${N}"
    echo -e "${C}===============================================${N}"
    echo ""
    if [ "$PROD_MODE" = "1" ]; then
        echo "  UI (web):        https://${DOMAIN:-$ip}  (reverse proxy TLS)"
        echo "  CWMP (CPEs):     http://${ip}:7547"
    else
        echo "  UI (web):        http://${ip}:3000"
        echo "  CWMP (CPEs):     http://${ip}:7547"
        echo "  NBI (API):       http://${ip}:7557"
        echo "  FS (firmwares):  http://${ip}:7567"
    fi
    echo ""
    echo "  Primer acceso a la UI: pulsar el boton para crear la"
    echo "  configuracion por defecto -> login admin / admin"
    echo "  (cambiar la clave en Admin > Users)"
    echo ""
    echo "  Config:      $ENV_FILE"
    echo "  Extensiones: $EXT_DIR"
    echo "  Logs:        $LOG_DIR   ·   Instalacion: $INSTALL_LOG"
    echo "  Respaldos:   $BACKUP_DIR (timer diario; 'install.sh backup|restore|status')"
    echo ""
    warn "El respaldo vive en la MISMA VM: copiar a un NAS externo (--backup-remote)"
    warn "Por defecto acepta cualquier CPE: configurar cwmp.auth en Admin > Config"
    [ "$PROD_MODE" != "1" ] && warn "Si expones a internet: reinstalar con --prod (UI tras TLS)"
}

#---------------------------------------------------------------
# Acciones operativas
#---------------------------------------------------------------
do_backup() {
    [ -x "$BACKUP_BIN" ] || err "Falta ${BACKUP_BIN}; corre la instalacion primero"
    "$BACKUP_BIN"
}

do_restore() {
    local file="$1"
    [ "$(id -u)" -eq 0 ] || err "Ejecutar como root"
    command -v mongorestore >/dev/null 2>&1 || err "mongorestore ausente (apt-get install -y mongodb-database-tools)"
    [ -n "$file" ] || { echo "Respaldos disponibles en ${BACKUP_DIR}:"; ls -1t "${BACKUP_DIR}"/genieacs-*.archive.gz 2>/dev/null; err "Uso: install.sh restore <archivo.archive.gz>"; }
    [ -f "$file" ] || err "No existe el archivo: $file"
    warn "Esto REEMPLAZA la base genieacs con el respaldo (mongorestore --drop)."
    read -rp "Continuar? [s/N]: " ok < /dev/tty
    [ "$ok" = "s" ] || [ "$ok" = "S" ] || { echo "Cancelado"; return; }
    if mongorestore --gzip --archive="$file" --drop; then
        msg "Restauracion completada desde $file"
    else
        err "Fallo la restauracion"
    fi
}

do_update() {
    check_system
    command -v genieacs-cwmp >/dev/null 2>&1 || err "GenieACS no esta instalado; usa 'install' primero"
    log_init
    local old_ver
    old_ver=$(npm ls -g genieacs 2>/dev/null | awk -F@ '/genieacs@/{print $2; exit}')
    echo "Version actual: ${old_ver:-desconocida}  ->  objetivo: ${GENIEACS_VERSION}"

    # ACS-07: el respaldo es PRECONDICION DURA. Sin respaldo utilizable, no se muta.
    [ -x "$BACKUP_BIN" ] || err "No hay script de respaldo (${BACKUP_BIN}); reinstala. NO se actualiza sin respaldo."
    echo "Respaldando antes de actualizar..."
    "$BACKUP_BIN"; local brc=$?
    # exit 2 = dump local OK pero copia remota fallo; distinto de dump fallido (1)
    if [ "$brc" = "2" ]; then
        warn "Copia remota fallo, pero el dump local existe; continuo"
    elif [ "$brc" != "0" ]; then
        err "El respaldo FALLO (rc=$brc); se aborta la actualizacion (no mutar sin respaldo)."
    fi

    run npm install -g "genieacs@${GENIEACS_VERSION}" || err "Fallo npm install genieacs (sin cambios de servicio; respaldo intacto)"
    local svc
    for svc in cwmp nbi fs ui; do
        systemctl restart "genieacs-${svc}" >>"$INSTALL_LOG" 2>&1
    done
    sleep 2
    # ACS-07/11: si algo quedo caido, el update NO se declara exitoso.
    if do_status; then
        msg "Actualizacion OK (${old_ver:-?} -> ${GENIEACS_VERSION})"
    else
        err "Tras actualizar hay servicios caidos. Respaldo en ${BACKUP_DIR} (restore con: install.sh restore <archivo>)."
    fi
}

#---------------------------------------------------------------
# Desinstalar
#---------------------------------------------------------------
uninstall_genieacs() {
    echo ""
    read -rp "Esto elimina GenieACS y sus servicios. Continuar? [s/N]: " ok < /dev/tty
    [ "$ok" = "s" ] || [ "$ok" = "S" ] || { echo "Cancelado"; return; }

    local svc
    for svc in cwmp nbi fs ui; do
        systemctl disable --now "genieacs-${svc}" >/dev/null 2>&1
        rm -f "/etc/systemd/system/genieacs-${svc}.service"
    done
    systemctl disable --now genieacs-backup.timer >/dev/null 2>&1
    rm -f /etc/systemd/system/genieacs-backup.timer /etc/systemd/system/genieacs-backup.service "$BACKUP_BIN"
    systemctl daemon-reload
    npm uninstall -g genieacs >/dev/null 2>&1
    rm -f /etc/logrotate.d/genieacs
    msg "Servicios, timer de respaldo y paquete eliminados"
    warn "Se conservan los respaldos en $BACKUP_DIR (borrar a mano si se quiere)"

    read -rp "Borrar la base 'genieacs' y /opt/genieacs? [s/N]: " ok < /dev/tty
    if [ "$ok" = "s" ] || [ "$ok" = "S" ]; then
        if command -v mongosh >/dev/null 2>&1; then
            mongosh --quiet --eval 'db.getSiblingDB("genieacs").dropDatabase()' >/dev/null 2>&1 \
                && msg "Base 'genieacs' eliminada (las demas bases quedan intactas)"
        fi
        rm -rf /opt/genieacs "$LOG_DIR"
        msg "/opt/genieacs y logs eliminados"
        # ACS-10: la purga del motor borra /var/lib/mongodb = TODAS las bases.
        # Solo con confirmacion explicita de que el motor es dedicado al ACS.
        warn "Purgar el motor MongoDB elimina /var/lib/mongodb: TODAS las bases, no solo genieacs."
        read -rp "Si MongoDB es DEDICADO al ACS, escribe DEDICADO para purgar el motor: " full < /dev/tty
        if [ "$full" = "DEDICADO" ]; then
            systemctl disable --now mongod >/dev/null 2>&1
            apt-get purge -y 'mongodb-org*' >/dev/null 2>&1
            rm -rf /var/lib/mongodb /etc/apt/sources.list.d/mongodb-org.list
            msg "Motor MongoDB purgado por completo"
        else
            msg "Se conserva el motor MongoDB y las demas bases"
        fi
    fi
}

do_install() {
    log_init
    check_system
    run apt-get update
    # logrotate: en algunas imagenes minimas (Debian cloud) NO viene; sin el, la
    # config de /etc/logrotate.d/genieacs no rota nada y los access logs crecen.
    run apt-get install -y curl gnupg openssl logrotate
    install_node
    install_mongodb
    install_genieacs
    create_services
    setup_backup
    [ "$PROD_MODE" = "1" ] && setup_reverse_proxy
    configure_firewall
    show_summary
    echo ""
    do_status
}

#---------------------------------------------------------------
# Parseo de argumentos + dispatch
#---------------------------------------------------------------
# need_val: exige que el flag traiga un valor y que ese valor no sea otro flag.
need_val() { case "${2:-}" in ""|-*) err "La opcion $1 requiere un valor";; esac; }

# main() envuelve todo el flujo para que los tests puedan hacer `source` del
# script y probar funciones sin dispararlo (guardia BASH_SOURCE al final).
main() {
ACTION=""
RESTORE_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        install|--install)     ACTION="install" ;;
        uninstall|--uninstall) ACTION="uninstall" ;;
        backup|--backup)       ACTION="backup" ;;
        status|--status)       ACTION="status" ;;
        update|--update)       ACTION="update" ;;
        restore|--restore)
            ACTION="restore"
            # el archivo es opcional (sin el, lista los disponibles)
            if [ -n "${2:-}" ] && [ "${2#-}" = "${2:-}" ]; then RESTORE_FILE="$2"; shift; fi ;;
        --prod)                PROD_MODE=1 ;;
        --nbi-local)           NBI_LOCAL=1 ;;
        --fs-local)            FS_LOCAL=1 ;;
        --letsencrypt|--le)    USE_LE=1 ;;
        --domain)              need_val "--domain" "${2:-}"; DOMAIN="$2"; shift ;;
        --backup-remote)       need_val "--backup-remote" "${2:-}"; BACKUP_REMOTE="$2"; shift ;;
        --workers)
            need_val "--workers" "${2:-}"; WORKERS="$2"; shift
            case "$WORKERS" in ''|*[!0-9]*) err "--workers debe ser un entero (recibido: $WORKERS)";; esac
            [ "$WORKERS" -ge 1 ] || err "--workers debe ser >= 1" ;;
        -h|--help)             usage; exit 0 ;;
        -v|--version)          echo "installer ${INSTALLER_VERSION} (GenieACS ${GENIEACS_VERSION})"; exit 0 ;;
        *)                     err "Opcion/argumento no reconocido: $1 (usa --help)" ;;
    esac
    shift
done

# Validaciones de combinaciones (ACS-16): FS local necesita proxy + dominio.
if [ "$FS_LOCAL" = "1" ]; then
    [ "$PROD_MODE" = "1" ] || err "--fs-local requiere --prod (el FS se publica por el reverse proxy)"
    [ -n "$DOMAIN" ] || err "--fs-local requiere --domain (para GENIEACS_FS_URL_PREFIX y el proxy /fs/)"
fi
[ "$USE_LE" = "1" ] && [ -z "$DOMAIN" ] && err "--letsencrypt requiere --domain"

banner

if [ -z "$ACTION" ]; then
    echo "  1) Instalar GenieACS"
    echo "  2) Desinstalar"
    echo "  3) Respaldo ahora"
    echo "  4) Estado / auditoria"
    echo "  5) Salir"
    echo ""
    [ "$PROD_MODE" = "1" ] && warn "modo --prod activo"
    read -rp "Opcion [1]: " opt < /dev/tty
    case "${opt:-1}" in
        1) ACTION="install" ;;
        2) ACTION="uninstall" ;;
        3) ACTION="backup" ;;
        4) ACTION="status" ;;
        *) echo "Saliendo"; exit 0 ;;
    esac
fi

case "$ACTION" in
    install)   do_install ;;
    uninstall) uninstall_genieacs ;;
    backup)    do_backup ;;
    restore)   do_restore "$RESTORE_FILE" ;;
    status)    do_status ;;
    update)    do_update ;;
    *)         usage; exit 1 ;;
esac
}

# Solo ejecuta main si el script se corre directamente (no si se hace `source`,
# como en los tests de regresion).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
