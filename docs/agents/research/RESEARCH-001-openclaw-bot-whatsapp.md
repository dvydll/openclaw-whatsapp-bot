# RESEARCH-001 — OpenClaw para bot de WhatsApp: qué es nativo y qué hay que construir

## Información General

| Campo             | Valor                    |
| ----------------- | ------------------------ |
| **ID**            | `RESEARCH-001`           |
| **Fecha**         | 2026-10-15               |
| **Ref. Issue**    | `ISSUE-001`              |
| **Estado**        | Completada               |
| **Investigador**  | Agente `knowledge-assistant` |

## Objetivo

Determinar, para el `ISSUE-001`, qué funcionalidades del bot de WhatsApp son
**nativas de OpenClaw**, cuáles requieren **construcción propia** y cuáles están
**no disponibles** en la versión actual. Cada conclusión contrasta fuentes
primarias: la documentación oficial (`docs.openclaw.ai`) y el código fuente del
repositorio (`github.com/openclaw/openclaw`, clonado en sparse el 2026-10-15).

Leyenda de veredictos:

- **NATIVO**: existe y se configura/usa tal cual, sin código propio.
- **REQUIERE CONSTRUCCIÓN**: no existe end-to-end; hay piezas de apoyo pero hay
  que implementar (skill, tool personalizada, Dockerfile propio, etc.).
- **NO DISPONIBLE**: no existe ni hay pieza utilizable directamente; se necesita
  desarrollo a medida sustancial.

---

## 1. Despliegue con Docker (imagen oficial, yt-dlp/ffmpeg, Dockerfile propio)

**Veredicto base: NATIVO** (despliegue oficial). **Veredicto yt-dlp/ffmpeg:
REQUIERE CONSTRUCCIÓN** (no van en la imagen; Dockerfile propio).

### Despliegue oficial (NATIVO)

- Repo `docker-compose.yml` y `Dockerfile` oficiales.
- Servicio por defecto: `openclaw-gateway`, expone puerto `18789`.
- Variables clave del contenedor:
  - `OPENCLAW_STATE_DIR=/home/node/.openclaw` — estado/volumen.
  - `OPENCLAW_CONFIG_PATH=/home/node/.openclaw/openclaw.json` — config.
  - `env_file: .env` — el compose ya inyecta un `.env`.
- Arranque: `docker compose up -d` (o `openclaw gateway` fuera de Docker).
- La imagen base es **Debian `node:22-bookworm-slim`** (no Alpine; la doc
  advierte explícitamente que *Alpine no soporta el native runtime*). Esto es
  relevante: al ser Debian, instalar `yt-dlp`/`ffmpeg` por `apt` en un Dockerfile
  heredado es viable.

### Extensión con Dockerfile propio (REQUIERE CONSTRUCCIÓN)

- El `Dockerfile` oficial acepta el build-arg `OPENCLAW_EXTENSIONS` para
  preinstalar extensiones, pero **no** incluye `yt-dlp` ni `ffmpeg` completos.
- Búsqueda en el repo: no hay ninguna referencia a `yt-dlp`/`yt_dlp` en
  `extensions/` ni `docs/`. Único rastro de ffmpeg: `ffmpeg-static` como
  *optional peer dependency* de `prism-media` (uso interno de audio/llamadas),
  insuficiente para transcodificación de vídeo de yt-dlp.
- Opción recomendada: heredar de la imagen oficial (`FROM` la imagen publicada o
  `OPENCLAW_IMAGE`) e instalar vía `apt-get install -y yt-dlp ffmpeg` (o
  binario estático de yt-dlp para evitar el desactualizado de bookworm).
- Alternativa: binarios laterales dentro de `~/.openclaw/skills/` y usar `bash`
  desde el sandbox del agente.

**Config keys relevantes**: `OPENCLAW_IMAGE` (override de imagen),
`OPENCLAW_EXTENSIONS` (build-arg), `OPENCLAW_STATE_DIR`, `OPENCLAW_CONFIG_PATH`.

---

## 2. Plugin de WhatsApp: instalación y config keys

**Veredicto: NATIVO.**

### Instalación y login (NATIVO)

```bash
openclaw plugins install @openclaw/whatsapp
openclaw channels login --channel whatsapp   # pairing por QR / código
```

El plugin usa **Baileys `7.0.0-rc14`** bajo el capó
(`extensions/whatsapp/package.json`). Incluye un CLI companion `meowcaller`
solo para llamadas de voz (VoIP), no relacionado con moderación de grupos.

