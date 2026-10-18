---
name: ytdl
description: Descarga vídeo o audio de YouTube con yt-dlp (allowlist de dominios y límite MEDIA_MAX_MB) y envía el resultado al chat.
metadata:
  openclaw:
    requires:
      bins: ["yt-dlp", "ffmpeg", "wacli"]
---

# ytdl — descarga de YouTube (vídeo o audio)

Descarga un vídeo o su audio desde YouTube con `yt-dlp` + `ffmpeg`, con
allowlist estricta de dominios y chequeo de tamaño antes de entregar
(decisión D3 del PLAN-001). El directorio temporal se limpia siempre.

## Cuándo usar esta skill

Cuando el usuario pida descargar/bajar un vídeo de YouTube o su audio
("bájame esto", "pásame el audio de…") a partir de una URL.

## Flujo

1. Extrae la URL del mensaje.
2. Invoca el script (`{baseDir}` es la raíz de esta skill), con modo
   `video` o `audio`:

```bash
{baseDir}/bin/ytdl.sh "https://www.youtube.com/watch?v=XXXXXXXXXXX" audio --out ./downloads
{baseDir}/bin/ytdl.sh "https://youtu.be/XXXXXXXXXXX" video --out ./downloads
```

3. En éxito (exit 0), `stdout` imprime la **ruta absoluta** del artefacto:
   envíalo al chat con el mecanismo de media de OpenClaw. Fallback:

```bash
wacli send file --to "1234567890@g.us" --file "/ruta/absoluta/al/artefacto.mp4"
```

4. Comprueba el código de salida (tabla siguiente).

## Límites y allowlist (los aplica el propio script)

- Dominios permitidos: `youtube.com`, `www.youtube.com`, `m.youtube.com`,
  `music.youtube.com`, `youtu.be`. Cualquier otro host → exit 3. No "valides"
  ni aceptes tú otras URLs: el script parsea la URL de forma estricta y
  rechaza también el spoofing (p. ej. `youtube.com.evil.com` o
  `youtube.com@evil.com`).
- `--no-playlist` va **implícito** en el script: si la URL es de una
  playlist, solo se descarga el elemento concreto de la URL.
- Tamaño: el artefacto se comprueba contra `MEDIA_MAX_MB` (defecto: 50 MB)
  **antes** de entregarlo; superarlo → exit 5 (ver abajo).
- Formatos: `video` → mp4 de mejor calidad disponible; `audio` → mp3.

## Códigos de salida de `ytdl.sh`

| Exit | Motivo | Acción del agente |
|------|--------|-------------------|
| 0 | Éxito: la ruta absoluta del artefacto está en `stdout` | Envía el fichero al chat |
| 1 | Uso incorrecto o error genérico | Corrige la invocación |
| 2 | URL inválida (sin esquema `http(s)`, malformada) | Pide la URL correcta |
| 3 | Dominio no permitido | **Rechaza la petición**; no intentes descargar por otro medio ni de otro dominio |
| 4 | Descarga fallida (`yt-dlp` con error) | Informa al usuario; reintenta como máximo una vez |
| 5 | El archivo supera `MEDIA_MAX_MB` | Ver "Cuando supera el límite" |
| 6 | Dependencia ausente (`yt-dlp` o `ffmpeg`) | Informa de un problema del bot |

## Cuando supera el límite (exit 5)

El fichero **no se entrega** por defecto. Según `MEDIA_FORCE_DOCUMENT`:

- `false` (defecto): responde con un aviso de texto (p. ej. el tamaño
  descargado vs. el máximo) y no envíes nada.
- `true`: invoca el script **desde el primer intento** con
  `YTDL_KEEP_OVERSIZE=1`, que conserva el fichero pese a salir con 5 e
  imprime su ruta; envíalo entonces como **documento** con el mecanismo de
  media de OpenClaw o con `wacli send file --to <JID> --file <ruta>`:

```bash
YTDL_KEEP_OVERSIZE=1 {baseDir}/bin/ytdl.sh "https://www.youtube.com/watch?v=XXXXXXXXXXX" video --out ./downloads
```
