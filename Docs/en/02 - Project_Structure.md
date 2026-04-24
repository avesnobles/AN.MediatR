# Project Structure

This document enumerates every project in the `MediatR.slnx` solution, its purpose, dependencies, and relation to the rest of the codebase. It complements [Architecture](01%20-%20Architecture.md), which describes the high-level layering.

---

## Solution overview

AN.MediatR is organized into three top-level folders inside the repository:

| Folder | Contents |
|--------|----------|
| `src/` | The two NuGet packages: `MediatR` and `MediatR.Contracts` |
| `samples/` | Ten sample projects showing integration patterns |
| `test/` | Three test projects (unit, DI, benchmarks) |

---

## `src/` — Production code

### `src/MediatR/MediatR.csproj`

The main library. Produces the `MediatR` NuGet package.

- **Target frameworks**: `netstandard2.0`, `net8.0`, `net9.0`, `net10.0`, and `net462` (Windows only).
- **Nullable**: enabled.
- **Strong-named**: yes, via `..\..\MediatR.snk`.
- **XML docs**: generated (`GenerateDocumentationFile = true`).
- **Package metadata**: package icon, README, license file (`LICENSE.md`), `PackageRequireLicenseAcceptance = true`, project URL `https://mediatr.io`.
- **Versioning**: `MinVer` with tag prefix `v` (e.g. `v13.2.0`).
- **MSBuild target**: `EmbedBuildDate` runs before `CoreCompile`. It executes `git log -1 --format=%cI` and writes the ISO-8601 build date into an `[assembly: AssemblyMetadata("BuildDateUtc", "...")]` attribute used by the perpetual-license logic (`BuildInfo.cs`).
- **Dependencies**:
  - `IsExternalInit` (dev-only polyfill) — enables `init`-only properties on `netstandard2.0` / `net462`.
  - `MediatR.Contracts` (version `[2.0.1, 3.0.0)`).
  - `Microsoft.Bcl.AsyncInterfaces` (only on `netstandard2.0`).
  - `Microsoft.Extensions.DependencyInjection.Abstractions` v10+.
  - `Microsoft.Extensions.Logging.Abstractions` v10+.
  - `Microsoft.IdentityModel.JsonWebTokens` v8.14+ (required by the licensing subsystem).
  - `Microsoft.SourceLink.GitHub` 8.0.0 (dev-only).
  - `MinVer` 6.0.0 (dev-only).
- **`InternalsVisibleTo`**: exposes internal types to `MediatR.Tests` (signed public key hash).

Folder layout:

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

A minimal, dependency-free package containing just the contract interfaces. Produces the `MediatR.Contracts` NuGet package.

- **Target framework**: `netstandard2.0` only.
- **License**: `Apache-2.0` (`PackageLicenseExpression`).
- **Version**: fixed at `2.0.1` (not driven by `MinVer`).
- **Dependencies**: none beyond SourceLink (dev-only).

Contents:

```
src/MediatR.Contracts/
├── INotification.cs           # marker interface for notifications
├── IRequest.cs                # IBaseRequest, IRequest, IRequest<TResponse>
├── IStreamRequest.cs          # IStreamRequest<TResponse>
├── Unit.cs                    # Unit value type (void substitute)
└── MediatR.Contracts.csproj
```

See [Contracts Package](14%20-%20Contracts_Package.md) for rationale and usage.

---

## `samples/` — Sample applications

All sample projects are console applications (or a minimal ASP.NET Core host) and reference `src/MediatR/MediatR.csproj` directly.

| Project | Purpose |
|---------|---------|
| `MediatR.Examples` | Baseline: defines `Ping`/`Pong`, `Pinged`, `Jing`, `Sing`/`Song`, pre/post-processors, exception handlers. Contains `Runner.cs` used by other sample hosts. |
| `MediatR.Examples.AspNetCore` | Registers MediatR via `Microsoft.Extensions.DependencyInjection`, runs the `Runner` inside a minimal host. |
| `MediatR.Examples.Autofac` | Integration with Autofac container. |
| `MediatR.Examples.DryIoc` | Integration with DryIoc container. |
| `MediatR.Examples.Lamar` | Integration with Lamar container. |
| `MediatR.Examples.LightInject` | Integration with LightInject container. |
| `MediatR.Examples.PublishStrategies` | Defines six notification publishing strategies (`Async`, `ParallelNoWait`, `ParallelWhenAll`, `ParallelWhenAny`, `SyncContinueOnException`, `SyncStopOnException`) via a `CustomMediator` subclass. |
| `MediatR.Examples.SimpleInjector` | Integration with SimpleInjector. |
| `MediatR.Examples.Stashbox` | Integration with Stashbox. |
| `MediatR.Examples.Windsor` | Integration with Castle.Windsor. |

