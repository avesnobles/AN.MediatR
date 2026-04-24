# Architecture

## Technology stack

| Area | Technology / Version |
|------|----------------------|
| Language | C# 13 (`LangVersion` = `13.0` in `Directory.Build.props`) |
| Runtime | .NET Framework 4.6.2, .NET Standard 2.0, .NET 8, .NET 9, .NET 10 |
| Target frameworks (`MediatR`) | `netstandard2.0;net8.0;net9.0;net10.0;net462` (net462 only on Windows) |
| Target frameworks (`MediatR.Contracts`) | `netstandard2.0` |
| DI abstractions | `Microsoft.Extensions.DependencyInjection.Abstractions` (v10) |
| Logging abstractions | `Microsoft.Extensions.Logging.Abstractions` (v10) |
| JWT | `Microsoft.IdentityModel.JsonWebTokens` (v8.14+) |
| Polyfill | `IsExternalInit` (so `init` works on netstandard2.0 / net462) |
| Source linking | `Microsoft.SourceLink.GitHub` (8.0.0) |
| Versioning | `MinVer` (6.0.0) with tag prefix `v` |
| Signing | Strong-named with `MediatR.snk` |
| Package license | RPL 1.5 (see `LICENSE.md`) — commercial license available |
| Warnings as errors | Yes (`TreatWarningsAsErrors = true`) |
| Documentation XML | Generated (`GenerateDocumentationFile = true`) |
| Deterministic build | Yes (`Deterministic = true`) |

Source: [Directory.Build.props](../../Directory.Build.props), [src/MediatR/MediatR.csproj](../../src/MediatR/MediatR.csproj), [src/MediatR.Contracts/MediatR.Contracts.csproj](../../src/MediatR.Contracts/MediatR.Contracts.csproj).

---

## Repository layout

```
AN.MediatR/
├── MediatR.slnx                    # Solution file (new slnx format)
├── MediatR.snk                     # Strong-name signing key
├── Directory.Build.props           # Shared MSBuild props for all projects
├── Build.ps1                       # Clean + build + test + pack MediatR
├── BuildContracts.ps1              # Build + pack MediatR.Contracts
├── Push.ps1                        # Push .nupkg to NuGet feed
├── NuGet.Config                    # NuGet feed configuration
├── LICENSE.md                      # RPL 1.5 + commercial license notice
├── README.md                       # Quickstart / NuGet README
├── assets/                         # Logo assets (package icon)
├── src/
│   ├── MediatR/                    # Main library (pipeline, wrappers, DI, licensing)
│   │   ├── Entities/               # OpenBehavior (registration entity)
│   │   ├── Internal/               # HandlersOrderer, ObjectDetails
│   │   ├── Licensing/              # BuildInfo, Edition, License, LicenseAccessor, LicenseValidator, ProductType
│   │   ├── MicrosoftExtensionsDI/  # AddMediatR extension, service configuration
│   │   ├── NotificationPublishers/ # ForeachAwaitPublisher, TaskWhenAllPublisher
│   │   ├── Pipeline/               # Pre/Post/Exception processors + interfaces
│   │   ├── Registration/           # ServiceRegistrar (reflection-based scanning)
│   │   ├── Wrappers/               # Type-erasure wrappers for handlers
│   │   ├── IMediator.cs, ISender.cs, IPublisher.cs
│   │   ├── IRequestHandler.cs, INotificationHandler.cs, IStreamRequestHandler.cs
│   │   ├── IPipelineBehavior.cs, IStreamPipelineBehavior.cs
│   │   ├── INotificationPublisher.cs, NotificationHandlerExecutor.cs
│   │   ├── Mediator.cs             # Default IMediator implementation
│   │   ├── TypeForwardings.cs      # Forwards IRequest, INotification, Unit to MediatR.Contracts
│   │   ├── license.txt             # Embedded license text
│   │   └── MediatR.csproj
│   └── MediatR.Contracts/          # Minimal contracts package (Apache-2.0)
│       ├── IRequest.cs             # IBaseRequest, IRequest, IRequest<TResponse>
│       ├── INotification.cs
│       ├── IStreamRequest.cs
│       ├── Unit.cs
│       └── MediatR.Contracts.csproj
├── samples/
│   ├── MediatR.Examples/           # Base samples: Ping/Pong, processors, exceptions, streams
│   ├── MediatR.Examples.AspNetCore/
│   ├── MediatR.Examples.Autofac/
│   ├── MediatR.Examples.DryIoc/
│   ├── MediatR.Examples.Lamar/
│   ├── MediatR.Examples.LightInject/
│   ├── MediatR.Examples.PublishStrategies/  # 6 notification publishing strategies
│   ├── MediatR.Examples.SimpleInjector/
│   ├── MediatR.Examples.Stashbox/
│   └── MediatR.Examples.Windsor/
└── test/
    ├── MediatR.Benchmarks/         # BenchmarkDotNet performance tests
    ├── MediatR.DependencyInjectionTests/
    └── MediatR.Tests/              # Core xUnit tests
```

