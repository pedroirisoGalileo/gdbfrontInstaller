#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# deploy_gdb_frontend_v8.sh
# - NO compila tmux. Si no existe, lo instala con "apt install tmux".
# - Clona/actualiza gdb-frontend en el HOME del alumno.
# - Crea launchers: gdb-frontend-run y c-debug-frontend.
# - Asegura PATH (~/.local/bin) y ownership.
#
# Uso:
#   sudo bash deploy_gdb_frontend_v8.sh \
#     --target-home /home/alumno \
#     --student-user alumno \
#     [--verbose]
# ============================================================

TARGET_HOME=""
STUDENT_USER=""
VERBOSE="no"

REPO_URL="https://github.com/rohanrhu/gdb-frontend.git"
FRONTEND_DIR_NAME="gdb-frontend"

log()  { printf "[INFO ] %s\n" "$*" >&2; }
warn() { printf "[WARN ] %s\n" "$*" >&2; }
err()  { printf "[ERROR] %s\n" "$*" >&2; }
dbg()  { [[ "$VERBOSE" == "yes" ]] && printf "[DEBUG] %s\n" "$*" >&2 || true; }

usage() {
  cat <<EOF
Uso:
  sudo bash \$0 --target-home /home/ALUMNO --student-user ALUMNO [--verbose]

Opciones:
  --target-home PATH     HOME del alumno (obligatorio)
  --student-user USER    usuario del alumno (recomendado, para chown)
  --verbose              salida detallada
  --help                 esta ayuda
EOF
}

# Parseo args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-home) TARGET_HOME="${2:-}"; shift 2 ;;
    --student-user) STUDENT_USER="${2:-}"; shift 2 ;;
    --verbose) VERBOSE="yes"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) err "Opción no reconocida: $1"; usage; exit 1 ;;
  esac
done

[[ -z "$TARGET_HOME" ]] && { err "--target-home es obligatorio"; exit 2; }
[[ ! -d "$TARGET_HOME" ]] && { err "No existe el directorio: $TARGET_HOME"; exit 3; }

# Derivados
BIN_DIR="${TARGET_HOME}/.local/bin"
FRONTEND_DIR="${TARGET_HOME}/${FRONTEND_DIR_NAME}"
BASHRC="${TARGET_HOME}/.bashrc"

log "Parámetros:"
log "  TARGET_HOME   = $TARGET_HOME"
log "  STUDENT_USER  = ${STUDENT_USER:-<no especificado>}"
log "  verbose       = $VERBOSE"
dbg "BIN_DIR=$BIN_DIR"
dbg "FRONTEND_DIR=$FRONTEND_DIR"
dbg "BASHRC=$BASHRC"

have() { command -v "$1" >/dev/null 2>&1; }
as_student() {
  # Ejecuta comando como alumno con su entorno de login
  if [[ -n "$STUDENT_USER" ]]; then
    su - "$STUDENT_USER" -c "$1"
  else
    bash -lc "$1"
  fi
}

# 0) directorios base
log "0) Creando directorios base del alumno…"
mkdir -p "$BIN_DIR"

# 1) asegurar PATH (~/.local/bin) en .bashrc del alumno
log "1) Asegurando ~/.local/bin en PATH del alumno…"
touch "$BASHRC"
if ! grep -qE '(^|:)\$HOME/\.local/bin(:|$)' "$BASHRC"; then
  printf '\n# Añadido por deploy_gdb_frontend_v8.sh\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$BASHRC"
  log "   Agregado export PATH a $BASHRC"
else
  log "   PATH ya incluía ~/.local/bin"
fi

# 2) clonar / actualizar gdb-frontend
log "2) Preparando repositorio gdb-frontend en ${FRONTEND_DIR}…"
if [[ -d "$FRONTEND_DIR/.git" ]]; then
  log "   Repo existente: actualizando…"
  git -C "$FRONTEND_DIR" fetch --all --prune || true
  git -C "$FRONTEND_DIR" reset --hard origin/master || git -C "$FRONTEND_DIR" pull --rebase || true
else
  log "   Clonando repositorio…"
  git clone "$REPO_URL" "$FRONTEND_DIR"
fi

