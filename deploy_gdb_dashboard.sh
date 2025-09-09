#!/usr/bin/env bash
set -euo pipefail

# ==========================
# deploy_gdb_dashboard_v4.sh
# ==========================
# Instala gdb-dashboard en el HOME del alumno (sin tocar tu HOME):
# - Descarga dashboard en  ~/.local/share/gdb-dashboard/.gdbinit  (del alumno)
# - Escribe/actualiza       ~/.gdbinit (con backup)
# - Crea wrappers en        ~/.local/bin: gdb-dash  y (opcional) c-debug
# - (Opcional) apt-get install gdbserver y socat
#
# Uso:
#   sudo bash deploy_gdb_dashboard_v4.sh \
#     --target-home /home/alumno \
#     --student-user alumno \
#     [--install-all] [--with-c-helper] [--verbose]
#
# Notas:
# - gdb-dashboard requiere GDB con Python. Si no hay Python, el dashboard no cargará,
#   pero c-debug hace fallback a 'gdb -tui'.
# ==========================

TARGET_HOME=""
STUDENT_USER=""
DO_INSTALL_ALL="no"
WITH_C_HELPER="no"
VERBOSE="no"

DASH_RAW_URL="https://raw.githubusercontent.com/cyrus-and/gdb-dashboard/master/.gdbinit"

log()  { printf "[INFO ] %s\n" "$*" >&2; }
warn() { printf "[WARN ] %s\n" "$*" >&2; }
err()  { printf "[ERROR] %s\n" "$*" >&2; }
dbg()  { [[ "$VERBOSE" == "yes" ]] && printf "[DEBUG] %s\n" "$*" >&2 || true; }

usage() {
  cat <<EOF
Uso:
  sudo bash \$0 --target-home /home/alumno --student-user alumno [--install-all] [--with-c-helper] [--verbose]

Hace:
  - Descarga gdb-dashboard en  \$HOME/.local/share/gdb-dashboard/.gdbinit  (del alumno)
  - Escribe/actualiza          \$HOME/.gdbinit (con backup)
  - Crea wrappers:             \$HOME/.local/bin/gdb-dash  y (opcional) \$HOME/.local/bin/c-debug
  - (Opcional) apt-get install gdbserver y socat

Opciones:
  --target-home PATH     HOME del alumno (obligatorio)
  --student-user USER    usuario del alumno (recomendado para chown)
  --install-all          instala gdbserver y socat con apt
  --with-c-helper        crea helper c-debug (compila .c y abre el debugger)
  --verbose              salida detallada
  --help                 esta ayuda
EOF
}

have() { command -v "$1" >/dev/null 2>&1; }

# Parseo
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-home) TARGET_HOME="${2:-}"; shift 2 ;;
    --student-user) STUDENT_USER="${2:-}"; shift 2 ;;
    --install-all) DO_INSTALL_ALL="yes"; shift ;;
    --with-c-helper) WITH_C_HELPER="yes"; shift ;;
    --verbose) VERBOSE="yes"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) err "Opción no reconocida: $1"; usage; exit 1 ;;
  esac
done

# Validaciones
[[ -z "$TARGET_HOME" ]] && { err "--target-home es obligatorio"; exit 2; }
[[ ! -d "$TARGET_HOME" ]] && { err "No existe el directorio: $TARGET_HOME"; exit 3; }

BIN_DIR="${TARGET_HOME}/.local/bin"
DASH_DIR="${TARGET_HOME}/.local/share/gdb-dashboard"
GDBINIT="${TARGET_HOME}/.gdbinit"
BASHRC="${TARGET_HOME}/.bashrc"
BACKUP_SUFFIX=".$(date +%Y%m%d-%H%M%S).bak"

log "Parámetros:"
log "  TARGET_HOME   = $TARGET_HOME"
log "  STUDENT_USER  = ${STUDENT_USER:-<no especificado>}"
log "  install-all   = $DO_INSTALL_ALL"
log "  with-c-helper = $WITH_C_HELPER"
dbg "BIN_DIR=$BIN_DIR"
dbg "DASH_DIR=$DASH_DIR"
dbg "GDBINIT=$GDBINIT"
dbg "BASHRC=$BASHRC"

# 1) Directorios
log "1) Creando directorios del alumno (~/.local/bin y ~/.local/share/gdb-dashboard)…"
mkdir -p "$BIN_DIR" "$DASH_DIR"

# 2) Descargar dashboard
log "2) Descargando gdb-dashboard a ${DASH_DIR}/.gdbinit…"
if have curl; then
  curl -fsSL "$DASH_RAW_URL" -o "$DASH_DIR/.gdbinit"
elif have wget; then
  wget -qO "$DASH_DIR/.gdbinit" "$DASH_RAW_URL"
else
  err "No hay curl ni wget para descargar."
  exit 4
fi

