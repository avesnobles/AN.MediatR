# Estructura del Proyecto

Este documento enumera cada proyecto de la solución `MediatR.sln`, su propósito, dependencias y relación con el resto del código. Complementa [Arquitectura](01%20-%20Arquitectura.md).

---

## Visión general de la solución

AN.MediatR se organiza en tres carpetas principales dentro del repositorio:

| Carpeta | Contenido |
|---------|-----------|
| `src/` | Los dos paquetes NuGet: `MediatR` y `MediatR.Contracts` |
| `samples/` | Diez proyectos de ejemplo con patrones de integración |
| `test/` | Dos proyectos de test (unidad/DI, benchmarks) |

---

## `src/` — Código de producción

### `src/MediatR/MediatR.csproj`

La librería principal. Produce el paquete NuGet `MediatR`.

- **Frameworks destino**: `netstandard2.0;net8.0;net9.0;net10.0` (más `net462` en Windows).
- **Nullable**: activado.
- **Strong-named**: sí, mediante `..\..\MediatR.snk`.
- **Documentación XML**: generada (`GenerateDocumentationFile = true`).
- **Metadatos del paquete**: icono, README, licencia Apache-2.0, URL del proyecto.
- **Versionado**: `MinVer` con prefijo de tag `v` (p. ej. `v12.5.0`).
- **Dependencias**:
  - `IsExternalInit` (solo dev) — permite propiedades `init` en `netstandard2.0`.
  - `MediatR.Contracts` (versión `[2.0.1, 3.0.0)`).
  - `Microsoft.Bcl.AsyncInterfaces` v10.0.0 (solo en `netstandard2.0`) — aporta `IAsyncEnumerable<T>`.
  - `Microsoft.Extensions.DependencyInjection.Abstractions` v10.0.0.
  - `Microsoft.SourceLink.GitHub` 8.0.0 (solo dev).
  - `MinVer` 6.0.0 (solo dev).

Distribución de carpetas:

```
src/MediatR/
├── Entities/
│   └── OpenBehavior.cs
├── Internal/
│   ├── HandlersOrderer.cs
│   └── ObjectDetails.cs
├── MicrosoftExtensionsDI/
│   ├── MediatrServiceConfiguration.cs
│   ├── RequestExceptionActionProcessorStrategy.cs
│   └── ServiceCollectionExtensions.cs
├── NotificationPublishers/
│   ├── ForeachAwaitPublisher.cs
│   └── TaskWhenAllPublisher.cs
├── Pipeline/
│   ├── IRequestExceptionAction.cs
│   ├── IRequestExceptionHandler.cs
│   ├── IRequestPostProcessor.cs
│   ├── IRequestPreProcessor.cs
│   ├── RequestExceptionActionProcessorBehavior.cs
│   ├── RequestExceptionHandlerState.cs
│   ├── RequestExceptionProcessorBehavior.cs
│   ├── RequestPostProcessorBehavior.cs
│   └── RequestPreProcessorBehavior.cs
├── Registration/
│   └── ServiceRegistrar.cs
├── Wrappers/
│   ├── NotificationHandlerWrapper.cs
│   ├── RequestHandlerWrapper.cs
│   └── StreamRequestHandlerWrapper.cs
├── IMediator.cs
├── INotificationHandler.cs
├── INotificationPublisher.cs
├── IPipelineBehavior.cs
├── IPublisher.cs
├── IRequestHandler.cs
├── ISender.cs
├── IStreamPipelineBehavior.cs
├── IStreamRequestHandler.cs
├── Mediator.cs
├── MediatR.csproj
├── NotificationHandlerExecutor.cs
└── TypeForwardings.cs
```

> Nota: a diferencia del upstream v13+, este árbol **no tiene carpeta `Licensing/`**, ni `license.txt` embebido, ni `BuildInfo.cs`, ni target MSBuild `EmbedBuildDate`. No hay subsistema de licenciamiento en runtime.

### `src/MediatR.Contracts/MediatR.Contracts.csproj`

Paquete mínimo sin dependencias con solo las interfaces de contrato.

- **Framework destino**: solo `netstandard2.0`.
- **Licencia**: `Apache-2.0`.
- **Versión**: fijada en `2.0.1` (no gestionada por `MinVer`).
- **Dependencias**: ninguna más allá de SourceLink (solo dev).

