#!/bin/bash
#
# make-sticker.sh — crea stickers de WhatsApp (webp 512x512) a partir de una
# imagen estática o de un vídeo/gif corto, usando ffmpeg.
#
# Plan: PLAN-001, tarea T-10 (decisión D2). Límites de wacli (ADR-001):
#   - Estático : webp 512x512 con fondo transparente, <= 100 KiB (102400 B).
#   - Animado  : webp 512x512, fps=12, con metadata de animación
#                (chunks ANIM/ANMF y bucle infinito), <= 500 KiB (512000 B).
#   Un sticker fuera de límite NUNCA se entrega ni se envía.
#
# Uso:
#   make-sticker.sh <entrada> [--send <JID>] [--out <dir>]
#
#   <entrada>      Imagen (png/jpg/webp/...) o vídeo/gif corto (gif/mp4/webm/...).
#                  Se valida que exista, sea legible y sea imagen o vídeo.
#   --send <JID>   Al terminar, envía el sticker con:
#                  wacli send sticker --to <JID> --file <ruta>
#                  (con --send el fichero NO se conserva: solo se envía).
#   --out <dir>    Dónde dejar el sticker creado (defecto: ./downloads).
#                  Solo se usa cuando NO se pasa --send.
#   -h, --help     Muestra esta ayuda.
#
# Variables de entorno:
#   STICKER_MAX_SEC  Duración máxima (s) aplicada a la entrada de vídeo.
#                    Defecto: 15. Debe ser un entero >= 1.
#   DEBUG=1          Mensajes de depuración adicionales (stderr).
#
# Códigos de salida:
#   0  Éxito (creado; y enviado si se pasa --send)
#   1  Uso incorrecto o error genérico
#   2  La entrada no existe o no es un fichero legible
#   3  Tipo de entrada no soportado (no es imagen ni vídeo)
#   4  ffmpeg ha fallado durante la conversión
#   5  No se alcanza el límite de tamaño: no se entrega ni se envía
#   6  Dependencia ausente (ffmpeg; wacli además si se usa --send)
#   7  Envío fallido (wacli send sticker)
#
# Contrato de salida:
#   - stdout: sin --send, la ruta ABSOLUTA del sticker creado (1 línea);
#     con --send, una confirmación de envío. Nada más.
#   - stderr: todo el resto (avisos, errores, progreso de ffmpeg).
#
# Limitaciones conocidas:
#   - ffmpeg 6.x NO puede leer webp ANIMADO de entrada (falla con código 4);
#     entrar por gif/mp4/webm en ese caso.
#   - Si `file` no está instalado, el tipo se deduce de la extensión.
#   - Un fichero homónimo en --out se sobrescribe.

set -Eeuo pipefail

SCRIPT_NAME="${BASH_SOURCE[0]##*/}"

# --- Límites duros de wacli (no configurables) ------------------------------
readonly MAX_STATIC_BYTES=$((100 * 1024))   # 100 KiB
readonly MAX_ANIMATED_BYTES=$((500 * 1024)) # 500 KiB

# --- Escalones de iteración --------------------------------------------------
# Estático: calidades decrecientes hasta caber en 100 KiB.
declare -ar CALIDADES_ESTATICA=(85 75 65 55 45 35 25 15 8)
# Animado: primero duración completa (acotada) con calidades decrecientes...
declare -ar CALIDADES_ANIMADA=(70 55 45 35 25 20 15 10 8)
# ...y si no cabe, recortar duración (s) probando calidades por rung.
declare -ar DURACIONES_RECORTE=(10 7 5 3 2)
declare -ar CALIDADES_RECORTE=(25 15 8)

# Cadenas de filtros: aspecto contenido + lienzo 512x512 con fondo transparente.
# format=bgra al final es imprescindible: sin él la negociación de formatos
# puede dejar el pad en yuv420p y las barras saldrían NEGRO OPAQUE en vez de
# transparentes (verificado empíricamente con ffmpeg 6.1).
readonly VF_ESTATICA="scale=512:512:force_original_aspect_ratio=decrease:flags=lanczos,pad=512:512:(ow-iw)/2:(oh-ih)/2:color=0x00000000,format=bgra"
readonly VF_ANIMADA="fps=12,scale=512:512:force_original_aspect_ratio=decrease:flags=lanczos,pad=512:512:(ow-iw)/2:(oh-ih)/2:color=0x00000000,format=bgra"

# --- Estado ------------------------------------------------------------------
TMP_DIR=""
SALIDA_TMP=""
entrada=""
send_to=""
out_dir=""
out_dir_explicito=0
TOPE_DURACION=15

