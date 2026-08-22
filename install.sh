#!/bin/bash
#===============================================================
# GenieACS Installer - Debian 12/13 y Ubuntu 22.04/24.04
# ACS TR-069 (CWMP) para gestion remota de CPEs/ONUs
# https://github.com/mtandazo35/genieacs-installer
#===============================================================

GENIEACS_VERSION="1.2.16"
NODE_MAJOR="20"
MONGO_VERSION="8.0"
ENV_FILE="/opt/genieacs/genieacs.env"
EXT_DIR="/opt/genieacs/ext"
LOG_DIR="/var/log/genieacs"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'

msg()  { echo -e "${G}[OK]${N} $1"; }
warn() { echo -e "${Y}[!]${N} $1"; }
err()  { echo -e "${R}[ERROR]${N} $1"; exit 1; }

banner() {
    echo -e "${C}"
    echo "==============================================="
    echo "        GenieACS Installer v${GENIEACS_VERSION}"
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
    if command -v node >/dev/null 2>&1 && [ "$(node -v | cut -dv -f2 | cut -d. -f1)" -ge 12 ]; then
        msg "Node.js $(node -v) ya instalado"
        return
    fi
    echo "Instalando Node.js ${NODE_MAJOR}.x..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null 2>&1
    apt-get install -y nodejs >/dev/null 2>&1 || err "Fallo instalando Node.js"
    msg "Node.js $(node -v) instalado"
}

install_mongodb() {
    if systemctl is-active --quiet mongod; then
        msg "MongoDB ya instalado y activo"
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
        chown genieacs:genieacs "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        msg "Config creada en $ENV_FILE (JWT secret generado)"
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
EnvironmentFile=${ENV_FILE}
ExecStart=${bin}/genieacs-${svc}
Restart=on-failure
RestartSec=5

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

configure_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        ufw allow 7547/tcp comment 'GenieACS CWMP (CPEs)' >/dev/null 2>&1
        ufw allow 3000/tcp comment 'GenieACS UI' >/dev/null 2>&1
        msg "UFW: abiertos 7547 (CWMP) y 3000 (UI)"
        warn "NBI 7557 y FS 7567 NO se abrieron: exponerlos solo a IPs de confianza"
    fi
}

show_summary() {
    IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo -e "${C}===============================================${N}"
    echo -e "${G} GenieACS ${GENIEACS_VERSION} instalado${N}"
    echo -e "${C}===============================================${N}"
    echo ""
    echo "  UI (web):        http://${IP}:3000"
    echo "  CWMP (CPEs):     http://${IP}:7547"
    echo "  NBI (API):       http://${IP}:7557"
    echo "  FS (firmwares):  http://${IP}:7567"
    echo ""
    echo "  Primer acceso a la UI: pulsar el boton para crear la"
    echo "  configuracion por defecto -> login admin / admin"
    echo "  (cambiar la clave en Admin > Users)"
    echo ""
    echo "  Config:      $ENV_FILE"
    echo "  Extensiones: $EXT_DIR"
    echo "  Logs:        $LOG_DIR"
    echo ""
    warn "Por defecto acepta cualquier CPE: configurar cwmp.auth en Admin > Config"
    warn "Para produccion poner TLS (reverse proxy o GENIEACS_CWMP_SSL_CERT/KEY)"
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
    systemctl daemon-reload
    npm uninstall -g genieacs >/dev/null 2>&1
    rm -f /etc/logrotate.d/genieacs
    msg "Servicios y paquete eliminados"

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
banner
case "${1:-}" in
    install|--install)     opcion=1 ;;
    uninstall|--uninstall) opcion=2 ;;
    *)
        echo "  1) Instalar GenieACS"
        echo "  2) Desinstalar"
        echo "  3) Salir"
        echo ""
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
        configure_firewall
        show_summary
        ;;
    2)
        uninstall_genieacs
        ;;
    *)
        echo "Saliendo"
        ;;
esac
