#!/bin/bash
#
# ytdl.sh — descarga vídeos o audio de YouTube con yt-dlp de forma defensiva.
#
# Plan: PLAN-001, tarea T-12 (decisión D3) · skill bash-defensive-patterns.
#
# Uso:
#   ytdl.sh <URL> <video|audio> [--out <dir>]
#
#   <URL>          Debe empezar por http:// o https:// y el HOST debe estar
#                  en la allowlist (parsing de URL propio, no grep: se
#                  rechazan hostes tipo youtube.com.evil.com y trucos con
#                  userinfo tipo youtube.com@evil.com).
#   video          -f 'best[ext=mp4]/best'
#   audio          -x --audio-format mp3 (nunca m3u8)
#   --out <dir>    Directorio donde dejar el artefacto (defecto: ./downloads).
#   -h, --help     Muestra esta ayuda.
#
# Ambas rutas usan --no-playlist: solo se descarga el elemento de la URL.
#
# Variables de entorno:
#   MEDIA_MAX_MB       Tamaño máximo del artefacto en MB (defecto: 50).
#                      Debe ser un entero >= 1. Se comprueba con stat ANTES
#                      de entregar el fichero.
#   YTDL_KEEP_OVERSIZE 0 (defecto): si el archivo supera MEDIA_MAX_MB NO se
#                      entrega (se borra con el tmpdir) y se sale con 5.
#                      1: se conserva igualmente y se imprime su ruta (aunque
#                      la salida siga siendo 5) para permitir al SKILL
#                      enviarlo como documento si MEDIA_FORCE_DOCUMENT=true.
#   DEBUG=1            Mensajes de depuración adicionales (stderr).
#
# Códigos de salida:
#   0  Éxito: artefacto entregado; su ruta ABSOLUTA se imprime en stdout
#   1  Uso incorrecto o error genérico
#   2  URL inválida (malformada: sin esquema http(s), host vacío o con
#      caracteres no permitidos)
#   3  Dominio no permitido (fuera de la allowlist de YouTube)
#   4  Descarga fallida (yt-dlp con error, o artefacto inesperado)
#   5  El archivo supera MEDIA_MAX_MB (no se entrega por defecto)
#   6  Dependencia ausente (yt-dlp o ffmpeg)
#
# Contrato de salida:
#   - stdout: solo la ruta absoluta del artefacto (o la conservación con
#     YTDL_KEEP_OVERSIZE=1, siempre con salida 5).
#   - stderr: todo el resto (avisos, errores, progreso de yt-dlp).
#
# Limpieza: el directorio temporal propio (mktemp -d) se elimina SIEMPRE en
# EXIT, tanto en éxito como en cualquier fallo.

set -Eeuo pipefail

SCRIPT_NAME="${BASH_SOURCE[0]##*/}"

# Allowlist estricta (coincidencia exacta con el host, en minúsculas).
# music.youtube.com es opcional en el plan y se incluye deliberadamente.
readonly -a DOMINIOS_PERMITIDOS=(
  youtube.com
  www.youtube.com
  m.youtube.com
  music.youtube.com
  youtu.be
)

# --- Estado ------------------------------------------------------------------
TMP_DIR=""
url=""
modo=""
out_dir=""

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
Uso: $SCRIPT_NAME <URL> <video|audio> [--out <dir>]

Descarga de YouTube con yt-dlp, con allowlist de dominios y límite de tamaño.

  video   -f 'best[ext=mp4]/best'  --no-playlist
  audio   -x --audio-format mp3     --no-playlist
  --out   Directorio de salida (defecto: ./downloads)

Dominios permitidos: ${DOMINIOS_PERMITIDOS[*]}

Variables de entorno:
  MEDIA_MAX_MB       Tamaño máximo en MB (defecto: 50)
  YTDL_KEEP_OVERSIZE 1 = conservar el fichero al superar el límite (sale con 5)
  DEBUG=1            Depuración adicional

Códigos de salida:
  0 éxito | 1 uso/error genérico | 2 URL inválida | 3 dominio no permitido
  4 descarga fallida | 5 supera MEDIA_MAX_MB | 6 dependencia ausente
EOF
}

