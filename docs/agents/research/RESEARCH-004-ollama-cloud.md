# RESEARCH-004: Ollama Cloud como proveedor LLM para el bot

| Campo | Valor |
| --- | --- |
| **ID** | RESEARCH-004 |
| **Fecha** | 2026-10-16 |
| **Ref. Issue** | ISSUE-001 |
| **Estado** | Completada |

## Contexto

RESEARCH-003 (ya en el repo) comparó OpenRouter free vs Ollama local y concluyó
con una config híbrida recomendada. Este informe investiga un tercer candidato:
**Ollama Cloud** (ollama.com), el servicio cloud gestionado de Ollama, respondiendo
a 5 puntos: (1) existencia y modelos/límites gratuitos, (2) API y tool-calling,
(3) compatibilidad con el plugin `ollama`/`ollama-cloud` de OpenClaw con configs
exactas, (4) comparación de cuota vs OpenRouter (50 req/día), y (5) candidatos
gratuitos con tools. El requisito duro sigue siendo el de RESEARCH-003:
**tool-calling fiable** para las skills `yt-dlp`, `ffmpeg` y `wacli` (bash).

Fuentes: `ollama.com/blog`, `ollama.com/pricing`, `docs.ollama.com` y
`docs.openclaw.ai` (consultadas el 2026-10-16). Lo que no se pudo confirmar en
fuente primaria queda marcado explícitamente como **NO PUBLICADO / NO
CONFIRMADO** en Lagunas.

---

## 1. Ollama Cloud (2026): servicio, plan gratuito y límites

**Veredicto: EL SERVICIO EXISTE y es usable sin tarjeta; el plan Free es
gratuito con "starter credits" de importe NO PUBLICADO y sobre una lista de
modelos "starter" NO PUBLICADA.**

### 1.1 ¿Existe?