Contenidos:

```
src/MediatR.Contracts/
├── INotification.cs
├── IRequest.cs                # IBaseRequest, IRequest, IRequest<TResponse>
├── IStreamRequest.cs
├── Unit.cs
└── MediatR.Contracts.csproj
```

Ver [Paquete Contracts](13%20-%20Paquete_Contracts.md).

---

## `samples/` — Aplicaciones de ejemplo

Todas referencian directamente `src/MediatR/MediatR.csproj`.

| Proyecto | Propósito |
|----------|-----------|
| `MediatR.Examples` | Base: `Ping`/`Pong`, `Pinged`, `Jing`, `Sing`/`Song`, procesadores, handlers de excepciones. Contiene `Runner.cs`. |
| `MediatR.Examples.AspNetCore` | Registra MediatR vía `Microsoft.Extensions.DependencyInjection`. |
| `MediatR.Examples.Autofac` | Integración con Autofac. |
| `MediatR.Examples.DryIoc` | Integración con DryIoc. |
| `MediatR.Examples.Lamar` | Integración con Lamar. |
| `MediatR.Examples.LightInject` | Integración con LightInject. |
| `MediatR.Examples.PublishStrategies` | 6 estrategias de publicación (`Async`, `ParallelNoWait`, `ParallelWhenAll`, `ParallelWhenAny`, `SyncContinueOnException`, `SyncStopOnException`) vía `CustomMediator`. |
| `MediatR.Examples.SimpleInjector` | Integración con SimpleInjector. |
| `MediatR.Examples.Stashbox` | Integración con Stashbox. |
| `MediatR.Examples.Windsor` | Integración con Castle.Windsor. |

Ver [Integración de Contenedores DI](15%20-%20Integracion_Contenedores_DI.md).

---

## `test/` — Proyectos de test

### `test/MediatR.Tests`

Suite xUnit completa. Cubre:

- Request/response (incluyendo requests void que devuelven `Unit`).
- Publicación de notificaciones (secuencial, paralelo, publishers custom).
- Comportamientos del pipeline (orden de registro, encadenado de `RequestHandlerDelegate`).
- Procesadores pre y post.
- Handlers y actions de excepciones (con aserciones de prioridad vía `HandlersOrderer`).
- Stream handlers y comportamientos de stream.
- Semántica de `ObjectDetails`.
- Registro `AddMediatR(...)`, escaneo DI, registro de genéricos abiertos, límites de registro — en la subcarpeta `MicrosoftExtensionsDI/`.

(En v12.5 no hay proyecto separado `MediatR.DependencyInjectionTests` — los tests de DI viven dentro de `MediatR.Tests/MicrosoftExtensionsDI/`.)

### `test/MediatR.Benchmarks`

Microbenchmarks con `BenchmarkDotNet` para `Send`, `Publish`, `CreateStream` y overhead del pipeline.

---

## Orquestación de build

### `Build.ps1`

```powershell
dotnet clean -c Release
dotnet build -c Release
dotnet test  -c Release --no-build -l trx --verbosity=normal
dotnet pack  .\src\MediatR\MediatR.csproj -c Release -o .\artifacts --no-build
```

Clean + build + test + pack. Salida en `./artifacts`.

### `BuildContracts.ps1`

Build + pack de `MediatR.Contracts` con `ContinuousIntegrationBuild=true`.

### `Push.ps1`

Sube cada `.nupkg` de `./artifacts` al feed indicado por `NUGET_URL` y `NUGET_API_KEY`, con `--skip-duplicate`.

Ver [Build, Tests y Publicación](16%20-%20Build_Tests_Publicacion.md).

---

## Archivo de solución

`MediatR.sln` usa el formato de texto clásico `.sln`. Todos los proyectos se referencian ahí.

---

## Archivos globales

| Archivo | Propósito |
|---------|-----------|
| `Directory.Build.props` | Props MSBuild compartidas (lenguaje 10, warnings como errores). |
| `MediatR.snk` | Clave de firma strong-name. |
| `NuGet.Config` | Configuración del feed NuGet. |
| `LICENSE` | Texto completo de la licencia Apache-2.0. |
| `README.md` | Quickstart, empaquetado también como README del NuGet. |
| `assets/logo/gradient_128x128.png` | Icono del paquete. |
