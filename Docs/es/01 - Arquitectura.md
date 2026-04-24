# Arquitectura

## Stack tecnológico

| Área | Tecnología / Versión |
|------|----------------------|
| Lenguaje | C# 13 (`LangVersion` = `13.0` en `Directory.Build.props`) |
| Runtime | .NET Framework 4.6.2, .NET Standard 2.0, .NET 8, .NET 9, .NET 10 |
| Frameworks destino (`MediatR`) | `netstandard2.0;net8.0;net9.0;net10.0;net462` (net462 solo en Windows) |
| Frameworks destino (`MediatR.Contracts`) | `netstandard2.0` |
| Abstracciones DI | `Microsoft.Extensions.DependencyInjection.Abstractions` (v10) |
| Abstracciones de logging | `Microsoft.Extensions.Logging.Abstractions` (v10) |
| JWT | `Microsoft.IdentityModel.JsonWebTokens` (v8.14+) |
| Polyfill | `IsExternalInit` (para que `init` funcione en netstandard2.0 / net462) |
| Source linking | `Microsoft.SourceLink.GitHub` (8.0.0) |
| Versionado | `MinVer` (6.0.0) con prefijo de tag `v` |
| Firma | Strong-named con `MediatR.snk` |
| Licencia del paquete | RPL 1.5 (ver `LICENSE.md`) — licencia comercial disponible |
| Warnings como errores | Sí (`TreatWarningsAsErrors = true`) |
| XML de documentación | Generado (`GenerateDocumentationFile = true`) |
| Build determinista | Sí (`Deterministic = true`) |

Fuentes: [Directory.Build.props](../../Directory.Build.props), [src/MediatR/MediatR.csproj](../../src/MediatR/MediatR.csproj), [src/MediatR.Contracts/MediatR.Contracts.csproj](../../src/MediatR.Contracts/MediatR.Contracts.csproj).

---

## Estructura del repositorio

```
AN.MediatR/
├── MediatR.slnx                    # Archivo de solución (formato slnx nuevo)
├── MediatR.snk                     # Clave de firma strong-name
├── Directory.Build.props           # Props de MSBuild compartidas por todos los proyectos
├── Build.ps1                       # Clean + build + test + pack MediatR
├── BuildContracts.ps1              # Build + pack MediatR.Contracts
├── Push.ps1                        # Push de .nupkg al feed NuGet
├── NuGet.Config                    # Configuración del feed NuGet
├── LICENSE.md                      # Aviso de licencia RPL 1.5 + comercial
├── README.md                       # Quickstart / README del paquete NuGet
├── assets/                         # Recursos del logo (icono del paquete)
├── src/
│   ├── MediatR/                    # Librería principal (pipeline, wrappers, DI, licenciamiento)
│   │   ├── Entities/               # OpenBehavior (entidad de registro)
│   │   ├── Internal/               # HandlersOrderer, ObjectDetails
│   │   ├── Licensing/              # BuildInfo, Edition, License, LicenseAccessor, LicenseValidator, ProductType
│   │   ├── MicrosoftExtensionsDI/  # Extensión AddMediatR, configuración del servicio
│   │   ├── NotificationPublishers/ # ForeachAwaitPublisher, TaskWhenAllPublisher
│   │   ├── Pipeline/               # Procesadores Pre/Post/Excepciones + interfaces
│   │   ├── Registration/           # ServiceRegistrar (escaneo por reflexión)
│   │   ├── Wrappers/               # Wrappers de type-erasure para handlers
│   │   ├── IMediator.cs, ISender.cs, IPublisher.cs
│   │   ├── IRequestHandler.cs, INotificationHandler.cs, IStreamRequestHandler.cs
│   │   ├── IPipelineBehavior.cs, IStreamPipelineBehavior.cs
│   │   ├── INotificationPublisher.cs, NotificationHandlerExecutor.cs
│   │   ├── Mediator.cs             # Implementación por defecto de IMediator
│   │   ├── TypeForwardings.cs      # Redirige IRequest, INotification, Unit a MediatR.Contracts
│   │   ├── license.txt             # Texto de licencia embebido
│   │   └── MediatR.csproj
│   └── MediatR.Contracts/          # Paquete mínimo de contratos (Apache-2.0)
│       ├── IRequest.cs             # IBaseRequest, IRequest, IRequest<TResponse>
│       ├── INotification.cs
│       ├── IStreamRequest.cs
│       ├── Unit.cs
│       └── MediatR.Contracts.csproj
├── samples/
│   ├── MediatR.Examples/           # Ejemplos base: Ping/Pong, procesadores, excepciones, streams
│   ├── MediatR.Examples.AspNetCore/
│   ├── MediatR.Examples.Autofac/
│   ├── MediatR.Examples.DryIoc/
│   ├── MediatR.Examples.Lamar/
│   ├── MediatR.Examples.LightInject/
│   ├── MediatR.Examples.PublishStrategies/  # 6 estrategias de publicación
│   ├── MediatR.Examples.SimpleInjector/
│   ├── MediatR.Examples.Stashbox/
│   └── MediatR.Examples.Windsor/
└── test/
    ├── MediatR.Benchmarks/         # Pruebas de rendimiento con BenchmarkDotNet
    ├── MediatR.DependencyInjectionTests/
    └── MediatR.Tests/              # Tests xUnit del núcleo
```