### Config keys verificadas (en `channels.whatsapp.*`)

Todas confirmadas en `extensions/whatsapp/src/schema.ts` y en
`docs/channels/whatsapp.md`:

| Key | Tipo / valores | Default | Notas |
| --- | --- | --- | --- |
| `channels.whatsapp.dmPolicy` | `"allowlist" \| "closed"` | `allowlist` | Política de DMs (1:1). |
| `channels.whatsapp.allowFrom` | `string[]` (E.164) | `[]` | Allowlist de DMs. Normaliza números E.164. **Solo gating de DM entrante**; no gates envíos explícitos a grupos. |
| `channels.whatsapp.groupPolicy` | `"allowlist" \| "closed"` | `allowlist` | Política de grupos. |
| `channels.whatsapp.groupAllowFrom` | `string[]` (JID de grupo) | `[]` | Allowlist de grupos permitidos. |
| `channels.whatsapp.historyLimit` | `number` | `50` | Fallback: `messages.groupChat.historyLimit`. Historial inyectado al agente. |
| `channels.whatsapp.requireMention` | `boolean` | — | Legacy; ver §3. |
| `channels.whatsapp.trimUserHistory` | `number` | — | Trunca historial por usuario. |
| `channels.whatsapp.textChunkLimit` | `number` | `4000` | Troceado de mensajes largos. |
| `channels.whatsapp.mediaMaxMb` | `number` | `50` | Límite media entrante/saliente (ver §6). Override por cuenta: `channels.whatsapp.accounts.<id>.mediaMaxMb`. |
| `channels.whatsapp.replyToMode` | `"off"\|"first"\|"all"\|"batched"` | `off` | Citar mensaje original en respuestas. |
| `channels.whatsapp.allowGroups` | `string[]` | — | Lista de grupos operativos. |
| `channels.whatsapp.linkPrefixes` | `string[]` | — | Manejo de links. |
| `channels.whatsapp.handleRestarts` | `boolean` | — | Gestión de reconexión. |
| `channels.whatsapp.disableMediaDownload` | `boolean` | — | Ahorro de banda. |
| `channels.whatsapp.voipTimeoutSeconds` | `number` | — | Llamadas. |
| `channels.whatsapp.debugVerbose` | `boolean` | — | Debug. |

Además, a nivel global de acceso:
`commands.ownerAllowFrom` (allowlist de owners para comandos del CLI/agent).

---

## 3. Activación solo bajo mención en grupos (+ allowlist de DMs)

**Veredicto: NATIVO.**

### Modo de activación (NATIVO)

- `activation.mode`: `mention` (default) | `auto` | `off`.
- `mention` = el agente solo despierta en grupos con mención real (`@`).
- Las menciones reales se resuelven vía `mentionedJids`.

### Patterns de mención (NATIVO)

- Por agente: `agents.entries.<id>.groupChat.mentionPatterns` (regex/strings).
- Fallback global: `messages.groupChat.mentionPatterns`.
- Si no se configura, se **deriva del nombre/emoji de identidad** del agente.
- Legacy: `channels.whatsapp.requireMention` (boolean) como atajo antiguo.

### Allowlist de DMs (NATIVO)

- `channels.whatsapp.allowFrom` + `dmPolicy: "allowlist"` → en DM solo
  contesta a los números listados. Combined con `commands.ownerAllowFrom` para
  restricción de owner.

**Conclusión para ISSUE-001 punto 4**: ambos controles (grupo solo bajo
mención, DM solo allowlist) son **100% nativos y configurables** sin código.

---

## 4. Expulsar participantes (kick) + ¿puede el agente saber si el emisor es admin?

**Kick: NO DISPONIBLE. Detección de admin del emisor: NO DISPONIBLE
(por descarte del plugin). Ambos: REQUIERE CONSTRUCCIÓN.**

### Kick de participantes (NO DISPONIBLE / REQUIERE CONSTRUCCIÓN)

Verificado contra el código fuente (`extensions/whatsapp/src` completo +
`docs/channels/whatsapp*`):

- **No existe ninguna acción de kick/removeParticipant para WhatsApp.** El único
  `groupParticipantsUpdate`/`kick`/`removeParticipant` del repo es de **Discord**
  (CLI `kick`) y de **iMessage** (`addParticipant`/`removeParticipant`, vía
  private API). Ni rastro en el plugin de WhatsApp.
