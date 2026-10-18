---
name: sticker
description: Crea stickers de WhatsApp (imagen o vídeo corto → webp 512x512) con ffmpeg y los envía al chat vía wacli.
metadata:
  openclaw:
    requires:
      bins: ["ffmpeg", "wacli"]
---

# sticker — creación y envío de stickers

Convierte una imagen o un vídeo/gif corto en un sticker de WhatsApp
(webp 512x512) con `ffmpeg` y lo envía al chat (decisión D2 del PLAN-001).
Un sticker fuera de límite **nunca** se entrega ni se envía.

## Cuándo usar esta skill

Cuando el usuario pida un sticker o pegatina (estático o animado) a partir
de una imagen o de un vídeo/gif.

## Flujo

1. Determina la **entrada**: un fichero recibido en el mensaje o una ruta.
   Antes de invocar el script, **verifica que la ruta existe y es un fichero
   legible** (el script sale con código 2 si no lo es); no improvises rutas.
2. Invoca el script (`{baseDir}` es la raíz de esta skill):

- Enviar directamente al chat (`--send` hace el envío con
  `wacli send sticker --to <JID> --file <ruta>`; no se conserva copia):

```bash
{baseDir}/bin/make-sticker.sh /ruta/a/foto.jpg --send "1234567890@g.us"
```

- O solo crear el fichero (por defecto en `./downloads`; `stdout` imprime su
  **ruta absoluta**; `--send` y `--out` no se combinan — con `--send` se
  ignora `--out`):

```bash
{baseDir}/bin/make-sticker.sh /ruta/a/clip.mp4 --out ./downloads
```

3. Comprueba el código de salida (tabla siguiente). Si solo has creado el
   fichero y el usuario quiere que lo envíes, envíalo con
   `wacli send sticker --to <JID> --file <ruta>` usando la ruta absoluta
   que imprimió `stdout`.

## Límites (los aplica el propio script)

- Salida: **webp 512x512** con fondo transparente.
- Estático (imagen): **≤ 100 KiB** (el script reduce calidad iterativamente
  hasta caber).
- Animado (gif/vídeo): fps=12, bucle infinito, **≤ 500 KiB** (si no cabe,
  recorta la duración automáticamente).
- Entrada de vídeo acotada a `STICKER_MAX_SEC` segundos (defecto: 15).

## Códigos de salida de `make-sticker.sh`

| Exit | Motivo | Acción del agente |
|------|--------|-------------------|
| 0 | Éxito (creado; y enviado si se pasa `--send`) | Informar / dar por enviado |
| 1 | Uso incorrecto o error genérico | Corrige la invocación |
| 2 | La entrada no existe o no es un fichero legible | Verifica la ruta antes de reintentar |
| 3 | Tipo de entrada no soportado (no es imagen ni vídeo) | Informa al usuario |
| 4 | ffmpeg ha fallado durante la conversión | Informa al usuario |
| 5 | No se alcanza el límite de tamaño: **no se entrega ni se envía** | **Nunca** enviar la entrada original "para que se vea"; avisa al usuario (p. ej. pide una imagen menor o un clip más corto) |
| 6 | Dependencia ausente (`ffmpeg`; además `wacli` con `--send`) | Informa de un problema del bot |
| 7 | Envío fallido (`wacli send sticker`) | Informa al usuario; no repitas el envío en bucle |
