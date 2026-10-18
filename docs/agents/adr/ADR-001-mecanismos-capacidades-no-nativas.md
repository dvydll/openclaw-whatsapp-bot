# ADR-001: Mecanismos para capacidades no nativas de OpenClaw (kick, roles admin, stickers, multimedia)

**Estado**: Aceptado (GATE 1b, 2026-10-15)
**Fecha**: 2026-10-15
**Autor**: Coordinador (software-architect)

## Contexto

El `ISSUE-001` requiere que el bot de WhatsApp sea capaz de:

1. Expulsar (kick) participantes de grupos, **solo bajo verificación de que el
   emisor es admin**.
2. Enviar stickers.
3. Crear stickers (imagen → webp 512×512 y vídeo → sticker animado) y descargar
   multimedia (p. ej. YouTube) para enviarla por el canal.

La investigación `RESEARCH-001` determinó, contrastando documentación oficial y
código fuente, que el plugin oficial `@openclaw/whatsapp` (Baileys
`7.0.0-rc14`) **NO** ofrece estas capacidades al agente:

- **Kick**: no existe ninguna acción de kick/removeParticipant para WhatsApp en
  el plugin (los `removeParticipant` del repo son de Discord/iMessage).
  `channel-actions.ts` solo despacha reacciones y aprobaciones. Aunque Baileys
  expone `groupParticipantsUpdate(jid, participants, "remove")`, OpenClaw no lo
  sube a tool/CLI del agente.
- **Roles de admin del emisor**: el plugin cachea `GroupMetadata`, pero
  (`inbound/group-metadata-cache.ts`) descarta el campo `admin`/`superadmin` de
  cada participante; el agente no recibe información de quién es admin.
