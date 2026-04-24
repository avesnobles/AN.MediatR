# Documentación de AN.MediatR

Bienvenido a la documentación completa de **AN.MediatR**, un fork libre y de código abierto de la conocida librería [MediatR](https://github.com/jbogard/MediatR) creada originalmente por **Jimmy Bogard**.

Este fork parte de **MediatR v12.5** — la **última versión publicada bajo Apache-2.0** antes de que el proyecto upstream pasara a un modelo de licenciamiento comercial — y es mantenido por el equipo de **Aves Nobles (AN)**. A partir de v12.5, AN.MediatR diverge del upstream `jbogard/MediatR` y evoluciona como una librería open-source independiente.

AN.MediatR es una **implementación simple y sin pretensiones del patrón Mediator para .NET**. Proporciona mensajería en proceso con cero dependencias externas más allá de `Microsoft.Extensions.DependencyInjection.Abstractions`, soportando petición/respuesta, comandos, consultas, notificaciones, eventos y streaming — tanto síncronos como asíncronos — con dispatching inteligente gracias a la varianza genérica de C#.

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
| [Paquete Contracts](13%20-%20Paquete_Contracts.md) | Paquete NuGet `MediatR.Contracts` y `TypeForwardings` |
| [Ejemplos de Uso](14%20-%20Ejemplos_de_Uso.md) | Escenarios típicos con código: Ping/Pong, notificaciones, streams, excepciones |
| [Integración de Contenedores DI](15%20-%20Integracion_Contenedores_DI.md) | ASP.NET Core, Autofac, DryIoc, Lamar, LightInject, SimpleInjector, Stashbox, Windsor |
| [Build, Tests y Publicación](16%20-%20Build_Tests_Publicacion.md) | `Build.ps1`, `BuildContracts.ps1`, `Push.ps1`, tests, benchmarks |
| [Buenas Prácticas y FAQ](17%20-%20Buenas_Practicas_y_FAQ.md) | Patrones, anti-patrones, preguntas habituales |
| [Glosario](18%20-%20Glosario.md) | Glosario de términos usados en toda la documentación |

---

## Ruta de lectura recomendada

Según tu rol, prioriza distintos documentos:

- **Nuevo desarrollador de aplicación** (usando MediatR en su app): 03 → 04 → 14 → 06 → 07 → 09 → 11 → 17
- **Contribuidor / Mantenedor de la librería**: 01 → 02 → 05 → 12 → 11 → 08 → 16
- **DevOps / Ingeniero de release**: 02 → 16 → 13
- **Arquitecto / Responsable de CQRS**: 03 → 06 → 09 → 10 → 17

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
| `src/MediatR` | Librería (NuGet) | Mediator principal, pipeline, extensiones DI |
| `src/MediatR.Contracts` | Librería (NuGet) | Contratos mínimos: `IRequest`, `INotification`, `IStreamRequest`, `Unit` |
| `samples/MediatR.Examples` | Ejemplo | Ping/Pong, notificaciones, procesadores, excepciones |
| `samples/MediatR.Examples.AspNetCore` | Ejemplo | Integración con DI de ASP.NET Core |
| `samples/MediatR.Examples.PublishStrategies` | Ejemplo | 6 estrategias de publicación de notificaciones |
| `samples/MediatR.Examples.*` | Ejemplos | Integración con Autofac, DryIoc, Lamar, LightInject, SimpleInjector, Stashbox, Windsor |
| `test/MediatR.Tests` | xUnit | Tests del núcleo + registro en DI |
| `test/MediatR.Benchmarks` | BenchmarkDotNet | Benchmarks de rendimiento |

---

## Licenciamiento y relación con el upstream

| Aspecto | AN.MediatR (este fork) | jbogard/MediatR v12.5 (origen) | jbogard/MediatR v13+ |
|---------|------------------------|--------------------------------|----------------------|
| Licencia | **Apache-2.0** | Apache-2.0 | Dual RPL-1.5 / comercial, con licenciamiento JWT |
| Comprobación de licencia en runtime | ❌ Ninguna | ❌ Ninguna | ✅ Validación JWT, warnings si falta |
| Mantenedor | Aves Nobles (AN) | Jimmy Bogard (estado upstream en v12.5) | Lucky Penny Software |
| Dirección futura | Fork open-source independiente | N/A (abandonado en esa versión) | Producto comercial |

**Por qué hemos forkeado**: queríamos una librería mediator con la misma semántica que la MediatR que conocen la mayoría de desarrolladores .NET, pero:
- manteniéndola totalmente open-source (Apache-2.0);
- sin sistema de licenciamiento en runtime;
- libre para evolucionar según las necesidades de nuestros proyectos.

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
