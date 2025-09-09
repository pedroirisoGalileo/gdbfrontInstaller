#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# deploy_gdb_frontend_v7.sh
# - NO usa apt. No toca paquetes del sistema.
# - Si falta tmux, lo construye en el HOME del alumno (user-space)
#   junto con libevent y ncurses en ~/.local/tmux-prefix
# - Clona gdb-frontend en el HOME del alumno
# - Crea launchers: gdb-frontend-run y c-debug-frontend
# - Asegura PATH y ownership
#
# Uso:
#   sudo bash deploy_gdb_frontend_v7.sh \
#     --target-home /home/alumno \
#     --student-user alumno \
#     [--verbose]
#
# Requisitos de compilación:
#   - make, gcc, tar, xz/gzip, curl o wget (suelen venir por defecto).
#   - no requiere sudo para compilar en el HOME del alumno.
# ============================================================

TARGET_HOME=""
STUDENT_USER=""
VERBOSE="no"

REPO_URL="https://github.com/rohanrhu/gdb-frontend.git"
FRONTEND_DIR_NAME="gdb-frontend"

# Versiones (estables y probadas) para build local:
NCURSES_VER="6.4"
LIBEVENT_VER="2.1.12-stable"
TMUX_VER="3.3a"

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

Este script NO usa apt. Si tmux no existe, lo compila en el HOME del alumno
junto con libevent y ncurses en ~/.local/tmux-prefix.
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

# Prefijo local para libs y tmux
PREFIX="${TARGET_HOME}/.local/tmux-prefix"
SRC_DIR="${TARGET_HOME}/.local/src-tmux-build"

log "Parámetros:"
log "  TARGET_HOME   = $TARGET_HOME"
log "  STUDENT_USER  = ${STUDENT_USER:-<no especificado>}"
log "  verbose       = $VERBOSE"
dbg "BIN_DIR=$BIN_DIR"
dbg "FRONTEND_DIR=$FRONTEND_DIR"
dbg "BASHRC=$BASHRC"
dbg "PREFIX=$PREFIX"
dbg "SRC_DIR=$SRC_DIR"

have() { command -v "$1" >/dev/null 2>&1; }
as_student() {
  # Ejecuta comando como alumno con su entorno de login
  if [[ -n "$STUDENT_USER" ]]; then
    su - "$STUDENT_USER" -c "$1"
  else
    bash -lc "$1"
  fi
}

# 0) crear dirs base
log "0) Creando directorios base del alumno…"
mkdir -p "$BIN_DIR" "$PREFIX" "$SRC_DIR"

# 1) asegurar PATH (prioriza ~/.local/bin y ~/.local/tmux-prefix/bin)
log "1) Asegurando rutas en PATH del alumno…"
touch "$BASHRC"
ADD_PATH_LINE='# Añadido por deploy_gdb_frontend_v7.sh
export PATH="$HOME/.local/tmux-prefix/bin:$HOME/.local/bin:$PATH"'
if ! grep -q 'deploy_gdb_frontend_v7.sh' "$BASHRC"; then
  printf '\n%s\n' "$ADD_PATH_LINE" >> "$BASHRC"
  log "   Se añadió export PATH a $BASHRC"
else
  log "   PATH ya estaba ajustado previamente"
fi

# 2) clonar / actualizar gdb-frontend (como root, luego chown)
log "2) Preparando repositorio gdb-frontend en ${FRONTEND_DIR}…"
if [[ -d "$FRONTEND_DIR/.git" ]]; then
  log "   Repo existente: actualizando…"
  git -C "$FRONTEND_DIR" fetch --all --prune || true
  git -C "$FRONTEND_DIR" reset --hard origin/master || git -C "$FRONTEND_DIR" pull --rebase || true
else
  log "   Clonando repositorio…"
  git clone "$REPO_URL" "$FRONTEND_DIR"
fi

# 3) tmux: usar el del sistema si existe; si no, compilar localmente
need_build="no"
if as_student 'command -v tmux >/dev/null 2>&1'; then
  log "3) tmux detectado en PATH del alumno. No se compila."
else
  log "3) tmux no detectado: voy a compilar tmux + libevent + ncurses en el HOME del alumno (sin sudo)…"
  need_build="yes"
fi

download() {
  local url="$1" out="$2"
  if have curl; then
    curl -fsSL "$url" -o "$out"
  elif have wget; then
    wget -qO "$out" "$url"
  else
    err "No hay curl ni wget para descargar $url"
    return 1
  fi
}