- `channel-actions.ts` del plugin solo despacha `reactions` (y acciones de
  aprobación), no moderación de participantes.
- Baileys (la lib subyacente) **sí** expone `groupParticipantsUpdate(jid,
  participants, "remove")`, pero OpenClaw no lo sube a tool/CLI del agente.

**Implicación**: aunque el bot sea admin del grupo, el agente **no puede expulsar
con capacidades nativas**. Hay que construir una tool personalizada que llame a
Baileys (o un fork/extensión del plugin). Fuera del alcance del plugin actual.

### Detección de admin del emisor (NO DISPONIBLE / REQUIERE CONSTRUCCIÓN)

Verificado en `inbound/group-metadata-cache.ts`:

- El plugin cachea `GroupMetadata` de Baileys, pero al resumir
  (`summarize`) **solo conserva**: `subject`, lista de `participants` (solo
  display/E.164/LID para menciones) y TTL. **Descarta por completo el campo
  `admin`/`superadmin`** que Baileys sí incluye en cada participante.
- `formatGroupMembers` (auto-reply) solo emite la lista de participantes con
  nombre, **sin roles**.
- Por lo tanto el agente **no recibe información de quién es admin** en el
  contexto del mensaje de grupo.

**Implicación**: para el requisito "expulsar solo bajo comando de admins y
verificar que el emisor es admin", hay que construir:
1. Una tool que lea `GroupMetadata.participants[].admin` (rol del emisor).
2. Una tool de kick vía `groupParticipantsUpdate`.
3. Ambas requieren modificar/extender el plugin o crear una extensión propia.

---

## 5. Stickers (enviar + crear webp 512x512 + vídeo→sticker animado)

**Veredicto: NO DISPONIBLE para el agente / REQUIERE CONSTRUCCIÓN.**

### Evidencia

- **Recepción**: sí. Los stickers entrantes se normalizan como
  `<media:sticker>` (`docs/channels/whatsapp.md` y `inbound/media.ts`).
- **Envío**: existe un `sendSticker` a nivel de driver interno
  (`inbound/send-api.ts` → `sendStructuredMessage(..., { sticker, mimetype:
  "image/webp" })`), **PERO**:
  - Solo está expuesto en el **QA driver** (`qa-driver.runtime.ts`, entorno de
    pruebas), **no** como tool del agente ni acción del canal.
  - El CLI `openclaw message sticker send/upload` es **exclusivo de Discord**
    (`docs/cli/message.md`).
  - Issue abierto `#7476` "Feature Request: WhatsApp sticker send support"
    (2 feb 2026) confirma que **no está soportado** end-to-end.
- **Creación de sticker webp 512x512**: no hay ninguna tool nativa de
  generación de stickers. La generación de imágenes existente
  (`docs/tools/image-generation.md`) produce PNG/JPG, no stickers webp 512x512
  ni conversión vídeo→sticker animado.
- No hay integración `ffmpeg`-para-stickers ni uso de `webpmux`/`cwebp` en el
  repo.

**Conclusión**: enviar stickers desde el agente y crear stickers (imagen→webp
512x512, vídeo→animado) requiere **construcción propia**:
- Creación: skill con `ffmpeg` (frame extraído + `cwebp`/`ffmpeg` a webp, con
  `fps` y squeeze a 512x512) en Dockerfile propio (§1).
- Envío: como el `sendSticker` interno no está expuesto, o bien se usa el QA
  driver (no recomendado en prod), o bien se construye una extensión/tool que
  llame a `sock.sendMessage(jid, { sticker })` de Baileys.

---

## 6. Skills de yt-dlp + ffmpeg, permisos/sandbox, límites de media de WhatsApp

**Permisos/sandbox de herramientas: NATIVO. Límites de media: NATIVO (config).
Skills yt-dlp/ffmpeg concretos: REQUIERE CONSTRUCCIÓN.**

### Límites de media WhatsApp (NATIVO, verificado)

De `docs/channels/whatsapp.md` (Accordion "Media size limits"):

- Límite de subida (inbound save) y de envío (outbound send):
  `channels.whatsapp.mediaMaxMb` — **default `50`** (MB).
- Override por cuenta: `channels.whatsapp.accounts.<id>.mediaMaxMb`.
- Las **imágenes se auto-optimizan** (resize/quality sweep) para caber en el
  límite, salvo que se pida `forceDocument`/`asDocument`.
