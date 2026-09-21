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
INSTALLER_VERSION="2.0.0"
NODE_MAJOR="20"
NODE_MIN="18"                 # minimo compatible con GenieACS 1.2.x
MONGO_VERSION="8.0"
MONGO_MAJOR="${MONGO_VERSION%%.*}"

ENV_FILE="/opt/genieacs/genieacs.env"
EXT_DIR="/opt/genieacs/ext"
LOG_DIR="/var/log/genieacs"
INSTALL_LOG="/var/log/genieacs-install.log"
BACKUP_DIR="/root/backups/genieacs"
BACKUP_BIN="/usr/local/sbin/genieacs-backup.sh"
BACKUP_KEEP=14
TLS_DIR="/etc/genieacs/tls"

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

install_genieacs() {
    echo "Instalando GenieACS ${GENIEACS_VERSION} via npm..."
    run npm install -g "genieacs@${GENIEACS_VERSION}" || err "Fallo npm install genieacs"
    msg "GenieACS instalado: $(command -v genieacs-cwmp)"

    id genieacs >/dev/null 2>&1 || useradd --system --no-create-home --user-group genieacs

    mkdir -p "$EXT_DIR" "$LOG_DIR"
    chown genieacs:genieacs "$EXT_DIR" "$LOG_DIR"

    if [ ! -f "$ENV_FILE" ]; then
        local jwt workers
        jwt=$(node -e "console.log(require('crypto').randomBytes(64).toString('hex'))")
        workers=$(compute_workers)
        {
            echo "GENIEACS_CWMP_ACCESS_LOG_FILE=${LOG_DIR}/genieacs-cwmp-access.log"
            echo "GENIEACS_NBI_ACCESS_LOG_FILE=${LOG_DIR}/genieacs-nbi-access.log"
            echo "GENIEACS_FS_ACCESS_LOG_FILE=${LOG_DIR}/genieacs-fs-access.log"
            echo "GENIEACS_UI_ACCESS_LOG_FILE=${LOG_DIR}/genieacs-ui-access.log"
            echo "NODE_OPTIONS=--enable-source-maps"
            echo "GENIEACS_EXT_DIR=${EXT_DIR}"
            echo "GENIEACS_UI_JWT_SECRET=${jwt}"
            if [ -n "$workers" ]; then
                local s
                for s in CWMP NBI FS UI; do echo "GENIEACS_${s}_WORKER_PROCESSES=${workers}"; done
            fi
            [ "$PROD_MODE" = "1" ] && echo "GENIEACS_UI_INTERFACE=127.0.0.1"
            [ "$NBI_LOCAL" = "1" ] && echo "GENIEACS_NBI_INTERFACE=127.0.0.1"
            [ "$FS_LOCAL" = "1" ]  && echo "GENIEACS_FS_INTERFACE=127.0.0.1"
        } > "$ENV_FILE"
        chown genieacs:genieacs "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        msg "Config creada en $ENV_FILE (JWT secret generado)"
        [ -n "$workers" ] && msg "Workers por servicio: ${workers} (VM con poca RAM)"
        [ "$PROD_MODE" = "1" ] && msg "Modo --prod: UI ligada a 127.0.0.1"
    else
        msg "Config existente en $ENV_FILE (se conserva)"
        [ "$PROD_MODE" = "1" ] && warn "El env ya existia: revisa manualmente GENIEACS_UI_INTERFACE=127.0.0.1 para --prod"
    fi
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
    # Si el unit cambio y el servicio ya estaba activo, hay que reiniciar para
    # que tome la nueva definicion (enable --now NO reinicia lo ya activo).
    if [ "$changed" = "1" ]; then
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
    cat > "$BACKUP_BIN" <<EOF
#!/bin/bash
# Respaldo de la base GenieACS (mongodump comprimido). Generado por el instalador.
set -u
DIR="${BACKUP_DIR}"
KEEP=${BACKUP_KEEP}
REMOTE="${BACKUP_REMOTE}"
mkdir -p "\$DIR"
OUT="\$DIR/genieacs-\$(date +%F-%H%M).archive.gz"
if mongodump --db genieacs --gzip --archive="\$OUT" >/dev/null 2>&1; then
    echo "\$(date '+%F %T') backup OK: \$OUT (\$(du -h "\$OUT" | cut -f1))"
else
    echo "\$(date '+%F %T') backup FALLO" >&2; exit 1
fi
# copia off-box opcional
if [ -n "\$REMOTE" ]; then
    rsync -a "\$OUT" "\$REMOTE"/ 2>/dev/null \
        || scp -q "\$OUT" "\$REMOTE" 2>/dev/null \
        || echo "\$(date '+%F %T') copia remota FALLO (\$REMOTE)" >&2
fi
# retencion: conservar los ultimos \$KEEP locales
ls -1t "\$DIR"/genieacs-*.archive.gz 2>/dev/null | tail -n +\$((KEEP+1)) | xargs -r rm -f
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

    if [ "$USE_LE" = "1" ] && [ -n "$DOMAIN" ]; then
        run apt-get install -y certbot python3-certbot-nginx
    fi

    mkdir -p "$TLS_DIR"
    if [ ! -f "$TLS_DIR/acs.crt" ]; then
        run openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$TLS_DIR/acs.key" -out "$TLS_DIR/acs.crt" \
            -subj "/CN=${server_name}"
        chmod 600 "$TLS_DIR/acs.key"
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

    ssl_certificate     ${TLS_DIR}/acs.crt;
    ssl_certificate_key ${TLS_DIR}/acs.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
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
        [ "$USE_LE" = "1" ] && [ -n "$DOMAIN" ] && \
            warn "Para cert Let's Encrypt real: certbot --nginx -d ${DOMAIN}"
    else
        warn "nginx -t fallo; revisa /etc/nginx/sites-available/genieacs y $INSTALL_LOG"
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
do_status() {
    local p="${G}[PASS]${N}" w="${Y}[WARN]${N}" f="${R}[FAIL]${N}"
    echo -e "${C}--------- ESTADO GenieACS ---------${N}"

    # OJO: `genieacs-cwmp --version` NO imprime version, ARRANCA el servicio
    # (intenta bindear :7547). Leer la version por npm, que es read-only.
    if command -v genieacs-cwmp >/dev/null 2>&1; then
        local gver; gver=$(npm ls -g genieacs 2>/dev/null | awk -F@ '/genieacs@/{print $2; exit}')
        echo -e "$p GenieACS instalado (${gver:-version?})"
    else
        echo -e "$f GenieACS no instalado"
    fi

    local nm; nm=$(node -p "process.versions.node.split('.')[0]" 2>/dev/null)
    [ "$nm" = "$NODE_MAJOR" ] \
        && echo -e "$p Node.js $(node -v)" \
        || echo -e "$w Node.js $(node -v 2>/dev/null) (el stack fija ${NODE_MAJOR}.x)"

    local mm; mm=$(mongod --version 2>/dev/null | awk '/db version/ {gsub("v","",$3); split($3,a,"."); print a[1]}')
    [ "$mm" = "$MONGO_MAJOR" ] \
        && echo -e "$p MongoDB v${mm}.x" \
        || echo -e "$w MongoDB v${mm:-?}.x (el stack fija ${MONGO_VERSION})"

    if grep -qE "bindIp:\s*127\.0\.0\.1" /etc/mongod.conf 2>/dev/null && ! grep -qE "bindIp:.*0\.0\.0\.0" /etc/mongod.conf 2>/dev/null; then
        echo -e "$p MongoDB escucha solo en localhost"
    else
        echo -e "$w MongoDB bind: revisar /etc/mongod.conf"
    fi

    local svc allok=1
    for svc in cwmp nbi fs ui; do
        systemctl is-active --quiet "genieacs-${svc}" || allok=0
    done
    [ "$allok" = "1" ] && echo -e "$p 4 servicios activos" || echo -e "$f Algun servicio genieacs caido (journalctl -u genieacs-*)"

    id genieacs >/dev/null 2>&1 \
        && echo -e "$p Servicios como usuario genieacs (no-root)" \
        || echo -e "$f usuario genieacs ausente"

    grep -q "GENIEACS_UI_JWT_SECRET=" "$ENV_FILE" 2>/dev/null \
        && echo -e "$p JWT de UI generado" || echo -e "$w JWT de UI ausente"

    [ "$(stat -c '%a' "$ENV_FILE" 2>/dev/null)" = "600" ] \
        && echo -e "$p Permisos ${ENV_FILE} = 600" || echo -e "$w Permisos de ${ENV_FILE}"

    [ -f /etc/logrotate.d/genieacs ] \
        && echo -e "$p logrotate configurado" || echo -e "$w logrotate ausente"

    systemctl is-enabled --quiet genieacs-backup.timer 2>/dev/null \
        && echo -e "$p Respaldo diario activo (${BACKUP_DIR})" || echo -e "$w Respaldo diario no activo"

    if grep -q "GENIEACS_UI_INTERFACE=127.0.0.1" "$ENV_FILE" 2>/dev/null; then
        echo -e "$p UI ligada a localhost (reverse proxy)"
    else
        echo -e "$w UI/NBI/FS escuchan en 0.0.0.0 (ok en red local; usa --prod si se expone)"
    fi
    echo -e "$w CWMP en HTTP sin TLS (ok en red local; TLS si se expone a internet)"
    echo -e "$w cwmp.auth pendiente: por defecto acepta cualquier CPE (Admin > Config)"

    # datos operativos si mongosh esta disponible
    if command -v mongosh >/dev/null 2>&1; then
        local d t fa
        d=$(mongosh --quiet genieacs --eval 'db.devices.countDocuments({})' 2>/dev/null)
        t=$(mongosh --quiet genieacs --eval 'db.tasks.countDocuments({})' 2>/dev/null)
        fa=$(mongosh --quiet genieacs --eval 'db.faults.countDocuments({})' 2>/dev/null)
        echo -e "${C}--- Mongo: devices=${d:-?} tasks=${t:-?} faults=${fa:-?} ---${N}"
    fi
    echo -e "${C}-----------------------------------${N}"
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
    warn "Actualizando GenieACS a ${GENIEACS_VERSION}. Se respalda antes."
    [ -x "$BACKUP_BIN" ] && "$BACKUP_BIN"
    run npm install -g "genieacs@${GENIEACS_VERSION}" || err "Fallo npm install genieacs"
    local svc
    for svc in cwmp nbi fs ui; do
        systemctl restart "genieacs-${svc}" >>"$INSTALL_LOG" 2>&1
    done
    sleep 2
    do_status
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

    read -rp "Borrar tambien MongoDB, base de datos y /opt/genieacs? [s/N]: " ok < /dev/tty
    if [ "$ok" = "s" ] || [ "$ok" = "S" ]; then
        systemctl disable --now mongod >/dev/null 2>&1
        apt-get purge -y 'mongodb-org*' >/dev/null 2>&1
        rm -rf /var/lib/mongodb /etc/apt/sources.list.d/mongodb-org.list /opt/genieacs "$LOG_DIR"
        msg "MongoDB y datos eliminados"
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
ACTION=""
RESTORE_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        install|--install)     ACTION="install" ;;
        uninstall|--uninstall) ACTION="uninstall" ;;
        backup|--backup)       ACTION="backup" ;;
        restore|--restore)     ACTION="restore"; shift; RESTORE_FILE="${1:-}" ;;
        status|--status)       ACTION="status" ;;
        update|--update)       ACTION="update" ;;
        --prod)                PROD_MODE=1 ;;
        --nbi-local)           NBI_LOCAL=1 ;;
        --fs-local)            FS_LOCAL=1 ;;
        --letsencrypt|--le)    USE_LE=1 ;;
        --domain)              shift; DOMAIN="${1:-}" ;;
        --workers)             shift; WORKERS="${1:-}" ;;
        --backup-remote)       shift; BACKUP_REMOTE="${1:-}" ;;
        -h|--help)             usage; exit 0 ;;
        -v|--version)          echo "installer ${INSTALLER_VERSION} (GenieACS ${GENIEACS_VERSION})"; exit 0 ;;
        *)                     warn "Opcion desconocida: $1" ;;
    esac
    shift
done

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