if [[ "$need_build" == "yes" ]]; then
  # Rutas y URLs
  NCURSES_TAR="ncurses-${NCURSES_VER}.tar.gz"
  NCURSES_URL="https://ftp.gnu.org/gnu/ncurses/${NCURSES_TAR}"
  LIBEVENT_TAR="libevent-${LIBEVENT_VER}.tar.gz"
  LIBEVENT_URL="https://github.com/libevent/libevent/releases/download/release-${LIBEVENT_VER}/${LIBEVENT_TAR}"
  TMUX_TAR="tmux-${TMUX_VER}.tar.gz"
  TMUX_URL="https://github.com/tmux/tmux/releases/download/${TMUX_VER}/${TMUX_TAR}"

  log "   Descargando fuentes a ${SRC_DIR}…"
  mkdir -p "$SRC_DIR"
  pushd "$SRC_DIR" >/dev/null

  [[ -f "$NCURSES_TAR" ]] || download "$NCURSES_URL" "$NCURSES_TAR"
  [[ -f "$LIBEVENT_TAR" ]] || download "$LIBEVENT_URL" "$LIBEVENT_TAR"
  [[ -f "$TMUX_TAR" ]] || download "$TMUX_URL" "$TMUX_TAR"

  log "   Extrayendo…"
  rm -rf "ncurses-${NCURSES_VER}" "libevent-${LIBEVENT_VER}" "tmux-${TMUX_VER}" || true
  tar -xzf "$NCURSES_TAR"
  tar -xzf "$LIBEVENT_TAR"
  tar -xzf "$TMUX_TAR"

  # Build NCURSES (local)
  log "   Compilando ncurses ${NCURSES_VER} (local)…"
  pushd "ncurses-${NCURSES_VER}" >/dev/null
  ./configure --prefix="$PREFIX" --with-shared --without-debug --enable-widec
  make -j"$(nproc)"
  make install
  popd >/dev/null

  # Build LIBEVENT (local)
  log "   Compilando libevent ${LIBEVENT_VER} (local)…"
  pushd "libevent-${LIBEVENT_VER}" >/dev/null
  ./configure --prefix="$PREFIX" --disable-openssl
  make -j"$(nproc)"
  make install
  popd >/dev/null

  # Build TMUX (local), enlazando contra libs locales
  log "   Compilando tmux ${TMUX_VER} (local)…"
  pushd "tmux-${TMUX_VER}" >/dev/null
  CPPFLAGS="-I${PREFIX}/include -I${PREFIX}/include/ncursesw" \
  LDFLAGS="-L${PREFIX}/lib" \
  PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig" \
  ./configure --prefix="$PREFIX"
  make -j"$(nproc)"
  make install
  popd >/dev/null

  popd >/dev/null

  # Symlink conveniente a ~/.local/bin
  ln -sf "${PREFIX}/bin/tmux" "${BIN_DIR}/tmux"
  log "   tmux local instalado en ${PREFIX}/bin/tmux y enlazado desde ${BIN_DIR}/tmux"
fi

# 4) launchers del alumno
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

# tip: -p 0 para puerto aleatorio
exec "$EXEC" "$@"
EOF
chmod +x "${BIN_DIR}/gdb-frontend-run"

# c-debug-frontend
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

# Ruta absoluta portable
SRC_ABS="$(python3 - "$SRC" <<'PY'
import os,sys; print(os.path.abspath(sys.argv[1]))
PY
)"
SRC_DIR="$(dirname "$SRC_ABS")"
SRC_BASE="$(basename "$SRC_ABS")"
EXE_BASENAME="${SRC_BASE%.*}"
EXE_PATH="${SRC_DIR}/${EXE_BASENAME}"

# Compilación amigable para debug
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
exec "$EXEC" -p 0
EOF
chmod +x "${BIN_DIR}/c-debug-frontend"

log "   Creado: ${BIN_DIR}/gdb-frontend-run y ${BIN_DIR}/c-debug-frontend"

# 5) ownership final
if [[ -n "$STUDENT_USER" ]]; then
  log "5) Ajustando ownership a ${STUDENT_USER}:${STUDENT_USER}…"
  chown -R "${STUDENT_USER}:${STUDENT_USER}" \
    "$BIN_DIR" "$FRONTEND_DIR" "$BASHRC" "$PREFIX" "$SRC_DIR" || true
else
  warn "5) (omitido) --student-user no especificado; revisá ownership."
fi

# 6) checks informativos
log "6) Chequeos informativos:"
if as_student 'command -v tmux >/dev/null 2>&1'; then
  log "   tmux en PATH del alumno: OK ($(as_student 'tmux -V' 2>/dev/null || echo tmux))"
else
  warn "   tmux no quedó en PATH del alumno. Revisar ${PREFIX}/bin/tmux y ~/.bashrc"
fi
if as_student 'command -v python3 >/dev/null 2>&1'; then
  log "   python3: OK"
else
  warn "   python3 no detectado para el alumno (generalmente viene instalado)."
fi
if as_student 'command -v gdb >/dev/null 2>&1'; then
  log "   gdb: OK"
else
  warn "   gdb no detectado en PATH del alumno."
fi

log "==== TODO LISTO ===="
echo "Como el alumno, abrí NUEVA terminal y probá:"
echo "  gdb-frontend-run -p 0         # imprime URL/puerto (web UI)"
echo "  c-debug-frontend /ruta/a.c    # compila y abre el frontend en esa carpeta"