- Si el envío de media falla, el fallback envía un **aviso de texto** en lugar
  de descartar en silencio.
- Texto troceado en `channels.whatsapp.textChunkLimit = 4000`.

**Implicación ISSUE-001 punto 3**: vídeos de YouTube pueden superar 50 MB →
habrá que forzar entrega como documento (`forceDocument`) o comprimir, y
configurar `mediaMaxMb` adecuadamente. La auto-optimización de imagen no aplica
a vídeo/audio.

### Skills yt-dlp / ffmpeg (REQUIERE CONSTRUCCIÓN)

- **No existe skill oficial de yt-dlp en OpenClaw.** El catálogo real de skills
  es **ClawHub** (`github.com/openclaw/clawhub`), no `openclaw/skills` (que da
  404). En ClawHub hay skills de terceros, p. ej.
  `apollo1234/yt-dlp-downloader-skill` (comunidad, no oficial, sin auditar).
- El sandbox del agente puede ejecutar `bash`; por tanto un skill propio que
  invoque `yt-dlp` + `ffmpeg` (instalados en el Dockerfile heredado, §1) es el
  camino. Requiere declarar permisos de shell/herramientas correspondientes.

### Permisos y sandbox de tools (NATIVO)

- Config de tools/skills: bloques `skills.*` y `skills-config` (schema
  disponible), política de tools documentada en
  `docs/gateway/config-tools/tool-policy`.
- El agente ejecuta comandos dentro de su sandbox; los permisos de qué tools/
  comandos están disponibles se configuran en la policy. Esto es nativo y
  suficiente para declarar el uso de `yt-dlp`/`ffmpeg` vía `bash`.

---

## 7. Config de agentes (`agents.entries.*` vs `agents.list`), identidad, skills en `~/.openclaw/skills`, SKILL.md, hot-reload

**Veredicto: NATIVO (todo).**

### Forma de config de agentes (NATIVO, confirmado actual)

- **`agents.entries.<id>.*`** es la forma vigente (confirmado en
  `docs/gateway/config-agents/entries-and-multi-agent`).
- Cada entrada soporta overrides que se **deep-mergean** sobre
  `agents.defaults`.
- Multi-agent: bindings vía `multiAgent` (alias `agents.multiAgent`).
- `agents.defaults.modelPolicy.allow`, `agents.defaults.models` para modelos.

### Identidad (NATIVO)

- Cada agente define identidad (nombre, emoji, tono). Si no se configuran
  `mentionPatterns`, se derivan del nombre/emoji (§3).

### Skills y SKILL.md (NATIVO)

- Directorio por defecto de skills: **`~/.openclaw/skills`**
  (`/home/node/.openclaw/skills` en contenedor; montable como volumen).
- Cada skill es un paquete con **`SKILL.md`** con frontmatter YAML (metadatos:
  nombre, descripción, triggers) + recursos/_scripts.
- Instalación desde ClawHub:
  `openclaw skills install <org>/<skill>` (p. ej. `openclaw skills install
  openclaw/openclaw-core` o el skill de terceros yt-dlp).
- Skills personalizados = crear directorio + `SKILL.md` en `~/.openclaw/skills`.

### Hot-reload (NATIVO)

- El Gateway aplica snapshots de config **versionados y con hot-reload**.
- La mayoría de claves se aplican en caliente; algunas fuerzan restart
  (`docs/gateway/configuration/hot-reload`).

**Conclusión ISSUE-001 punto 5**: la config de agentes, identidad, montaje de
skills y hot-reload son nativos; no requieren construcción.

---

## 8. Proveedor LLM parametrizado en `.env`

**Veredicto: NATIVO.**

### Mecanismos verificados (NATIVO)

- **Referencia de modelo**: formato `provider/model` (p. ej.
  `openai/gpt-4o`, `anthropic/claude-...`).
- **Selección**: `agents.defaults.models` (por agente vía
  `agents.entries.<id>`), `agents.defaults.modelPolicy.allow` (allowlist),
  o CLI `openclaw models set <provider/model>`.
- **Providers**: quick-rules en
  `docs/concepts/model-providers/quick-rules`; múltiples providers
  (OpenAI, Anthropic, etc.).

### Resolución vía `.env` (NATIVO, verificado)

