# RESEARCH-002: Mecanismos de extensión de OpenClaw para capacidades no expuestas por `@openclaw/whatsapp`

| Campo | Valor |
| --- | --- |
| **ID** | RESEARCH-002 |
| **Fecha** | 2026-10-15 |
| **Ref. Issue** | ISSUE-001 |
| **Estado** | Completada |

## Contexto

El plugin oficial `@openclaw/whatsapp` (Baileys `7.0.0-rc14`) no expone hoy
acciones de kick de participantes, descarta el campo `admin` del
`GroupMetadata`, y el envío de stickers (`sendSticker`) solo existe interno en
el driver QA (issue upstream [#7476](https://github.com/openclaw/openclaw/issues/7476)).
Esta investigación determina las **vías posibles** para añadir esas capacidades
al agente. Contexto ya verificado (no se repite aquí): no existe acción de kick
en el plugin; el campo `admin` se descarta; `sendSticker` solo en el QA driver.

Se han investigado 4 caminos. Veredictos al final, en la tabla resumen.

---

## Camino 1: API de plugins/tools de OpenClaw

**Veredicto: VIABLE** (para añadir tools y para que el agente ejecute comandos
externos vía `exec`/skills). **NO VIABLE** para alcanzar el socket Baileys
interno del plugin desde un tercero.

### 1.1 Plugins de tools de terceros (`defineToolPlugin`) — VIABLE

OpenClaw permite crear plugins que **solo añaden tools invocables por el
agente**, sin tocar canal ni proveedor. Documentado en
[Tool plugins](https://docs.openclaw.ai/plugins/tool-plugins):

```bash
openclaw plugins init stock-quotes --name "Stock Quotes"
cd stock-quotes && npm install
npm run plugin:build      # tsc + openclaw plugins build --entry ./dist/index.js
npm run plugin:validate   # openclaw plugins validate --entry ./dist/index.js
openclaw plugins install ./stock-quotes        # o npm-pack:./<pkg>.tgz
openclaw plugins inspect stock-quotes --runtime
openclaw plugins reload stock-quotes           # tras editar, sin reiniciar Gateway
```

Requisitos: Node 24.16+, TypeScript ESM, `typebox` en `dependencies`,
`openclaw >= 2026.5.17` (exporta `openclaw/plugin-sdk/tool-plugin`). El SDK
ofrece `defineToolPlugin` con schemas TypeBox, `outputSchema`, herramientas
factory y entrega de respuesta (`sourceReply`). Un plugin de tools podría, por
ejemplo, registrar una tool `wa_kick` cuya `execute` haga `curl`/CLI a un
servicio externo (ver caminos 2 y 3).

### 1.2 MCP como fuente de tools — VIABLE

OpenClaw soporta conectar **servidores MCP de terceros** como fuente de tools
([Connect MCP servers](https://docs.openclaw.ai/tools/mcp)). Las tools pasan
por el mismo tool-policy que el resto:

```bash
openclaw mcp add local-tools --command node --arg ./dist/mcp-server.js --cwd /srv/openclaw-tools
openclaw mcp doctor local-tools --probe
# o remoto:
openclaw mcp add wacli --url https://mcp.example.com/mcp --transport streamable-http --include 'group_*'
```

Config en `openclaw.json` (`mcp.servers.<nombre>` con `command`/`args` o
`url`/`transport`, `toolFilter.include/exclude`). Nota: `wacli` declara
explícitamente "out of scope: a daemon, MCP server" — no hay wrapper MCP
oficial; habría que escribirlo a mano (stdio) y registrarlo con
`openclaw mcp add` (combinación no documentada, marcada como no confirmada).

### 1.3 Skills con scripts/`exec` — VIABLE (orquestación, no capacidades nuevas)

Las skills son ficheros `SKILL.md` (markdown + frontmatter YAML) que enseñan al
agente cuándo usar tools ([Skills](https://docs.openclaw.ai/tools/skills)).
Se instalan con `openclaw skills install ./ruta --as wa-admin` o viven en
`<workspace>/skills/`. Una skill puede instruir al agente para invocar
`wacli ...` o `curl` mediante la tool `exec`. Soportan `command-dispatch: tool`
(dispatch directo a una tool registrada) y gating por bins requeridos
(`metadata.openclaw.requires.bins: ["wacli"]`).

### 1.4 ¿Puede la bash del agente alcanzar el socket Baileys del plugin? — NO

- La tool `exec` ([Exec tool](https://docs.openclaw.ai/tools/exec)) ejecuta
  shell en el host del Gateway: **por defecto `host=auto` resuelve a `gateway`**
  (sandboxing **off by default**), así que la bash del agente corre en el mismo
  host que el plugin y puede lanzar binarios externos (`wacli`, `curl`, un
  sidecar Node).
- Sin embargo, **no hay API pública ni IPC documentado para que un proceso
  externo (o un plugin de terceros) reutilice el socket Baileys del plugin**:
  "The gateway owns the WhatsApp socket and reconnect loop"
  ([WhatsApp](https://docs.openclaw.ai/channels/whatsapp)); las superficies de
  canal para plugins son de inspección read-only
  ([Channel surfaces](https://docs.openclaw.ai/plugins/architecture-internals/channel-surfaces));
  el issue [#144695](https://github.com/openclaw/openclaw/issues/144695)
  confirma que "the plugin's active listener/send API exposes no group metadata
  or participant-update methods".

### 1.5 API local/HTTP del Gateway para acciones de canal — PARCIAL

- **CLI**: `openclaw message send|poll|react --channel whatsapp` existe
  ([Message](https://docs.openclaw.ai/cli/message)), pero **no hay kick**;
  `member info` solo soporta Discord/Matrix/msteams/Slack; `sticker send` es
  solo Discord. El vocabulario compartido `addParticipant`/`removeParticipant`
  devuelve `INVALID_REQUEST: Message action ... not supported for channel whatsapp`
  (issue #144695).
- **HTTP**: el Gateway expone `POST /tools/invoke`
  ([Tools invoke API](https://docs.openclaw.ai/gateway/tools-invoke-http-api))
  para invocar cualquier tool permitida por política (`Authorization: Bearer <gateway token>`),
  con `exec`/`spawn`/etc. en deny-list por defecto sobre HTTP. Sirve como
  superficie de invocación de tools propias, no aporta acciones de canal nuevas.
- **CLI directory**: `openclaw directory groups list --channel whatsapp` hace
  listado **live** de grupos ("WhatsApp group listing is live. Gateway lookups
  reuse its owned connection"), pero **no confirmado** que exponga roles de
  admin.
- **Hooks de plugins**: existen hooks de mensajes/lifecycle
  ([Plugin hooks](https://docs.openclaw.ai/plugins/hooks)), pero no conceden
  mutaciones de canal que el plugin no implemente.

---

## Camino 2: wacli (CLI oficial de la organización openclaw)

**Veredicto: VIABLE — el camino más directo y mejor encaje.**

- **Existe**: https://wacli.sh y https://github.com/openclaw/wacli (antes
  steipete/wacli; ahora bajo la org `openclaw`). Instalación:
  `brew install openclaw/tap/wacli`. CLI en Go sobre **whatsmeow**, binario
  único, empareja como **dispositivo WhatsApp Web vinculado**, replica historial
  en SQLite local (FTS5).
- **Operaciones de GRUPO — COMPLETAS** ([groups](https://wacli.sh/groups.html)):

```bash
wacli groups info --jid 123456789@g.us
wacli groups participants list --jid 123456789@g.us --json   # snapshot local (read-only OK)
wacli groups participants remove --jid 123456789@g.us --user "+34 600 123 456"   # KICK
wacli groups participants promote --jid ... --user ...        # promover a admin
wacli groups participants demote  --jid ... --user ...
wacli groups participants add     --jid ... --user ...
wacli groups requests list|approve|reject --jid ... --user ...
wacli groups invite link get|revoke --jid ...
wacli groups announce-only|locked --jid ... --on|--off
wacli groups create|rename|topic|description|leave|join|refresh
```

- **Stickers — SÍ** ([send](https://wacli.sh/send.html)):
  `wacli send sticker --to <JID|teléfono|nombre> --file ./sticker-512.webp`.
  Requiere WebP 512×512; estáticos ≤100 KiB; animados ≤500 KiB (con metadata de
  animación). También `send text|file|voice|location|react|poll|status|select`.
- **Autenticación** ([auth](https://wacli.sh/auth.html)): QR por terminal
  (`wacli auth [--qr-format text]`) o emparejamiento por teléfono
  (`wacli auth --phone "+34 ..."`). Cada tienda (store) es una sesión de
  dispositivo vinculado **independiente**; `wacli accounts add NAME` crea
  cuentas con stores aislados (`--account`). Los locks de store impiden dos
  instancias sobre la misma identidad; los envíos se delegan al proceso
  `wacli sync --follow` si está corriendo (evita una segunda sesión).
- **Convivencia con la sesión de OpenClaw**: WhatsApp Multi-Device permite hasta
  **4 dispositivos vinculado**s además del teléfono primario
  ([FAQ WhatsApp](https://faq.whatsapp.com/378279804439436),
  [engineering.fb.com](https://engineering.fb.com/2021/07/14/security/whatsapp-multi-device/)).
  La sesión Baileys del plugin ocupa 1 slot; wacli ocuparía un 2º. **Precedente
  documentado dentro del propio OpenClaw**: MeowCaller (llamadas WhatsApp)
  usa "a separately paired whatsmeow linked-device session — it cannot reuse
  the plugin's Baileys credentials. Pairing adds another linked device to the
  same WhatsApp account" ([WhatsApp — MeowCaller](https://docs.openclaw.ai/channels/whatsapp)).
- **Integración con el agente**: skill `SKILL.md` + tool `exec` del Gateway
  (bash en el host, sin sandbox por defecto) invocando `wacli --json ...`, o
  `openclaw mcp add` con un wrapper MCP stdio propio (no oficial).
- **Advertencias**: disclaimer propio de wacli ("third-party tool… not
  affiliated with WhatsApp or Meta… subject to WhatsApp's terms"); riesgo de
  detección/ban ver en Camino 3. Modo `--read-only`/`WACLI_READONLY=1` disponible
  para riesgo cero de mutación accidental.

---

## Camino 3: Sidecar Baileys propio (2º/3er dispositivo vinculado)

**Veredicto: VIABLE** (patrón avalado por OpenClaw) **con riesgo de
suspensión NO CUANTIFICABLE (riesgo real, probabilidad NO CONFIRMADA).**

- **Patrón de "linked device" secundario — documentado**: WhatsApp admite hasta
  4 companion devices independientes del teléfono
  ([FAQ](https://faq.whatsapp.com/378279804439436),
  [Meta engineering](https://engineering.fb.com/2021/07/14/security/whatsapp-multi-device/)).
  OpenClaw mismo lo usa en MeowCaller (whatsmeow vinculado en paralelo al
  socket Baileys del plugin, con su propio store en
  `~/.openclaw/credentials/whatsapp-calls/<account>/wa-voip.db`). Un sidecar
  Node con Baileys `7.0.0-rc14` y su propio `auth` (2º QR) es el mismo patrón.
- **Capacidades Baileys confirmadas por los propios issues de OpenClaw**:
  - Sticker: `await sock.sendMessage(jid, { sticker: buffer })`
    (comentario en [#7476](https://github.com/openclaw/openclaw/issues/7476)).
  - `groupMetadata` y `groupParticipantsUpdate` ya existen en Baileys
    ([#144695](https://github.com/openclaw/openclaw/issues/144695)) — es
    decir, kick/promote/demote y metadata con roles son triviales en un sidecar.
- **Arquitectura propuesta (viable)**: servicio Node pequeño con HTTP local
  (`POST /group/kick`, `GET /group/:jid/metadata`, `POST /send/sticker`),
  autenticado con token local; el agente lo invoca vía `exec`+`curl` (o un
  wrapper MCP stdio registrado con `openclaw mcp add`). El agente necesita
  además una skill que enseñe el flujo (verificar admin → kick → verificar).
- **Advertencias / riesgos**:
  - ToS: wacli se descubre a sí mismo como no afiliado y "pairing as a linked
    device is subject to WhatsApp's terms".
  - Riesgo documentado de avisos y baneos con clientes no oficiales:
    [whatsmeow #810](https://github.com/tulir/whatsmeow/issues/810) — avisos
    "Your account may be at risk" y baneos reportados **incluso con uso de bajo
    volumen**, afectando a whatsmeow **y Baileys** ("recent updates to
    WhatsApp's detection systems may be targeting both libraries"); cerrado
    como *not planned*. Existen también reportes de suspensión temporal al
    vincular dispositivos (Reddit, no oficial).
  - Cada dispositivo vinculado adicional incrementa la superficie de
    detección; un 3er vinculado (plugin + wacli + sidecar) sería redundante —
    elegir **uno** de wacli o sidecar, no ambos.
  - Mitigación operativa (patrón wacli): rate-limit de envíos (wacli avisa si
    se repiten envíos en <5 s), evitar bulk, número dedicado.

---

## Camino 4: Fork/patch del plugin `@openclaw/whatsapp`

**Veredicto: VIABLE técnicamente, pero ALTO mantenimiento y con un riesgo
concreto de "confianza de canal" (NO CONFIRMADO para el caso WhatsApp).**

### 4.1 Cómo instala OpenClaw los plugins

- Instalación oficial: `openclaw plugins install @openclaw/whatsapp` (npm;
  fallback a ClawHub) ([WhatsApp](https://docs.openclaw.ai/channels/whatsapp)).
- Locators soportados ([Install plugins](https://docs.openclaw.ai/cli/plugins/install)):
  `clawhub:`, `npm:`, `npm-pack:<path.tgz>`, **`git:github.com/<owner>/<repo>[@<ref>]`**
  (forks vía git son un locator de primera clase), ruta local, y
  **`-l/--link`** (enlazar directorio local sin copiar → `plugins.load.paths`).
- Raíces de instalación ([Dependency resolution](https://docs.openclaw.ai/plugins/dependency-resolution)):
  npm → `~/.openclaw/npm/projects/<encoded-package>`; git → `~/.openclaw/git`.
  Son estado duradero, no caché.

### 4.2 Vías de parcheo

1. **Fork + instalación git** (la más limpia):
   `openclaw plugins install git:github.com/<tu-fork>/openclaw@<tag> --force`
   (requiere revisar la fuente arbitraria). Después: `openclaw plugins reload <id>`.
2. **Link local**: editar el código y `openclaw plugins install -l ./mi-whatsapp-parcheado`;
   `openclaw plugins reload <id>` recarga código editado sin reiniciar el
   Gateway ([Uninstall and update](https://docs.openclaw.ai/cli/plugins/uninstall-and-update)).
3. **Parche directo del árbol instalado** (`~/.openclaw/npm/projects/...` +
   reload): funciona a corto plazo, pero el propio runtime lo desaconseja:
   "the next install or update recreates the project from package metadata".
4. **`pnpm patch` / overrides**: **NO es una feature para usuarios**. La
   documentación de pnpm/patch describe el packaging interno de OpenClaw
   (bundled dependencies con "approved workspace patch"), no un mecanismo
   público para parchear plugins instalados. **NO CONFIRMADO / no soportado**.

### 4.3 Riesgo de confianza del canal (importante)

[Install plugins](https://docs.openclaw.ai/cli/plugins/install) advierte:
"Local copies selected through `plugins.load.paths`, including `--link`
installs, **do not inherit official package trust**… If a channel requires
trusted plugin state, such as its durable ingress queue, startup records the
refusal and leaves the **channel blocked**". Confirmado en vivo por el issue
[#151795](https://github.com/openclaw/openclaw/issues/151795) ("Path-managed
(--link) plugin installs are not trusted: channels refuse to start — Channel
ingress queue is unavailable"). **NO CONFIRMADO** si las instalaciones `git:`
comparten esa restricción con `--link`; la documentación sugiere que cualquier
fuente no oficial puede perder la confianza de canal → verificar antes de
comprometerse (probar en un entorno con un canal de prueba).

### 4.4 Fragilidad y estado upstream

- Issue [#7476](https://github.com/openclaw/openclaw/issues/7476) (stickers):
  **abierto** (P3, "needs product decision" desde 2026-10-08); el PR #7502
  ("feat(whatsapp): send WebP files as stickers") está **cerrado sin mergear**;
  existe un patch local de la comunidad sobre `dist/web/...` (layout antiguo —
  el código se movió a `extensions/whatsapp/src/...` en el refactor
  `16505718e827`).
- Issue [#144695](https://github.com/openclaw/openclaw/issues/144695)
  (participant info/add/remove nativos): **cerrado como "not planned"**
  (2026-10-03, stale). Antes, el PR #89033 (tools de grupo) fue cerrado sin
  mergear por faltas de salvaguardas de autorización; #114687 se cerró como
  duplicado de #74261. Señal clara: **upstream no va a implementarlo a corto
  plazo** → un fork tiene valor duradero, pero el mantenimiento (rebase por
  cada release, la release cohort ata los plugins oficiales a la versión del
  host) recae en el usuario.
- Rutas de contribución documentadas:
  [Adding capabilities](https://docs.openclaw.ai/plugins/adding-capabilities),
  [Community plugins](https://docs.openclaw.ai/plugins/community),
  [ClawHub publishing](https://docs.openclaw.ai/clawhub/publishing). Un PR al
  plugin oficial es la vía "limpia" aunque lenta (los dos PRs existentes no
  se han mergearado).

---

## ¿Se pueden obtener hoy los roles de admin del grupo?

| Superficie | ¿Expone roles admin? | Evidencia |
| --- | --- | --- |
| Tool/acción del canal WhatsApp (`member info`, `addParticipant`, `removeParticipant`) | **NO** | `INVALID_REQUEST: Message action ... not supported for channel whatsapp` ([#144695](https://github.com/openclaw/openclaw/issues/144695)); `openclaw channels capabilities --channel whatsapp --json` solo anuncia `send`, `broadcast`, `react`, `poll`, `upload-file` |
| CLI `openclaw message member info` | **NO** (Discord/Matrix/msteams/Slack) | [Message](https://docs.openclaw.ai/cli/message) |
| Plugin `@openclaw/whatsapp` (GroupMetadata) | **NO** — descarta `admin` | Contexto ISSUE-001 (ya verificado) |
| CLI `openclaw directory groups list/members --channel whatsapp` | Listado **live** de grupos; **roles admin NO CONFIRMADOS** | [Directory](https://docs.openclaw.ai/cli/directory) |
| CLI del plugin/whatsapp (subcomandos de grupo) | **NO existen** | No hay namespace `openclaw whatsapp`; el CLI del canal es solo login/logout/status |
| `wacli groups participants list --json` / `groups info --json` | **PROBABLE pero NO CONFIRMADO** por la doc (whatsmeow sí incluye el rol en groupInfo; la doc de wacli no lo especifica) | [wacli groups](https://wacli.sh/groups.html) — verificar empíricamente con `--json` |

---

## Tabla resumen de viabilidad

| # | Camino | Veredicto | Coste | Mantenimiento | Riesgo |
| --- | --- | --- | --- | --- | --- |
| 1 | Plugin/tool propio + MCP + skills (`exec` hacia CLI externo) | **VIABLE** (pero no alcanza el socket del plugin) | Bajo-medio | Bajo | Bajo (sin segundo dispositivo vinculado si no se usa CLI externo) |
| 2 | **wacli** (kick/promote/demote + stickers + metadata) | **VIABLE — recomendado** | Bajo (`brew install` + skill) | Bajo (CLI mantenido por la org openclaw) | Medio: 2º dispositivo vinculado; avisos/bans documentados con libs no oficiales |
| 3 | Sidecar Baileys propio (HTTP + 2º QR) | **VIABLE** | Medio-alto (servicio Node + auth + mantenimiento) | Alto | Medio-alto: 2º/3er dispositivo, ToS, detección (whatsmeow #810) |
| 4 | Fork/patch de `@openclaw/whatsapp` (git:, --link, reload) | **VIABLE pero frágil** | Medio (parches pequeños: send-api.ts, channel-actions.ts, GroupMetadata) | **Alto**: rebase por release; PRs upstream no mergeados (#7476, #89033); #144695 cerrado "not planned" | Medio: fuentes no oficiales pueden bloquear el canal (ingress queue, #151795); pnpm patch no soportado |

**Recomendación implícita de la evidencia**: camino 2 (wacli) como primera
opción — es la que usa el propio issue #144695 como workaround conocido, cubre
kick/promote/demote/stickers de forma completa y con menor superficie de
mantenimiento; camino 1 para envolverlo en tools/skills del agente; camino 3
solo si se necesita control total; camino 4 como último recurso o vía PR
upstream.

## Lagunas y no confirmado

1. **Ban rate**: no existe métrica pública de probabilidad de suspensión con
   wacli/whatsmeow/Baileys; solo reportes anecdoticos (whatsmeow #810, Reddit).
2. **`wacli groups participants list --json`**: no confirmado si incluye el
   campo de rol admin (verificar empíricamente).
3. **`openclaw directory groups` para WhatsApp**: no confirmado si el listado
   live incluye roles o solo JID/nombre.
4. **Instalaciones `git:` del plugin WhatsApp**: no confirmado si comparten la
   restricción de "confianza de canal" (ingress queue) de `--link` (#151795).
5. **Wrapper MCP sobre wacli + `openclaw mcp add`**: patrón plausible según las
   docs, pero no hay ejemplo oficial (wacli declara MCP server fuera de su
   alcance).
6. **Límite exacto de slots vinculados usados**: se asume 4 companion devices
   (FAQ oficial); no se ha verificado el comportamiento de WhatsApp al
   superarlo en 2026.
7. El patch documentado en #7476 usa rutas `dist/web/...` (layout antiguo);
   las rutas actuales son `extensions/whatsapp/src/inbound/send-api.ts`,
   `extensions/whatsapp/src/inbound/types.ts`, `extensions/whatsapp/src/send.ts`,
   `extensions/whatsapp/src/channel-actions.ts` (según revisión Codex del
   issue, commit `ef58307f843e`).

## Referencias

- Docs OpenClaw (índice): https://docs.openclaw.ai/llms.txt
- Tool plugins (`defineToolPlugin`): https://docs.openclaw.ai/plugins/tool-plugins
- Connect MCP servers: https://docs.openclaw.ai/tools/mcp
- Skills: https://docs.openclaw.ai/tools/skills · Crear skills: https://docs.openclaw.ai/tools/creating-skills
- Exec tool: https://docs.openclaw.ai/tools/exec
- Tools invoke HTTP API: https://docs.openclaw.ai/gateway/tools-invoke-http-api
- CLI `openclaw message`: https://docs.openclaw.ai/cli/message
- CLI `openclaw directory`: https://docs.openclaw.ai/cli/directory
- CLI `openclaw plugins` (install): https://docs.openclaw.ai/cli/plugins/install
- CLI `openclaw plugins` (uninstall/update/reload): https://docs.openclaw.ai/cli/plugins/uninstall-and-update
- Plugin dependency resolution: https://docs.openclaw.ai/plugins/dependency-resolution
- Channel surfaces (plugins): https://docs.openclaw.ai/plugins/architecture-internals/channel-surfaces
- Canal WhatsApp: https://docs.openclaw.ai/channels/whatsapp
- Grupos (multi-canal): https://docs.openclaw.ai/channels/groups
- wacli: https://wacli.sh · https://github.com/openclaw/wacli
  - groups: https://wacli.sh/groups.html
  - send (stickers): https://wacli.sh/send.html
  - auth: https://wacli.sh/auth.html
- Issue #7476 (WhatsApp sticker send): https://github.com/openclaw/openclaw/issues/7476
- Issue #144695 (participant info/add/remove — cerrado not planned): https://github.com/openclaw/openclaw/issues/144695
- Issue #151795 (instalaciones --link no confiables → canal bloqueado): https://github.com/openclaw/openclaw/issues/151795
- PR #7502 (sticker send, cerrado sin mergear): https://github.com/openclaw/openclaw/pull/7502
- PR #89033 (group create/add/invite tools, cerrado sin mergear): https://github.com/openclaw/openclaw/pull/89033
- WhatsApp Multi-Device FAQ: https://faq.whatsapp.com/378279804439436
- Meta engineering — multi-device: https://engineering.fb.com/2021/07/14/security/whatsapp-multi-device/
- whatsmeow #810 (avisos "account may be at risk", Baileys incluido): https://github.com/tulir/whatsmeow/issues/810
- Adding capabilities (contributor guide): https://docs.openclaw.ai/plugins/adding-capabilities
- Community plugins: https://docs.openclaw.ai/plugins/community
