# GenieACS Installer

Instalador de [GenieACS](https://genieacs.com/) — ACS **TR-069 (CWMP)** open source para gestión remota de CPEs/ONUs (routers, fibra, DSL, LTE, VoIP).

Instala y deja en marcha la versión estable **1.2.16** con Node.js 20, MongoDB 8.0 y los 4 servicios como unidades systemd.

## ⚡ Quick install (one-liner)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mtandazo35/genieacs-installer/main/install.sh)
```

## Requisitos

- Debian 12/13 o Ubuntu 22.04/24.04 (systemd)
- root
- 2 GB RAM mínimo (4 GB recomendado en producción)
- CPU con **AVX** (MongoDB 8 lo exige). En Proxmox: CPU type `host`, no `kvm64`

## Qué instala

| Servicio | Puerto | Función |
|---|---|---|
| genieacs-cwmp | 7547 | Endpoint TR-069 donde apuntan los CPEs |
| genieacs-nbi | 7557 | API REST (integración billing/scripts) |
| genieacs-fs | 7567 | Servidor de archivos (firmwares) |
| genieacs-ui | 3000 | Interfaz web |

Además: usuario de sistema `genieacs`, config en `/opt/genieacs/genieacs.env` (JWT secret autogenerado, `chmod 600`), directorio de extensiones `/opt/genieacs/ext`, logs en `/var/log/genieacs` con logrotate (30 días, maxsize 100M).

Si UFW está activo abre **7547** y **3000**. Los puertos 7557 (NBI) y 7567 (FS) no se abren: expónlos solo a IPs de confianza.

## Post-instalación

1. Abrir `http://IP:3000` → pulsar el botón para crear la configuración por defecto → login `admin` / `admin` → **cambiar la clave** en *Admin → Users*.
2. Apuntar los CPEs al ACS: URL `http://IP:7547` (parámetro `ManagementServer.URL`).
3. **Autenticación de CPEs**: por defecto acepta cualquier equipo. Configurar `cwmp.auth` en *Admin → Config*, p. ej.:
   ```
   AUTH(InternetGatewayDevice.ManagementServer.Username, InternetGatewayDevice.ManagementServer.Password)
   ```
4. Para producción: TLS con reverse proxy o `GENIEACS_CWMP_SSL_CERT`/`KEY` en el env file.

## Dimensionamiento (VM Proxmox)

| CPEs | RAM | vCPU | Disco |
|---|---|---|---|
| < 500 | 2 GB | 2 | 20 GB |
| hasta ~5.000 | 4 GB | 2–4 | 40 GB |
| ~15.000 | 8 GB | 4–8 | 100 GB+ |

El consumidor real de RAM es MongoDB; la carga la define el *inform interval* (15–60 min recomendado en ISP), no el número de equipos.

## Desinstalar

Ejecutar el instalador de nuevo y elegir la opción **2** (pregunta si borrar también MongoDB y los datos).

## Documentación

- Docs oficiales: https://docs.genieacs.com
- Foro: https://forum.genieacs.com
