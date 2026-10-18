#!/bin/bash
#
# group-kick.sh — expulsa (kick) a un participante de un grupo de WhatsApp
# de forma FAIL-CLOSED, verificando los roles con wacli ANTES de tocar nada.
#
# Plan: PLAN-001, tarea T-08 (decisión D1) · skill bash-defensive-patterns.
#
# Uso:
#   group-kick.sh --group <JID_grupo> --actor <JID_emisor> \
#                 --target <JID_objetivo> [--json]
#
#   --group    JID del grupo (...@g.us).
#   --actor    JID del emisor del mensaje que ordena la expulsión. DEBE ser el
#              JID real del emisor, tomado del contexto del mensaje (nunca un
#              texto alegado por el usuario).
#   --target   JID del participante a expulsar.
#   --json     Emite también el resultado (éxito o error) como JSON por stdout.
#   -h, --help Muestra esta ayuda.
#
# Verificaciones ANTES de expulsar (fail-closed, sin reintentos):
#   1. El emisor figura como admin/superadmin del grupo   (si no: salida 10)
#   2. El bot (BOT_JID) figura como admin/superadmin      (si no: salida 11)
#   3. El objetivo es participante del grupo              (si no: salida 12)
# Ante CUALQUIER duda o error NO se ejecuta `participants remove`.
#
# Variables de entorno:
#   BOT_JID        JID del propio bot (obligatorio; identidad a confirmar en
#                  T-07 y fijada en .env). Sin él NO se expulsa nunca (21).
#   WACLI_TIMEOUT  Segundos de timeout por invocación a wacli (defecto: 20).
#   DEBUG=1        Mensajes de depuración adicionales (stderr).
#
# Códigos de salida:
#   0  Éxito: objetivo expulsado (o ya ausente del grupo gestionado por wacli)
#   2  Uso inválido (argumentos o WACLI_TIMEOUT)
#   6  Dependencia ausente (wacli, jq o timeout)
#   7  `wacli groups participants remove` falló (expulsión no completada)
#   10 El emisor NO figura como admin/superadmin del grupo
#   11 El bot (BOT_JID) NO figura como admin/superadmin del grupo
#   12 El objetivo NO es participante del grupo
#   20 Consulta de participantes fallida o timeout (ambas fuentes: list y info)
#   21 JSON de wacli ilegible o sin campo de roles (roles no confirmados,
#      T-07 pendiente), o BOT_JID ausente en el entorno
#
# Contrato de salida:
#   - stdout: con --json, un único objeto JSON ({"ok":true|false,...} generado
#     con jq, siempre parseable); sin --json, en éxito un mensaje legible y en
#     error nada (todo a stderr).
#   - stderr: avisos, errores y la salida cruda de wacli.
#
# Nota de roles (T-07 pendiente): el campo exacto de rol en la salida --json
# de wacli NO está confirmado; este parser acepta los formatos razonables
# ("admin"/"superadmin" o booleano en `admin`/`Admin`/`role`/`isAdmin`/
# `is_admin`) y, si ninguno aparece, falla con 21 sin expulsar nunca.

set -Eeuo pipefail

SCRIPT_NAME="${BASH_SOURCE[0]##*/}"

# --- Estado ------------------------------------------------------------------
grupo=""
actor=""
target=""
json_salida=0
BOT_JID="${BOT_JID:-}"

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
Uso: $SCRIPT_NAME --group <JID_grupo> --actor <JID_emisor> --target <JID_objetivo> [--json]

Expulsión fail-closed: el emisor y el bot deben ser admin/superadmin y el
objetivo un participante del grupo; si falta CUALQUIER condición NO se expulsa.

Variables de entorno:
  BOT_JID        JID del propio bot (obligatorio; pendiente de confirmar en T-07)
  WACLI_TIMEOUT  Timeout en segundos por invocación a wacli (defecto: 20)
  DEBUG=1        Depuración adicional

Códigos de salida:
  0 éxito | 2 uso inválido | 6 dependencia ausente | 7 fallo del remove
  10 emisor no admin | 11 bot no admin | 12 objetivo no participante
  20 consulta wacli fallida/timeout | 21 JSON ilegible o sin roles / BOT_JID ausente
EOF
}

# Termina con un código diferenciado: error a stderr (+ JSON si --json).
fallar() {
  local -r codigo="$1"
  shift
  local -r mensaje="$*"
  log_error "$mensaje"
  if (( json_salida == 1 )); then
    jq -n --arg error "$mensaje" --argjson code "$codigo" \
      '{ok: false, error: $error, code: $code}' || true
  fi
  exit "$codigo"
}

# --- Limpieza y trampas ------------------------------------------------------
# shellcheck disable=SC2317  # invocada indirectamente vía trap ERR
on_error_inesperado() {
  log_error "error inesperado en la línea ${LINENO} (código $?)"
}

