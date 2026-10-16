# RESEARCH-003: Proveedor LLM gratuito para el bot (OpenRouter free vs Ollama local vs híbrido)

| Campo | Valor |
| --- | --- |
| **ID** | RESEARCH-003 |
| **Fecha** | 2026-10-16 |
| **Ref. Issue** | ISSUE-001 |
| **Estado** | Completada |

## Contexto

El bot autoalojado (Docker Compose) necesita un LLM **gratuito** para el agente
OpenClaw, que usa tools intensivamente: las 3 skills del repo (`yt-dlp`,
`ffmpeg`/media, `wacli`) dependen de que el modelo ejecute llamadas a tool
(`exec`) de forma fiable. El criterio crítico es, por tanto, **tool-calling**,
no calidad conversacional.

Se investigan 6 puntos sobre dos candidatos (OpenRouter free tier y Ollama
local) más la opción híbrida. Fuentes: documentación de OpenClaw
(`docs.openclaw.ai`), documentación de OpenRouter (`openrouter.ai/docs`),
documentación de Ollama (`docs.ollama.com`, `ollama.com`) y consulta directa
del catálogo público de OpenRouter (`/api/v1/models`, 2026-10-16).

---

## 1. Soporte de OpenRouter en OpenClaw

**Veredicto: SOPORTADO Y OFICIAL** (plugin incluido de serie: `openrouter`).