---

## Capas arquitectónicas

AN.MediatR es deliberadamente pequeño. En alto nivel, la librería se organiza en cinco capas conceptuales:

### 1. Contratos (API pública)

Principalmente en `src/MediatR.Contracts/` y parcialmente en `src/MediatR/`.

**Propósito**: declarar las interfaces marcador que implementan los tipos de request, notificación y stream. Sin comportamiento.

Tipos clave:

- `IBaseRequest`, `IRequest`, `IRequest<TResponse>`, `IStreamRequest<TResponse>`, `INotification`, `Unit`.
- Las interfaces de handler viven también en `src/MediatR/`: `IRequestHandler`, `INotificationHandler`, `IStreamRequestHandler`.
- Contratos del pipeline: `IPipelineBehavior`, `IStreamPipelineBehavior`, `IRequestPreProcessor`, `IRequestPostProcessor`, `IRequestExceptionHandler`, `IRequestExceptionAction`, `INotificationPublisher`.

### 2. Núcleo del mediator

`src/MediatR/Mediator.cs`.

La clase `Mediator` implementa `IMediator` (que extiende `ISender` y `IPublisher`). Cachea wrappers de handlers en instancias estáticas de `ConcurrentDictionary<Type, ...>` y despacha mensajes a través de wrappers con tipo eliminado (type-erased).

### 3. Wrappers (type erasure)

`src/MediatR/Wrappers/`.

`RequestHandlerWrapper`, `NotificationHandlerWrapper` y `StreamRequestHandlerWrapper` traducen llamadas a handlers genéricos fuertemente tipados en un delegate no-genérico uniforme, de forma que todos los mensajes compartan la misma caché.

### 4. Pipeline

`src/MediatR/Pipeline/`.

Los comportamientos (`IPipelineBehavior<TRequest, TResponse>`) forman una cadena alrededor de cada handler. Los procesadores pre/post y los manejadores de excepciones se implementan como decoradores `IPipelineBehavior` dedicados:

- `RequestPreProcessorBehavior<,>` → ejecuta `IRequestPreProcessor<>` antes del handler.
- `RequestPostProcessorBehavior<,>` → ejecuta `IRequestPostProcessor<,>` después del handler.
- `RequestExceptionProcessorBehavior<,>` → dirige excepciones lanzadas hacia `IRequestExceptionHandler<,,>`.
- `RequestExceptionActionProcessorBehavior<,>` → dirige excepciones hacia `IRequestExceptionAction<,>` (observacional — siempre relanza).

### 5. Registro + Licenciamiento

`src/MediatR/Registration/` + `src/MediatR/MicrosoftExtensionsDI/` + `src/MediatR/Licensing/`.

- `ServiceRegistrar` realiza **escaneo de ensamblados por reflexión** y registra handlers concretos y de genéricos abiertos, comportamientos, procesadores y handlers de excepciones en un `IServiceCollection`.
- `MediatRServiceCollectionExtensions.AddMediatR(...)` es el punto de entrada que invocan los desarrolladores.
- `LicenseAccessor` lee la clave de licencia, valida su firma JWT con una clave RSA pública hardcodeada y expone un objeto `License`. `LicenseValidator` inspecciona esa licencia (edición, tipo de producto, expiración, bandera perpetua) y registra warnings/errores según corresponda.

---

## Flujo de petición (alto nivel)