# --- Utilidades de registro (siempre a stderr) -------------------------------
log_error() { printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2; }
log_aviso() { printf '%s: aviso: %s\n' "$SCRIPT_NAME" "$*" >&2; }
log_info()  { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; }
log_debug() {
  if [[ "${DEBUG:-0}" == "1" ]]; then
    printf '%s: debug: %s\n' "$SCRIPT_NAME" "$*" >&2
  fi
}

mostrar_ayuda() {
  cat <<EOF
Uso: $SCRIPT_NAME <entrada> [--send <JID>] [--out <dir>]

Crea un sticker de WhatsApp (webp 512x512) con ffmpeg:
  - imagen estática -> <= 100 KiB, fondo transparente
  - gif/vídeo corto -> <= 500 KiB, fps=12, animado (bucle infinito)

Opciones:
  --send <JID>   Envía el sticker con wacli send sticker (no se conserva copia)
  --out <dir>    Dónde dejar el sticker (defecto: ./downloads)
  -h, --help     Esta ayuda

Variables de entorno:
  STICKER_MAX_SEC  Duración máxima (s) del vídeo de entrada (defecto: 15)
  DEBUG=1          Depuración adicional

Códigos de salida:
  0 éxito | 1 uso/error genérico | 2 entrada ilegible | 3 tipo no soportado
  4 error de ffmpeg | 5 límite de tamaño no alcanzable | 6 dependencia ausente
  7 envío fallido
EOF
}

# --- Limpieza y trampas ------------------------------------------------------
# shellcheck disable=SC2317  # invocada indirectamente vía trap EXIT
limpiar() {
  # Se ejecuta SIEMPRE (éxito o fallo): borra el directorio temporal propio.
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR" || true
  fi
}

# shellcheck disable=SC2317  # invocada indirectamente vía trap ERR
on_error_inesperado() {
  log_error "error inesperado en la línea ${LINENO} (código $?)"
}

# --- Validaciones ------------------------------------------------------------
# Clasifica la entrada: imprime 'estatico' | 'animado'; sale con 3 si no es
# imagen ni vídeo.
detectar_tipo() {
  local -r fichero="$1"
  local mime=""
  if command -v file >/dev/null 2>&1; then
    mime=$(file --brief --mime-type -- "$fichero" 2>/dev/null) || mime=""
    case "$mime" in
      image/gif) printf 'animado\n'; return 0 ;;
      image/*)   printf 'estatico\n'; return 0 ;;
      video/*)   printf 'animado\n'; return 0 ;;
      "") ;; # file ha fallado: se intenta con la extensión
      *)
        log_error "tipo no soportado: '$mime' (no es imagen ni vídeo): $fichero"
        exit 3
        ;;
    esac
  fi
  # Fallback por extensión (cuando `file` no está disponible o no decide)
  local base ext
  base="${fichero##*/}"
  if [[ "$base" == *.* ]]; then
    ext="${base##*.}"
    ext="${ext,,}"
  else
    ext=""
  fi
  case "$ext" in
    png|jpg|jpeg|jpe|webp|bmp|tif|tiff|heic|heif|avif)
      printf 'estatico\n' ;;
    gif|webm|mp4|mov|mkv|avi|m4v|mpeg|mpg|ts|3gp|ogv)
      printf 'animado\n' ;;
    *)
      log_error "tipo no soportado (extensión '.$ext' desconocida): $fichero"
      exit 3
      ;;
  esac
}

# --- Conversión --------------------------------------------------------------
# Ejecuta ffmpeg redirigiendo su salida a stderr; código 4 si falla.
ejecutar_ffmpeg() {
  local rc
  "$@" >&2 || {
    rc=$?
    log_error "ffmpeg ha fallado (código $rc) al procesar '$entrada'"
    exit 4
  }
}

tamano_del_fichero() {
  # Imprime el tamaño en bytes; código 1 si no se puede leer.
  local sz
  sz=$(stat -c%s -- "$1") || {
    log_error "no se pudo leer el tamaño de '$1'"
    exit 1
  }
  printf '%s\n' "$sz"
}

crear_estatico() {
  local q sz
  for q in "${CALIDADES_ESTATICA[@]}"; do
    ejecutar_ffmpeg ffmpeg -y -hide_banner -loglevel error -i "$entrada" \
      -frames:v 1 -vf "$VF_ESTATICA" \
      -c:v libwebp -lossless 0 -q:v "$q" -compression_level 6 \
      -an -sn -dn "$SALIDA_TMP"
    sz=$(tamano_del_fichero "$SALIDA_TMP")
    if (( sz <= MAX_STATIC_BYTES )); then
      log_info "sticker estático creado: calidad q=$q, $sz bytes (límite 100 KiB)"
      return 0
    fi
    log_debug "q=$q -> $sz bytes > 100 KiB; reintentando con calidad menor"
  done
  log_error "no se alcanza el límite de 100 KiB para '$entrada' (con q=8 aún son $sz bytes); NO se entrega ni se envía"
  exit 5
}