---

## Architectural layers

AN.MediatR is deliberately small. At the highest level, the library is organized in five conceptual layers:

### 1. Contracts (public API)

Located mostly in `src/MediatR.Contracts/` and partially in `src/MediatR/`.

**Purpose**: Declare marker interfaces that request, notification, and stream message types implement. No behavior.

Key types:

- `IBaseRequest`, `IRequest`, `IRequest<TResponse>`, `IStreamRequest<TResponse>`, `INotification`, `Unit`.
- The handler interfaces also live in `src/MediatR/`: `IRequestHandler`, `INotificationHandler`, `IStreamRequestHandler`.
- Pipeline contracts: `IPipelineBehavior`, `IStreamPipelineBehavior`, `IRequestPreProcessor`, `IRequestPostProcessor`, `IRequestExceptionHandler`, `IRequestExceptionAction`, `INotificationPublisher`.

### 2. Mediator core

`src/MediatR/Mediator.cs`.

The `Mediator` class implements `IMediator` (which extends both `ISender` and `IPublisher`). It caches handler wrappers in static `ConcurrentDictionary<Type, ...>` instances and dispatches messages through type-erased wrappers.

### 3. Wrappers (type erasure)

`src/MediatR/Wrappers/`.

`RequestHandlerWrapper`, `NotificationHandlerWrapper`, and `StreamRequestHandlerWrapper` translate strongly-typed generic handler calls into a uniform non-generic delegate, so all dispatched messages can share the same cache.

### 4. Pipeline

`src/MediatR/Pipeline/`.

Pipeline behaviors (`IPipelineBehavior<TRequest, TResponse>`) form a chain around each request handler. Pre/post-processors and exception handlers/actions are implemented as dedicated `IPipelineBehavior` decorators:

- `RequestPreProcessorBehavior<,>` → runs `IRequestPreProcessor<>` before the handler.
- `RequestPostProcessorBehavior<,>` → runs `IRequestPostProcessor<,>` after the handler.
- `RequestExceptionProcessorBehavior<,>` → dispatches thrown exceptions to `IRequestExceptionHandler<,,>`.
- `RequestExceptionActionProcessorBehavior<,>` → dispatches thrown exceptions to `IRequestExceptionAction<,>` (observational — always rethrows).

### 5. Registration + Licensing

`src/MediatR/Registration/` + `src/MediatR/MicrosoftExtensionsDI/` + `src/MediatR/Licensing/`.

- `ServiceRegistrar` performs **reflection-based assembly scanning** and registers concrete/open-generic handlers, behaviors, processors and exception handlers into an `IServiceCollection`.
- `MediatRServiceCollectionExtensions.AddMediatR(...)` is the entry point developers call.
- `LicenseAccessor` reads the license key, validates its JWT signature with a hardcoded RSA public key, and exposes a `License` object. `LicenseValidator` inspects that license (edition, product type, expiration, perpetual flag) and logs warnings/errors accordingly.

---

## High-level request flow

