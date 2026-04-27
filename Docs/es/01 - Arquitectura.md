# Arquitectura

## Stack tecnológico

| Área | Tecnología / Versión |
|------|----------------------|
| Lenguaje | C# 13 (`LangVersion` = `13.0` en `Directory.Build.props`) |
| Runtime | .NET Standard 2.0, .NET 8, .NET 9, .NET 10, .NET Framework 4.6.2 (solo Windows) |
| Frameworks destino (`MediatR`) | `netstandard2.0;net8.0;net9.0;net10.0` (+ `net462` en Windows) |
| Frameworks destino (`MediatR.Contracts`) | `netstandard2.0` |
| Abstracciones DI | `Microsoft.Extensions.DependencyInjection.Abstractions` (v10.0.0) |
| Polyfill | `IsExternalInit` (para que `init` funcione en netstandard2.0) |
| Polyfill asíncrono | `Microsoft.Bcl.AsyncInterfaces` (v10.0.0, solo en netstandard2.0) |
| Source linking | `Microsoft.SourceLink.GitHub` (8.0.0) |
| Versionado | `MinVer` (6.0.0) con prefijo de tag `v` |
| Firma | Strong-named con `MediatR.snk` |
| Licencia del paquete | **Apache-2.0** (tanto `MediatR` como `MediatR.Contracts`) |
| Warnings como errores | Sí (`TreatWarningsAsErrors = true`) |
| XML de documentación | Generado (`GenerateDocumentationFile = true`) |
| Build determinista | Sí (`Deterministic = true`) |

Fuentes: [Directory.Build.props](../../Directory.Build.props), [src/MediatR/MediatR.csproj](../../src/MediatR/MediatR.csproj), [src/MediatR.Contracts/MediatR.Contracts.csproj](../../src/MediatR.Contracts/MediatR.Contracts.csproj).

