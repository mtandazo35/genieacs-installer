#!/bin/bash
#===============================================================
# GenieACS Installer - Debian 12/13 y Ubuntu 22.04/24.04
# ACS TR-069 (CWMP) para gestion remota de CPEs/ONUs
# https://github.com/mtandazo35/genieacs-installer
#===============================================================

GENIEACS_VERSION="1.2.16"
INSTALLER_VERSION="1.1.0"
NODE_MAJOR="20"
NODE_MIN="18"                 # minimo compatible con GenieACS 1.2.x
MONGO_VERSION="8.0"
ENV_FILE="/opt/genieacs/genieacs.env"
EXT_DIR="/opt/genieacs/ext"
LOG_DIR="/var/log/genieacs"
BACKUP_DIR="/root/backups/genieacs"
BACKUP_BIN="/usr/local/sbin/genieacs-backup.sh"
BACKUP_KEEP=14
PROD_MODE=0                   # --prod: liga UI/NBI/FS a localhost (reverse proxy)

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'

msg()  { echo -e "${G}[OK]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }
err()  { echo -e "${R}[ERROR]${N} $1"; exit 1; }

banner() {
    echo -e "${C}"
    echo "==============================================="
    echo "   GenieACS ${GENIEACS_VERSION} · installer v${INSTALLER_VERSION}"
    echo "     ACS TR-069 para gestion de CPEs/ONUs"
    echo "==============================================="
    echo -e "${N}"
}

#---------------------------------------------------------------
# Comprobaciones basicas
#---------------------------------------------------------------
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
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null 2>&1
    apt-get install -y nodejs >/dev/null 2>&1 || err "Fallo instalando Node.js"
    msg "Node.js $(node -v) instalado"
}

install_mongodb() {
    if systemctl is-active --quiet mongod; then
        local cur
        cur=$(mongod --version 2>/dev/null | awk '/db version/ {gsub("v","",$3); split($3,a,"."); print a[1]}')
        if [ -n "$cur" ] && [ "$cur" != "${MONGO_VERSION%%.*}" ]; then
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
        | gpg --dearmor -o /usr/share/keyrings/mongodb-server.gpg 2>/dev/null

    if [ "$repo_os" = "debian" ]; then
        echo "deb [signed-by=/usr/share/keyrings/mongodb-server.gpg] https://repo.mongodb.org/apt/debian ${repo_code}/mongodb-org/${MONGO_VERSION} main" \
            > /etc/apt/sources.list.d/mongodb-org.list
    else
        echo "deb [signed-by=/usr/share/keyrings/mongodb-server.gpg] https://repo.mongodb.org/apt/ubuntu ${repo_code}/mongodb-org/${MONGO_VERSION} multiverse" \
            > /etc/apt/sources.list.d/mongodb-org.list
    fi

    apt-get update >/dev/null 2>&1
    apt-get install -y mongodb-org >/dev/null 2>&1 || err "Fallo instalando MongoDB"
    systemctl enable --now mongod >/dev/null 2>&1
    systemctl is-active --quiet mongod || err "mongod no arranco (revisar: journalctl -u mongod)"
    msg "MongoDB $(mongod --version | head -1 | awk '{print $3}') activo"
}

#---------------------------------------------------------------
# GenieACS
#---------------------------------------------------------------
install_genieacs() {
    echo "Instalando GenieACS ${GENIEACS_VERSION} via npm..."
    npm install -g "genieacs@${GENIEACS_VERSION}" >/dev/null 2>&1 || err "Fallo npm install genieacs"
    msg "GenieACS instalado: $(command -v genieacs-cwmp)"

    id genieacs >/dev/null 2>&1 || useradd --system --no-create-home --user-group genieacs

    mkdir -p "$EXT_DIR" "$LOG_DIR"
    chown genieacs:genieacs "$EXT_DIR" "$LOG_DIR"

    if [ ! -f "$ENV_FILE" ]; then
        JWT_SECRET=$(node -e "console.log(require('crypto').randomBytes(64).toString('hex'))")
        cat > "$ENV_FILE" <<EOF
GENIEACS_CWMP_ACCESS_LOG_FILE=${LOG_DIR}/genieacs-cwmp-access.log
GENIEACS_NBI_ACCESS_LOG_FILE=${LOG_DIR}/genieacs-nbi-access.log
GENIEACS_FS_ACCESS_LOG_FILE=${LOG_DIR}/genieacs-fs-access.log
GENIEACS_UI_ACCESS_LOG_FILE=${LOG_DIR}/genieacs-ui-access.log
NODE_OPTIONS=--enable-source-maps
GENIEACS_EXT_DIR=${EXT_DIR}
GENIEACS_UI_JWT_SECRET=${JWT_SECRET}
EOF
        if [ "$PROD_MODE" = "1" ]; then
            cat >> "$ENV_FILE" <<EOF
GENIEACS_UI_INTERFACE=127.0.0.1
GENIEACS_NBI_INTERFACE=127.0.0.1
GENIEACS_FS_INTERFACE=127.0.0.1
EOF
        fi
        chown genieacs:genieacs "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        msg "Config creada en $ENV_FILE (JWT secret generado)"
        [ "$PROD_MODE" = "1" ] && msg "Modo --prod: UI/NBI/FS ligados a 127.0.0.1 (publicar por reverse proxy)"
    else
        msg "Config existente en $ENV_FILE (se conserva)"
    fi
}

