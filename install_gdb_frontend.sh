#!/usr/bin/env bash
set -euo pipefail

# -------------------------------
# Configuración
# -------------------------------
REPO_URL="https://github.com/pedroirisoGalileo/gdbfrontInstaller.git"
TARGET_HOME="/home/tareas"
STUDENT_USER="tareas"

# -------------------------------
# Verificaciones previas
# -------------------------------
if ! command -v git >/dev/null 2>&1; then
  echo "[ERROR] 'git' no está instalado. Instalalo con: sudo apt-get update && sudo apt-get install -y git"
  exit 1
fi

if [[ ! -d "$TARGET_HOME" ]]; then
  echo "[ERROR] No existe el directorio $TARGET_HOME"
  exit 1
fi

# -------------------------------
# Preparar directorio temporal
# -------------------------------
WORKDIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "[INFO] Clonando repositorio en $WORKDIR ..."
git clone --depth=1 "$REPO_URL" "$WORKDIR/gdbfrontInstaller"

# -------------------------------
# Dar permisos de ejecución a scripts
# -------------------------------
echo "[INFO] Asignando permisos de ejecución a scripts *.sh ..."
find "$WORKDIR/gdbfrontInstaller" -type f -name "*.sh" -exec chmod +x {} +

# -------------------------------
# Ejecutar el instalador
# -------------------------------
INSTALLER="$WORKDIR/gdbfrontInstaller/deploy_gdb_frontend.sh"
if [[ ! -f "$INSTALLER" ]]; then
  echo "[ERROR] No se encontró deploy_gdb_frontend.sh en el repositorio."
  exit 1
fi

echo "[INFO] Ejecutando instalador ..."
sudo bash "$INSTALLER" \
  --target-home "$TARGET_HOME" \
  --student-user "$STUDENT_USER" \
  --verbose

# -------------------------------
# Copiar debug-frontend.sh a /home/tareas
# -------------------------------
echo "[INFO] Buscando 'debug-frontend.sh' en el repositorio ..."
DEBUG_SRC="$(find "$WORKDIR/gdbfrontInstaller" -type f -name 'debug-frontend.sh' | head -n1 || true)"

if [[ -z "${DEBUG_SRC}" ]]; then
  echo "[ERROR] No se encontró el archivo 'debug-frontend.sh' dentro del repositorio."
  exit 1
fi

DEBUG_DST="$TARGET_HOME/debug-frontend.sh"
echo "[INFO] Instalando $DEBUG_SRC -> $DEBUG_DST (propietario: $STUDENT_USER) ..."
# 'install' copia, asigna propietario y permisos en un solo paso
sudo install -o "$STUDENT_USER" -g "$STUDENT_USER" -m 0644 "$DEBUG_SRC" "$DEBUG_DST"

# Asegurar permiso de escritura para el usuario (por si el umask fue raro)
sudo chmod u+rw "$DEBUG_DST"

echo "[OK] Proceso finalizado."
echo "[OK] Archivo instalado en: $DEBUG_DST (owner: $STUDENT_USER, modo: 0644)"