> **Punto de partida del fork**: AN.MediatR arranca desde **MediatR v12.5** (`jbogard/MediatR`, Apache-2.0). El equipo AN también ha portado selectivamente mejoras no-relacionadas-con-licenciamiento desde el upstream v13+ (resiliencia del scanner ante ensamblados F#, soporte de behaviors con tipo de respuesta genérico anidado, deduplicación de handlers de notificaciones, TFMs más nuevos). El subsistema de licenciamiento del upstream **no** se ha portado a propósito.

---

## Estructura del repositorio

```
AN.MediatR/
├── MediatR.sln                     # Archivo de solución (formato sln clásico)
├── MediatR.snk                     # Clave de firma strong-name
├── Directory.Build.props           # Props de MSBuild compartidas
├── Build.ps1                       # Clean + build + test + pack MediatR
├── BuildContracts.ps1              # Build + pack MediatR.Contracts
├── Push.ps1                        # Push de .nupkg al feed NuGet
├── NuGet.Config                    # Configuración del feed NuGet
├── LICENSE                         # Texto Apache-2.0
├── README.md                       # Quickstart
├── Docs/                           # Esta documentación (en + es)
├── assets/                         # Recursos del logo (icono del paquete)
├── src/
│   ├── MediatR/                    # Librería principal (pipeline, wrappers, DI)
│   │   ├── Entities/               # OpenBehavior
│   │   ├── Internal/               # HandlersOrderer, ObjectDetails
│   │   ├── MicrosoftExtensionsDI/  # AddMediatR, configuración
│   │   ├── NotificationPublishers/ # ForeachAwaitPublisher, TaskWhenAllPublisher
│   │   ├── Pipeline/               # Pre/Post/Excepciones + interfaces
│   │   ├── Registration/           # ServiceRegistrar (escaneo reflexivo)
│   │   ├── Wrappers/               # Wrappers de type-erasure
│   │   ├── IMediator.cs, ISender.cs, IPublisher.cs
│   │   ├── IRequestHandler.cs, INotificationHandler.cs, IStreamRequestHandler.cs
│   │   ├── IPipelineBehavior.cs, IStreamPipelineBehavior.cs
│   │   ├── INotificationPublisher.cs, NotificationHandlerExecutor.cs
│   │   ├── Mediator.cs             # Implementación por defecto de IMediator
│   │   ├── TypeForwardings.cs      # Redirige IRequest, INotification, Unit a MediatR.Contracts
│   │   └── MediatR.csproj
│   └── MediatR.Contracts/          # Paquete mínimo (Apache-2.0)
│       ├── IRequest.cs
│       ├── INotification.cs
│       ├── IStreamRequest.cs
│       ├── Unit.cs
│       └── MediatR.Contracts.csproj
├── samples/                        # 10 proyectos de ejemplo
└── test/
    ├── MediatR.Benchmarks/         # Benchmarks con BenchmarkDotNet
    └── MediatR.Tests/              # Tests xUnit (incluye registro DI)
```

---

## Capas arquitectónicas

AN.MediatR es deliberadamente pequeño. En alto nivel, se organiza en cuatro capas conceptuales:

### 1. Contratos (API pública)

Principalmente en `src/MediatR.Contracts/` y parcialmente en `src/MediatR/`.

**Propósito**: declarar las interfaces marcador que implementan los tipos de request, notificación y stream. Sin comportamiento.

Tipos clave: `IBaseRequest`, `IRequest`, `IRequest<TResponse>`, `IStreamRequest<TResponse>`, `INotification`, `Unit`. Interfaces de handler y pipeline: `IRequestHandler`, `INotificationHandler`, `IStreamRequestHandler`, `IPipelineBehavior`, `IStreamPipelineBehavior`, `IRequestPreProcessor`, `IRequestPostProcessor`, `IRequestExceptionHandler`, `IRequestExceptionAction`, `INotificationPublisher`.

### 2. Núcleo del mediator

`src/MediatR/Mediator.cs`.

La clase `Mediator` implementa `IMediator`, cachea wrappers en `ConcurrentDictionary<Type, ...>` estáticos y despacha mensajes con tipo borrado.

### 3. Wrappers (type erasure)

`src/MediatR/Wrappers/`. `RequestHandlerWrapper`, `NotificationHandlerWrapper` y `StreamRequestHandlerWrapper` traducen llamadas genéricas a un delegate no-genérico uniforme.

### 4. Pipeline + Registro

`src/MediatR/Pipeline/` + `src/MediatR/Registration/` + `src/MediatR/MicrosoftExtensionsDI/`.

Los behaviors forman una cadena alrededor de cada handler. Procesadores pre/post y handlers/actions de excepciones se implementan como decoradores `IPipelineBehavior`:

- `RequestPreProcessorBehavior<,>` → ejecuta `IRequestPreProcessor<>` antes.
- `RequestPostProcessorBehavior<,>` → ejecuta `IRequestPostProcessor<,>` después.
- `RequestExceptionProcessorBehavior<,>` → dirige excepciones hacia `IRequestExceptionHandler<,,>`.
- `RequestExceptionActionProcessorBehavior<,>` → dirige hacia `IRequestExceptionAction<,>` (observacional — siempre relanza).

`ServiceRegistrar` realiza **escaneo de ensamblados por reflexión**. `ServiceCollectionExtensions.AddMediatR(...)` es el punto de entrada.

---

## Flujo de petición (alto nivel)

```
Llamador
  │  mediator.Send(new Ping { Message = "hi" })
  ▼
Mediator.Send<TResponse>(IRequest<TResponse>)
  │  (1) lookup en caché por tipo de request
  ▼
RequestHandlerWrapperImpl<Ping, Pong>  ◄── Activator.CreateInstance
  │  (2) sp.GetServices<IPipelineBehavior<Ping, Pong>>().Reverse().Aggregate(...)
  ▼
[Behavior N] → ... → [Behavior 1] → Handler
      ^                                │
      └─── await/return ───────────────┘
```

---

## Principios de diseño

1. **Caching estático a nivel de aplicación** — wrappers cacheados en `static ConcurrentDictionary<Type, ...>`.
2. **Type erasure mediante wrappers** — reflexión una vez, llamadas virtuales después.
3. **Dependencias mínimas** — solo `Microsoft.Extensions.DependencyInjection.Abstractions` en runtime. Sin JWT, sin logging, sin red.
4. **Convención sobre configuración** — `AddMediatR(cfg => cfg.RegisterServicesFromAssembly(...))` descubre todo.
5. **Pipeline como middleware** — composición con `Reverse().Aggregate(handler, (next, b) => t => b.Handle(req, next, t))()`.
6. **Orden opinado de handlers** — `HandlersOrderer` prioriza por proximidad de ensamblado y namespace.
7. **Sin validación de licencia en runtime** — a diferencia del upstream v13+, AN.MediatR no valida JWTs ni emite mensajes de licencia. Apache-2.0 en todo.

---

## Namespaces

| Namespace | Propósito |
|-----------|-----------|
| `MediatR` | Interfaces públicas y la implementación `Mediator` |
| `MediatR.Wrappers` | Wrappers internos de type-erasure |
| `MediatR.Pipeline` | Interfaces del pipeline + behaviors pre/post/excepciones |
| `MediatR.NotificationPublishers` | Estrategias built-in de publicación |
| `MediatR.Registration` | `ServiceRegistrar` |
| `MediatR.Entities` | `OpenBehavior` |
| `MediatR.Internal` | `HandlersOrderer`, `ObjectDetails` |
| `Microsoft.Extensions.DependencyInjection` | `AddMediatR`, `MediatRServiceConfiguration`, `RequestExceptionActionProcessorStrategy` |

---

## Artefactos de build

Dos paquetes NuGet:

| Paquete | Licencia | Depende de |
|---------|----------|------------|
| `MediatR` | Apache-2.0 | `MediatR.Contracts`, `Microsoft.Extensions.DependencyInjection.Abstractions` |
| `MediatR.Contracts` | Apache-2.0 | — |

Ambos son totalmente Apache-2.0. Ver [Paquete Contracts](13%20-%20Paquete_Contracts.md) para el motivo de la separación.