# --- Análisis de argumentos --------------------------------------------------
error_args=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      mostrar_ayuda
      exit 0
      ;;
    --json)
      json_salida=1
      shift
      ;;
    --group|--actor|--target)
      if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
        error_args="$1 requiere un valor"
        break
      fi
      case "$1" in
        --group)  grupo="$2" ;;
        --actor)  actor="$2" ;;
        --target) target="$2" ;;
      esac
      shift 2
      ;;
    *)
      error_args="opción o argumento desconocido: $(printf '%q' "$1")"
      break
      ;;
  esac
done

if [[ -n "$error_args" ]]; then
  log_error "$error_args"
  mostrar_ayuda >&2
  exit 2
fi
[[ -n "$grupo" ]]  || { mostrar_ayuda >&2; fallar 2 "falta el argumento obligatorio --group"; }
[[ -n "$actor" ]]  || { mostrar_ayuda >&2; fallar 2 "falta el argumento obligatorio --actor"; }
[[ -n "$target" ]] || { mostrar_ayuda >&2; fallar 2 "falta el argumento obligatorio --target"; }

# Formato JID mínimo: '<local>@<dominio>' sin espacios (la validación fina de
# dominios/formatos la confirma T-07 con wacli real).
validar_jid() {
  local -r etiqueta="$1"
  local -r valor="$2"
  if [[ ! "$valor" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]]; then
    fallar 2 "$etiqueta no parece un JID válido (se esperaba '<algo>@<dominio>'): $(printf '%q' "$valor")"
  fi
}
validar_jid "--group" "$grupo"
validar_jid "--actor" "$actor"
validar_jid "--target" "$target"

# WACLI_TIMEOUT: entero >= 1 (se aplica a cada invocación de wacli, incluido
# el remove: una consulta/expulsión colgada no debe dejar el proceso vivo).
readonly WACLI_TIMEOUT="${WACLI_TIMEOUT:-20}"
if [[ ! "$WACLI_TIMEOUT" =~ ^[1-9][0-9]{0,3}$ ]]; then
  fallar 2 "WACLI_TIMEOUT debe ser un entero >= 1 (recibido: '${WACLI_TIMEOUT}')"
fi

# --- Condiciones de habilitación (fail-closed) -------------------------------
# Sin la identidad propia del bot NUNCA se expulsa: no podemos verificar que
# el bot es admin. BOT_JID debe venir del entorno (.env; confirmado en T-07).
if [[ -z "$BOT_JID" ]]; then
  fallar 21 "BOT_JID no está definido en el entorno: sin la identidad propia del bot NO se expulsa (T-07 pendiente; define BOT_JID en .env)"
fi
validar_jid "BOT_JID" "$BOT_JID"

# --- Dependencias ------------------------------------------------------------
declare -a faltantes=()
for cmd in wacli jq timeout; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    faltantes+=("$cmd")
  fi