# 3) .gdbinit (con backup) — módulos correctos
log "3) Escribiendo ~/.gdbinit (con backup si existe)…"
if [[ -f "$GDBINIT" ]]; then
  cp "$GDBINIT" "${GDBINIT}${BACKUP_SUFFIX}"
  log "   Backup: ${GDBINIT}${BACKUP_SUFFIX}"
fi
cat > "$GDBINIT" <<'EOF'
# --- gdb-dashboard bootstrap ---
set auto-load safe-path /
set history save on
set history filename ~/.gdb_history
set history size 10000
source ~/.local/share/gdb-dashboard/.gdbinit
# Layout con nombres de módulos válidos:
# (source, registers, stack, threads, breakpoints, memory, etc.)
dashboard -layout source registers stack threads breakpoints
EOF
log "   ~/.gdbinit escrito."

# 4) Wrappers (heredoc, sin eval)
log "4) Creando wrapper gdb-dash…"
cat > "${BIN_DIR}/gdb-dash" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec gdb -q "$@"
EOF
chmod +x "${BIN_DIR}/gdb-dash"
log "   Creado: ${BIN_DIR}/gdb-dash"

if [[ "$WITH_C_HELPER" == "yes" ]]; then
  log "   Creando helper c-debug…"
  cat > "${BIN_DIR}/c-debug" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Uso: $0 archivo.c [args-del-programa...]" >&2
  exit 1
fi

SRC="$1"; shift || true
if [[ ! -f "$SRC" ]]; then
  echo "No encuentro: $SRC" >&2
  exit 1
fi

# Normalizar a ruta absoluta del fuente y su directorio
SRC_ABS="$(readlink -f "$SRC" 2>/dev/null || python3 - "$SRC" <<'PY'
import os,sys
print(os.path.abspath(sys.argv[1]))
PY
)"
SRC_DIR="$(dirname "$SRC_ABS")"
SRC_BASE="$(basename "$SRC_ABS")"
EXE_BASENAME="${SRC_BASE%.*}"
EXE_PATH="${SRC_DIR}/${EXE_BASENAME}"

# Compilar con símbolos y sin optimizar (para debug amigable)
gcc -g -O0 -Wall -fno-omit-frame-pointer -o "$EXE_PATH" "$SRC_ABS"

# ¿Existe gdb-dash en el mismo directorio?
WRAP_DIR="$(dirname "$0")"
GDB_WRAP="${WRAP_DIR}/gdb-dash"
if [[ -x "$GDB_WRAP" ]]; then
  # Pasar working dir y ruta de fuentes a gdb, luego los argumentos del programa
  exec "$GDB_WRAP" \
    -ex "cd $SRC_DIR" \
    -ex "directory $SRC_DIR" \
    --args "$EXE_PATH" "$@"
else
  # Fallback a gdb -tui si no está el wrapper (o si el dashboard no carga)
  exec gdb -tui \
    -ex "cd $SRC_DIR" \
    -ex "directory $SRC_DIR" \
    --args "$EXE_PATH" "$@"
fi
EOF
  chmod +x "${BIN_DIR}/c-debug"
  log "   Creado: ${BIN_DIR}/c-debug"
fi

# 5) PATH en .bashrc
log "5) Asegurando ~/.local/bin en PATH del alumno…"
touch "$BASHRC"
if ! grep -qE '(^|:)\$HOME/\.local/bin(:|$)' "$BASHRC"; then
  printf '\n# Añadido por deploy_gdb_dashboard_v4.sh\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$BASHRC"
  log "   Agregado export PATH a $BASHRC"
else
  log "   PATH ya incluía ~/.local/bin"
fi

# 6) Paquetes (opcional)
if [[ "$DO_INSTALL_ALL" == "yes" ]]; then
  log "6) Instalando gdbserver y socat (apt)…"
  apt-get update -y
  apt-get install -y gdbserver socat
  log "   gdbserver y socat instalados."
else
  log "6) (omitido) Instalación de paquetes del sistema."
fi

# 7) Ownership
if [[ -n "$STUDENT_USER" ]]; then
  log "7) Ajustando ownership a ${STUDENT_USER}:${STUDENT_USER}…"
  chown -R "${STUDENT_USER}:${STUDENT_USER}" \
    "$BIN_DIR" "$DASH_DIR" "$GDBINIT" "$BASHRC" || true
else
  warn "7) (omitido) --student-user no especificado; revisá ownership."
fi

# 8) Chequeo informativo de Python en GDB
log "8) Chequeo rápido de Python en GDB (informativo)…"
if have gdb && gdb -q -ex "python print('OK')" -ex quit 2>/dev/null | grep -q '^OK$'; then
  log "   GDB con Python detectado: gdb-dashboard debería funcionar."
else
  warn "   GDB sin Python: el dashboard no cargará; usar 'gdb -tui' (c-debug ya hace fallback)."
fi

log "==== TODO LISTO ===="
echo "Como el alumno, abrir NUEVA terminal y ejecutar:"
echo "  gdb-dash ./programa"
[[ "$WITH_C_HELPER" == "yes" ]] && echo "  c-debug archivo.c   # compila con -g y abre el debugger"