# --- Limpieza y trampas ------------------------------------------------------
# shellcheck disable=SC2317  # invocada indirectamente vía trap EXIT
limpiar() {
  # Se ejecuta SIEMPRE (éxito o fallo): no deja basura en tmp.
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR" || true
  fi
}

# shellcheck disable=SC2317  # invocada indirectamente vía trap ERR
on_error_inesperado() {
  log_error "error inesperado en la línea ${LINENO} (código $?)"
}

# --- Validación de la URL ----------------------------------------------------
# Imprime el host en minúsculas. Sale con 2 (URL malformada) o 3 (dominio
# fuera de la allowlist). Parsing con expansión de parámetros de bash, nunca
# con grep: "youtube.com.evil.com" o "youtube.com@evil.com" quedan fuera.
extraer_host_permitido() {
  local -r entrada_url="$1"
  local bajo resto autoridad host

  bajo="${entrada_url,,}"
  if [[ "$bajo" != http://* && "$bajo" != https://* ]]; then
    log_error "URL inválida (debe empezar por http:// o https://): $(printf '%q' "$entrada_url")"
    exit 2
  fi

  # Parte tras el esquema, hasta el primer '/', '?' o '#'
  resto="${entrada_url#*://}"
  autoridad="${resto%%[/?#]*}"
  if [[ -z "$autoridad" ]]; then
    log_error "URL inválida (host vacío): $(printf '%q' "$entrada_url")"
    exit 2
  fi

  # userinfo (usuario:contraseña@) → lo que queda tras el ÚLTIMO '@' es el host
  host="${autoridad##*@}"

  # Puerto numérico opcional
  if [[ "$host" =~ ^(.+):[0-9]+$ ]]; then
    host="${BASH_REMATCH[1]}"
  fi
  host="${host,,}"

  # Charset estricto de host: sin esto, '@', ':' o '%' permitirían trucos
  if [[ -z "$host" || ! "$host" =~ ^[a-z0-9.-]+$ ]]; then
    log_error "URL inválida (host no reconocido): $(printf '%q' "$entrada_url")"
    exit 2
  fi

  local permitido=0 d
  for d in "${DOMINIOS_PERMITIDOS[@]}"; do
    if [[ "$host" == "$d" ]]; then
      permitido=1
      break
    fi
  done
  if (( permitido == 0 )); then
    log_error "dominio no permitido: '$host' (permitidos: ${DOMINIOS_PERMITIDOS[*]})"
    exit 3
  fi

  printf '%s\n' "$host"
}

# --- Entrega -----------------------------------------------------------------
entregar_artefacto() {
  # Mueve el artefacto a out_dir y imprime su ruta absoluta por stdout.
  local -r origen="$1"
  local base dir_abs
  mkdir -p -- "$out_dir" || {
    log_error "no se pudo crear el directorio de salida '$out_dir'"
    exit 1
  }
  dir_abs=$(cd -- "$out_dir" && pwd -P) || {
    log_error "no se pudo resolver el directorio de salida '$out_dir'"
    exit 1
  }
  base="${origen##*/}"
  mv -- "$origen" "$dir_abs/$base" || {
    log_error "no se pudo mover el artefacto a '$dir_abs'"
    exit 1
  }
  printf '%s\n' "$dir_abs/$base"
}

# --- Análisis de argumentos --------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      mostrar_ayuda
      exit 0
      ;;
    --out)
      if [[ $# -lt 2 || -z "$2" ]]; then
        log_error "--out requiere un directorio"
        mostrar_ayuda >&2
        exit 1
      fi
      out_dir="$2"
      shift 2
      ;;
    --*)
      log_error "opción desconocida: $1"
      mostrar_ayuda >&2
      exit 1
      ;;
    *)
      if [[ -z "$url" ]]; then
        url="$1"
      elif [[ -z "$modo" ]]; then
        modo="$1"
      else
        log_error "argumento posicional inesperado: $1"
        mostrar_ayuda >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$url" || -z "$modo" ]]; then
  log_error "faltan argumentos: se requiere <URL> y <video|audio>"
  mostrar_ayuda >&2
  exit 1
fi
if [[ "$modo" != "video" && "$modo" != "audio" ]]; then
  log_error "modo no válido: '$modo' (debe ser 'video' o 'audio')"
  mostrar_ayuda >&2
  exit 1
fi
if [[ -z "$out_dir" ]]; then
  out_dir="./downloads"
fi

# MEDIA_MAX_MB: validar ANTES de descargar (no gastar red para luego tirar)
readonly MEDIA_MAX_MB_VALUE="${MEDIA_MAX_MB:-50}"
if [[ ! "$MEDIA_MAX_MB_VALUE" =~ ^[1-9][0-9]{0,6}$ ]]; then
  log_error "MEDIA_MAX_MB debe ser un entero >= 1 (recibido: '${MEDIA_MAX_MB:-}')"
  exit 1
fi
readonly MAX_BYTES=$((MEDIA_MAX_MB_VALUE * 1024 * 1024))

# --- Validación de URL y dominio (antes de tocar red) ------------------------
host=$(extraer_host_permitido "$url") || exit $?

# --- Dependencias ------------------------------------------------------------
if ! command -v yt-dlp >/dev/null 2>&1; then
  log_error "yt-dlp no está instalado o no está en PATH"
  exit 6
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  log_error "ffmpeg no está instalado o no está en PATH (necesario para fusionar/convertir)"
  exit 6
fi

trap limpiar EXIT
trap on_error_inesperado ERR

# --- Directorio temporal propio ---------------------------------------------
TMP_DIR=$(mktemp -d) || {
  log_error "no se pudo crear el directorio temporal"
  exit 1
}
log_debug "directorio temporal: $TMP_DIR"

# --- Descarga ----------------------------------------------------------------
# Plantilla dentro del tmpdir: solo puede haber un artefacto (--no-playlist).
plantilla="$TMP_DIR/%(title).80B [%(id)s].%(ext)s"

declare -a args=(--ignore-config --no-playlist --no-part --newline)
if [[ "$modo" == "video" ]]; then
  args+=(-f 'best[ext=mp4]/best')
else
  args+=(-x --audio-format mp3)
fi
args+=(-o "$plantilla")

log_info "descargando en modo '$modo' desde host '$host'..."
log_debug "yt-dlp ${args[*]} $(printf '%q' "$url")"

yt-dlp "${args[@]}" "$url" >&2 || {
  rc=$?
  log_error "yt-dlp ha fallado (código $rc); la descarga NO se entrega"
  exit 4
}

# --- Comprobación del artefacto ----------------------------------------------
declare -a artefactos=()
while IFS= read -r -d '' fichero; do
  artefactos+=("$fichero")
done < <(find "$TMP_DIR" -maxdepth 1 -type f \
  ! -name '*.part' ! -name '*.ytdl' ! -name '*.tmp' -print0)

if (( ${#artefactos[@]} != 1 )); then
  log_error "se esperaba exactamente 1 artefacto y hay ${#artefactos[@]}; descarga NO entregada"
  exit 4
fi
if [[ ! -s "${artefactos[0]}" ]]; then
  log_error "el artefacto '${artefactos[0]##*/}' está vacío; descarga NO entregada"
  exit 4
fi

tamano=$(stat -c%s -- "${artefactos[0]}") || {
  log_error "no se pudo leer el tamaño del artefacto"
  exit 1
}
log_info "artefacto: '${artefactos[0]##*/}' ($tamano bytes, límite $MAX_BYTES = ${MEDIA_MAX_MB_VALUE} MB)"

# --- Límite de tamaño ANTES de entregar --------------------------------------
if (( tamano > MAX_BYTES )); then
  log_error "el archivo supera MEDIA_MAX_MB: $tamano bytes > $MAX_BYTES bytes (${MEDIA_MAX_MB_VALUE} MB). NO se entrega"
  if [[ "${YTDL_KEEP_OVERSIZE:-0}" == "1" ]]; then
    log_aviso "YTDL_KEEP_OVERSIZE=1: se conserva el fichero pese a superar el límite (salida 5; úsalo solo para envío como documento)"
    entregar_artefacto "${artefactos[0]}"
  fi
  exit 5
fi

# --- Entrega -----------------------------------------------------------------
entregar_artefacto "${artefactos[0]}"
exit 0
