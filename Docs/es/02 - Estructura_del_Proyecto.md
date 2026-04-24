# Estructura del Proyecto

Este documento enumera cada proyecto de la solución `MediatR.slnx`, su propósito, dependencias y relación con el resto del código. Complementa [Arquitectura](01%20-%20Arquitectura.md), que describe el stack de alto nivel.

---

## Visión general de la solución

AN.MediatR se organiza en tres carpetas principales dentro del repositorio:

| Carpeta | Contenido |
|---------|-----------|
| `src/` | Los dos paquetes NuGet: `MediatR` y `MediatR.Contracts` |
| `samples/` | Diez proyectos de ejemplo con patrones de integración |
| `test/` | Tres proyectos de test (unitarios, DI, benchmarks) |

---

## `src/` — Código de producción

### `src/MediatR/MediatR.csproj`

La librería principal. Produce el paquete NuGet `MediatR`.

- **Frameworks destino**: `netstandard2.0`, `net8.0`, `net9.0`, `net10.0` y `net462` (solo Windows).
- **Nullable**: activado.
- **Strong-named**: sí, mediante `..\..\MediatR.snk`.
- **Documentación XML**: generada (`GenerateDocumentationFile = true`).
- **Metadatos del paquete**: icono, README, archivo de licencia (`LICENSE.md`), `PackageRequireLicenseAcceptance = true`, URL del proyecto `https://mediatr.io`.
- **Versionado**: `MinVer` con prefijo de tag `v` (p. ej. `v13.2.0`).
- **Target MSBuild**: `EmbedBuildDate` se ejecuta antes de `CoreCompile`. Ejecuta `git log -1 --format=%cI` y escribe la fecha ISO-8601 del build en un atributo `[assembly: AssemblyMetadata("BuildDateUtc", "...")]` usado por la lógica de licencia perpetua (`BuildInfo.cs`).
- **Dependencias**:
  - `IsExternalInit` (solo dev) — permite propiedades `init` en `netstandard2.0` / `net462`.
  - `MediatR.Contracts` (versión `[2.0.1, 3.0.0)`).
  - `Microsoft.Bcl.AsyncInterfaces` (solo en `netstandard2.0`).
  - `Microsoft.Extensions.DependencyInjection.Abstractions` v10+.
  - `Microsoft.Extensions.Logging.Abstractions` v10+.
  - `Microsoft.IdentityModel.JsonWebTokens` v8.14+ (requerida por el subsistema de licenciamiento).
  - `Microsoft.SourceLink.GitHub` 8.0.0 (solo dev).
  - `MinVer` 6.0.0 (solo dev).
- **`InternalsVisibleTo`**: expone tipos internos a `MediatR.Tests` (hash de clave pública firmada).

Distribución de carpetas:

```
src/MediatR/
├── Entities/
│   └── OpenBehavior.cs
├── Internal/
│   ├── HandlersOrderer.cs
│   └── ObjectDetails.cs
├── Licensing/
│   ├── BuildInfo.cs
│   ├── Edition.cs
│   ├── License.cs
│   ├── LicenseAccessor.cs
│   ├── LicenseValidator.cs
│   └── ProductType.cs
├── MicrosoftExtensionsDI/
│   ├── MediatRServiceCollectionExtensions.cs
│   ├── MediatrServiceConfiguration.cs
│   └── RequestExceptionActionProcessorStrategy.cs
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
├── TypeForwardings.cs
└── license.txt
```

### `src/MediatR.Contracts/MediatR.Contracts.csproj`

Un paquete mínimo y sin dependencias con solo las interfaces de contrato. Produce el paquete NuGet `MediatR.Contracts`.

- **Framework destino**: solo `netstandard2.0`.
- **Licencia**: `Apache-2.0` (`PackageLicenseExpression`).
- **Versión**: fijada en `2.0.1` (no gestionada por `MinVer`).
- **Dependencias**: ninguna más allá de SourceLink (solo dev).

Contenidos:

```
src/MediatR.Contracts/
├── INotification.cs           # interfaz marcador para notificaciones
├── IRequest.cs                # IBaseRequest, IRequest, IRequest<TResponse>
├── IStreamRequest.cs          # IStreamRequest<TResponse>
├── Unit.cs                    # Tipo de valor Unit (sustituto de void)
└── MediatR.Contracts.csproj
```

Ver [Paquete Contracts](14%20-%20Paquete_Contracts.md) para la justificación y uso.

---

## `samples/` — Aplicaciones de ejemplo

Todos los proyectos de ejemplo son aplicaciones de consola (o un host mínimo de ASP.NET Core) y referencian directamente `src/MediatR/MediatR.csproj`.

