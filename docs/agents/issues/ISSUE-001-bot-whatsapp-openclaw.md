# ISSUE-001 — Bot de WhatsApp con OpenClaw (docker)

## Información General

| Campo             | Valor                                                       |
| ----------------- | ----------------------------------------------------------- |
| **ID**            | `ISSUE-001`                                                 |
| **Fecha**         | 2026-10-15                                                  |
| **Reportado por** | Propietario del proyecto                                    |
| **Prioridad**     | Alta                                                        |
| **Estado**        | Nuevo                                                       |
| **Entorno**       | Ambos                                                       |

## Descripción

Solicitud de creación desde cero, en el directorio del proyecto
`openclaw-whatsapp-bot`, de todo lo necesario para un bot de WhatsApp basado en
OpenClaw y desplegado con Docker, con las siguientes capacidades:

1. **Gestión del grupo de WhatsApp**: expulsión (baneo) de usuarios,
   **exclusivamente bajo comando de admins del grupo**. El bot debe verificar
   que el emisor del comando es admin antes de expulsar, y el bot a su vez debe
   ser admin del grupo.
2. **Creación de stickers** a partir de imágenes/vídeos (mediante `ffmpeg`).
3. **Descarga de vídeo/audio desde YouTube** con `yt-dlp` + `ffmpeg`,
   enviando el resultado al chat.
4. **Control de respuestas**: en grupos solo contesta bajo mención; en DMs solo
   contesta al propietario (allowlist con su número).
5. **Proveedor LLM aún sin definir**: la configuración debe quedar
   parametrizada en `.env`.

## Contexto / Requerimientos

1. El proyecto parte de cero en este directorio (repo nuevo).
2. Despliegue con Docker (y, previsiblemente, Docker Compose).
3. El bot debe ser **admin del grupo** para poder expulsar.
4. Antes de expulsar a un usuario, el bot debe **verificar que el emisor del
   comando es admin del grupo**; los usuarios no admins no deben poder expulsar.
5. Stickers generados a partir de imágenes o vídeos usando `ffmpeg`.
6. Descarga desde YouTube con `yt-dlp`, conversión/extracto con `ffmpeg`, y
   envío del archivo resultante al chat.
7. En grupos: el bot solo responde cuando es **mencionado**.
8. En DMs: el bot solo responde a los números incluidos en una allowlist
   (empezando por el número del propietario), configurada en `.env`.
9. El proveedor LLM no está definido todavía: debe quedar **parametrizado en
   `.env`** (proveedor, modelo, API key, etc.) para poder cambiarlo sin tocar
   código.

## Comportamiento Esperado

- El bot está desplegado con Docker y operativo en WhatsApp.
- Solo responde en grupos cuando se le menciona y en DMs cuando el emisor está
  en la allowlist.
- Ejecuta comandos de expulsión únicamente si el emisor es admin del grupo y
  el bot es admin.
- Genera y envía stickers y descargas de YouTube según lo solicitado.
- La configuración del LLM se lee de `.env` sin necesidad de recompilar.

## Comportamiento Actual

NO APLICA — proyecto nuevo; aún no existe implementación.

## Evidencia

*(Pendiente — NO APLICA por ahora: aún no hay implementación ni fallos que
evidenciar.)*

### Logs relevantes

```bash
# NO APLICA por ahora
```

### Capturas de pantalla

NO APLICA por ahora.

## Contexto Técnico

| Campo            | Valor                                                          |
| ---------------- | -------------------------------------------------------------- |
| **Componente**   | Bot de WhatsApp (OpenClaw) / Integración / Despliegue Docker   |
| **URL afectada** | NO APLICA                                                       |
| **Navegador**    | NO APLICA                                                       |
| **Versión**      | `v0.x.x` (inicial)                                             |

## Análisis de Causa Raíz

NO APLICA por ahora — es una solicitud de creación, no un bug. Se completará
durante la investigación si procede.

## Solución Propuesta

*(Completar durante la investigación/plan: arquitectura del bot, estructura de
directorios, servicios Docker, definición de comandos y allowlist en `.env`.)*

## Resolución

| Campo                   | Valor |
| ----------------------- | ----- |
| **Resuelto por**        |       |
| **Fecha de resolución** |       |
| **Commit**              |       |
| **Notas**               |       |
