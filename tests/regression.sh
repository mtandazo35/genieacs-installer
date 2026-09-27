#!/usr/bin/env bash
#===============================================================
# Tests de regresion del instalador GenieACS.
# Cubren los defectos corregidos en v2.1.0 (referencias ACS-* de la auditoria).
# No instala nada: usa `source` (guardia BASH_SOURCE) y comandos simulados.
#===============================================================
# Varias variables se asignan aqui para que las CONSUMA reconcile_env/do_status
# (sourced desde install.sh); shellcheck no sigue ese uso -> SC2034 a nivel archivo.
# shellcheck disable=SC2034
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../install.sh"
PASS=0; FAIL=0
ok() { echo "  ok   - $1"; PASS=$((PASS+1)); }
ko() { echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
# assert_rc <esperado> <descripcion> -- compara con el rc del ultimo comando
assert_rc() { if [ "$1" = "$2" ]; then ok "$3"; else ko "$3 (rc esperado=$1, real=$2)"; fi; }

echo "== Caja negra: validacion de argumentos (ACS-21) =="
bash "$SCRIPT" --workers banana   >/dev/null 2>&1; assert_rc 1 "$?" "--workers no numerico se rechaza"
bash "$SCRIPT" --workers --prod   >/dev/null 2>&1; assert_rc 1 "$?" "--workers no consume el flag siguiente"
bash "$SCRIPT" --bogus            >/dev/null 2>&1; assert_rc 1 "$?" "opcion desconocida se rechaza"
bash "$SCRIPT" --fs-local --prod  >/dev/null 2>&1; assert_rc 1 "$?" "--fs-local sin --domain se rechaza (ACS-16)"
bash "$SCRIPT" --letsencrypt      >/dev/null 2>&1; assert_rc 1 "$?" "--letsencrypt sin --domain se rechaza"
bash "$SCRIPT" --help             >/dev/null 2>&1; assert_rc 0 "$?" "--help sale 0"
bash "$SCRIPT" --version          >/dev/null 2>&1; assert_rc 0 "$?" "--version sale 0"

echo "== Unidad: funciones (source sin ejecutar main) =="
# shellcheck source=/dev/null
source "$SCRIPT"

# --- .env idempotente (ACS-06) ---
# (estas variables las consume reconcile_env, sourced desde install.sh)
# shellcheck disable=SC2034
ENV_FILE="$(mktemp)"; : > "$ENV_FILE"
# shellcheck disable=SC2034
PROD_MODE=1; NBI_LOCAL=0; FS_LOCAL=0; DOMAIN=""; WORKERS=2; ENV_CHANGED=0
reconcile_env
grep -q '^GENIEACS_UI_INTERFACE=127.0.0.1$'      "$ENV_FILE" && ok "reconcile pone UI_INTERFACE con --prod" || ko "reconcile UI_INTERFACE"
grep -q '^GENIEACS_CWMP_WORKER_PROCESSES=2$'      "$ENV_FILE" && ok "reconcile pone workers"               || ko "reconcile workers"
# shellcheck disable=SC2034
PROD_MODE=0; WORKERS=""; reconcile_env
grep -q 'GENIEACS_UI_INTERFACE'                   "$ENV_FILE" && ko "sin --prod deberia quitar UI_INTERFACE" || ok "sin --prod quita UI_INTERFACE (converge)"
rm -f "$ENV_FILE"

# --- mongo bind solo-loopback (ACS-12) ---
MONGOD_CONF="$(mktemp)"
printf '  bindIp: 127.0.0.1\n'             > "$MONGOD_CONF"; mongo_bind_localhost_only && ok "127.0.0.1 = solo localhost"          || ko "127.0.0.1"
printf '  bindIp: 127.0.0.1,10.10.10.10\n' > "$MONGOD_CONF"; mongo_bind_localhost_only && ko "IP extra NO es solo localhost"       || ok "127.0.0.1,10.10.10.10 rechazado (ACS-12)"
printf '  bindIp: 0.0.0.0\n'               > "$MONGOD_CONF"; mongo_bind_localhost_only && ko "0.0.0.0 NO es localhost"              || ok "0.0.0.0 rechazado"
rm -f "$MONGOD_CONF"

# --- do_status: exit code real (ACS-11) ---
MOCK="$(mktemp -d)"
printf '#!/bin/bash\ntrue\n' > "$MOCK/genieacs-cwmp"
cat > "$MOCK/systemctl" <<'M'
#!/bin/bash
case "$*" in
  *is-active*genieacs-*) [ "${MOCK_SVC_UP:-1}" = "1" ] && exit 0 || exit 3 ;;
  *is-enabled*) exit 0 ;;
  *) exit 0 ;;
esac
M
printf '#!/bin/bash\n[ "$1" = genieacs ] && exit 0 || exit 1\n' > "$MOCK/id"
chmod +x "$MOCK"/*
export PATH="$MOCK:$PATH"
ENV_FILE="$(mktemp)"; echo "GENIEACS_UI_JWT_SECRET=deadbeef" > "$ENV_FILE"; chmod 600 "$ENV_FILE"
MONGOD_CONF="$(mktemp)"; printf '  bindIp: 127.0.0.1\n' > "$MONGOD_CONF"

MOCK_SVC_UP=1 do_status >/dev/null 2>&1; assert_rc 0 "$?" "status sano devuelve 0"
MOCK_SVC_UP=0 do_status >/dev/null 2>&1; assert_rc 1 "$?" "status con servicio caido devuelve !=0 (ACS-11)"
# JWT vacio debe hacer fallar aunque los servicios esten arriba
: > "$ENV_FILE"
MOCK_SVC_UP=1 do_status >/dev/null 2>&1; assert_rc 1 "$?" "status con JWT ausente devuelve !=0 (ACS-12)"
rm -rf "$MOCK" "$ENV_FILE" "$MONGOD_CONF"

echo ""
echo "Resultado: ${PASS} ok, ${FAIL} FAIL"
[ "$FAIL" -eq 0 ]
