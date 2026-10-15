# Registro de Issues

Este directorio contiene el registro de errores y problemas reportados durante
la operación del proyecto FSFA-UGT (Formación Sanitaria para la Fundación Salud
y Formación de Andalucía).

## Cómo Reportar un Issue

1. Copiar [[ISSUE-TEMPLATE.md]] a un nuevo archivo:
   `ISSUE-<numero>-<descripcion-corta>.md`
2. Rellenar la sección **Información General** y **Descripción**
3. Incluir **pasos para reproducir** y **logs relevantes**
4. El equipo investigará y completará las secciones de análisis y resolución

## Convención de Nombres

```
ISSUE-001-login-fallido.md
ISSUE-002-informe-pdf-0bytes.md
ISSUE-003-error-seguimiento-npe.md
```

## Estados

| Estado               | Descripción                          |
| -------------------- | ------------------------------------ |
| **Nuevo**            | Issue reportado, pendiente de triage |
| **En investigación** | Analizando causa raíz                |
| **En progreso**      | Solución en desarrollo               |
| **Resuelto**         | Fix implementado y desplegado        |
| **Cerrado**          | Verificado en producción             |

## Prioridades

| Prioridad | Criterio                                                     |
| --------- | ------------------------------------------------------------ |
| **Alta**  | Bloquea funcionalidad principal (login, matriculación, pago) |
| **Media** | Funcionalidad afectada pero con workaround                   |
| **Baja**  | Cosmético o mejora menor                                     |

## Issues Registrados

| ID  | Descripción | Estado | Fecha |
| --- | ----------- | ------ | ----- |
| ISSUE-001 | Bot de WhatsApp con OpenClaw (docker) | Nuevo | 2026-10-15 |

---

*Última actualización: 2026-10-09*