- El Gateway carga `.env` desde el **cwd** y desde `~/.openclaw/.env`.
- Soporta **sustitución `${VAR}`** en `openclaw.json` → cualquier clave
  (p. ej. API key o el propio `provider/model`) se puede parametrizar desde
  `.env`.
- Bloque `env.vars` en `openclaw.json` para inyectar variables.
- El `docker-compose.yml` oficial ya usa `env_file: .env`.

**Conclusión ISSUE-001 punto 5**: parametrizar el proveedor LLM en `.env` (con
`${VAR}` en la config) es 100% nativo. Aún sin definir el proveedor, la
infraestructura está lista.

---

## Arquitectura prevista (basada en hallazgos nativos)

```text
                      ┌──────────────────────────────────────────┐
                      │  Contenedor: openclaw-gateway (Debian)    │
  .env ──────────────▶│  OPENCLAW_STATE_DIR=/home/node/.openclaw  │
  (LLM keys,          │  OPENCLAW_CONFIG_PATH=.../openclaw.json   │
   mediaMaxMb,        │                                           │
   provider/model)    │  ┌─ channels.whatsapp.* (plugin Baileys) ─┐
                      │  │  dmPolicy / allowFrom / groupPolicy /  │
  Volumen             │  │  groupAllowFrom / historyLimit         │
  ~/.openclaw ───────▶│  └────────────────────────────────────────┘
  (estado, skills,    │  ┌─ agents.entries.<id> ──────────────────┐
   config, auth       │  │  groupChat.mentionPatterns (activación)│
   WhatsApp)          │  │  identidad + models (provider/model)   │
                      │  └────────────────────────────────────────┘
                      │  ┌─ ~/.openclaw/skills ───────────────────┐
                      │  │  SKILL.md custom (yt-dlp / stickers)   │
                      │  └────────────────────────────────────────┘
                      └──────────────────────────────────────────┘
Puerto: 18789 (Gateway)
```

### Flujo de login WhatsApp

1. `openclaw plugins install @openclaw/whatsapp`
2. `openclaw channels login --channel whatsapp` → escanear **QR** (o pairing
   code) desde el teléfono.
3. Gateway mantiene la sesión (Baileys) en `~/.openclaw` (volumen).

### Servicios Docker (previstos)

- **`openclaw-gateway`** (oficial): sirve todo (canal WhatsApp, agente, skills).
- Posible servicio/sidecar o imagen heredada para binarios `yt-dlp`/`ffmpeg` si
  no se prefieren skills con `bash` (ver §1 y §5).

---

## Lagunas y riesgos (pendientes de verificación / decisiones)

1. **Kick y detección de admin (RIESGO ALTO)**: no son nativos. Requieren
   extensión del plugin o tool propia sobre Baileys (`groupParticipantsUpdate`,
   leer `participantes[].admin`). Es el mayor gap frente al ISSUE-001 punto 1.
   *Pendiente de verificar*: esfuerzo real de tocar el plugin (privacidad de
   APIs internas, compatibilidad al actualizar).
2. **Stickers (RIESGO MEDIO-ALTO)**: envío no expuesto al agente (solo QA
   driver); creación webp 512x512 y vídeo→animado no existen. Issue `#7476`
   abierto. Requiere skill ffmpeg + posible extensión para el envío.
3. **`wacli`**: no confirmada su existencia. El companion del plugin es
   `meowcaller` (VoIP). *Pendiente*: confirmar si hay un CLI de WA dedicado.
4. **Límites de media de WhatsApp (documentados como 50 MB por defecto)**:
   valor por defecto confirmado, pero **el límite duro real de la API de
   WhatsApp** (que puede ser menor, p. ej. ~16 MB para vídeo en algunos casos)
   *no está confirmado en la fuente*. Verificar empíricamente.
5. **Skill yt-dlp de ClawHub (`apollo1234/...`)**: es de terceros, **no
   auditar todavía**. Riesgo de seguridad si se usa sin revisión. Recomendado:
   skill propio.
6. **Versión de yt-dlp en `apt` de bookworm**: potencialmente desactualizado
   (los videos de YouTube requieren yt-dlp muy reciente). *Pendiente*: decidir
   binario estático vs apt vs pip.
7. **`agents.list`**: se ha confirmado que `agents.entries.*` es la forma
   actual; no se ha encontrado soporte de `agents.list` en la doc vigente.
   Asumir `entries` como canónico.