```
Caller
  │
  │  mediator.Send(new Ping { Message = "hi" })
  ▼
Mediator.Send<TResponse>(IRequest<TResponse>)
  │
  │  (1) cache lookup by request type
  ▼
RequestHandlerWrapperImpl<Ping, Pong>  ◄── Activator.CreateInstance
  │
  │  (2) sp.GetServices<IPipelineBehavior<Ping, Pong>>().Reverse().Aggregate(...)
  ▼
[Behavior N] → [Behavior N-1] → ... → [Behavior 1] → Handler
      ^                                                  │
      └──────────────  await/return  ────────────────────┘
```

For notifications the flow fans out across handlers and is fed to an `INotificationPublisher` (sequential or parallel).

For streaming, the pipeline is wrapped in a chain of `IStreamPipelineBehavior<,>` and the return type is `IAsyncEnumerable<TResponse>`.

---

## Design principles

1. **Static, application-wide caching** — handler wrappers and notification wrappers are cached in `static ConcurrentDictionary<Type, ...>` on the `Mediator` class. This keeps dispatch allocation-free on steady state.
2. **Type erasure via wrappers** — instead of invoking handlers via reflection on every call, reflection is used once to create a generic wrapper, then the cached wrapper is called via virtual dispatch.
3. **Minimal dependencies** — only the `Microsoft.Extensions.*.Abstractions` + JWT library. No DI container is mandatory; any container that exposes `IServiceProvider` works.
4. **Convention over configuration** — `AddMediatR(cfg => cfg.RegisterServicesFromAssembly(...))` automatically discovers and registers every handler. Explicit registration is still possible (and preferred for open-generic behaviors).
5. **Pipeline as middleware** — behaviors compose via `Reverse().Aggregate(handler, (next, b) => t => b.Handle(req, next, t))()`, producing a Russian-doll chain similar to ASP.NET Core middleware.
6. **Opinionated handler ordering** — for exception handlers and actions, `HandlersOrderer` prioritizes handlers by assembly and namespace proximity to the request type, mimicking how a developer would expect local handlers to win over generic ones.
7. **Licensing is transparent but non-blocking** — missing/invalid license keys produce logged warnings but never break the app. This makes the library usable during development and CI.

---

## Namespaces

| Namespace | Purpose |
|-----------|---------|
| `MediatR` | Public interfaces and the `Mediator` implementation |
| `MediatR.Wrappers` | Internal type-erasure wrappers |
| `MediatR.Pipeline` | Pipeline interfaces + pre/post/exception behaviors |
| `MediatR.NotificationPublishers` | Built-in publisher strategies |
| `MediatR.Registration` | `ServiceRegistrar` (assembly scanning) |
| `MediatR.Licensing` | Licensing types (all `internal`) |
| `MediatR.Entities` | `OpenBehavior` registration entity |
| `MediatR.Internal` | `HandlersOrderer`, `ObjectDetails` (internal helpers) |
| `Microsoft.Extensions.DependencyInjection` | `AddMediatR` extension + `MediatRServiceConfiguration` + `RequestExceptionActionProcessorStrategy` |

Note the deliberate decision to place the DI extensions in the `Microsoft.Extensions.DependencyInjection` namespace so `AddMediatR` appears as a first-class service collection extension without additional `using` statements.

---

## Build artifacts

The build produces two NuGet packages:

| Package | Path on NuGet | License | Depends on |
|---------|---------------|---------|------------|
| `MediatR` | https://www.nuget.org/packages/MediatR | RPL 1.5 or commercial | `MediatR.Contracts`, `Microsoft.Extensions.*.Abstractions`, `Microsoft.IdentityModel.JsonWebTokens` |
| `MediatR.Contracts` | https://www.nuget.org/packages/MediatR.Contracts | Apache-2.0 | — |

The contracts package is intentionally free (Apache-2.0) so that request/notification types can be defined in libraries, API-contract assemblies, Blazor WASM clients, or gRPC contract projects without pulling in the main licensed library.

See [Contracts Package](14%20-%20Contracts_Package.md) for details.
