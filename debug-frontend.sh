#!/usr/bin/env bash
set -euo pipefail

# debug-frontend.sh
# Compila (con símbolos) y abre gdb-frontend en la carpeta del fuente/proyecto.
# Soporta: archivo.c  |  proyecto.cbp (Code::Blocks)
#
# Requisitos: gcc/g++ (según fuentes), gdb, tmux, y el launcher `gdb-frontend-run` en PATH.

die() { echo "[ERROR] $*" >&2; exit 1; }
info(){ echo "[INFO ] $*" >&2; }

# --- resolver ruta absoluta portable (sin depender de readlink -f en todas distros)
abspath() {
  python3 - "$1" <<'PY'
import os,sys
print(os.path.abspath(sys.argv[1]))
PY
}

[[ $# -ge 1 ]] || die "Uso: $0 <archivo.c | proyecto.cbp> [args-del-programa...]"

INPUT="$1"; shift || true
[[ -e "$INPUT" ]] || die "No existe: $INPUT"

INPUT_ABS="$(abspath "$INPUT")"
INPUT_DIR="$(dirname "$INPUT_ABS")"
INPUT_BASE="$(basename "$INPUT_ABS")"

need_cxx="no"
sources=()
includes=()
exe_path=""

# --- helpers de compilación
compile_c() {
  local src_abs="$1"
  local dir="$(dirname "$src_abs")"
  local base="$(basename "$src_abs")"
  local name="${base%.*}"
  local out="${dir}/${name}"
  info "Compilando C: ${base}  →  ${out}"
  gcc -g -O0 -Wall -fno-omit-frame-pointer -o "$out" "$src_abs"
  exe_path="$out"
}

compile_project_cbp() {
  local cbp_abs="$1"
  local proj_dir="$(dirname "$cbp_abs")"
  local proj_base="$(basename "$cbp_abs")"
  local proj_name="${proj_base%.*}"

  info "Analizando proyecto Code::Blocks: $proj_base"

  # 1) extraer Units (archivos fuente)
  #    Soporta Unit con comillas simples o dobles, caminos relativos/absolutos.
  mapfile -t sources < <(sed -n 's/.*<Unit[[:space:]][^>]*filename=[\"\x27]\([^\"\x27]*\)[\"\x27].*/\1/p' "$cbp_abs" | sed 's/\r$//')
  [[ ${#sources[@]} -gt 0 ]] || die "No se encontraron <Unit filename=\"...\"> en el .cbp"

  # Normalizar a rutas absolutas y detectar si hay .cpp
  local norm_sources=()
  for s in "${sources[@]}"; do
    if [[ "$s" != /* ]]; then
      s="${proj_dir}/$s"
    fi
    s="$(abspath "$s")"
    [[ -f "$s" ]] || die "Unidad declarada pero no existe: $s"
    norm_sources+=("$s")
    case "$s" in
      *.cpp|*.cxx|*.cc) need_cxx="yes" ;;
    esac
  done
  sources=("${norm_sources[@]}")

  # 2) includes del proyecto: <Add directory="..."> dentro de <Compiler>
  mapfile -t includes < <(sed -n 's/.*<Add[[:space:]][^>]*directory=[\"\x27]\([^\"\x27]*\)[\"\x27].*/\1/p' "$cbp_abs" | sed 's/\r$//')
  local norm_includes=()
  for inc in "${includes[@]}"; do
    if [[ "$inc" != /* ]]; then
      inc="${proj_dir}/$inc"
    fi
    inc="$(abspath "$inc")"
    norm_includes+=("$inc")
  done
  includes=("${norm_includes[@]}")

  # 3) nombre del ejecutable: si hay <Option output="..."> lo usamos; si no, proj_name en proj_dir
  local output_xml
  output_xml="$(sed -n 's/.*<Option[[:space:]][^>]*output=[\"\x27]\([^\"\x27]*\)[\"\x27].*/\1/p' "$cbp_abs" | head -n1 || true)"
  if [[ -n "${output_xml:-}" ]]; then
    if [[ "$output_xml" != /* ]]; then
      exe_path="$(abspath "${proj_dir}/${output_xml}")"
    else
      exe_path="$(abspath "$output_xml")"
    fi
  else
    exe_path="$(abspath "${proj_dir}/${proj_name}")"
  fi
  local out_dir="$(dirname "$exe_path")"
  mkdir -p "$out_dir"

  # 4) compilar (g++ si hay C++; si no, gcc). Pasamos includes con -I
  local CC="gcc"
  [[ "$need_cxx" == "yes" ]] && CC="g++"

  # Construir lista de includes (-I)
  local incflags=()
  for inc in "${includes[@]}"; do
    incflags+=("-I" "$inc")
  done

  info "Compilando proyecto → ${exe_path}"
  info "  Compilador: $CC"
  if [[ ${#includes[@]} -gt 0 ]]; then
    info "  Includes: ${includes[*]}"
  fi

  # Compilación directa (simple): todas las fuentes linkeadas en una
  "$CC" -g -O0 -Wall -fno-omit-frame-pointer "${incflags[@]}" "${sources[@]}" -o "$exe_path"

  # Nota: si el proyecto requiere libs extra (SDL, pthread, etc.) tendrás que agregarlas
  # a mano o extender este script para leerlas del .cbp (<Linker>).
}

launch_frontend() {
  local wd="$1"
  info "Iniciando gdb-frontend en: $wd"
  cd "$wd"
  # -p 0 → puerto aleatorio; gdb-frontend imprime la URL/puerto en stdout
  if command -v gdb-frontend-run >/dev/null 2>&1; then
    exec gdb-frontend-run -p 0
  else
    die "No encuentro 'gdb-frontend-run' en PATH. ¿Se instaló el launcher?"
  fi
}

case "$INPUT_ABS" in
  *.c)
    compile_c "$INPUT_ABS"
    launch_frontend "$(dirname "$exe_path")"
    ;;
  *.cbp)
    compile_project_cbp "$INPUT_ABS"
    launch_frontend "$(dirname "$exe_path")"
    ;;
  *)
    die "Extensión no soportada: $INPUT_BASE (esperaba .c o .cbp)"
    ;;
esac
