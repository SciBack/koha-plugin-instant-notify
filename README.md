# SciBack Instant Notify — Koha Plugin

Plugin para Koha ILS que envía notificaciones de email **instantáneas** en operaciones de circulación (checkout, devolución, renovación), sin depender del cron de `process_message_queue.pl`.

## El problema que resuelve

Koha genera notificaciones de email al hacer un préstamo o devolución, pero las encola en `message_queue`. El cron que las procesa corre cada 1-5 minutos. Este plugin intercepta la transacción en tiempo real y envía el email directamente por SMTP, funcionando como **voucher digital instantáneo**.

## Compatibilidad

| Koha | Estado |
|------|--------|
| 22.11 | ✅ Compatible |
| 23.11 | ✅ Compatible |
| 25.11 | ✅ Probado |

Requiere `enable_plugins = 1` en `koha-conf.xml`.

## Instalación

1. Descargar el `.kpz` desde [Releases](../../releases)
2. Koha Staff → Administration → Plugins → Upload plugin
3. Buscar "SciBack Instant Notify" → Activar
4. Configurar SMTP en Administration → SMTP Servers
5. Abrir configuración del plugin y ajustar plantillas

## Configuración

| Campo | Descripción | Default |
|-------|-------------|---------|
| Préstamo/Devolución/Renovación | Habilitar por tipo | Todos activos |
| From address | Remitente del email | `KohaAdminEmailAddress` |
| Timeout SMTP | Segundos máx por envío | 8s |
| Fallback a cola | Si SMTP falla, encola en `message_queue` | Activo |

El plugin usa el **servidor SMTP configurado en Koha** (Administration → SMTP Servers). No requiere configuración SMTP propia.

## Variables en templates

```
<<nombre_completo>>       Nombre y apellido del patron
<<borrowers.firstname>>   Nombre
<<borrowers.surname>>     Apellido
<<borrowers.cardnumber>>  Número de carné
<<biblio.title>>          Título del material
<<biblio.author>>         Autor
<<items.barcode>>         Código de barras
<<checkout.date_due>>     Fecha de vencimiento (solo checkout/renewal)
<<branches.branchname>>   Sede de la biblioteca
<<library_name>>          Nombre de la biblioteca (syspref LibraryName)
<<opac_url>>              URL del OPAC (syspref OPACBaseURL)
```

## Arquitectura

```
Bibliotecario → checkout en staff UI
    → C4::Circulation::AddIssue()
        → Koha::Hooks::run_hooks('after_circ_action', ...)
            → InstantNotify::after_circ_action()
                → Koha::Email->create() + SMTP::Servers->get_default
                    → Email llega en < 3 segundos
                    [si SMTP falla → fallback a message_queue]
```

## Desarrollado por

[SciBack](https://sciback.pe) — Soluciones de infraestructura académica para universidades peruanas.

Licencia: GPL-3.0-or-later (mismo que Koha)
