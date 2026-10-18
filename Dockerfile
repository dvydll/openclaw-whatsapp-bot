# ══════════════════════════════════════════════════════════════════════
# openclaw-whatsapp-bot — imagen derivada de la oficial de OpenClaw
#
# PLAN-001 "Cambio 1" · ADR-001 "Decisión secundaria: imagen Docker derivada"
#
# Añade a la imagen oficial publicada:
#   - ffmpeg, jq y ca-certificates (apt)
#   - yt-dlp: binario estático oficial de GitHub Releases (NO el paquete de
#     bookworm, que va obsoleto para YouTube)
#   - wacli: binario Go oficial de GitHub Releases (github.com/openclaw/wacli)
#
# No se modifican CMD, ENTRYPOINT ni USER de la imagen base: los installs se
# hacen como root y se restaura el usuario `node` al final.
#═══════════════════════════════════════════════════════════════════════

# Imagen oficial publicada. GHCR es el registro principal de release;
# mirror equivalente en Docker Hub: openclaw/openclaw:<tag>.
# Etiqueta fijada (reproducible): release estable 2026.10.3 (2026-10-13).
ARG OPENCLAW_BASE_IMAGE="ghcr.io/openclaw/openclaw:2026.10.3"
FROM ${OPENCLAW_BASE_IMAGE}

# Los ARG declarados antes de FROM quedan fuera de scope; se redeclaran aquí.
ARG OPENCLAW_BASE_IMAGE
# Última release estable de yt-dlp con binario standalone por plataforma:
#   https://github.com/yt-dlp/yt-dlp/releases
ARG YT_DLP_VERSION="2026.08.19"
# Última release de wacli (tag "v<WACLI_VERSION>"; assets
# wacli_<ver>_linux_<arch>.tar.gz):
#   https://github.com/openclaw/wacli/releases
ARG WACLI_VERSION="0.21.0"

# La imagen base termina con USER node; apt y las descargas exigen root.
# Se restaura USER node antes de terminar (USER final = el de la base).
USER root

# ── Dependencias de sistema (apt) ──────────────────────────────────────
# ca-certificates ya viene en la base (bookworm-slim lo instala explícitamente);
# se lista igualmente por idempotencia. Limpieza de listas según DoD.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates \
      ffmpeg \
      jq && \
    rm -rf /var/lib/apt/lists/*

# ── yt-dlp: binario standalone oficial (no el de bookworm) ─────────────
# Assets por plataforma en el release: yt-dlp_linux (amd64) y
# yt-dlp_linux_aarch64 (arm64). Binario autocontenido (incluye Python).
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) ytdlp_asset="yt-dlp_linux" ;; \
      arm64) ytdlp_asset="yt-dlp_linux_aarch64" ;; \
      *) echo "ERROR: sin binario de yt-dlp para la arquitectura $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 --retry-delay 2 \
      -o /usr/local/bin/yt-dlp \
      "https://github.com/yt-dlp/yt-dlp/releases/download/${YT_DLP_VERSION}/${ytdlp_asset}"; \
    chmod 0755 /usr/local/bin/yt-dlp

# ── wacli: binario Go oficial ──────────────────────────────────────────
# El release trae tarballs por plataforma (linux_amd64 / linux_arm64) con el
# binario `wacli` en la raíz del tarball (verificado: ./wacli, LICENSE, README).
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
      amd64) wac_arch="linux_amd64" ;; \
      arm64) wac_arch="linux_arm64" ;; \
      *) echo "ERROR: sin binario de wacli para la arquitectura $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac; \
    wac_tmp="$(mktemp -d)"; \
    curl -fsSL --retry 3 --retry-delay 2 \
      -o "${wac_tmp}/wacli.tar.gz" \
      "https://github.com/openclaw/wacli/releases/download/v${WACLI_VERSION}/wacli_${WACLI_VERSION}_${wac_arch}.tar.gz"; \
    tar -xzf "${wac_tmp}/wacli.tar.gz" -C "${wac_tmp}"; \
    wac_bin="$(find "${wac_tmp}" -maxdepth 2 -type f -name wacli -print -quit)"; \
    if [ -z "${wac_bin}" ]; then \
      echo "ERROR: el tarball de wacli no contiene el binario 'wacli'" >&2; exit 1; \
    fi; \
    install -m 0755 "${wac_bin}" /usr/local/bin/wacli; \
    rm -rf "${wac_tmp}"

# ── Restaurar el usuario de la base y verificación de binarios ─────────
# USER/CMD/ENTRYPOINT finales = los heredados de la imagen oficial.
USER node

# Sanity check del build (DoD T-03): los 4 binarios responden.
RUN ffmpeg -version && yt-dlp --version && wacli --version && jq --version