# 3) tmux: si no está, instalar vía apt (solo tmux, nada más)
if as_student 'command -v tmux >/dev/null 2>&1'; then
  log "3) tmux detectado en PATH del alumno. OK."
else
  log "3) tmux no detectado: instalando con apt (solo tmux)…"
  apt update -y
  apt install -y tmux || {
    err "Fallo install de tmux con apt. Revisá el estado de apt/dpkg."
    exit 4
  }
fi

# (Opcional) checks informativos de herramientas (no instalamos nada más)
if ! have git; then warn "git no detectado en PATH root; ya se clonó antes, pero confirmalo si replicás en otra PC."; fi
if ! as_student 'command -v python3 >/dev/null 2>&1'; then warn "python3 no detectado para el alumno (gdb-frontend requiere Python 3)."; fi
if ! as_student 'command -v gdb >/dev/null 2>&1'; then warn "gdb no detectado para el alumno (instalalo si hace falta)."; fi

# 4) launchers en ~/.local/bin del alumno
log "4) Creando launchers en ${BIN_DIR}…"

# gdb-frontend-run
cat > "${BIN_DIR}/gdb-frontend-run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
FRONTEND_DIR="$HOME/gdb-frontend"
EXEC="$FRONTEND_DIR/gdbfrontend"

if [[ ! -x "$EXEC" ]]; then
  echo "[ERROR] No encuentro $EXEC. ¿Clonaste gdb-frontend en $FRONTEND_DIR?" >&2
  exit 1
fi

# Sugerencias:
#   -p 0  → puerto aleatorio (la URL/puerto se imprime en stdout)
#   --help para opciones adicionales
exec "$EXEC" "$@"
EOF
chmod +x "${BIN_DIR}/gdb-frontend-run"

# c-debug-frontend (compila .c y abre el frontend en esa carpeta)
cat > "${BIN_DIR}/c-debug-frontend" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Uso: $0 archivo.c [args-del-programa...]" >&2
  exit 1
fi

SRC="$1"; shift || true
if [[ ! -f "$SRC" ]]; then
  echo "[ERROR] No encuentro: $SRC" >&2
  exit 1
fi

# Ruta absoluta portable con Python (por compatibilidad)
SRC_ABS="$(python3 - "$SRC" <<'PY'
import os,sys; print(os.path.abspath(sys.argv[1]))
PY
)"
SRC_DIR="$(dirname "$SRC_ABS")"
SRC_BASE="$(basename "$SRC_ABS")"
EXE_BASENAME="${SRC_BASE%.*}"
EXE_PATH="${SRC_DIR}/${EXE_BASENAME}"

# Compilación con símbolos
gcc -g -O0 -Wall -fno-omit-frame-pointer -o "$EXE_PATH" "$SRC_ABS"
echo "[INFO ] Compilado: $EXE_PATH"

FRONTEND_DIR="$HOME/gdb-frontend"
EXEC="$FRONTEND_DIR/gdbfrontend"
if [[ ! -x "$EXEC" ]]; then
  echo "[ERROR] No encuentro $EXEC. ¿Clonaste gdb-frontend en $FRONTEND_DIR?" >&2
  exit 1
fi

# Entramos en la carpeta del fuente; la UI permitirá cargar/ejecutar el binario
cd "$SRC_DIR"
# Puerto aleatorio para evitar conflictos
exec "$EXEC" -p 0
EOF
chmod +x "${BIN_DIR}/c-debug-frontend"

log "   Creado: ${BIN_DIR}/gdb-frontend-run y ${BIN_DIR}/c-debug-frontend"

# 5) ownership final
if [[ -n "$STUDENT_USER" ]]; then
  log "5) Ajustando ownership a ${STUDENT_USER}:${STUDENT_USER}…"
  chown -R "${STUDENT_USER}:${STUDENT_USER}" \
    "$BIN_DIR" "$FRONTEND_DIR" "$BASHRC" || true
else
  warn "5) (omitido) --student-user no especificado; revisá ownership."
fi

# 6) Mensaje final
log "==== TODO LISTO ===="
echo "Como el alumno, abrí NUEVA terminal y probá:"
echo "  gdb-frontend-run -p 0         # imprime URL/puerto (web UI)"
echo "  c-debug-frontend /ruta/a.c    # compila y abre el frontend en esa carpeta"