8. **Baileys `7.0.0-rc14` es release-candidate**: posible inestabilidad. Riesgo
   a monitorizar en producción.
9. **Proveedor LLM sin definir** (ISSUE-001 punto 5): la infraestructura está
   lista, pero falta elegir proveedor y sus límites/costes. *Pendiente de
   decisión humana*.

---

## Resumen de veredictos por tema

| #  | Tema | Veredicto |
| -- | ---- | --------- |
| 1  | Despliegue Docker (base) | **NATIVO** |
| 1  | yt-dlp + ffmpeg en imagen | **REQUIERE CONSTRUCCIÓN** (Dockerfile propio) |
| 2  | Plugin WhatsApp + config keys | **NATIVO** |
| 3  | Activación solo bajo mención + allowlist DM | **NATIVO** |
| 4  | Kick de participantes | **NO DISPONIBLE** / REQUIERE CONSTRUCCIÓN |
| 4  | Detección de admin del emisor | **NO DISPONIBLE** / REQUIERE CONSTRUCCIÓN |
| 5  | Stickers (enviar + crear) | **NO DISPONIBLE** (agente) / REQUIERE CONSTRUCCIÓN |
| 6  | Límites de media WhatsApp | **NATIVO** (config `mediaMaxMb`, default 50) |
| 6  | Permisos/sandbox de tools | **NATIVO** |
| 6  | Skills yt-dlp/ffmpeg | **REQUIERE CONSTRUCCIÓN** |
| 7  | Config agentes (`agents.entries.*`) | **NATIVO** |
| 7  | Skills en `~/.openclaw/skills` + SKILL.md | **NATIVO** |
| 7  | Hot-reload | **NATIVO** |
| 8  | Proveedor LLM parametrizado en `.env` | **NATIVO** |

---

## Referencias

### Fuentes primarias (docs oficiales)

- Índice documental: <https://docs.openclaw.ai/llms.txt>
- Instalación Docker: <https://docs.openclaw.ai/install/docker>
- Variables de entorno Docker:
  <https://docs.openclaw.ai/install/docker/environment-variables>
- Canal WhatsApp: <https://docs.openclaw.ai/channels/whatsapp>
- Grupos (activación/mención): <https://docs.openclaw.ai/channels/groups>
- Mensajes de grupo: <https://docs.openclaw.ai/channels/group-messages>
- Referencia plugin WhatsApp: <https://docs.openclaw.ai/plugins/reference/whatsapp>
- CLI `message`: <https://docs.openclaw.ai/cli/message>
- CLI `directory`: <https://docs.openclaw.ai/cli/directory>
- Config de agentes / entries: <https://docs.openclaw.ai/gateway/config-agents/entries-and-multi-agent>
- Hot-reload: <https://docs.openclaw.ai/gateway/configuration/hot-reload>
- Variables de entorno (gateway):
  <https://docs.openclaw.ai/gateway/configuration/environment-variables>
- Model providers / quick-rules: <https://docs.openclaw.ai/concepts/model-providers/quick-rules>
- Tool policy: <https://docs.openclaw.ai/gateway/config-tools/tool-policy>
- Skills: <https://docs.openclaw.ai/tools/skills>
- Media overview: <https://docs.openclaw.ai/tools/media-overview>

### Repositorio y código fuente

- Repo: <https://github.com/openclaw/openclaw>
- `docker-compose.yml` (raw):
  <https://raw.githubusercontent.com/openclaw/openclaw/main/docker-compose.yml>
- `Dockerfile` (raw):
  <https://raw.githubusercontent.com/openclaw/openclaw/main/Dockerfile>
- Plugin WhatsApp (código): `extensions/whatsapp/` (clon sparse local en
  `/tmp/opencode/openclaw`)
- `extensions/whatsapp/src/schema.ts` — config keys del canal.
- `extensions/whatsapp/src/inbound/group-metadata-cache.ts` — metadata de grupo
  (participantes, sin roles admin).
- `extensions/whatsapp/src/inbound/send-api.ts` — `sendSticker` interno (solo QA
  driver).

### Issues / catálogo

- Issue stickers WhatsApp: <https://github.com/openclaw/openclaw/issues/7476>
- Catálogo de skills (ClawHub): <https://github.com/openclaw/clawhub>
- Skill yt-dlp (terceros, sin auditar):
  `apollo1234/yt-dlp-downloader-skill` en ClawHub.

---

*Investigación completada: 2026-10-15*