| Aspecto | Valor verificado | Fuente |
| --- | --- | --- |
| Nombre del provider | `openrouter` | [Official provider plugins](https://docs.openclaw.ai/concepts/model-providers/official-provider-plugins) |
| Env var de key | `OPENROUTER_API_KEY` (o sign-in OpenRouter OAuth) | [Official provider plugins](https://docs.openclaw.ai/concepts/model-providers/official-provider-plugins) · [OpenRouter](https://docs.openclaw.ai/providers/openrouter) |
| Formato de modelo | `openrouter/<provider>/<model>` (3 segmentos: se parte en el **primer** `/`, el resto es el id de OpenRouter) | [OpenRouter](https://docs.openclaw.ai/providers/openrouter) · [Models CLI](https://docs.openclaw.ai/cli/models) |
| Modelo por defecto si solo hay key | **`openrouter/auto`** (onboarding API-key y OAuth arrancan aquí) | [OpenRouter](https://docs.openclaw.ai/providers/openrouter) |
| Listado del catálogo | `openclaw models list --provider openrouter [--refresh]` | [Models CLI](https://docs.openclaw.ai/cli/models) |

### 1.1 `openclaw models search` NO existe

La referencia CLI de `openclaw models` solo declara estos subcomandos:
`status`, `list`, `refresh`, `set`, `set-image`, `scan`, `aliases`,
`fallbacks`, `accounts`, `auth` ([Models CLI](https://docs.openclaw.ai/cli/models)).
No hay subcomando `search`. Equivalentes:

```bash
openclaw models list --provider openrouter --refresh   # catálogo real del proveedor
openclaw models list --all --json                      # catálogo publicado completo
openclaw models scan                                   # ¡específico: ranking de modelos ':free'! (ver §2)
openclaw docs search "openrouter"                      # búsqueda solo en la documentación
```

### 1.2 Config en `openclaw.json`

Ejemplo oficial ([OpenRouter](https://docs.openclaw.ai/providers/openrouter)):

```json5
{
  env: { vars: { OPENROUTER_API_KEY: "sk-or-..." } },
  agents: {
    defaults: {
      model: { primary: "openrouter/auto" },
    },
  },
}
```

Aplicado a este repo (hoy `config/openclaw.json` inyecta solo
`OPENAI_API_KEY`/`ANTHROPIC_API_KEY` desde `${LLM_API_KEY}`):

- Opción A (recomendada, sin tocar config): definir `OPENROUTER_API_KEY=sk-or-...`
  en `.env` → el `env_file` del `docker-compose.yml` lo expone al contenedor y
  OpenClaw lo toma como auth del proveedor.
- Opción B: añadir en el bloque `env.vars` de `config/openclaw.json`:
  `"OPENROUTER_API_KEY": "${OPENROUTER_API_KEY}"`.

### 1.3 Tool-calling en OpenRouter desde OpenClaw

> "Discovered models use OpenRouter's advertised tool support. When a model's
> `supported_parameters` list omits `tools`, OpenClaw sends requests without
> tool definitions or tool choice."
> — [OpenRouter (OpenClaw)](https://docs.openclaw.ai/providers/openrouter)

Es decir: **OpenClaw confía en el metadato `supported_parameters` de OpenRouter**.
Si un modelo `:free` no declara `tools`, OpenClaw ni siquiera envía las tools →
el agente queda inútil. Por eso el filtro `tools` (§2) es el criterio duro.

Otras peculiaridades relevantes ([Official provider plugins — quirks](https://docs.openclaw.ai/concepts/model-providers/official-provider-plugins),
[Model failover](https://docs.openclaw.ai/concepts/model-failover)):

- OpenRouter declara `managesOwnAvailability: true`: OpenClaw **no** aplica
  cooldowns propios de rate-limit/overload a este proveedor (lo gestiona el upstream).
- Errores tipo `OpenRouter 403 Key limit exceeded` entran en el bucket de billing.
- Headers de atribución (`HTTP-Referer`, `X-OpenRouter-Title`, …) solo se inyectan
  en rutas verificadas `openrouter.ai`.

---

## 2. Modelos gratuitos de OpenRouter (`:free`)

**Veredicto: EL CATÁLOGO `:free` HA CAMBIADO POR COMPLETO (oct-2026). Los
modelos clásicos citados en el issue YA NO EXISTEN como `:free`.**

### 2.1 Lista real a 2026-10-16 (consulta directa a `https://openrouter.ai/api/v1/models`)

- Total de entradas `:free`: **15**; de ellas, **14 declaran `tools`**
  (la única sin tools: `nvidia/nemotron-3.5-content-safety:free`).
- **NO encontrados** (sonados en el issue): `meta-llama/llama-3.3-70b-instruct:free`,
  `qwen/qwen3-235b-a22b:free`, `deepseek/deepseek-chat-v3-0324:free`,
  `google/gemini-2.5-flash:free` → `found: false` en el catálogo.

Candidatos `:free` con `tools` y contexto amplio (recomendados 3-5, todos con
precio `prompt: "0"`, `completion: "0"`):

| Modelo (ref para OpenClaw) | Contexto | Notas |
| --- | --- | --- |
| `openrouter/nvidia/nemotron-3-super-120b-a12b:free` | 262K | 120B MoE, gama alta, buen perfil agentic/tools |
| `openrouter/nvidia/nemotron-3.5-lightning:free` | 1M | rápido, 1M ctx, tools |
| `openrouter/google/gemma-4-31b-it:free` (y `gemma-4-26b-a4b-it:free`) | 262K | vision + tools; familia que OpenClaw recomienda en local |
| `openrouter/cohere/north-mini-code:free` | 256K | orientado a código/tools |
| `openrouter/thinkingmachines/inkling:free` | 1M | multimodal (texto/imagen/audio) |
| `openrouter/poolside/laguna-s-2.1:free` | 262K | orientado a código |
| `openrouter/nvidia/nemotron-3-ultra-550b-a55b:free` | 1M | 550B MoE (el más capaz de la lista) |

Alternativa "todo en uno": **`openrouter/free`** — Free Models Router de
OpenRouter, selecciona **aleatoriamente** un modelo gratis por petición
filtrando por capacidades necesarias (incluye *tool calling*): ver
[Free Models Router](https://openrouter.ai/docs/cookbook/get-started/free-models-router-playground).
Existe y declara `tools: true` en el catálogo. Traducción a ref OpenClaw:
`openrouter/free`.

> ⚠️ `openrouter/auto` (el default del onboarding) **NO** es el router gratis:
> es el enrutado automático general de OpenRouter (modelos de pago incluidos).
> Para uso gratuito explícito usar `openrouter/free` o ids `:free`.

### 2.2 Límites reales del free tier con API key

Fuente: [OpenRouter Limits](https://openrouter.ai/docs/api-reference/limits) y
[OpenRouter FAQ](https://openrouter.ai/docs/faq) (constantes publicadas en la doc):

| Límite | Valor |
| --- | --- |
| Requests/minuto (modelos `:free`) | **20 RPM** (igual con o sin créditos) |
| Requests/día **sin** créditos comprados | **50/día** (global, todos los `:free` sumados) |
| Requests/día con ≥ ~$10 de créditos comprados | **1.000/día** |
| Tokens/día | **No documentado** (solo se documentan req/min y req/día; protección adicional = DDoS de Cloudflare) |
| Varias API keys / varias cuentas | **NO aumentan límites**: "we govern capacity globally" ([Limits](https://openrouter.ai/docs/api-reference/limits)) |
| Ventana diaria | Día **UTC** (`free_model_daily_requests` en `GET /api/v1/key`) |

Comprobación de cuota restante:

```bash
curl -s https://openrouter.ai/api/v1/key -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  | jq '.data.free_model_daily_requests'
```

### 2.3 ¿Round-robin entre modelos gratis? — NO nativo en ninguno de los dos

**OpenRouter NO ofrece round-robin.** Ofrece, como máximo (todas con fuente):

1. **`openrouter/free`**: selección **aleatoria** de un modelo gratis por
   petición con filtro de capacidades (lo más parecido a rotación; la cuota
   diaria sigue siendo global). [Free Models Router](https://openrouter.ai/docs/cookbook/get-started/free-models-router-playground)
2. **Fallback entre proveedores del mismo modelo** automático si un proveedor
   falla. [FAQ](https://openrouter.ai/docs/faq)
3. **Fallback entre modelos** con el parámetro `models: [...]` de la API
   (ante errores: rate-limit, downtime, moderación, contexto). Se envía desde
   el cliente; OpenClaw **no lo documenta** como opción propia (posible
   pass-through vía `params.extraBody`, ver Lagunas).
   [Model Fallbacks](https://openrouter.ai/docs/guides/routing/model-fallbacks)
4. Variantes de enrutado: `:nitro` (throughput), `:floor` (precio) y
   **`:exacto`** (*quality-first signals tuned for tool-calling reliability*).
   [FAQ — model variants](https://openrouter.ai/docs/faq)

**OpenClaw NO hace round-robin entre modelos.** Ofrece:

1. **Fallback ordenado** `agents.defaults.model.fallbacks`: avanza de modelo
   **solo ante errores** (rate-limit, billing, 404, timeout, overflow…), nunca
   por balanceo. "OpenClaw fallbacks switch models per turn on provider errors."
   [Local models](https://docs.openclaw.ai/gateway/local-models) ·
   [Model failover](https://docs.openclaw.ai/concepts/model-failover)
2. **Rotación round-robin de perfiles de auth** (varias keys del mismo
   proveedor) — pero en OpenRouter **no sube la cuota** (límite global de
   plataforma) y solo hay un perfil `openrouter:default` por defecto.
   [Model failover](https://docs.openclaw.ai/concepts/model-failover)
3. **`openclaw models scan`**: lee el catálogo público `:free` de OpenRouter,
   hace sonda de soporte de tools/imagen y **reescribe
   `agents.defaults.model.fallbacks`** con los candidatos rankeados
   (con key: sonda real + `--set-default` opcional; sin key:
   `--no-probe` solo metadata).
   [Models CLI — scan](https://docs.openclaw.ai/cli/models)

**Conclusión (veredicto explícito): round-robin NO nativo en OpenRouter ni en
OpenClaw.** Alternativas reales: (a) `openrouter/free` (aleatorio por request,
cuota global igual), (b) fallback ordenado con `openclaw models scan` /
`models fallbacks add`, (c) fallback al `primary` tras agotar la cadena.
**Rotar keys en `.env` NO sirve** (la cuota es global de plataforma).

---

## 3. Soporte de Ollama en OpenClaw

**Veredicto: SOPORTADO Y OFICIAL (plugin incluido de serie: `ollama`), con
tool-calling FIABLE solo si se usa la API nativa.**

### 3.1 Provider y config exacta

| Aspecto | Valor verificado | Fuente |
| --- | --- | --- |
| Provider id | `ollama` (variante cloud: `ollama-cloud`) | [Ollama (OpenClaw)](https://docs.openclaw.ai/providers/ollama) |
| Base URL | `baseUrl: "http://host:11434"` — **SIN `/v1`** (`baseURL` aceptado por compat, pero usar `baseUrl`) | [Ollama configuration](https://docs.openclaw.ai/providers/ollama/configuration) |
| API | `api: "ollama"` (explícito → "guarantees native tool-calling behavior") | [Ollama configuration](https://docs.openclaw.ai/providers/ollama/configuration) |
| Formato de modelo | `ollama/<modelo>`, p. ej. `ollama/qwen3:32b`, `ollama/gemma4` | [Ollama setup](https://docs.openclaw.ai/providers/ollama/setup) |
| Auth (host local/LAN) | `OLLAMA_API_KEY="ollama-local"` (marker; hosts loopback/privados/.local no necesitan key real) | [Ollama setup](https://docs.openclaw.ai/providers/ollama/setup) |

```json5
{
  models: {
    providers: {
      ollama: {
        apiKey: "ollama-local",
        baseUrl: "http://host.docker.internal:11434", // No /v1 - native Ollama API URL
        api: "ollama",                                 // Explicit: guarantees native tool-calling behavior
        timeoutSeconds: 300,                           // presupuesto para modelos en frío
        models: [{ id: "qwen3:14b", name: "qwen3:14b", params: { keep_alive: "15m" } }],
      },
    },
  },
}
```

### 3.2 ¿Tool-calling? SÍ (nativo) — y advertencia crítica de OpenClaw

> **Warning**: "Do not use the `/v1` OpenAI-compatible URL
> (`http://host:11434/v1`). **It breaks tool calling** and models can emit raw
> tool-call JSON as plain text. Use the native URL: `baseUrl:
> "http://host:11434"` (no `/v1`)."
> — [Ollama (OpenClaw)](https://docs.openclaw.ai/providers/ollama)

- OpenClaw habla con la API nativa de Ollama **`/api/chat`**, no con `/v1`.
- Ollama sí expone endpoints compatibles OpenAI (`/v1/chat/completions` con
  `tools`, `/v1/responses`, `/v1/messages`) — [OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility) —
  pero **para OpenClaw están desaconsejados** por la nota anterior.
- Tool-calling documentado en Ollama (single-shot, paralelo, agent loop,
  streaming): [Tool calling — Ollama docs](https://docs.ollama.com/capabilities/tool-calling).

### 3.3 Descubrimiento de modelos (relevante para tools)

[Ollama model discovery](https://docs.openclaw.ai/providers/ollama/model-discovery) ·
[Ollama setup](https://docs.openclaw.ai/providers/ollama/setup):

- Catálogo: `/api/tags`; capacidades: `/api/show` → `contextWindow`,
  `num_ctx` y capabilities (`vision`/`tools`/`thinking`). Costes: todos `0`.
- El onboarding **solo considera automáticamente modelos cargados en memoria**
  (`/api/ps`) **con tool support y ≥16K de contexto**; si no hay ninguno,
  propone tirar un modelo recomendado (`gemma4`).
- Verificación: `openclaw models list --provider ollama`.
- Modelos locales Ollama usan **Tool Search estructurado automáticamente**
  (reduce la presión de schemas de tools en modelos pequeños)
  — [Local models](https://docs.openclaw.ai/gateway/local-models).

### 3.4 Networking desde el contenedor Docker al Ollama del host

Fuente principal: [Docker networking, providers, and storage](https://docs.openclaw.ai/install/docker/networking-and-storage)
+ práctica oficial de Ollama ([Docker](https://docs.ollama.com/docker), [FAQ](https://docs.ollama.com/faq)).

Dentro del contenedor `127.0.0.1` **es el contenedor**, no el host. Tres vías:

**Opción A (recomendada por OpenClaw): `host.docker.internal` + `host-gateway`**

```yaml
# docker-compose.yml — añadir a openclaw-gateway y openclaw-cli
services:
  openclaw-gateway:
    extra_hosts:
      - "host.docker.internal:host-gateway"   # necesario en Docker Engine Linux
```

```json5
// config/openclaw.json
"baseUrl": "http://host.docker.internal:11434"
```

Y Ollama en el host debe escuchar en todas las interfaces:

```bash
OLLAMA_HOST=0.0.0.0:11434 ollama serve   # por defecto binda 127.0.0.1
```

(El `docker-compose.yml` oficial de OpenClaw ya mapea ese alias; **el compose de
este repo NO lo tiene** → hay que añadirlo. Fuente: OpenClaw Docker networking.)

**Opción B: IP LAN del host** — igual que A pero `baseUrl: "http://<IP-lan-host>:11434"`
(Ollama en `0.0.0.0`); el firewall debe permitir el puerto en la red local.
Válido porque OpenClaw acepta hosts privados/LAN con el marker `ollama-local`.

**Opción C: `network_mode: host` del gateway** (solo Linux) — el contenedor ve
`127.0.0.1:11434` del host directamente. Cambia el mapa de puertos/publicación.

**Opción D: Ollama como servicio en el MISMO compose** — `baseUrl: "http://ollama:11434"`
(nombre de servicio en la red del compose), imagen oficial `ollama/ollama`
(`-p 11434:11434`; la imagen ya arranca con `OLLAMA_HOST=0.0.0.0:11434`).

---

## 4. Modelos locales recomendables para tools (gama media)

**Veredicto: hay opciones sólidas en 8B–32B, pero el requisito duro de OpenClaw
es "tools + ≥16K ctx" y validar con tareas reales.**

### 4.1 Requisitos que la doc de OpenClaw sí dice

- Onboarding/descubrimiento Ollama: modelo **con soporte de tools** y
  **≥16K de contexto** (favorito: no-reasoning y luego los más pequeños;
  sugerencia automática: `gemma4`).
  [Ollama setup](https://docs.openclaw.ai/providers/ollama/setup)
- "For custom servers, leave room for the full OpenClaw prompt, tools, history,
  and model output. **A model that loads or answers a short prompt may still
  fail an agent turn. Test actual tasks before making it your default.**"
  [Local models](https://docs.openclaw.ai/gateway/local-models)
- Suelo de hardware de los recipes gestionados de OpenClaw (llama.cpp, 64K ctx):
  **8 GiB de memoria mínima**; recipes mayores necesitan más.
  [Local models](https://docs.openclaw.ai/gateway/local-models)
- No existe en la doc de OpenClaw un **mínimo de calidad numérico** (p. ej. N
  parámetros) para agentes con tools; el requisito explícito es técnico
  (tools + contexto) + verificación empírica (ver Lagunas).
- Ollama recomienda **≥32K de contexto** para mejorar la fiabilidad de tool
  calling: "Using a context window of 32k or higher improves the performance of
  tool calling" — [Ollama blog: streaming tool](https://www.ollama.com/blog/streaming-tool)
  (misma entrada, lista oficial de modelos con tools: **Qwen3, Devstral,
  Qwen2.5/Qwen2.5-coder, Llama 3.1, Llama 4**).

### 4.2 Opciones (tamaños verificados en `ollama.com/library/<modelo>` el 2026-10-16)

RAM ≈ tamaño de descarga + overhead de KV cache/ctx (aumenta con el contexto):

| Modelo (ref OpenClaw) | Descarga | RAM aprox. | Uso |
| --- | --- | --- | --- |
| `ollama/llama3.1:8b` | 4,9 GB | ~8 GB | tools desde 8B; mínimo aceptable |
| `ollama/qwen3:8b` | 5,2 GB | ~8 GB | tools; buen balance 8B |
| `ollama/gemma4:12b` | 7,7 GB | ~12 GB | tools + vision; familia recomendada por OpenClaw |
| `ollama/qwen3:14b` | 9,3 GB | ~16 GB | **recomendado gama media** para agent loop |
| `ollama/devstral:24b` | 14 GB | ~24 GB | agentic (Mistral), orientado a tools/agentes |
| `ollama/qwen3-coder:30b` | 19 GB | ~32 GB | coding/tools, gama media-alta |
| `ollama/qwen3:32b` | 20 GB | ~32 GB | (ref usada en ejemplos de config de OpenClaw) |
| `ollama/gemma4:26b` | 16 GB | ~24 GB | vision + tools, alternativa grande |
| `ollama/llama3.1:70b` | 43 GB | ~48 GB | fuera de gama media (solo si hay RAM) |

**Evitar** (sin tool-calling): `gemma3` (solo vision), `llama3` original,
`llama3.2-vision`, `qwen2.5vl`, `deepseek-r1` distills pequeños — fuente
secundaria [betterclaw.io (2026-08-18)](https://www.betterclaw.io/blog/ollama-models-tool-calling-support);
la lista oficial de tools de Ollama empieza en **Llama 3.1+**
([blog](https://www.ollama.com/blog/tool-support), [streaming-tool](https://www.ollama.com/blog/streaming-tool)).
En la práctica, OpenClaw **filtra automáticamente** modelos sin capability
`tools` en la descubrimiento/onboarding, así que un `gemma3` nunca llega a
selecciónarse como modelo de agente.

Verificación de capabilities de un modelo concreto:

```bash
ollama show qwen3:14b | grep -A3 Capabilities   # debe aparecer "tools"
```

### 4.3 Verificación de tool-calling real (recomendado antes de fijarlo)

```bash
# 1) Smoke estrecho sin tools ni contexto de agente
ollama pull qwen3:14b
OLLAMA_API_KEY=ollama-local openclaw infer model run --local \
  --model ollama/qwen3:14b --prompt "Reply with exactly: pong" --json

# 2) Ruta del Gateway (sin transcript/tools)
OLLAMA_API_KEY=ollama-local openclaw infer model run --gateway \
  --model ollama/qwen3:14b --prompt "Reply with exactly: pong" --json

# 3) Turno real del agente con tools (la prueba que importa)
openclaw agent --agent bot --model ollama/qwen3:14b \
  --message "Ejecuta: echo hola"
```

(1) y (2) de [Ollama model discovery](https://docs.openclaw.ai/providers/ollama/model-discovery) /
[Local models](https://docs.openclaw.ai/gateway/local-models); si (1)-(2) pasan y
el turno real falla con tool calls malformados → problema de capacidad del
modelo, no del endpoint (mismo diagnóstico de la doc).

---

## 5. Config híbrida / por defecto

**Veredicto: SÍ se pueden definir varios providers a la vez y SÍ hay fallback
cruzado OpenRouter ↔ Ollama; NO hay fallback automático "por cuota" ni
round-robin.**

### 5.1 Varios providers simultáneos + `openclaw models set`

- Sí. `models.providers` convive con plugins oficiales; mantener
  `models.mode: "merge"` para que los modelos hosted sigan disponibles como
  fallback ([Local models](https://docs.openclaw.ai/gateway/local-models)).
- `openclaw models set <provider/model>` escribe `agents.defaults.model.primary`
  y funciona con cualquier provider instalado; `openclaw models fallbacks
  list|add|remove|clear` gestiona la cadena
  ([Models CLI](https://docs.openclaw.ai/cli/models)).

### 5.2 `agents.defaults.model` como lista ordenada con fallback

`model` acepta string (`"provider/model"`) u objeto `{ primary, fallbacks }`
(fallback **cruzado entre proveedores**: "configured fallbacks are tried […]
even if the requested model uses a different provider")
— [Configuration — agent models](https://docs.openclaw.ai/gateway/config-agents/models) ·
[Model failover](https://docs.openclaw.ai/concepts/model-failover).

Ejemplo híbrido oficial (hosted primary + local fallback)
— [Local models](https://docs.openclaw.ai/gateway/local-models):

```json5
{
  agents: {
    defaults: {
      model: {
        primary: "openrouter/nvidia/nemotron-3-super-120b-a12b:free",
        fallbacks: ["ollama/qwen3:14b"],
      },
    },
  },
}
```

"Inverso" (local primary, hosted safety net): basta intercambiar `primary` y
`fallbacks`.

### 5.3 ⚠️ Atención con `agents.entries.bot.model` (la config ACTUAL del repo)

`config/openclaw.json` hoy fija `"model": "${LLM_MODEL}"` (forma string) en
`agents.entries.bot.model`. Según [Model failover](https://docs.openclaw.ai/concepts/model-failover):

> "Native agent primary: `agents.entries.*.model` is **strict unless that
> agent's model object includes its own `fallbacks`**."

Es decir, **el bot NO usará `agents.defaults.model.fallbacks` mientras su
`model` sea una string**. Hay que convertirlo a objeto (en ISSUE-001/PLAN,
validando que `${LLM_MODEL}` sustituye dentro del objeto — el repo ya
documentó que ciertos campos no admiten sustitución):

```json5
"agents": {
  "entries": {
    "bot": {
      "model": {
        "primary": "${LLM_MODEL}",
        "fallbacks": ["ollama/qwen3:14b"]
      }
    }
  }
}
```

### 5.4 Semántica exacta del fallback (lo que SÍ y lo que NO hace)

- Avanza **solo ante errores**: rate-limit (hasta 10 reintentos con backoff
  antes de rotar), billing (deshabilita el perfil 10 min), auth, `model_not_found`,
  timeout, overflow… [Model failover](https://docs.openclaw.ai/concepts/model-failover)
- El fallback es **turn-local**: la respuesta sale del fallback pero **la
  selección de sesión no cambia**; el siguiente turno vuelve al `primary`.
- **No balancea** (no es round-robin ni load-balancing): si el `primary`
  responde, siempre responde él.
- Las **selecciones explícitas de usuario** (`/model ...`) son **estrictas**:
  sin fallback.
- `openclaw models scan` puede rellenar `agents.defaults.model.fallbacks`
  automáticamente con candidatos `:free` (ver §2.3).

---

## 6. Coste / cuota

**Veredicto: 0 € en ambos; el riesgo no es el coste, es la CUOTA DIARIA de
OpenRouter (50 req/día globales) para un agente con tools.**

| | OpenRouter free | Ollama local |
| --- | --- | --- |
| Coste por token | **0** (precio `prompt/completion = "0"` en el catálogo `:free`) | **0** |
| Cuenta / key | Alta y API key **sin comprar créditos**; los créditos son **opcionales** (solo suben el techo: 50 → 1.000 req/día) — [FAQ](https://openrouter.ai/docs/faq) | Sin cuenta |
| Tarjeta | No hace falta cargar créditos para usar `:free`; el pago es opcional (top-up ≥ ~$10 para subir a 1.000 req/día) | Sin tarjeta |
| Coste indirecto | — | Electricidad + hardware/RAM; sin GPU la inferencia 14B+ será lenta |
| ¿Qué pasa al agotar la cuota diaria? | OpenRouter devuelve **429** (`rate_limit_exceeded`, ventana UTC). OpenClaw: hasta 10 reintentos con backoff → rotación de perfil → **siguiente modelo de `agents.*.model.fallbacks`** → si la cadena se agota: **error terminal visible** (el bot responde con el fallo, sin respuesta útil). **Clave: el límite de 50/1.000 req/día es GLOBAL para todos los `:free`**, cambiar a otro modelo `:free` NO ayuda; solo (a) esperar al 00:00 UTC, (b) fallback a **otro proveedor** (Ollama), o (c) subir a paid tier / comprar créditos. [Limits](https://openrouter.ai/docs/api-reference/limits) · [Model failover](https://docs.openclaw.ai/concepts/model-failover) | Sin cuota; agotamiento = RAM/tiempo de respuesta, no 429 |

Nota operativa: **cada petición al LLM consume cuota**, y un turno de agente con
un bucle de 5 tool calls puede superar 1 request → 50 req/día se agotan muy
rápido en uso real con skills. Un modelo local fallback es lo único que mantiene
el bot vivo tras agotar la cuota.

---

## Tabla comparativa final

| Criterio | OpenRouter free (`:free` / `openrouter/free`) | Ollama local | **Híbrido (recomendado)** |
| --- | --- | --- | --- |
| **Coste** | 0 € (tarjeta no obligatoria; top-up opcional $10 → 1.000 req/día) | 0 € (hardware + electricidad) | 0 € |
| **Tool-calling** | Sí, si el modelo declara `tools` (14/15 `:free` hoy); OpenClaw omite tools si no lo declara | Sí y fiable **solo con API nativa** `/api/chat` (`api:"ollama"`, sin `/v1`) | El mejor de los dos por turno; el fallback salva los modos rotos |
| **Límites duros** | **20 req/min · 50 req/día global** (1.000 con créditos) · sin tokens/día documentado · keys extra no suman | Sin cuotas; RAM/velocidad; arranque en frío (`timeoutSeconds`) | Cuota OpenRouter + capacidad local ilimitada |
| **Balanceo/rotación** | Round-robin NO; `openrouter/free` = aleatorio por request; fallback de modelos vía API `models[]` (no documentado en OpenClaw) | No aplica | Fallback ordenado en OpenClaw (solo ante errores, turn-local); round-robin NO |
| **Complejidad** | Baja: 1 key + `env.vars` + `models set` | Media: daemon Ollama, `OLLAMA_HOST=0.0.0.0`, `extra_hosts: host-gateway`, pull de modelos, RAM | Media-alta: ambas configs + `agents.entries.bot.model` en objeto con `fallbacks` |
| **Requisitos** | Cuenta OpenRouter + red saliente | Host encendido, ≥16 GB RAM (para 14B), ~12-32 GB de disco de modelos | Ambos |
| **Fiabilidad 24/7 del bot** | Limitada por cuota diaria (50/día) | Limitada por el host | **Alta** (si se agota la cuota, contesta el local) |
| **Privacidad** | Prompts salen hacia OpenRouter/proveedores | Todo local | El tráfico `:free` sale; el fallback no |

---

## Lagunas / a verificar

1. **Ejecución empírica pendiente**: no se ha ejecutado ninguna llamada real
   (falta `OPENROUTER_API_KEY` y hardware local); validar con las 3 skills
   (`yt-dlp`, `ffmpeg`, `wacli`) un turno real por cada candidato (§4.3).
2. **`openclaw models scan` con sonda real** (`--set-default`) sin probar aquí;
   además escribe `agents.defaults.model.fallbacks` (defaults), mientras el bot
   usa `agents.entries.bot.model` → habrá que reflejar la cadena en la entry (§5.3).
3. **Sustitución `${LLM_MODEL}` dentro de un objeto** `model: {primary, fallbacks}`
   en `config/openclaw.json` no está confirmada en la doc (el repo ya sufrió
   excepciones de sustitución en campos `integer`). Validar con `openclaw config validate`.
4. **Pass-through de OpenRouter `models[]`** (fallback upstream) vía
   `agents.defaults.models[...].params.extraBody` es una **hipótesis** de
   pass-through; no documentado para OpenClaw → no contar con ello.
5. **Combinación `:free` + `:exacto`** (ordenación por fiabilidad de
   tool-calling) no verificada; `:exacto` es variante de enrutado "para todo
   modelo" según la FAQ, pero su apilado con `:free` no está probado.
6. **`openrouter/auto` sin créditos**: la doc confirma que `auto` es el
   enrutado general (no el gratis); el comportamiento exacto de `auto` con
   saldo 0 (¿402 en rutas de pago?) **no está confirmado** → usar
   `openrouter/free` o `:free` explícitos.
7. **No existe mínimo de calidad numérico** en la doc de OpenClaw para agentes
   con tools (solo tools + ≥16K ctx + "test actual tasks"); si aparece una
   matriz de modelos recomendados, actualizar este informe.
8. **Catálogo `:free` vivo**: la lista del §2.1 es una foto del 2026-10-16 y
   cambia a menudo (los modelos del issue ya no existen) → re-ejecutar
   `openclaw models scan` periódicamente.
9. **Coste eléctrico/VRAM de Ollama** no cuantificado (depende del host final).

---

## Referencias

### OpenClaw
- https://docs.openclaw.ai/concepts/model-providers/official-provider-plugins — provider `openrouter`, `OPENROUTER_API_KEY`, quirks
- https://docs.openclaw.ai/providers/openrouter — config, `openrouter/auto`, refs `openrouter/<provider>/<model>`, tool support
- https://docs.openclaw.ai/providers/ollama — índice Ollama, warning `/v1` rompe tool calling
- https://docs.openclaw.ai/providers/ollama/configuration — `baseUrl` sin `/v1`, `api: "ollama"`, ejemplo `qwen3:32b`
- https://docs.openclaw.ai/providers/ollama/setup — auth `ollama-local`, onboarding (tools + ≥16K), `gemma4`
- https://docs.openclaw.ai/providers/ollama/model-discovery — `/api/tags`, `/api/show`, costs 0, smoke tests
- https://docs.openclaw.ai/cli/models — subcomandos, `models scan` (`:free`), `models set`, `models fallbacks`
- https://docs.openclaw.ai/concepts/model-failover — cadena de fallback, selecciones estrictas, rotación de perfiles
- https://docs.openclaw.ai/gateway/config-agents/models — `agents.defaults.model {primary, fallbacks}`, `models`, `modelPolicy`
- https://docs.openclaw.ai/gateway/local-models — config híbrida hosted+local, `models.mode: "merge"`, hardware floor, diagnóstico
- https://docs.openclaw.ai/install/docker/networking-and-storage — `host.docker.internal`, `host-gateway`, Ollama en host
- https://docs.openclaw.ai/concepts/model-providers/quick-rules — model refs `provider/model`, `models set`

### OpenRouter
- https://openrouter.ai/docs/api-reference/limits — 20 RPM, 50/1.000 RPD, `free_model_daily_requests`, keys no suman
- https://openrouter.ai/docs/faq — free tier, `openrouter/free`, fallback de proveedores, variantes (`:free`, `:exacto`)
- https://openrouter.ai/docs/guides/routing/model-fallbacks — parámetro `models[]`
- https://openrouter.ai/docs/cookbook/get-started/free-models-router-playground — Free Models Router
- https://openrouter.ai/docs/guides/routing/model-variants/free — variante `:free`
- https://openrouter.ai/api/v1/models — catálogo público consultado el 2026-10-16 (15 `:free`, 14 con tools)

### Ollama
- https://docs.ollama.com/capabilities/tool-calling — tool calling (single, paralelo, agent loop, streaming)
- https://docs.ollama.com/api/openai-compatibility — endpoints OpenAI-compatibles
- https://docs.ollama.com/docker — imagen oficial, `-p 11434:11434`
- https://docs.ollama.com/faq — `OLLAMA_HOST=0.0.0.0:11434` (bind por defecto 127.0.0.1)
- https://www.ollama.com/blog/streaming-tool — modelos con tools (Qwen3, Devstral, Qwen2.5, Llama 3.1+), ≥32K ctx recomendado
- https://ollama.com/blog/tool-support — lista original de modelos con tools
- https://ollama.com/library/{qwen3,llama3.1,gemma4,devstral,qwen3-coder} — tamaños de descarga (2026-10-16)
- https://ollama.com/search?tags=tools — 99 modelos con capability `tools`

### Secundarias
- https://www.betterclaw.io/blog/ollama-models-tool-calling-support — tabla de compatibilidad de tools (tercero, 2026-08-18)

---

*Última actualización: 2026-10-16*