# render_animado <calidad> [duración_s]
# Sin duración usa TOPE_DURACION. -t va antes de -i para acotar la LECTURA.
render_animado() {
  local -r q="$1"
  local dur="${2:-}"
  if [[ -z "$dur" ]]; then
    dur="$TOPE_DURACION"
  fi
  ejecutar_ffmpeg ffmpeg -y -hide_banner -loglevel error -t "$dur" -i "$entrada" \
    -vf "$VF_ANIMADA" -c:v libwebp -lossless 0 -q:v "$q" -compression_level 6 \
    -loop 0 -an -sn -dn "$SALIDA_TMP"
}

crear_animado() {
  local q d sz
  # 1) Duración completa (acotada) con escalón de calidades decrecientes.
  for q in "${CALIDADES_ANIMADA[@]}"; do
    render_animado "$q" ""
    sz=$(tamano_del_fichero "$SALIDA_TMP")
    if (( sz <= MAX_ANIMATED_BYTES )); then
      log_info "sticker animado creado: calidad q=$q, $sz bytes (límite 500 KiB)"
      return 0
    fi
    log_debug "q=$q -> $sz bytes > 500 KiB; reintentando con calidad menor"
  done
  # 2) Recortar duración: solo rungs que realmente acortan la entrada.
  for d in "${DURACIONES_RECORTE[@]}"; do
    if (( d >= TOPE_DURACION )); then
      continue
    fi
    for q in "${CALIDADES_RECORTE[@]}"; do
      render_animado "$q" "$d"
      sz=$(tamano_del_fichero "$SALIDA_TMP")
      if (( sz <= MAX_ANIMATED_BYTES )); then
        log_aviso "sticker RECORTADO a ${d}s (q=$q, $sz bytes) para cumplir el límite de 500 KiB"
        return 0
      fi
      log_debug "recorte a ${d}s con q=$q -> $sz bytes > 500 KiB"
    done
  done
  log_error "no se alcanza el límite de 500 KiB para '$entrada' (último intento: $sz bytes); NO se entrega ni se envía"
  exit 5
}

# --- Entrega y envío ---------------------------------------------------------
entregar_sticker() {
  # Mueve el sticker a out_dir y imprime su ruta absoluta por stdout.
  local stem destino dir_abs
  mkdir -p -- "$out_dir" || {
    log_error "no se pudo crear el directorio de salida '$out_dir'"
    exit 1
  }
  dir_abs=$(cd -- "$out_dir" && pwd -P) || {
    log_error "no se pudo resolver el directorio de salida '$out_dir'"
    exit 1
  }
  stem="${entrada##*/}"
  stem="${stem%.*}"
  if [[ -z "$stem" ]]; then
    stem="sticker"
  fi
  destino="$dir_abs/$stem.webp"
  mv -- "$SALIDA_TMP" "$destino" || {
    log_error "no se pudo mover el sticker a '$destino'"
    exit 1
  }
  printf '%s\n' "$destino"
}

enviar_sticker() {
  local rc
  log_info "enviando sticker a '$send_to'..."
  # La salida de wacli va a stderr para dejar stdout limpio (contrato).
  wacli send sticker --to "$send_to" --file "$SALIDA_TMP" >&2 || {
    rc=$?
    log_error "wacli send sticker ha fallado (código $rc) para '$send_to'"
    exit 7
  }
  printf 'Sticker enviado a %s\n' "$send_to"
}