```
Llamador
  │
  │  mediator.Send(new Ping { Message = "hi" })
  ▼
Mediator.Send<TResponse>(IRequest<TResponse>)
  │
  │  (1) búsqueda en caché por tipo de request
  ▼
RequestHandlerWrapperImpl<Ping, Pong>  ◄── Activator.CreateInstance
  │
  │  (2) sp.GetServices<IPipelineBehavior<Ping, Pong>>().Reverse().Aggregate(...)
  ▼
[Behavior N] → [Behavior N-1] → ... → [Behavior 1] → Handler
      ^                                                  │
      └──────────────  await/return  ────────────────────┘
```

Para notificaciones, el flujo se abre en abanico sobre los handlers y se entrega a un `INotificationPublisher` (secuencial o paralelo).

Para streaming, el pipeline se envuelve en una cadena de `IStreamPipelineBehavior<,>` y el tipo de retorno es `IAsyncEnumerable<TResponse>`.

---

## Principios de diseño

1. **Caching estático a nivel de aplicación** — los wrappers de handlers y notificaciones se cachean en `static ConcurrentDictionary<Type, ...>` en la clase `Mediator`. Esto hace que el dispatch en estado estable sea casi libre de asignaciones.
2. **Type erasure mediante wrappers** — en lugar de invocar handlers por reflexión en cada llamada, la reflexión se usa una vez para crear un wrapper genérico; luego se llama al wrapper cacheado por despacho virtual.
3. **Dependencias mínimas** — solo `Microsoft.Extensions.*.Abstractions` + librería JWT. No se requiere ningún contenedor DI: cualquier contenedor que exponga `IServiceProvider` funciona.
4. **Convención sobre configuración** — `AddMediatR(cfg => cfg.RegisterServicesFromAssembly(...))` descubre y registra automáticamente todos los handlers. El registro explícito sigue siendo posible (y preferible para comportamientos de genéricos abiertos).
5. **Pipeline como middleware** — los comportamientos se componen con `Reverse().Aggregate(handler, (next, b) => t => b.Handle(req, next, t))()`, produciendo una cadena tipo matrioska similar al middleware de ASP.NET Core.
6. **Orden opinado de handlers** — para handlers y actions de excepciones, `HandlersOrderer` prioriza por proximidad de ensamblado y namespace al tipo de request, imitando cómo un desarrollador esperaría que los handlers locales ganen a los genéricos.
7. **El licenciamiento es transparente pero no bloqueante** — una clave ausente o inválida produce warnings en el log pero nunca rompe la app. Esto permite usar la librería en desarrollo y CI sin fricción.

---

## Namespaces

| Namespace | Propósito |
|-----------|-----------|
| `MediatR` | Interfaces públicas y la implementación `Mediator` |
| `MediatR.Wrappers` | Wrappers internos de type-erasure |
| `MediatR.Pipeline` | Interfaces del pipeline + comportamientos pre/post/excepciones |
| `MediatR.NotificationPublishers` | Estrategias built-in de publicación |
| `MediatR.Registration` | `ServiceRegistrar` (escaneo de ensamblados) |
| `MediatR.Licensing` | Tipos de licenciamiento (todos `internal`) |
| `MediatR.Entities` | Entidad de registro `OpenBehavior` |
| `MediatR.Internal` | `HandlersOrderer`, `ObjectDetails` (helpers internos) |
| `Microsoft.Extensions.DependencyInjection` | Extensión `AddMediatR` + `MediatRServiceConfiguration` + `RequestExceptionActionProcessorStrategy` |

Nota la decisión deliberada de colocar las extensiones DI en el namespace `Microsoft.Extensions.DependencyInjection` para que `AddMediatR` aparezca como una extensión de primera clase sin `using` adicionales.

---

## Artefactos de build

El build produce dos paquetes NuGet:

| Paquete | Ruta en NuGet | Licencia | Depende de |
|---------|---------------|----------|------------|
| `MediatR` | https://www.nuget.org/packages/MediatR | RPL 1.5 o comercial | `MediatR.Contracts`, `Microsoft.Extensions.*.Abstractions`, `Microsoft.IdentityModel.JsonWebTokens` |
| `MediatR.Contracts` | https://www.nuget.org/packages/MediatR.Contracts | Apache-2.0 | — |

El paquete de contratos es intencionalmente libre (Apache-2.0) para que los tipos de request/notificación se puedan definir en librerías de contratos API, ensamblados gRPC, clientes Blazor WASM o proyectos de contrato sin arrastrar la librería principal con licencia.

Ver [Paquete Contracts](14%20-%20Paquete_Contracts.md) para más detalles.