create_services() {
    local svc bin
    bin=$(dirname "$(command -v genieacs-cwmp)")
    for svc in cwmp nbi fs ui; do
        cat > "/etc/systemd/system/genieacs-${svc}.service" <<EOF
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
    done

    cat > /etc/logrotate.d/genieacs <<'EOF'
/var/log/genieacs/*.log /var/log/genieacs/*.yaml {
    daily
    rotate 30
    maxsize 100M
    compress
    delaycompress
    dateext
    missingok
    notifempty
}
EOF

    systemctl daemon-reload
    for svc in cwmp nbi fs ui; do
        systemctl enable --now "genieacs-${svc}" >/dev/null 2>&1
    done
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
    cat > "$BACKUP_BIN" <<EOF
#!/bin/bash
# Respaldo de la base GenieACS (mongodump comprimido). Generado por el instalador.
set -u
DIR="${BACKUP_DIR}"
KEEP=${BACKUP_KEEP}
mkdir -p "\$DIR"
OUT="\$DIR/genieacs-\$(date +%F-%H%M).archive.gz"
if mongodump --db genieacs --gzip --archive="\$OUT" >/dev/null 2>&1; then
    echo "\$(date '+%F %T') backup OK: \$OUT (\$(du -h "\$OUT" | cut -f1))"
else
    echo "\$(date '+%F %T') backup FALLO" >&2; exit 1
fi
# retencion: conservar los ultimos \$KEEP
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
    systemctl enable --now genieacs-backup.timer >/dev/null 2>&1
    msg "Respaldo diario configurado: ${BACKUP_DIR} (03:30, conserva ${BACKUP_KEEP})"
}

backup_now() {
    [ -x "$BACKUP_BIN" ] || err "Falta ${BACKUP_BIN}; corre la instalacion primero"
    "$BACKUP_BIN"
}

#---------------------------------------------------------------
# Firewall (solo si UFW ya esta activo)
#---------------------------------------------------------------
configure_firewall() {
    command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active" || return
    ufw allow 7547/tcp comment 'GenieACS CWMP (CPEs)' >/dev/null 2>&1
    if [ "$PROD_MODE" = "1" ]; then
        msg "UFW: abierto 7547 (CWMP). UI/NBI/FS en localhost: publicar por reverse proxy (443)."
    else
        ufw allow 3000/tcp comment 'GenieACS UI' >/dev/null 2>&1
        msg "UFW: abiertos 7547 (CWMP) y 3000 (UI)"
        warn "NBI 7557 y FS 7567 NO se abrieron: exponerlos solo a IPs de confianza"
    fi
}

#---------------------------------------------------------------
# Auditoria post-instalacion (PASS / WARN / FAIL)
#---------------------------------------------------------------
post_install_audit() {
    local p="${G}[PASS]${N}" w="${Y}[WARN]${N}" f="${R}[FAIL]${N}"
    echo ""
    echo -e "${C}--------- AUDITORIA POST-INSTALACION ---------${N}"
    command -v genieacs-cwmp >/dev/null 2>&1 \
        && echo -e "$p GenieACS ${GENIEACS_VERSION}" || echo -e "$f GenieACS no instalado"

    local nm; nm=$(node -p "process.versions.node.split('.')[0]" 2>/dev/null)
    [ "$nm" = "$NODE_MAJOR" ] \
        && echo -e "$p Node.js $(node -v)" \
        || echo -e "$w Node.js $(node -v 2>/dev/null) (el stack fija ${NODE_MAJOR}.x)"

    local mm; mm=$(mongod --version 2>/dev/null | awk '/db version/ {gsub("v","",$3); split($3,a,"."); print a[1]}')
    [ "$mm" = "${MONGO_VERSION%%.*}" ] \
        && echo -e "$p MongoDB v${mm}.x" \
        || echo -e "$w MongoDB v${mm:-?}.x (el stack fija ${MONGO_VERSION})"

    if grep -qE "bindIp:\s*127\.0\.0\.1" /etc/mongod.conf 2>/dev/null && ! grep -qE "bindIp:.*0\.0\.0\.0" /etc/mongod.conf 2>/dev/null; then
        echo -e "$p MongoDB escucha solo en localhost"
    else
        echo -e "$w MongoDB bind: revisar /etc/mongod.conf"
    fi

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

    if [ "$PROD_MODE" = "1" ]; then
        echo -e "$p Modo --prod: UI/NBI/FS ligados a localhost"
    else
        echo -e "$w UI/NBI/FS escuchan en 0.0.0.0 (ok en red local; usa --prod + reverse proxy si se expone)"
    fi
    echo -e "$w CWMP en HTTP sin TLS (ok en red local; TLS si se expone a internet)"
    echo -e "$w cwmp.auth pendiente: por defecto acepta cualquier CPE (Admin > Config)"
    echo -e "${C}----------------------------------------------${N}"
}

show_summary() {
    IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo -e "${C}===============================================${N}"
    echo -e "${G} GenieACS ${GENIEACS_VERSION} instalado${N}"
    echo -e "${C}===============================================${N}"
    echo ""
    if [ "$PROD_MODE" = "1" ]; then
        echo "  CWMP (CPEs):     http://${IP}:7547"
        echo "  UI / NBI / FS:   en 127.0.0.1 (publicar por reverse proxy 443)"
    else
        echo "  UI (web):        http://${IP}:3000"
        echo "  CWMP (CPEs):     http://${IP}:7547"
        echo "  NBI (API):       http://${IP}:7557"
        echo "  FS (firmwares):  http://${IP}:7567"
    fi
    echo ""
    echo "  Primer acceso a la UI: pulsar el boton para crear la"
    echo "  configuracion por defecto -> login admin / admin"
    echo "  (cambiar la clave en Admin > Users)"
    echo ""
    echo "  Config:      $ENV_FILE"
    echo "  Extensiones: $EXT_DIR"
    echo "  Logs:        $LOG_DIR"
    echo "  Respaldos:   $BACKUP_DIR (timer diario 03:30, 'install.sh backup' para uno ya)"
    echo ""
    warn "El respaldo vive en la MISMA VM: copiar $BACKUP_DIR a un NAS/almacenamiento externo"
    warn "Por defecto acepta cualquier CPE: configurar cwmp.auth en Admin > Config"
    warn "Para produccion poner TLS (reverse proxy o GENIEACS_CWMP_SSL_CERT/KEY) y reinstalar con --prod"
}

#---------------------------------------------------------------
# Desinstalar
#---------------------------------------------------------------
uninstall_genieacs() {
    echo ""
    read -rp "Esto elimina GenieACS y sus servicios. Continuar? [s/N]: " ok < /dev/tty
    [ "$ok" = "s" ] || [ "$ok" = "S" ] || { echo "Cancelado"; return; }

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
        apt-get purge -y mongodb-org* >/dev/null 2>&1
        rm -rf /var/lib/mongodb /etc/apt/sources.list.d/mongodb-org.list /opt/genieacs "$LOG_DIR"
        msg "MongoDB y datos eliminados"
    fi
}

#---------------------------------------------------------------
# Menu
#---------------------------------------------------------------
for a in "$@"; do [ "$a" = "--prod" ] && PROD_MODE=1; done

banner
case "${1:-}" in
    install|--install)     opcion=1 ;;
    uninstall|--uninstall) opcion=2 ;;
    backup|--backup)       opcion=3 ;;
    *)
        echo "  1) Instalar GenieACS"
        echo "  2) Desinstalar"
        echo "  3) Respaldo ahora"
        echo "  4) Salir"
        echo ""
        [ "$PROD_MODE" = "1" ] && warn "modo --prod activo: UI/NBI/FS quedaran en localhost"
        read -rp "Opcion [1]: " opcion < /dev/tty
        opcion=${opcion:-1}
        ;;
esac

case "$opcion" in
    1)
        check_system
        apt-get update >/dev/null 2>&1
        apt-get install -y curl gnupg >/dev/null 2>&1
        install_node
        install_mongodb
        install_genieacs
        create_services
        setup_backup
        configure_firewall
        show_summary
        post_install_audit
        ;;
    2)
        uninstall_genieacs
        ;;
    3)
        backup_now
        ;;
    *)
        echo "Saliendo"
        ;;
esac