# --- Análisis de argumentos --------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      mostrar_ayuda
      exit 0
      ;;
    --send)
      if [[ $# -lt 2 || -z "$2" ]]; then
        log_error "--send requiere un JID"
        mostrar_ayuda >&2
        exit 1
      fi
      send_to="$2"
      shift 2
      ;;
    --out)
      if [[ $# -lt 2 || -z "$2" ]]; then
        log_error "--out requiere un directorio"
        mostrar_ayuda >&2
        exit 1
      fi
      out_dir="$2"
      out_dir_explicito=1
      shift 2
      ;;
    --*)
      log_error "opción desconocida: $1"
      mostrar_ayuda >&2
      exit 1
      ;;
    *)
      if [[ -n "$entrada" ]]; then
        log_error "argumento posicional inesperado: $1"
        mostrar_ayuda >&2
        exit 1
      fi
      entrada="$1"
      shift
      ;;
  esac
done

if [[ -z "$entrada" ]]; then
  log_error "falta el fichero de entrada"
  mostrar_ayuda >&2
  exit 1
fi
if [[ -z "$out_dir" ]]; then
  out_dir="./downloads"
fi

# STICKER_MAX_SEC: entero >= 1
if [[ ! "${STICKER_MAX_SEC:-15}" =~ ^[1-9][0-9]{0,4}$ ]]; then
  log_error "STICKER_MAX_SEC debe ser un entero >= 1 (recibido: '${STICKER_MAX_SEC:-}')"
  exit 1
fi
readonly STICKER_MAX_SEC_VALUE="${STICKER_MAX_SEC:-15}"
TOPE_DURACION="$STICKER_MAX_SEC_VALUE"

# --- Validación de la entrada ------------------------------------------------
if [[ ! -e "$entrada" ]]; then
  log_error "la entrada no existe: $entrada"
  exit 2
fi
if [[ ! -f "$entrada" ]]; then
  log_error "la entrada no es un fichero: $entrada"
  exit 2
fi
if [[ ! -r "$entrada" ]]; then
  log_error "la entrada no es legible: $entrada"
  exit 2
fi
if [[ ! -s "$entrada" ]]; then
  log_error "la entrada está vacía: $entrada"
  exit 2
fi

# Tipo antes que dependencias: el error del usuario primero.
tipo=$(detectar_tipo "$entrada") || exit $?

# --- Dependencias ------------------------------------------------------------
if ! command -v ffmpeg >/dev/null 2>&1; then
  log_error "ffmpeg no está instalado o no está en PATH"
  exit 6
fi
if [[ -n "$send_to" ]] && ! command -v wacli >/dev/null 2>&1; then
  log_error "wacli no está instalado o no está en PATH (necesario con --send)"
  exit 6
fi
if [[ "$tipo" == "animado" ]] && ! command -v ffprobe >/dev/null 2>&1; then
  log_aviso "ffprobe no está disponible: no se podrá informar de la duración"
fi

trap limpiar EXIT
trap on_error_inesperado ERR

# --- Directorio temporal propio ---------------------------------------------
TMP_DIR=$(mktemp -d) || {
  log_error "no se pudo crear el directorio temporal"
  exit 1
}
SALIDA_TMP="$TMP_DIR/sticker.webp"
log_debug "directorio temporal: $TMP_DIR"

if [[ -n "$send_to" && "$out_dir_explicito" -eq 1 ]]; then
  log_aviso "con --send se ignora --out: el sticker solo se envía, no se conserva"
fi

# --- Duración real de la entrada animada (si ffprobe está disponible) --------
if [[ "$tipo" == "animado" ]] && command -v ffprobe >/dev/null 2>&1; then
  dur_entrada=$(ffprobe -v error -show_entries format=duration \
    -of default=nw=1:nk=1 -- "$entrada" 2>/dev/null) || dur_entrada=""
  if [[ "$dur_entrada" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    dur_int="${dur_entrada%%.*}"
    if (( dur_int > 0 && dur_int < TOPE_DURACION )); then
      TOPE_DURACION="$dur_int"
    fi
    if (( dur_int > STICKER_MAX_SEC_VALUE )); then
      log_aviso "la entrada dura ${dur_entrada}s: se acota a ${STICKER_MAX_SEC_VALUE}s (STICKER_MAX_SEC)"
    fi
  else
    dur_entrada=""
  fi
  log_debug "duración de la entrada: ${dur_entrada:-desconocida}s; tope efectivo: ${TOPE_DURACION}s"
fi

# --- Conversión --------------------------------------------------------------
log_info "convirtiendo '$entrada' ($tipo) a webp 512x512..."
case "$tipo" in
  estatico) crear_estatico ;;
  animado)  crear_animado ;;
  *)
    log_error "tipo interno desconocido: $tipo"
    exit 3
    ;;
esac

# Verificación final de límite (defensa en profundidad: los bucles ya la hacen)
tamano_final=$(tamano_del_fichero "$SALIDA_TMP")
if [[ "$tipo" == "estatico" ]]; then
  if (( tamano_final > MAX_STATIC_BYTES )); then
    log_error "verificación final fallida: $tamano_final bytes > 100 KiB; NO se entrega ni se envía"
    exit 5
  fi
else
  if (( tamano_final > MAX_ANIMATED_BYTES )); then
    log_error "verificación final fallida: $tamano_final bytes > 500 KiB; NO se entrega ni se envía"
    exit 5
  fi
fi

# --- Envío o entrega ---------------------------------------------------------
if [[ -n "$send_to" ]]; then
  enviar_sticker
else
  entregar_sticker
fi

exit 0
