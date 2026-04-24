# Documentación de AN.MediatR

Bienvenido a la documentación completa de **AN.MediatR**, un fork de la conocida librería [MediatR](https://github.com/jbogard/MediatR) creada originalmente por **Jimmy Bogard** y actualmente mantenida como producto comercial por **Lucky Penny Software** (la organización detrás del ecosistema **Aves Nobles** / **AN**).

AN.MediatR es una **implementación simple y sin pretensiones del patrón Mediator para .NET**. Proporciona mensajería en proceso con cero dependencias externas más allá de `Microsoft.Extensions.DependencyInjection.Abstractions` y `Microsoft.Extensions.Logging.Abstractions`, soportando petición/respuesta, comandos, consultas, notificaciones, eventos y streaming — tanto síncronos como asíncronos — con dispatching inteligente gracias a la varianza genérica de C#.

Este fork añade un **sistema de licenciamiento empresarial** (basado en JWT) sobre el mediator open-source original, que es la diferencia funcional clave respecto al upstream `jbogard/MediatR`.

---

## Índice de contenidos

| Documento | Descripción |
|-----------|-------------|
| [Arquitectura](01%20-%20Arquitectura.md) | Stack tecnológico, frameworks destino y estructura de alto nivel |
| [Estructura del Proyecto](02%20-%20Estructura_del_Proyecto.md) | Distribución de la solución, proyectos, dependencias y herramientas |
| [Conceptos Fundamentales](03%20-%20Conceptos_Fundamentales.md) | Patrón Mediator, CQRS, requests, notificaciones, streams |
| [Interfaces Principales](04%20-%20Interfaces_Principales.md) | `IMediator`, `ISender`, `IPublisher`, `IRequest`, `INotification`, handlers, `Unit` |
| [Implementación del Mediator](05%20-%20Implementacion_Mediator.md) | Detalle interno de la clase `Mediator`: caching, dispatching |
| [Comportamientos del Pipeline](06%20-%20Comportamientos_del_Pipeline.md) | `IPipelineBehavior`, construcción del pipeline con Reverse+Aggregate |
| [Procesadores](07%20-%20Procesadores.md) | Procesadores previos y posteriores, conexión con el pipeline |
| [Gestión de Excepciones](08%20-%20Gestion_de_Excepciones.md) | Handlers y actions de excepciones, orden, estrategia |
| [Publicadores de Notificaciones](09%20-%20Publicadores_Notificaciones.md) | `ForeachAwaitPublisher`, `TaskWhenAllPublisher`, publicadores personalizados |
| [Streaming](10%20-%20Streaming.md) | `IStreamRequest`, `IStreamRequestHandler`, comportamientos para streams |
| [Inyección de Dependencias](11%20-%20Inyeccion_de_Dependencias.md) | `AddMediatR`, `MediatRServiceConfiguration`, `ServiceRegistrar`, escaneo, límites de genéricos |
| [Wrappers e Internos](12%20-%20Wrappers_e_Internos.md) | Wrappers de type-erasure, `HandlersOrderer`, `ObjectDetails` |
| [Licenciamiento](13%20-%20Licenciamiento.md) | Sistema de licencias de Lucky Penny — JWT, ediciones, licencias perpetuas |
| [Paquete Contracts](14%20-%20Paquete_Contracts.md) | Paquete NuGet `MediatR.Contracts` y `TypeForwardings` |
| [Ejemplos de Uso](15%20-%20Ejemplos_de_Uso.md) | Escenarios típicos con código: Ping/Pong, notificaciones, streams, excepciones |
| [Integración de Contenedores DI](16%20-%20Integracion_Contenedores_DI.md) | ASP.NET Core, Autofac, DryIoc, Lamar, LightInject, SimpleInjector, Stashbox, Windsor |
| [Build, Tests y Publicación](17%20-%20Build_Tests_Publicacion.md) | `Build.ps1`, `BuildContracts.ps1`, `Push.ps1`, tests, benchmarks, firma |
| [Buenas Prácticas y FAQ](18%20-%20Buenas_Practicas_y_FAQ.md) | Patrones, anti-patrones, preguntas habituales |
| [Glosario](19%20-%20Glosario.md) | Glosario de términos usados en toda la documentación |

---

## Ruta de lectura recomendada

Según tu rol, prioriza distintos documentos:

- **Nuevo desarrollador de aplicación** (usando MediatR en su app): 03 → 04 → 15 → 06 → 07 → 09 → 11 → 18
- **Contribuidor / Mantenedor de la librería**: 01 → 02 → 05 → 12 → 11 → 08 → 13 → 17
- **DevOps / Ingeniero de release**: 02 → 17 → 13 → 14
- **Arquitecto / Responsable de CQRS**: 03 → 06 → 09 → 10 → 18
- **Administrador de licencias / Compras**: 13 → 14 → 18

---

## Visión general

AN.MediatR implementa el **patrón de diseño Mediator (comportamiento)**: los llamadores hablan con una única instancia de `IMediator` en lugar de resolver e invocar handlers directamente. El mediator enruta cada mensaje al handler o handlers correctos a través de un **pipeline de comportamientos transversales** (logging, validación, caching, gestión de excepciones, etc.).

Soporta tres tipos de mensajes:

- **Requests** (`IRequest`, `IRequest<TResponse>`): un llamador → exactamente **un** handler. Pueden devolver una respuesta (`IRequest<TResponse>`) o ser void (`IRequest`).
- **Notificaciones** (`INotification`): un llamador → **cero, uno o muchos** handlers. Sin respuesta.
- **Stream requests** (`IStreamRequest<TResponse>`): un llamador → exactamente un handler que devuelve `IAsyncEnumerable<TResponse>`. Usados para pipelines de streaming.

### Proyectos de la solución

| Proyecto | Tipo | Descripción |
|----------|------|-------------|
| `src/MediatR` | Librería (NuGet) | Mediator principal, pipeline, extensiones DI, **licenciamiento** |
| `src/MediatR.Contracts` | Librería (NuGet) | Contratos mínimos: `IRequest`, `INotification`, `IStreamRequest`, `Unit` |
| `samples/MediatR.Examples` | Ejemplo | Ping/Pong, notificaciones, procesadores, excepciones |
| `samples/MediatR.Examples.AspNetCore` | Ejemplo | Integración con DI de ASP.NET Core |
| `samples/MediatR.Examples.PublishStrategies` | Ejemplo | 6 estrategias de publicación de notificaciones |
| `samples/MediatR.Examples.*` | Ejemplos | Integración con Autofac, DryIoc, Lamar, LightInject, SimpleInjector, Stashbox, Windsor |
| `test/MediatR.Tests` | xUnit | Tests del núcleo |
| `test/MediatR.DependencyInjectionTests` | xUnit | Tests de registro en DI |
| `test/MediatR.Benchmarks` | BenchmarkDotNet | Benchmarks de rendimiento |

---

## Diferencias clave frente al MediatR upstream

| Característica | jbogard/MediatR | AN.MediatR (LuckyPennySoftware) |
|----------------|-----------------|---------------------------------|
| API del mediator | Igual | Igual |
| Pipeline, procesadores, stream requests | Igual | Igual |
| Licencia (código fuente) | Apache-2.0 (≤ v12) / Comercial (v13+) | RPL 1.5 o comercial |
| Clave de licencia en runtime | No | Sí (se registra warning si falta) |
| Validación JWT de licencia | No | Sí (`LicenseAccessor`, `LicenseValidator`) |
| Licencia perpetua | No | Sí (comprobación contra fecha de build) |
| `Mediator.LicenseKey` / `cfg.LicenseKey` | No | Sí |
| Integración con ILogger para licenciamiento | No | Sí (categoría `LuckyPennySoftware.MediatR.License`) |

---

## Cómo leer esta documentación

1. Cada sección vive en su propio archivo Markdown con un prefijo numérico que indica el orden de lectura.
2. Las referencias cruzadas usan enlaces relativos y espacios URL-encoded (p. ej. `01%20-%20Arquitectura.md`).
3. Los fragmentos de código usan los nombres exactos del código real. Las rutas siguen el convenio `src/MediatR/...`.
4. Hay una versión en inglés de esta documentación disponible en [`Docs/en/`](../en/).

---

## Cómo contribuir a esta documentación

- Mantén cada sección sincronizada con el código — revisa tras cambios significativos.
- Referencia las rutas de archivos al documentar detalles de implementación (`src/MediatR/Mediator.cs:42`).
- No dupliques información; enlaza a la sección correspondiente.
- Mantén alineadas las dos versiones (`en` y `es`) cuando añadas o edites contenido.