| Proyecto | Propósito |
|----------|-----------|
| `MediatR.Examples` | Base: define `Ping`/`Pong`, `Pinged`, `Jing`, `Sing`/`Song`, procesadores pre/post, handlers de excepciones. Contiene `Runner.cs` usado por el resto de ejemplos. |
| `MediatR.Examples.AspNetCore` | Registra MediatR vía `Microsoft.Extensions.DependencyInjection`, ejecuta el `Runner` en un host mínimo. |
| `MediatR.Examples.Autofac` | Integración con contenedor Autofac. |
| `MediatR.Examples.DryIoc` | Integración con contenedor DryIoc. |
| `MediatR.Examples.Lamar` | Integración con contenedor Lamar. |
| `MediatR.Examples.LightInject` | Integración con contenedor LightInject. |
| `MediatR.Examples.PublishStrategies` | Define seis estrategias de publicación de notificaciones (`Async`, `ParallelNoWait`, `ParallelWhenAll`, `ParallelWhenAny`, `SyncContinueOnException`, `SyncStopOnException`) mediante una subclase `CustomMediator`. |
| `MediatR.Examples.SimpleInjector` | Integración con SimpleInjector. |
| `MediatR.Examples.Stashbox` | Integración con Stashbox. |
| `MediatR.Examples.Windsor` | Integración con Castle.Windsor. |

El patrón típico en cada ejemplo:

1. Construir el contenedor DI y registrar MediatR + handlers.
2. Resolver `IMediator`.
3. Ceder el control al método compartido `Runner.Run(...)` de `MediatR.Examples`, que envía `Ping`, publica `Pinged`, envía `Jing` (espera que falle), opcionalmente hace streaming de `Sing`, y ejercita los handlers / actions de excepciones.

Ver [Integración de Contenedores DI](16%20-%20Integracion_Contenedores_DI.md) para detalles específicos de cada contenedor.

---

## `test/` — Proyectos de test

### `test/MediatR.Tests`

Suite xUnit principal. Cubre:

- Request/response (incluyendo requests void que devuelven `Unit`).
- Publicación de notificaciones (secuencial, paralelo, publicadores custom).
- Comportamientos del pipeline (orden de registro, encadenado de `RequestHandlerDelegate`).
- Procesadores pre y post.
- Handlers y actions de excepciones (con aserciones de prioridad vía `HandlersOrderer`).
- Stream handlers y comportamientos de stream.
- Tests de licenciamiento (claves válidas/inválidas/expiradas/perpetuas, logs de warning).
- Semántica de comparación de `ObjectDetails`.

Los tests pueden ver tipos `internal` gracias al atributo `InternalsVisibleTo` en `MediatR.csproj`.

### `test/MediatR.DependencyInjectionTests`

Tests que ejercitan el comportamiento de `AddMediatR(...)` y `ServiceRegistrar`:

- Escaneo del ensamblado correcto.
- Overrides transient vs. singleton.
- Registro de handlers cerrados y de genéricos abiertos.
- Límites de escaneo (`MaxGenericTypeParameters`, `MaxTypesClosing`, `MaxGenericTypeRegistrations`, `RegistrationTimeout`).
- Filtros custom vía `TypeEvaluator`.
- Registro automático de procesadores (`AutoRegisterRequestProcessors`).
- Casos extremos de visibilidad (handlers internos/privados).

### `test/MediatR.Benchmarks`

Microbenchmarks con `BenchmarkDotNet` para `Send`, `Publish`, `CreateStream` y overhead del pipeline. Útiles para detectar regresiones durante refactorizaciones.

---

## Orquestación de build

### `Build.ps1`

```powershell
dotnet clean -c Release
dotnet build -c Release
dotnet test  -c Release --no-build -l trx --verbosity=normal
dotnet pack  .\src\MediatR\MediatR.csproj -c Release -o .\artifacts --no-build
```

Clean + build + test + pack del paquete principal `MediatR`. Los artefactos van a `./artifacts`.

### `BuildContracts.ps1`

Script dedicado que solo hace build + pack de `MediatR.Contracts` con `ContinuousIntegrationBuild=true` para builds deterministas.

### `Push.ps1`

Sube cada `.nupkg` en `./artifacts` al feed NuGet especificado por las variables de entorno `NUGET_URL` y `NUGET_API_KEY`, usando `--skip-duplicate`.

Ver [Build, Tests y Publicación](17%20-%20Build_Tests_Publicacion.md) para detalles.

---

## Archivo de solución

`MediatR.slnx` usa el nuevo formato XML de solución (alternativa al `.sln` de texto legacy). Cada proyecto está referenciado ahí. Algunas versiones de Visual Studio / Rider necesitan una extensión o SDK reciente para abrir `.slnx`.

---

## Archivos globales

| Archivo | Propósito |
|---------|-----------|
| `Directory.Build.props` | Propiedades MSBuild compartidas (versión del lenguaje, warnings como errores, códigos suprimidos). |
| `MediatR.snk` | Clave de firma strong-name para `MediatR` y `MediatR.Contracts`. |
| `NuGet.Config` | Configuración del feed NuGet. |
| `LICENSE.md` | Aviso de licencia dual (RPL 1.5 / comercial). |
| `README.md` | Quickstart, también empaquetado como README NuGet de `MediatR`. |
| `assets/logo/gradient_128x128.png` | Icono del paquete. |