- **Envío de stickers**: existe un `sendSticker` interno
  (`inbound/send-api.ts`), pero solo está expuesto en el **QA driver** (entorno
  de pruebas), no como tool del agente ni acción del canal; el CLI
  `openclaw message sticker send` es exclusivo de Discord. Issue upstream
  [#7476](https://github.com/openclaw/openclaw/issues/7476) **abierto**;
  [#144695](https://github.com/openclaw/openclaw/issues/144695) (acciones de
  participante nativas) **cerrado como "not planned"**; PR
  [#7502](https://github.com/openclaw/openclaw/pull/7502) **cerrado sin
  mergear**.
- **Creación de stickers (webp 512×512, vídeo→animado)**: no hay tool nativa;
  la generación de imágenes existente produce PNG/JPG. No hay integración
  ffmpeg-para-stickers ni `webpmux`/`cwebp` en el repo.
- **yt-dlp/ffmpeg**: no van en la imagen oficial de Docker; requieren build
  propio (aunque heredar de la imagen oficial es viable porque la base es
  Debian `node:22-bookworm-slim`, no Alpine).

Todo lo demás necesario para el `ISSUE-001` **sí es nativo** y no motiva esta
decisión: activación bajo mención en grupos (`activation.mode: mention`),
allowlist de DMs (`channels.whatsapp.dmPolicy`/`allowFrom`), config de
agentes (`agents.entries.*`), skills en `~/.openclaw/skills` con `SKILL.md`,
permisos/sandbox de tools, límites de media (`channels.whatsapp.mediaMaxMb`,
default 50 MB) y parametrización del proveedor LLM vía `.env` con sustitución
`${VAR}` en `openclaw.json`.

La pregunta de este ADR es: **¿con qué mecanismo se dotan al agente las
capacidades no nativas (kick + verificación de admin + stickers) y las skills
multimedia, sin comprometer la mantenibilidad ni la confianza del canal?**

## Decisiones Consideradas

### Opción A: `wacli` (CLI oficial de la org openclaw, sobre whatsmeow) como 2º dispositivo vinculado + skills propias con `bash`

Usar [`wacli`](https://wacli.sh) ([github.com/openclaw/wacli](https://github.com/openclaw/wacli)),
CLI oficial bajo la organización openclaw (antes steipete/wacli), escrita en Go
sobre **whatsmeow**, binario único que empareja como **dispositivo WhatsApp Web
vinculado** con store propio en SQLite (`~/.wacli`), con autenticación
independiente por QR (`wacli auth`) o pairing por teléfono. Skills propias
(`SKILL.md` en `~/.openclaw/skills`) instruyen al agente para invocarlo vía la
tool `exec` (bash en el host del Gateway; sandbox off by default).

Operaciones de grupo cubiertas (`wacli groups ...`):

- **Kick**: `wacli groups participants remove --jid <grupo> --user <usuario>`.
- **Roles admin (verificación)**: `wacli groups participants list --jid <grupo>
  --json` (snapshot local) y `wacli groups info --jid <grupo>` — *el rol admin
  en el `--json` es **probable pero NO CONFIRMADO** por la doc; whatsmeow sí
  incluye el rol en groupInfo, verificar empíricamente*.
- Otras operaciones: `promote`, `demote`, `add`, requests, invite link,
  announce-only, etc.

**Envío de stickers**: `wacli send sticker --to <JID> --file ./sticker-512.webp`
(WebP 512×512; estáticos ≤100 KiB; animados ≤500 KiB con metadata de
animación).

**Convivencia con la sesión del plugin**: WhatsApp Multi-Device admite hasta
**4 companion devices** además del teléfono; la sesión Baileys del plugin ocupa
1 slot, wacli un 2º. **Precedente oficial dentro de OpenClaw**: MeowCaller
(llamadas WhatsApp) usa "a separately paired whatsmeow linked-device session —
it cannot reuse the plugin's Baileys credentials".

#### Pros

- Operaciones de grupo **completas** (kick/promote/demote/metadata) y envío de
  stickers resueltos con un CLI mantenido por la propia org openclaw.
- **No hay que tocar ni hacer fork del plugin** `@openclaw/whatsapp`: sin
  rebase por release, sin riesgo de perder la confianza del canal (#151795).
- No hay que escribir ni mantener servicio de red propio (frente a un sidecar
  Baileys artesanal).
- Integración sencilla con el patrón skill + `exec` de OpenClaw (binario único,
  salida `--json`); gating de binarios requeridos soportado por las skills
  (`metadata.openclaw.requires.bins: ["wacli"]`).
- Modo read-only disponible (`--read-only` / `WACLI_READONLY=1`) para reducir
  riesgo de mutación accidental.

#### Contras

- Consume un **2º dispositivo vinculado** (2ª sesión QR independiente en
  `~/.wacli`) que hay que mantener (locks de store, reconexión).
- Riesgo residual de detección/ban con libs no oficiales (ver Consecuencias).
- Comandos y salida en **inglés**.
- El rol admin en `participants list --json` **no está confirmado** por la doc
  de wacli; la verificación de admin depende de confirmarlo empíricamente.

### Opción B: Fork/patch del plugin `@openclaw/whatsapp` (locators `git:` / `--link`)

Hacer fork del plugin y añadir tools de kick/roles/sticker al propio canal
(instalación vía `openclaw plugins install git:github.com/<fork>/openclaw@<tag>
--force`, o `--link` con directorio local y `openclaw plugins reload`).

#### Pros

- Las capacidades quedarían integradas en el canal (un solo dispositivo
  vinculado; sin CLI externo).
- Los locators `git:` y `-l/--link` son mecanismos de primera clase
  documentados.

#### Contras

- **Frágil en actualizaciones**: la release cohort ata los plugins oficiales a
  la versión del host; habría que hacer rebase por cada release. Upstream no va
  a implementarlo a corto plazo (#144695 "not planned"; PRs #7502 y #89033
  cerrados sin mergear).
- **`pnpm patch` NO es feature de usuario**: la doc describe el packaging
  interno de OpenClaw, no un mecanismo público para parchear plugins
  instalados (**no soportado**).
- **RIESGO de confianza de canal**: la doc de `plugins install` advierte que
  las instalaciones locales vía `plugins.load.paths` (incluido `--link`) **no
  heredan la confianza oficial del paquete** y un canal que requiera estado
  confiable puede quedar **bloqueado** ("ingress queue unavailable"), confirmado
  en vivo por [#151795](https://github.com/openclaw/openclaw/issues/151795).
  **NO CONFIRMADO** si `git:` comparte esa restricción con `--link`, pero la
  doc sugiere que cualquier fuente no oficial puede perder la confianza.

### Opción C: Sidecar Baileys propio (servicio Node con su sesión, HTTP API)

Escribir un servicio Node pequeño con Baileys `7.0.0-rc14`, su propio auth
(2º/3er QR) y una HTTP API local (`POST /group/kick`,
`GET /group/:jid/metadata`, `POST /send/sticker`) con token local; el agente lo
invocaría vía `exec`+`curl` o un wrapper MCP stdio.

#### Pros

- Mismo patrón de "linked device" secundario que usa el propio OpenClaw en
  MeowCaller; capacidades confirmadas en Baileys (`groupParticipantsUpdate`,
  `sock.sendMessage(jid, { sticker })`).
- Control total del código.

#### Contras

- Hay que **escribir y mantener un servicio nuevo** (auth, reconexión, HTTP,
  token, errores) — coste medio-alto y mantenimiento alto.
- **Riesgo de ToS/ban documentado**: [whatsmeow #810](https://github.com/tulir/whatsmeow/issues/810)
  reporta avisos "Your account may be at risk" y baneos **incluso con uso de
  bajo volumen**, afectando a whatsmeow **y Baileys**; cerrado como *not planned*.
- **Redundante con wacli**: elegir wacli o sidecar, no ambos (un 3er vinculado
  — plugin + wacli + sidecar — incrementaría la superficie de detección sin
  aportar capacidades nuevas).

### Opción D: Esperar a upstream (#7476, #144695)

No construir nada y esperar a que OpenClaw exponga kick/roles/stickers.

#### Pros

- Cero coste de implementación y cero riesgo propio si llega.

#### Contras

- **Sin fecha**: #144695 está cerrado como "not planned" (2026-10-03) y #7476
  abierto como "needs product decision" (P3); el PR #7502 se cerró sin mergear.
  No hay señal de que vaya a implementarse a corto plazo.
- **Bloquea el `ISSUE-001`** (kick con verificación de admin y stickers quedarían
  sin resolver).

### Nota: plugin de tools (`defineToolPlugin`) y MCP (`openclaw mcp add`)

Ambos mecanismos son **válidos y documentados** para añadir tools invocables por
el agente, pero **no resuelven solos el problema**: no hay API pública ni IPC
para que un proceso externo o plugin de terceros reutilice el socket Baileys del
plugin ("The gateway owns the WhatsApp socket and reconnect loop"; las
superficies de canal para plugins son read-only; #144695 confirma que "the
plugin's active listener/send API exposes no group metadata or
participant-update methods"). Es decir, un tool plugin o un servidor MCP pueden
**envolver** el mecanismo elegido (p. ej. wacli), pero no sustituyen la decisión
sobre dónde obtener kick/roles/stickers. Wacli además declara explícitamente
fuera de su alcance ser daemon/MCP server: no hay wrapper MCP oficial (**no
confirmado** el patrón wrapper propio + `openclaw mcp add`).

## Decisión

**Opción A (wacli)** como mecanismo para kick, verificación de admin y envío de
stickers, complementada con dos skills propias:

- **(a) Skill propia de creación de stickers** con `ffmpeg` (webp 512×512;
  vídeo → sticker animado con fps y squeeze a 512×512), y
- **(b) skill propia de descarga multimedia** con `yt-dlp` + `ffmpeg`.

### Justificación

- **Sin tocar el plugin**: se evita la fragilidad del fork (rebase por release,
  PRs upstream no mergeados) y el riesgo concreto de pérdida de confianza del
  canal en instalaciones no oficiales (#151795, "ingress queue unavailable").
- **Sin mantener código de red propio**: frente al sidecar Baileys artesanal, no
  hay servicio nuevo que escribir, autenticar y mantener.
- **Capacidades de grupo completas y verificadas**: kick, listado de
  participantes y metadata vía `wacli groups ...`; envío de stickers vía
  `wacli send sticker --file sticker-512.webp`.
- **Alineado con el ecosistema OpenClaw**: wacli está bajo
  `github.com/openclaw/wacli` y el patrón de 2º dispositivo vinculado tiene
  precedente oficial con MeowCaller.
- **Upstream no va a cubrirlo a corto plazo** (#144695 "not planned"), por lo
  que la Opción D queda descartada.
- La creación de stickers y las descargas se resuelven con skills propias
  (patrón nativo: `SKILL.md` + `exec` + binarios en la imagen), evitando además
  depender de skills de terceros sin auditar (p. ej. el skill yt-dlp de ClawHub,
  comunidad, no auditado).

### Decisión secundaria: imagen Docker derivada

En lugar de binarios laterales en `~/.openclaw/skills/` o instalación solo con
`apt` en cada despliegue, se creará una **imagen Docker derivada** (`FROM` la
imagen oficial de OpenClaw; base Debian `node:22-bookworm-slim` — Alpine no
soporta el native runtime) que instala:

- `ffmpeg` (por `apt`),
- `yt-dlp` — preferiblemente **binario estático** para evitar la versión
  desactualizada de bookworm (los vídeos de YouTube requieren yt-dlp muy
  reciente) — *decisión a verificar empíricamente* (apt vs estático vs pip),
- `wacli` (binario Go).

Justificación: reproducible, versionable en el repo y hereda las variables
oficiales (`OPENCLAW_STATE_DIR`, `OPENCLAW_CONFIG_PATH`, `env_file: .env`), sin
mantener un sidecar de red separado.

## Consecuencias

### Positivas

- **Sin fork del plugin**: mantenimiento bajo; las actualizaciones de OpenClaw
  no obligan a rebase de parches propios.
- **Capacidades completas** para el `ISSUE-001`: kick, verificación de admin,
  envío de stickers, creación de stickers y descargas multimedia.
- Sin servicio de red propio que mantener (frente a sidecar Baileys).
- Reutiliza patrones nativos de OpenClaw (skills + `exec`, imagen Docker
  derivada, `.env` con `${VAR}`) para todo lo demás.

### Negativas

- **2º dispositivo vinculado = 2ª sesión QR** que emparejar y mantener
  (`~/.wacli`, store independiente del plugin; locks de store; un envío en
  cola puede delegarse en `wacli sync --follow`).
- **Riesgo residual de ban/avisos** con clientes no oficiales, documentado de
  forma honesta en [whatsmeow #810](https://github.com/tulir/whatsmeow/issues/810):
  avisos "Your account may be at risk" y baneos reportados incluso con uso de
  bajo volumen, afectando a whatsmeow **y Baileys** (la probabilidad exacta
  **no está cuantificada**; solo reportes anecdóticos). Wacli se declara
  "third-party tool… not affiliated with WhatsApp or Meta… subject to
  WhatsApp's terms".
- El agente **depende de la verificación de admin vía datos de wacli**: si
  `wacli groups participants list --json` **no incluye los roles** (no
  confirmado por la doc), habrá que verificar empíricamente y, en su caso,
  usar `groups info --json` u otra salida.
- **Texto en inglés** en comandos y mensajes de error de wacli.
- Imagen Docker derivada que hay que mantener (rebuild ante nuevas versiones).

### Riesgos Mitigados

- **Fragilidad del fork** (Opción B): se evita por completo al no parchear el
  plugin.
- **Riesgo de confianza de canal** (#151795, "ingress queue unavailable"): se
  evita al no usar fuentes no oficiales del plugin (`git:`/`--link`).
- **ToS/mantenimiento del sidecar artesanal** (Opción C): se sustituye por un
  CLI mantenido por la org openclaw; se mantiene un solo "segundo" dispositivo
  vinculado (no plugin + wacli + sidecar).
- **Dependencia de upstream** (Opción D): se elimina la espera a #7476/#144695.

### Riesgos Residuales

- Suspensión/avisos de la cuenta por uso de cliente no oficial (whatsmeow/wacli)
  — probabilidad **no confirmada**; mitigación operativa: rate-limit de envíos
  (wacli avisa si se repiten envíos en <5 s), evitar bulk, número dedicado, y
  modo read-only (`WACLI_READONLY=1`) donde no se necesite mutación.
- **Radio de impacto (*blast radius*) de un baneo: la cuenta completa.** WhatsApp
  Multi-Device implica que este bot es **una sola cuenta con dos dispositivos
  vinculados** (la sesión Baileys del plugin en `~/.openclaw` + la sesión de
  `wacli` en `~/.wacli`), **no dos cuentas independientes**. Por tanto, un baneo o
  bloqueo a **nivel de cuenta** —el escenario que reporta whatsmeow #810, que
  afecta a whatsmeow **y Baileys**— **tumba las dos sesiones a la vez**: la sesión
  Baileys del plugin **y** `wacli` caen simultáneamente y el bot queda inoperativo
  por completo, arrastrando consigo las capacidades no nativas (kick, stickers,
  descargas). No hay aislamiento entre ambas sesiones: es un **único radio de
  impacto que cubre todo el bot**, no un riesgo por componente.
- **Consecuencia operativa: hay que vigilar las dos sesiones.** Al compartir
  cuenta, el seguimiento debe comprobar **ambas** sesiones (la del plugin y la de
  `wacli`), porque sus fallos no son equivalentes: una **caída de `wacli`** degrada
  de forma **silenciosa** (el bot sigue respondiendo, pero las skills que dependen
  de él fallan y el kick falla *cerrado*, esto es, no expulsa); una **caída de la
  sesión Baileys del plugin** deja al bot **totalmente mudo**. Ninguno de los dos
  fallos es evidente desde el exterior sin comprobarlo, así que la vigilancia de
  ambas sesiones es explícita y no opcional.
- La verificación de admin (requisito de seguridad del kick) **pendiente de
  verificación empírica** del campo de rol en la salida JSON de wacli; no se
  debe desplegar el kick sin confirmarlo.
- Comportamiento de WhatsApp al superar los 4 companion devices en 2026 **no
  verificado** (asunción basada en la FAQ oficial).
- Versión de yt-dlp elegida (binario estático vs apt) **a verificar**; los
  vídeos de YouTube requieren yt-dlp muy reciente.
- El límite duro real de media de WhatsApp puede ser menor que los 50 MB por
  defecto de `mediaMaxMb` (no confirmado en la fuente) → verificar empíricamente.

## Implementación

Pasos de alto nivel (el detalle fino corresponderá al plan de implementación):

1. **Dockerfile derivado + compose**: `FROM` la imagen oficial de OpenClaw
   (Debian bookworm); instalar `ffmpeg`, `yt-dlp` (binario estático, a
   verificar) y `wacli`; heredar las variables oficiales
   (`OPENCLAW_STATE_DIR`, `OPENCLAW_CONFIG_PATH`, `env_file: .env`) y montar
   el volumen `~/.openclaw`.
2. **Instalación y auth de wacli**: binario disponible en la imagen;
   emparejar como 2º dispositivo vinculado con QR propio (`wacli auth`), store
   persistido (`~/.wacli`) como volumen.
3. **Skill `group-admin`**: enseñar el flujo kick solo tras verificar (1) que el
   emisor es admin y (2) que el bot es admin, usando `wacli groups
   participants list/info --json`, y ejecutar `wacli groups participants remove`;
   declarar `requires.bins: ["wacli"]`.
4. **Skill `sticker`**: creación de stickers con `ffmpeg` (webp 512×512,
   estático y animado con los límites de wacli: ≤100 KiB / ≤500 KiB) y envío vía
   `wacli send sticker --file`.
5. **Skill `yt-dlp`**: descarga/conversión de multimedia con `yt-dlp` +
   `ffmpeg`, con entrega respetando `channels.whatsapp.mediaMaxMb` (50 MB
   default; forzar documento/comprimir si se supera).
6. **Config `openclaw.json`**: `activation.mode: mention` para grupos y
   `channels.whatsapp.dmPolicy: "allowlist"` + `allowFrom` para DM (ambos
   nativos); parametrización LLM vía `.env` con `${VAR}`.
7. **Verificación empírica**: confirmar si `wacli groups participants list
   --json` incluye los roles admin (requisito del paso 3) y verificar los
   límites reales de media al enviar.

## Referencias

### Investigaciones de base

- `docs/agents/research/RESEARCH-001-openclaw-bot-whatsapp.md`
- `docs/agents/research/RESEARCH-002-mecanismos-extension-openclaw.md`

### Documentación oficial OpenClaw

- Índice documental: <https://docs.openclaw.ai/llms.txt>
- Instalación Docker: <https://docs.openclaw.ai/install/docker>
- Variables de entorno Docker:
  <https://docs.openclaw.ai/install/docker/environment-variables>
- Canal WhatsApp: <https://docs.openclaw.ai/channels/whatsapp> (incluye
  precedente MeowCaller de linked-device whatsmeow)
- Grupos: <https://docs.openclaw.ai/channels/groups>
- Referencia plugin WhatsApp: <https://docs.openclaw.ai/plugins/reference/whatsapp>
- CLI `message`: <https://docs.openclaw.ai/cli/message>
- CLI `directory`: <https://docs.openclaw.ai/cli/directory>
- CLI `plugins` (install): <https://docs.openclaw.ai/cli/plugins/install>
- CLI `plugins` (uninstall/update/reload):
  <https://docs.openclaw.ai/cli/plugins/uninstall-and-update>
- Tool plugins (`defineToolPlugin`): <https://docs.openclaw.ai/plugins/tool-plugins>
- Connect MCP servers: <https://docs.openclaw.ai/tools/mcp>
- Skills: <https://docs.openclaw.ai/tools/skills>
- Exec tool: <https://docs.openclaw.ai/tools/exec>
- Tool policy: <https://docs.openclaw.ai/gateway/config-tools/tool-policy>
- Config de agentes / entries:
  <https://docs.openclaw.ai/gateway/config-agents/entries-and-multi-agent>
- Model providers / quick-rules: <https://docs.openclaw.ai/concepts/model-providers/quick-rules>

### wacli

- Sitio: <https://wacli.sh> · Repo: <https://github.com/openclaw/wacli>
- Groups (kick, participants list, info): <https://wacli.sh/groups.html>
- Send (stickers): <https://wacli.sh/send.html>
- Auth (QR / pairing, stores): <https://wacli.sh/auth.html>

### Issues y PRs upstream

- #7476 (WhatsApp sticker send, abierto "needs product decision"):
  <https://github.com/openclaw/openclaw/issues/7476>
- #144695 (participant info/add/remove — cerrado "not planned"):
  <https://github.com/openclaw/openclaw/issues/144695>
- #151795 (instalaciones `--link` no confiables → canal bloqueado, ingress
  queue unavailable): <https://github.com/openclaw/openclaw/issues/151795>
- PR #7502 (sticker send, cerrado sin mergear): <https://github.com/openclaw/openclaw/pull/7502>
- PR #89033 (group create/add/invite tools, cerrado sin mergear):
  <https://github.com/openclaw/openclaw/pull/89033>
- whatsmeow #810 (avisos "account may be at risk"; whatsmeow y Baileys; cerrado
  not planned): <https://github.com/tulir/whatsmeow/issues/810>

### WhatsApp Multi-Device

- FAQ: <https://faq.whatsapp.com/378279804439436>
- Meta engineering: <https://engineering.fb.com/2021/07/14/security/whatsapp-multi-device/>

### Repositorio y código fuente

- Repo OpenClaw: <https://github.com/openclaw/openclaw>
- `extensions/whatsapp/src/schema.ts` — config keys del canal.
- `extensions/whatsapp/src/inbound/group-metadata-cache.ts` — metadata de grupo
  (descarta roles admin).
- `extensions/whatsapp/src/inbound/send-api.ts` — `sendSticker` interno (solo
  QA driver).