- **Sí.** Ollama Cloud se lanzó en preview el 2025-09-19
  ([Cloud models](https://ollama.com/blog/cloud-models)) y a 2026-10-16 sigue
  activo y evolucionado: catálogo público en [ollama.com/search?c=cloud](https://ollama.com/search?c=cloud)
  (**19 modelos cloud**), doc propia en [docs.ollama.com/cloud](https://docs.ollama.com/cloud),
  página comercial en [ollama.com/pricing](https://ollama.com/pricing) y
  planes rediseñados con precios por token el 2026-08-31
  ([transparent pricing](https://ollama.com/blog/transparent-pricing)).
- Ollama declara **8,9 M de desarrolladores** y financiación de $88M
  ([all aboard open models](https://ollama.com/blog/all-aboard-open-models),
  2026-07-09) → el cloud no es un experimento efímero.

### 1.2 Plan Free (0 €) — qué incluye de verdad

Según la FAQ de [ollama.com/pricing](https://ollama.com/pricing) y el blog
[transparent-pricing](https://ollama.com/blog/transparent-pricing):

| Aspecto | Valor verificado | Fuente |
| --- | --- | --- |
| Precio | **$0/mes**, sin suscripción, sin comisiones ("no service fees") | pricing (tarjeta Free) · blog 2026-08-31 |
| Tarjeta de crédito | **No obligatoria**: se puede usar sin cargar créditos; comprar créditos es opcional | pricing FAQ |
| Incluido | "Starter usage credits included" + "Includes access to **starter models**" — **importes y lista NO publicados** | pricing (tarjeta Free) · blog: "a small amount of monthly usage for a set of starter models" |
| Fuera de los starter models | Hay que **comprar créditos usage** (pay-as-you-go) para desbloquear el catálogo completo | pricing FAQ |
| Reset de cuota | **Mensual**, desde la fecha de alta (Free) | pricing FAQ |
| Roll-over | **No** (el importe se renueva, no se acumula) | pricing FAQ |
| Límites 5 h / semanales | **Eliminados**: "no service fees or no 5-hour or weekly limits" | blog 2026-08-31 |
| Concurrencia | **1 request concurrente** en Free (Pro 3, Max/Team 10); el exceso se **encola** y, si la cola está llena, se **rechaza** | pricing FAQ |
| Cuentas | "Ollama is one account per person" → **no se pueden rotar cuentas** para multiplicar cuota | pricing FAQ |
| Local | Modelos locales siempre ilimitados y gratuitos en todos los planes | pricing FAQ |

**Coste real por token en Free**: los modelos cloud **NO son 0 €/token**; el
plan Free consume los starter credits a las tarifas publicadas por millón de
tokens (p. ej. `gpt-oss:20b` $0,07 in / $0,30 out; ver §5). Consumido el
starter allowance del mes → o compras créditos o esperas al reset.

### 1.3 Límites de uso (rate limits)

| Límite | Valor | Fuente |
| --- | --- | --- |
| Requests/min (inferencia) | **NO PUBLICADO** — la doc solo documenta `429 Too Many Requests (e.g. when a rate limit is exceeded)` como posibilidad genérica | [errors](https://docs.ollama.com/api/errors) |
| Requests/día | **NO PUBLICADO** (no existe cuota diaria documentada) | — |
| Tokens/día | **NO PUBLICADO** — el modelo de cuota es **mensual en créditos $/tokens**, no diario | [pricing FAQ](https://ollama.com/pricing) |
| Concurrencia | **1 concurrente (Free)**; resto encolado; rechazo si la cola llena | pricing FAQ |
| Endpoint de monitoring `/api/usage` | **10 req/min por usuario** (compartido entre keys), con `Retry-After` en 429 | [Cloud usage](https://docs.ollama.com/api/cloud-usage) |
| Fair use documentada | Sin comisiones ni límites 5h/semanales; 1 cuenta por persona; cuota mensual con reset | blog · pricing FAQ |

**Observación para el bot**: un turno de agente con bucle de 5 tool calls
genera 1 request de inferencia *por paso* (mismo criterio que RESEARCH-003 §6);
con concurrencia 1 los pasos se serializan (van a cola, no se paralelizan) —
latencia algo mayor pero sin agotar cuota por requests, ya que **la cuota se
gasta en tokens, no en peticiones**.

---

## 2. API de Ollama Cloud

**Veredicto: endpoint `https://ollama.com/api` con API key (`OLLAMA_API_KEY`,
Bearer); API **nativa de Ollama completa** (`/api/chat` **con `tools`**), más
compat OpenAI (`/v1`) y Anthropic (`/v1/messages`). Tool-calling confirmado.**

### 2.1 Endpoint y autenticación

| Aspecto | Valor verificado | Fuente |
| --- | --- | --- |
| Endpoint nativo | **`https://ollama.com/api`** (`/api/chat`, `/api/tags`, `/api/generate`, …) | [Authentication](https://docs.ollama.com/api/authentication) · [Cloud](https://docs.ollama.com/cloud) |
| Endpoint OpenAI-compat | `https://ollama.com/v1` | [Authentication](https://docs.ollama.com/api/authentication) |
| Endpoint Anthropic-compat | `/v1/messages` (requiere `Authorization: Bearer`; **solo `x-api-key` NO vale**) | [Authentication](https://docs.ollama.com/api/authentication) |
| Autenticación | Header `Authorization: Bearer $OLLAMA_API_KEY`; key creada en [ollama.com/settings/keys](https://ollama.com/settings/keys); **no caducan** (revocables) | [Authentication](https://docs.ollama.com/api/authentication) |
| ¿Requiere instalar Ollama? | **No**: "No Ollama installation or local server is required" | [Authentication](https://docs.ollama.com/api/authentication) |
| Alternativa OAuth | `ollama signin` (CLI/app) — pensada para enrutar vía daemon local; **no necesaria** para acceso directo API | [Authentication](https://docs.ollama.com/api/authentication) |
| Listado de modelos cloud | `GET https://ollama.com/api/tags` (con Bearer) → ids de catálogo cloud (p. ej. `gemma4:31b`); en CLI/app usar sufijo `:cloud` | [Cloud](https://docs.ollama.com/cloud) |
| Uso consumido | `GET /api/usage?range=24h\|7d\|30d` → `request_count`, `usage_usd`, tokens | [Cloud usage](https://docs.ollama.com/api/cloud-usage) |
| Saldo restante | `GET /api/balance` (credits incluidos + comprados) | [Cloud usage](https://docs.ollama.com/api/cloud-usage) — "For your remaining included and purchased credits, use Balance" |
| Datos | Prompts/respuestas **no se loguean ni entrenan**; hosted US/EU; ZDR | [pricing FAQ](https://ollama.com/pricing) · [FAQ](https://docs.ollama.com/faq) |

Ejemplo oficial (extraído de [docs.ollama.com/cloud](https://docs.ollama.com/cloud)):

```bash
curl https://ollama.com/api/chat \
  -H "Authorization: Bearer $OLLAMA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma4:31b",
    "messages": [{"role": "user", "content": "Say hello in one sentence."}],
    "stream": false
  }'
```

### 2.2 ¿Compatible con la API nativa (`/api/chat` con tools) o solo OpenAI?

- **Nativa completa**: el ejemplo de la doc de Cloud usa `https://ollama.com/api/chat`
  con el mismo formato que el Ollama local; también `/api/tags` y `/api/usage`.
- **Además** existen las rutas OpenAI (`/v1/chat/completions`) y Anthropic
  (`/v1/messages`), pero son opcionales ("Each supports a subset of the
  original API") — [Cloud](https://docs.ollama.com/cloud).
- **Tool-calling en cloud: SÍ, confirmado por fuente primaria.**
  FAQ de pricing: *"Do models support tool calling? **Yes.** Cloud models that
  are trained to support tools are **tested for tool calling and with real
  agent workflows** before they go live."*
  ([ollama.com/pricing](https://ollama.com/pricing)). El formato es el mismo
  `/api/chat` con `tools` documentado en
  [Tool calling](https://docs.ollama.com/capabilities/tool-calling) (single-shot,
  paralelo, **agent loop** y streaming) — necesario para el bucle de agente de
  OpenClaw con `exec`.

---

## 3. Compatibilidad con OpenClaw (plugins `ollama` y `ollama-cloud`)

**Veredicto: SOPORTADO Y OFICIAL POR DOS VÍAS. Existe plugin dedicado
`ollama-cloud` (recomendado) apuntando directo a `https://ollama.com` con
`OLLAMA_API_KEY` y API nativa. El plugin `ollama` local TAMBIÉN admite apuntar
`baseUrl` a `https://ollama.com` con key real (aunque OpenClaw recomienda
`ollama-cloud`). NO hace falta la vía OpenAI-compatible/`openai`.**

### 3.1 Plugin dedicado `ollama-cloud` (vía recomendada)

Verificado en [Ollama Cloud (OpenClaw)](https://docs.openclaw.ai/providers/ollama-cloud)
y en la tabla de [Official provider plugins](https://docs.openclaw.ai/concepts/model-providers/official-provider-plugins)
(fila: `ollama-cloud` | `OLLAMA_API_KEY` | `ollama-cloud/kimi-k2.6`):

| Aspecto | Valor verificado |
| --- | --- |
| Provider id | **`ollama-cloud`** (registrado aparte del `ollama` local para no mezclar credenciales/catálogos) |
| Base URL | **`https://ollama.com`** (fija, sin daemon local y sin `ollama signin`) |
| API | Nativa Ollama `/api/chat` → **mismo formato y tool-calling que el local, sin `/v1`** |
| Auth | **`OLLAMA_API_KEY`** (env) o perfil guardado vía `openclaw onboard --auth-choice ollama-cloud` |
| Sin key | El provider **queda inactivo** ("requires an API key; without one it stays inactive") |
| Modelo por defecto del onboarding | `ollama-cloud/minimax-m2.7` (⚠️ ver §5: riesgo de 402 en plan Free) |
| Catálogo | Descubrimiento **en vivo** desde `https://ollama.com/api/tags` con tu key (`openclaw models list --provider ollama-cloud`) |
| Rechazo del marker local | El setup **rechaza `ollama-local`** (ni siquiera vía `OLLAMA_API_KEY`): solo vale una key cloud real |
| ¿Entrada en `models.providers`? | **No necesaria**: los plugins oficiales publican su catálogo; solo se usan `models.providers.*` para ajustes finos (timeouts) |
| ¿Entrada en `plugins.entries`? | No documentada como necesaria; se activa con la key (verificar: `openclaw models list --provider ollama-cloud`) |

**Config exacta "Ollama Cloud only"** (receta oficial
[Ollama config recipes](https://docs.openclaw.ai/providers/ollama/recipes)):

```json5
{
  agents: {
    defaults: {
      model: { primary: "ollama-cloud/kimi-k3" },
    },
  },
}
```

(más `export OLLAMA_API_KEY="..."` en el entorno; para el bot, el mismo efecto
se consigue con la key en `.env` → `env_file` del compose, ver §6).

### 3.2 Vía plugin `ollama` (local) con `baseUrl` apuntando a Ollama Cloud

También soportada, según [Ollama setup — Auth rules](https://docs.openclaw.ai/providers/ollama/setup):

> "**Remote and Ollama Cloud hosts**: Public remote hosts and `https://ollama.com`
> require a real credential: `OLLAMA_API_KEY`, an auth profile, or the provider's
> `apiKey`. **For direct hosted use, prefer the `ollama-cloud` provider.**"

Es decir: **se puede** (`models.providers.ollama.baseUrl: "https://ollama.com"`
+ `api: "ollama"` + key real), pero:

- El onboarding **rechaza** una URL `ollama.com` en los modos *Cloud + Local* /
  *Local only* ("hosted access belongs to **Ollama Cloud**") → esta vía es solo
  por config manual.
- Matiz de auth documentado: *"A pure `OLLAMA_API_KEY` env value is treated as
  the Ollama Cloud convention and is **not sent to local/self-hosted hosts** by
  default"* → una misma env key no se filtra al host local (bien para híbrido).

```json5
// Vía ALTERNATIVA (permitida, pero OpenClaw recomienda ollama-cloud):
{
  models: {
    providers: {
      ollama: {
        baseUrl: "https://ollama.com",   // sí se puede apuntar al cloud
        api: "ollama",                   // nativo: garanta tool-calling
        apiKey: "${OLLAMA_API_KEY}",     // key real; NO sirve "ollama-local"
        timeoutSeconds: 120,
        // models: [...] — descubrimiento en vivo igual que el local
      },
    },
  },
  agents: { defaults: { model: { primary: "ollama/gpt-oss:20b" } } },
}
```

> La sustitución `${OLLAMA_API_KEY}` dentro de `apiKey` es coherente con el
  mecanismo `${VAR}` del repo, pero **no está confirmada en la doc de OpenClaw
  para ese campo** → validar con `openclaw config validate` (Laguna 6). La
  alternativa sin sustitución es dejar que OpenClaw tome la env `OLLAMA_API_KEY`
  directamente (la doc de setup lo acepta como credencial válida).

### 3.3 Vía endpoint OpenAI-compatible con provider `openai`… — NO HACE FALTA

La hipótesis del enunciado (si el plugin no soportara key/remote → usar
`/v1` con un provider openai-compatible) **queda descartada**: el plugin
`ollama` sí soporta key y remote (§3.2) y existe `ollama-cloud` (§3.1). Además:

- Usar `/v1` con el provider `ollama` está **expresamente desaconsejado**:
  *"Do not use the `/v1` OpenAI-compatible URL… **It breaks tool calling** and
  models can emit raw tool-call JSON as plain text"* —
  [Ollama (OpenClaw)](https://docs.openclaw.ai/providers/ollama).
- El coste de la vía `openai`-compatible sería perder el comportamiento nativo
  de tools de OpenClaw, justo lo crítico para este bot.

### 3.4 Tool-calling cloud en OpenClaw

- El provider `ollama-cloud` habla `/api/chat` nativo → OpenClaw aplica el
  mismo comportamiento nativo de tools que con el local ("the same native
  Ollama chat API shape OpenClaw uses for local Ollama, but pointed at
  `https://ollama.com`") — [Ollama Cloud](https://docs.openclaw.ai/providers/ollama-cloud).
- Smoke test oficial del provider (cloud: texto, stream nativo y web search):
  `OPENCLAW_LIVE_TEST=1 OPENCLAW_LIVE_OLLAMA=1 OPENCLAW_LIVE_OLLAMA_BASE_URL=https://ollama.com OPENCLAW_LIVE_OLLAMA_MODEL=<id> pnpm test:live -- extensions/ollama/ollama.live.test.ts`
  (idéntico espíritu a los smoke tests de [model-discovery](https://docs.openclaw.ai/providers/ollama/model-discovery)
  documentados en RESEARCH-003 §4.3, sustituyendo `ollama/<m>` por
  `ollama-cloud/<m>`).
- Ojo con embeddings: "Ollama Cloud API keys **may not authorize** `/api/embed`"
  → no usar Ollama Cloud como backend de embeddings de memoria (usar el local).

---

## 4. Cuota Ollama Cloud Free vs OpenRouter free (50 req/día)

**Veredicto: cuotas de naturaleza DISTINTA — OpenRouter limita por peticiones/día
(50, duro y visible); Ollama Cloud Free limita por créditos mensuales en tokens
(importe NO publicado) con 1 concurrencia. Ollama no tiene techo diario de
requests documentado, pero su presupuesto mensual es opaco.**

| Criterio | **Ollama Cloud Free** | **OpenRouter `:free`** |
| --- | --- | --- |
| Coste | 0 € (starter credits); PAYG opcional sin suscripción ni comisiones | 0 € (sin comprar créditos) |
| Cuota principal | **Créditos mensuales en $/tokens** sobre **modelos starter** (importes y lista **NO publicados**) — [pricing](https://ollama.com/pricing) | **50 req/día globales** (todos los `:free` sumados) — [Limits](https://openrouter.ai/docs/api-reference/limits) |
| Requests/min | No publicado (429 genérico posible) | **20 RPM** en `:free` |
| Requests/día | **No publicado / no aplica** (presupuesto en tokens) | **50/día** (1.000 con ≥~$10 créditos) |
| Tokens/día | No publicado; cuota **mensual** en tokens/$ | No publicado |
| Concurrencia | **1 concurrente (Free)**; resto encola; cola llena → rechazo | No documentado como límite de plan |
| Reset | **Mensual desde la fecha de alta**, sin roll-over | Día **UTC** (diario) |
| Al agotarse | Starter credits agotados → fuera de starter models (sonda tercera: **402**, Laguna 3) o fin de crédito hasta el reset / compra de créditos | **429** `rate_limit_exceeded` → OpenClaw reintenta y salta a `fallbacks` |
| Rotación para más cuota | **Imposible**: 1 cuenta por persona | Inútil: "we govern capacity globally" (keys extra no suman) |
| Catálogo gratis con tools | 19 cloud → **18 con `tools`** (solo `clef` sin tools) — [search?c=cloud](https://ollama.com/search?c=cloud) | 15 `:free` → 14 con `tools` (RESEARCH-003 §2.1) |
| Visibilidad de consumo | **Alta**: `GET /api/usage` (tokens y $ por hora/día) + `GET /api/balance` | Media: `GET /api/v1/key` (`free_model_daily_requests`) |

Lectura para el bot: OpenRouter se agota **a mitad del día** con un agente
activo (RESEARCH-003 §6) y no hay forma de subir el techo sin pagar; Ollama
Free **no tiene techo diario de requests**, pero su presupuesto mensual opaco
puede agotarse a mitad de mes sin aviso previo (solo monitoring manual vía
`/api/usage` y alertas al 90% — estas últimas solo documentadas para planes de
pago). **Complementariedad**: ambos se agotan por mecanismos distintos → fallback
cruzado OpenClaw sigue siendo la estrategia (RESEARCH-003 §5).

---

## 5. Modelos cloud con tool-calling (candidatos gratuitos)

**Veredicto: 18 de 19 modelos cloud declaran `tools`; el subconjunto
"starter" del plan Free NO está publicado, así que los candidatos se eligen
por (a) pertenecer al catálogo cloud con tools, (b) tier de uso más barato
(quema menos starter credits) y (c) evidencia empírica disponible.**

### 5.1 Catálogo cloud (2026-10-16, [ollama.com/search?c=cloud](https://ollama.com/search?c=cloud))

19 modelos cloud; etiquetados `tools` todos salvo `clef` (solo
vision/decision). Etiquetas de precio por uso: **Low / Medium / High / Extra
High usage** (p. ej. `nemotron-3-super` $0,015 in · $0,60 out /1M;
`gpt-oss:20b` $0,07 · $0,30; `gemma4` $0,14 · $0,40).

> ⚠️ **NO CONFIRMADO** que la etiqueta "Low usage" = set "starter" del plan
  Free. No hay ninguna fuente que lo relacione (Laguna 1).

### 5.2 Candidatos recomendados (2-4)

| # | Ref OpenClaw | Contexto | Tools | Tarifa /1M (in/out) | Por qué |
| --- | --- | --- | --- | --- | --- |
| 1 | `ollama-cloud/gpt-oss:20b` | 128K | ✅ (+thinking) | $0,07 / $0,30 (tier **Low**) | Modelo agentic de OpenAI, barato, buen perfil tools; idéntico a los candidatos locales `gpt-oss:20b` documentados en OpenClaw |
| 2 | `ollama-cloud/gemma4:31b` | 256K | ✅ (+vision, thinking) | $0,14 / $0,40 (tier **Low**) | Familia recomendada por OpenClaw en local; **confirmado en sonda tercera con key Free** (Laguna 3); visión útil para la skill de media |
| 3 | `ollama-cloud/nemotron-3-super` | 256K | ✅ (+thinking) | **$0,015** / $0,60 (tier Medium) | **Entrada más barata del catálogo** → maximiza starter credits en prompts largos de agente; 120B MoE (12B activos) |
| 4 | `ollama-cloud/nemotron-3-nano` | 256K | ✅ (+thinking) | $0,06 / $0,24 (tier **Low**) | 4B/30B, el más barato en output; perfil agentic ligero |

Sustituto razonable si el anterior falla: `ollama-cloud/deepseek-v4.1-flash`
(1M ctx, vision+tools, $0,30/$1,20, tier Medium).

**Evitar como primary en plan Free**: `kimi-k3` ($3/$15), `deepseek-v4-pro`,
`glm-5.3`, `muse-spark-open`, `minimax-m3` (High/Extra High usage). Y **ojo con
el default del onboarding `ollama-cloud/minimax-m2.7`** (tier Medium): una sonda
tercera (2026-09-02) obtuvo **402 Payment Required** en `minimax-m3` con key
Free mientras `gpt-oss:120b`, `gemma4:31b` y `nemotron-3-ultra` respondían
(Laguna 3) → **fijar un modelo Low explícitamente en vez de confiar en el
default**.

---

## 6. Config propuesta para este repo

### 6.1 Opción A (RECOMENDADA): híbrida — Ollama Cloud primary + Ollama local fallback

Modificaciones exactas sobre `conf/openclaw.json` (JSON puro, copiable):

**(1) Añadir bloque `models.providers`** (solo el provider local; `ollama-cloud`
NO lleva entrada — es plugin oficial con descubrimiento en vivo):

```json
{
  "models": {
    "providers": {
      "ollama": {
        "baseUrl": "http://host.docker.internal:11434",
        "apiKey": "ollama-local",
        "api": "ollama",
        "timeoutSeconds": 300,
        "models": [
          {
            "id": "qwen3:14b",
            "name": "qwen3:14b",
            "input": ["text"],
            "contextTokens": 32768,
            "params": { "num_ctx": 32768, "keep_alive": "15m" }
          }
        ]
      }
    }
  }
}
```

> Requiere `extra_hosts: ["host.docker.internal:host-gateway"]` en los servicios
  del `docker-compose.yml` y `OLLAMA_HOST=0.0.0.0:11434` en el Ollama del host
  (RESEARCH-003 §3.4). El `apiKey: "ollama-local"` es obligatorio aquí aunque
  exista `OLLAMA_API_KEY` cloud en el entorno (la env cloud **no se envía** a
  hosts locales — [Ollama setup](https://docs.openclaw.ai/providers/ollama/setup)).

**(2) Reemplazar `agents.entries.bot.model`** (hoy es string `"${LLM_MODEL}"`;
RESEARCH-003 §5.3: la string **ignora** `agents.defaults.model.fallbacks` → hay
que convertirla en objeto):

```json
{
  "agents": {
    "entries": {
      "bot": {
        "model": {
          "primary": "ollama-cloud/gpt-oss:20b",
          "fallbacks": ["ollama/qwen3:14b"]
        }
      }
    }
  }
}
```

**(3) Sin cambios en `env.vars`**: `OLLAMA_API_KEY` entra por el `env_file: .env`
del compose (misma opción A de RESEARCH-003 §1.2). El bloque existente
`OPENAI_API_KEY`/`ANTHROPIC_API_KEY: "${LLM_API_KEY}"` se puede conservar
tal cual.

**`.env` (añadir):**

```bash
# ── Ollama Cloud (RESEARCH-004) ─────────────────────────────────────────
# Clave API de https://ollama.com/settings/keys (plan Free sin tarjeta).
# No caduca; revocable desde la misma página.
OLLAMA_API_KEY=***

# Informativo/alternativa: si se prefiere parametrizar el primary del bot,
# usar la forma string con ${LLM_MODEL} (REQUIERE convertir el objeto model
# a string o validar sustitución dentro del objeto — Laguna 4):
#LLM_MODEL=ollama-cloud/gpt-oss:20b
```

**(4) Modelo primary parametrizado (opcional, no validado):**

```json
"model": { "primary": "${LLM_MODEL}", "fallbacks": ["ollama/qwen3:14b"] }
```

con `LLM_MODEL=ollama-cloud/gpt-oss:20b` en `.env`. **NO CONFIRMADO** que la
sustitución `${LLM_MODEL}` funcione dentro de un objeto (misma laguna 3 de
RESEARCH-003) → validar con `openclaw config validate` antes de fijarlo;
mientras tanto, la literales del bloque (2) son la vía segura.

### 6.2 Opción B: solo Ollama Cloud (sin fallback local)

Config mínima (receta oficial [recipes](https://docs.openclaw.ai/providers/ollama/recipes)
adaptada al bot):

```json
{
  "agents": {
    "entries": {
      "bot": {
        "model": {
          "primary": "ollama-cloud/gpt-oss:20b",
          "fallbacks": ["ollama-cloud/gemma4:31b"]
        }
      }
    }
  }
}
```

`.env`: solo `OLLAMA_API_KEY=...`. **No recomendada como única**: si se agotan
los starter credits (o hay 402/429), el segundo modelo cloud comparte la misma
cuota → el bot se queda sin respuesta hasta el reset mensual. El fallback local
(§6.1) es lo único que mantiene el bot vivo 24/7 (mismo argumento que
RESEARCH-003 §6).

### 6.3 Verificación (adaptación de RESEARCH-003 §4.3)

```bash
# 1) Catálogo cloud con tu key (copia el id EXACTO de aquí)
docker compose --profile cli run --rm openclaw-cli \
  openclaw models list --provider ollama-cloud

# 2) Smoke de texto vía gateway
docker compose --profile cli run --rm openclaw-cli \
  openclaw infer model run --gateway --model ollama-cloud/gpt-oss:20b \
  --prompt "Reply with exactly: pong" --json

# 3) Turno REAL del agente con tools (la prueba que importa)
docker compose --profile cli run --rm openclaw-cli \
  openclaw agent --agent bot --message "Ejecuta: echo hola"

# 4) Consumo y saldo (cuota Free)
curl -s "https://ollama.com/api/usage?range=24h" -H "Authorization: Bearer $OLLAMA_API_KEY"
curl -s "https://ollama.com/api/balance"         -H "Authorization: Bearer $OLLAMA_API_KEY"
```

---

## Veredicto final

## ✅ **VIABLE CON RESTRICCIONES**

**A favor:**

- Ollama Cloud existe, es maduro y el plan Free cuesta **0 € sin tarjeta**.
- **Tool-calling confirmado** por fuente primaria (pricing FAQ) y probado con
  "real agent workflows" antes de publicar cada modelo.
- OpenClaw lo soporta **oficialmente y con API nativa** (`ollama-cloud`,
  `https://ollama.com`, `/api/chat`, `OLLAMA_API_KEY`) → sin el riesgo del `/v1`
  que rompe tools (RESEARCH-003 §3.2).
- **Sin techo diario de requests** documentado (a diferencia de los 50 req/día
  de OpenRouter) y con monitoring de consumo (`/api/usage`, `/api/balance`).
- Fallback local integrable con la misma config híbrida ya estudiada.

**Restricciones (por qué no es "plena viable"):**

1. La cuota Free **no está cuantificada** (starter credits de importe opaco)
   ni la **lista de modelos starter publicada** → no se puede garantizar
   autonomía 24/7 con solo cloud.
2. **Concurrencia 1** en Free (todo se encola; cola llena → rechazo).
3. Riesgo de **402** si el modelo elegido no es starter (incluido el default
   de onboarding `minimax-m2.7`) — a confirmar empíricamente.
4. El modelo de cuota es **mensual en tokens**, no por requests: prompts largos
   de agente (tools + historial) queman créditos más rápido que un chat simple.

**Recomendación operativa**: Opción A (§6.1) — primary
`ollama-cloud/gpt-oss:20b` (o `gemma4:31b`) + fallback local
`ollama/qwen3:14b`; validar el turno real con las 3 skills antes de fijarlo
(§6.3) y monitorizar `/api/usage` durante la primera semana.

---

## Lagunas / a verificar

1. **Importe de los starter credits y lista de modelos starter del plan
   Free: NO PUBLICADOS** (revisado pricing, blog y FAQ el 2026-10-16). Solo
   se puede medir empíricamente con una key Free.
2. **Rate limits de inferencia (req/min, req/día, tokens/día): NO
   PUBLICADOS.** Solo está documentado el 429 genérico, la concurrencia 1 y
   el límite de 10 req/min del endpoint de monitoring `/api/usage`.
3. **402 en modelos no-starter con key Free**: observación de fuentes
   terciarias ([mvalentsev (2026-09-08)](https://mvalentsev.github.io/awesome-free-ai-coding/providers/ollama-cloud/) —
   sonda 2026-09-02: `gpt-oss:120b`, `gemma4:31b`, `nemotron-3-ultra` OK;
   `minimax-m3` → 402; [itsfree.ai](https://itsfree.ai/provider/ollama-cloud/),
   [llmrates.ai](https://www.llmrates.ai/coding-plans/ollama-free) coinciden en
   "amount not published"). **Reproducir con cuenta propia antes de elegir modelo.**
4. **`ollama-cloud` y el bucket de billing de OpenClaw**: no está documentado
   que un 402/credit-exhausted de Ollama Cloud se clasifique como "billing" y
   active el fallback ([Model failover](https://docs.openclaw.ai/concepts/model-failover)
   documenta el bucket para otros proveedores). **Validar empíricamente**: si
   no hace fallback, el bot fallaría en silencio al agotar cuota.
5. **Sustitución `${LLM_MODEL}` / `${OLLAMA_API_KEY}` dentro de objetos y
   `apiKey`** de config: no confirmada en la doc (misma laguna 3 de
   RESEARCH-003). Validar con `openclaw config validate`.
6. **Id exacto de modelo cloud**: la doc de OpenClaw usa tanto
   `ollama-cloud/minimax-m2.7` como `ollama-cloud/minimax-m2.7:cloud` → copiar
   SIEMPRE el id de `openclaw models list --provider ollama-cloud` (§6.3).
7. **Activación del plugin `ollama-cloud` sin entrada en `plugins.entries`**:
   inferido de "without one [key] it stays inactive"; confirmar con el
   `models list` del punto 6.3.
8. **¿Etiquetas "Low/Medium/High usage" = tiers de starter?** No hay fuente
   que lo relacione; no usar como criterio.
9. **Ejecución empírica pendiente**: ningún comando de §6.3 se ha ejecutado
   (falta key y Ollama local operativo); el turno con las skills
   `yt-dlp`/`ffmpeg`/`wacli` sigue sin probarse en ningún candidato (laguna 1
   de RESEARCH-003).
10. **Catálogo cloud vivo (19 modelos)**: foto del 2026-10-16; verificar con
    `openclaw models list --provider ollama-cloud --refresh`.

---

## Referencias

### Ollama (primaria)
- https://ollama.com/pricing — planes (Free 0 $, starter credits, concurrencia 1, FAQ modelos/tools)
- https://ollama.com/blog/transparent-pricing — 2026-08-31: cuota mensual en $, "Free: a starter amount each month for a set of starter models", sin límites 5h/semanales
- https://ollama.com/blog — índice del blog (Cloud models 2025-09-19, OpenClaw 2026-02-01)
- https://ollama.com/blog/cloud-models — lanzamiento preview del cloud
- https://ollama.com/search?c=cloud — catálogo cloud (19 modelos, capabilities, precios)
- https://docs.ollama.com/cloud — uso del cloud: API key, `https://ollama.com/api/chat`, `/api/tags`, sin instalación
- https://docs.ollama.com/api/authentication — `https://ollama.com/api` y `/v1` con Bearer, keys no caducan, `ollama signin`
- https://docs.ollama.com/api/errors — 429 rate limit genérico, 502 cloud unreachable
- https://docs.ollama.com/api/cloud-usage — `GET /api/usage`, `GET /api/balance`, 10 req/min del endpoint
- https://docs.ollama.com/capabilities/tool-calling — tools nativos `/api/chat` (single, paralelo, agent loop, streaming)
- https://docs.ollama.com/faq — privacidad cloud, `disable_ollama_cloud`
- https://docs.ollama.com/llms.txt — índice de la documentación

### OpenClaw (primaria)
- https://docs.openclaw.ai/providers/ollama-cloud — provider `ollama-cloud`: baseUrl, key, API nativa, default `minimax-m2.7`, live test, troubleshooting
- https://docs.openclaw.ai/providers/ollama — índice Ollama, warning `/v1` rompe tool calling, enlace a `ollama-cloud`
- https://docs.openclaw.ai/providers/ollama/setup — auth rules: `https://ollama.com` exige key real, "prefer the `ollama-cloud` provider", env `OLLAMA_API_KEY` no se envía a hosts locales
- https://docs.openclaw.ai/providers/ollama/recipes — receta "Ollama Cloud only" y "Cloud plus local"
- https://docs.openclaw.ai/concepts/model-providers/official-provider-plugins — tabla bundled: `ollama-cloud` | `OLLAMA_API_KEY`
- https://docs.openclaw.ai/concepts/model-failover — semántica de fallback (RESEARCH-003)
- https://docs.openclaw.ai/providers/ollama/model-discovery — smoke tests (RESEARCH-003)

### Terciarias (marcadas como tales)
- https://mvalentsev.github.io/awesome-free-ai-coding/providers/ollama-cloud/ — sonda Free 2026-09-02 (402 en `minimax-m3`)
- https://itsfree.ai/provider/ollama-cloud/ — "monthly starter credits, 1 concurrent request"
- https://www.llmrates.ai/coding-plans/ollama-free — "starter usage credits, amount not published"
- https://ai-deals.rockpool.cc/offer-ollama-cloud-free-plan — oferta Free documentada, "credit amount is not published"

---

*Última actualización: 2026-10-16*