done
if (( ${#faltantes[@]} > 0 )); then
  fallar 6 "dependencias ausentes en PATH: ${faltantes[*]}"
fi

trap on_error_inesperado ERR

# --- Consulta de participantes (con fallback) --------------------------------
# Imprime por stdout el array JSON de participantes si el documento lo
# contiene (array raíz, .participants o .group.participants); si el JSON es
# ilegible o el formato no es reconocible, falla (vacío + rc != 0).
extraer_participantes() {
  printf '%s' "$1" | jq -c '
    if type == "array" then .
    elif (.participants? | type) == "array" then .participants
    elif (.group.participants? | type) == "array" then .group.participants
    else empty end' 2>/dev/null
}

log_info "consultando participantes del grupo $(printf '%q' "$grupo") (timeout ${WACLI_TIMEOUT}s)..."

rc_list=0
salida_list=""
salida_list=$(timeout "$WACLI_TIMEOUT" wacli groups participants list --jid "$grupo" --json) || rc_list=$?

json_participantes=""
if (( rc_list == 0 )); then
  if arr=$(extraer_participantes "$salida_list"); then
    json_participantes="$arr"
  fi
fi

rc_info=0
if [[ -z "$json_participantes" ]]; then
  log_aviso "participants list no devolvió un array de participantes (rc=$rc_list); probando fallback 'groups info'..."
  salida_info=""
  salida_info=$(timeout "$WACLI_TIMEOUT" wacli groups info --jid "$grupo" --json) || rc_info=$?
  if (( rc_info == 0 )); then
    if arr=$(extraer_participantes "$salida_info"); then
      json_participantes="$arr"
    fi
  fi
fi

if [[ -z "$json_participantes" ]]; then
  if (( rc_list != 0 && rc_info != 0 )); then
    fallar 20 "la consulta de participantes ha fallado o agotado el timeout (participants list rc=$rc_list, groups info rc=$rc_info); NO se expulsa"
  fi
  fallar 21 "la salida de wacli no contiene un array de participantes legible (JSON ilegible o formato inesperado; roles no confirmados, T-07 pendiente); NO se expulsa"
fi

# --- Parsing de roles --------------------------------------------------------
# TSV por participante: '<jid>\t<rol>' con rol ∈ {admin, member, desconocido,
# sin-campo}. Se aceptan los formatos razonables y documentados en la cabecera;
# cualquier valor de rol no reconocido es "desconocido" (fail-closed: nunca
# cuenta como admin).
tsv=""
if ! tsv=$(printf '%s' "$json_participantes" | jq -r '
  def norm_admin:
    if   . == true or . == "admin" or . == "superadmin" or . == "Admin" or . == "ADMIN" then "admin"
    elif . == false or . == null or . == "member" or . == "Member" or . == "none" or . == "" then "member"
    else "desconocido" end;
  .[] | select(type == "object")
  | ((.jid? // .id? // .user? // "") | tostring) as $id
  | (if   has("isAdmin")  then {c: 1, v: .isAdmin}
     elif has("is_admin") then {c: 1, v: .is_admin}
     elif has("admin")    then {c: 1, v: .admin}
     elif has("Admin")    then {c: 1, v: .Admin}
     elif has("role")     then {c: 1, v: .role}
     else {c: 0, v: null} end) as $r
  | (if $r.c == 0 then "sin-campo" else ($r.v | norm_admin) end) as $rol
  | [$id, $rol] | @tsv'); then
  fallar 21 "JSON ilegible al analizar los roles de participantes (T-07 pendiente); NO se expulsa"
fi
if [[ -z "$tsv" ]]; then
  fallar 21 "la salida de wacli no contiene participantes recognoscibles (formato inesperado; T-07 pendiente); NO se expulsa"
fi

declare -a IDS=()
declare -a ROLES=()
while IFS=$'\t' read -r pid prole; do
  if [[ -n "$pid" || -n "$prole" ]]; then
    IDS+=("$pid")
    ROLES+=("$prole")
  fi
done <<< "$tsv"

# Fail-closed central de T-07: si NINGÚN participante trae un campo de rol,
# el formato de wacli aún no está confirmado → nunca se expulsa.
roles_confirmados=0
for prole in "${ROLES[@]}"; do
  if [[ "$prole" != "sin-campo" ]]; then
    roles_confirmados=1
    break
  fi
done
if (( roles_confirmados == 0 )); then
  fallar 21 "roles no confirmados (T-07 pendiente): la salida de wacli no contiene campo de rol (admin/Admin/role/isAdmin/is_admin) por participante; NO se expulsa"
fi

log_debug "participantes analizados: ${#IDS[@]}"

# --- Verificaciones (a) emisor admin, (b) bot admin, (c) objetivo en grupo ---
# Comparación exacta de JID completo, insensible a mayúsculas. Ante cualquier
# duda (rol desconocido o ausente) NO se expulsa.
buscar_indice_jid() {
  local -r busqueda="${1,,}"
  shift
  local -a elementos=("$@")
  local idx
  for idx in "${!elementos[@]}"; do
    if [[ "${elementos[$idx],,}" == "$busqueda" ]]; then
      printf '%d' "$idx"
      return 0
    fi
  done
  return 1
}

if ! idx_actor=$(buscar_indice_jid "$actor" "${IDS[@]}"); then
  fallar 10 "el emisor $(printf '%q' "$actor") no figura entre los participantes del grupo; en particular NO es admin y NO se expulsa"
fi
if [[ "${ROLES[$idx_actor]}" != "admin" ]]; then
  fallar 10 "el emisor $(printf '%q' "$actor") no es admin/superadmin (rol detectado: ${ROLES[$idx_actor]}); NO se expulsa"
fi

if ! idx_bot=$(buscar_indice_jid "$BOT_JID" "${IDS[@]}"); then
  fallar 11 "el bot (BOT_JID=$(printf '%q' "$BOT_JID")) no figura entre los participantes del grupo; NO se expulsa"
fi
if [[ "${ROLES[$idx_bot]}" != "admin" ]]; then
  fallar 11 "el bot (BOT_JID=$(printf '%q' "$BOT_JID")) no es admin/superadmin (rol detectado: ${ROLES[$idx_bot]}); NO se expulsa"
fi

if ! idx_target=$(buscar_indice_jid "$target" "${IDS[@]}"); then
  fallar 12 "el objetivo $(printf '%q' "$target") no es participante del grupo; nada que expulsar"
fi
log_debug "objetivo encontrado (posición $idx_target, rol: ${ROLES[$idx_target]})"

# --- Expulsión (SOLO tras las 3 verificaciones) ------------------------------
log_info "las 3 verificaciones han pasado; expulsando a $(printf '%q' "$target") del grupo $(printf '%q' "$grupo")..."
rc_remove=0
timeout "$WACLI_TIMEOUT" wacli groups participants remove --jid "$grupo" --user "$target" >&2 || rc_remove=$?
if (( rc_remove != 0 )); then
  fallar 7 "wacli groups participants remove ha fallado (código $rc_remove); la expulsión de $(printf '%q' "$target") NO se pudo completar ni confirmar"
fi

# --- Resultado ---------------------------------------------------------------
if (( json_salida == 1 )); then
  jq -n --arg group "$grupo" --arg actor "$actor" --arg bot "$BOT_JID" --arg target "$target" \
    '{ok: true, group: $group, actor: $actor, bot: $bot, target: $target, removed: true}'
else
  printf 'OK: %s expulsado de %s (orden de %s, verificado con bot %s)\n' \
    "$target" "$grupo" "$actor" "$BOT_JID"
fi
exit 0