The typical pattern in every sample is:

1. Build the DI container and register MediatR + handlers.
2. Resolve `IMediator`.
3. Hand control to the shared `Runner.Run(...)` method in `MediatR.Examples` which sends `Ping`, publishes `Pinged`, sends `Jing` (expected to fail), optionally streams `Sing`, and exercises exception handlers / actions.

See [DI Container Integration](16%20-%20DI_Container_Integration.md) for container-specific setup.

---

## `test/` — Test projects

### `test/MediatR.Tests`

The core xUnit test suite. Covers:

- Request and response handling (including `Unit`-returning void requests).
- Notification publishing (sequential, parallel, custom publishers).
- Pipeline behaviors (registration order, `RequestHandlerDelegate` chaining).
- Pre and post-processors.
- Exception handlers and actions (with `HandlersOrderer` priority assertions).
- Stream handlers and stream pipeline behaviors.
- Licensing tests (valid/invalid/expired/perpetual keys, warning logs).
- `ObjectDetails` comparison semantics.

Tests are allowed to see `internal` types via the `InternalsVisibleTo` attribute on `MediatR.csproj`.

### `test/MediatR.DependencyInjectionTests`

Tests that exercise `AddMediatR(...)` and `ServiceRegistrar` behavior:

- Scanning the right assemblies.
- Transient vs. singleton lifetime overrides.
- Closed and open-generic handler registration.
- Assembly scanning limits (`MaxGenericTypeParameters`, `MaxTypesClosing`, `MaxGenericTypeRegistrations`, `RegistrationTimeout`).
- Custom `TypeEvaluator` filters.
- Automatic processor registration (`AutoRegisterRequestProcessors`).
- Internal/private handler visibility edge cases.

### `test/MediatR.Benchmarks`

`BenchmarkDotNet`-based microbenchmarks for `Send`, `Publish`, `CreateStream`, and pipeline overhead. Useful to detect regressions during refactors.

---

## Build orchestration

### `Build.ps1`

```powershell
dotnet clean -c Release
dotnet build -c Release
dotnet test  -c Release --no-build -l trx --verbosity=normal
dotnet pack  .\src\MediatR\MediatR.csproj -c Release -o .\artifacts --no-build
```

Clean + build + test + pack of the main `MediatR` package. Output artifacts go to `./artifacts`.

### `BuildContracts.ps1`

Dedicated script that builds and packs only `MediatR.Contracts` with `ContinuousIntegrationBuild=true` for deterministic builds.

### `Push.ps1`

Pushes every `.nupkg` in `./artifacts` to the NuGet feed specified by environment variables `NUGET_URL` and `NUGET_API_KEY`, using `--skip-duplicate`.

See [Build, Test & Publish](17%20-%20Build_Test_Publish.md) for details.

---

## Solution file

`MediatR.slnx` uses the new XML-based solution format (an alternative to the legacy `.sln` text format). Every project above is referenced there. Some Visual Studio / Rider versions need an extension or a recent SDK to open `.slnx` files.

---

## Global files

| File | Purpose |
|------|---------|
| `Directory.Build.props` | Shared MSBuild properties (language version, treat warnings as errors, suppressed warning codes). |
| `MediatR.snk` | Strong-name signing key for both `MediatR` and `MediatR.Contracts`. |
| `NuGet.Config` | NuGet feed configuration. |
| `LICENSE.md` | Dual licensing notice (RPL 1.5 / commercial). |
| `README.md` | Quickstart, also packed as the NuGet README for `MediatR`. |
| `assets/logo/gradient_128x128.png` | Package icon. |
