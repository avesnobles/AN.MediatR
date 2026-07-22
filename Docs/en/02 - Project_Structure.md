# Project Structure

This document enumerates every project in the `AN.MediatR.sln` solution, its purpose, dependencies, and relation to the rest of the codebase. It complements [Architecture](01%20-%20Architecture.md), which describes the high-level layering.

---

## Solution overview

AN.MediatR is organized into three top-level folders inside the repository:

| Folder | Contents |
|--------|----------|
| `src/` | The two NuGet packages: `AN.MediatR` and `AN.MediatR.Contracts` |
| `samples/` | Ten sample projects showing integration patterns |
| `test/` | Two test projects (unit/DI, benchmarks) |

---

## `src/` — Production code

### `src/AN.MediatR/AN.MediatR.csproj`

The main library. Produces the `MediatR` NuGet package.

- **Target frameworks**: `netstandard2.0;net8.0;net9.0;net10.0` (plus `net462` on Windows).
- **Nullable**: enabled.
- **Strong-named**: yes, via `..\..\AN.MediatR.snk`.
- **XML docs**: generated (`GenerateDocumentationFile = true`).
- **Package metadata**: package icon, README, Apache-2.0 license expression, project URL.
- **Versioning**: `MinVer` with tag prefix `v` (e.g. `v12.5.0`).
- **Dependencies**:
  - `IsExternalInit` (dev-only polyfill) — enables `init`-only properties on `netstandard2.0`.
  - `AN.MediatR.Contracts` (version `[2.0.1, 3.0.0)`).
  - `Microsoft.Bcl.AsyncInterfaces` v10.0.0 (only on `netstandard2.0`) — provides `IAsyncEnumerable<T>`.
  - `Microsoft.Extensions.DependencyInjection.Abstractions` v10.0.0.
  - `Microsoft.SourceLink.GitHub` 8.0.0 (dev-only).
  - `MinVer` 6.0.0 (dev-only).

Folder layout:

```
src/AN.MediatR/
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

> Note: unlike the v13+ upstream, this tree has **no `Licensing/` folder**, no `license.txt` embedded resource, no `BuildInfo.cs`, no `EmbedBuildDate` MSBuild target. There is no runtime licensing subsystem.

### `src/AN.MediatR.Contracts/AN.MediatR.Contracts.csproj`

A minimal, dependency-free package containing just the contract interfaces.

- **Target framework**: `netstandard2.0` only.
- **License**: `Apache-2.0` (`PackageLicenseExpression`).
- **Version**: fixed at `2.0.1` (not driven by `MinVer`).
- **Dependencies**: none beyond SourceLink (dev-only).

Contents:

```
src/AN.MediatR.Contracts/
├── INotification.cs           # marker interface for notifications
├── IRequest.cs                # IBaseRequest, IRequest, IRequest<TResponse>
├── IStreamRequest.cs          # IStreamRequest<TResponse>
├── Unit.cs                    # Unit value type (void substitute)
└── MediatR.Contracts.csproj
```

See [Contracts Package](13%20-%20Contracts_Package.md) for rationale and usage.

---

## `samples/` — Sample applications

All sample projects are console applications (or a minimal ASP.NET Core host) and reference `src/AN.MediatR/AN.MediatR.csproj` directly.

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
3. Hand control to the shared `Runner.Run(...)` method in `MediatR.Examples`.

See [DI Container Integration](15%20-%20DI_Container_Integration.md) for container-specific setup.

---

## `test/` — Test projects

### `test/AN.MediatR.Tests`

The full xUnit test suite. Located at `test/AN.MediatR.Tests/`. Covers:

- Request and response handling (including `Unit`-returning void requests).
- Notification publishing (sequential, parallel, custom publishers).
- Pipeline behaviors (registration order, `RequestHandlerDelegate` chaining).
- Pre and post-processors.
- Exception handlers and actions (with `HandlersOrderer` priority assertions).
- Stream handlers and stream pipeline behaviors.
- `ObjectDetails` comparison semantics.
- `AddMediatR(...)` registration, DI scanning, open-generic handler registration, generic-registration limits — in the `MicrosoftExtensionsDI/` sub-folder.

(In v12.5 there is no separate `MediatR.DependencyInjectionTests` project — the DI tests live under `MediatR.Tests/MicrosoftExtensionsDI/`.)

### `test/AN.MediatR.Benchmarks`

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

Clean + build + test + pack of the main `AN.MediatR` package. Output artifacts go to `./artifacts`.

### `BuildContracts.ps1`

Dedicated script that builds and packs only `AN.MediatR.Contracts` with `ContinuousIntegrationBuild=true` for deterministic builds.

### `Push.ps1`

Pushes every `.nupkg` in `./artifacts` to the NuGet feed specified by environment variables `NUGET_URL` and `NUGET_API_KEY`, using `--skip-duplicate`.

See [Build, Test & Publish](16%20-%20Build_Test_Publish.md) for details.

---

## Solution file

`AN.MediatR.sln` uses the classic text-based `.sln` format. Every project above is referenced there.

---

## Global files

| File | Purpose |
|------|---------|
| `Directory.Build.props` | Shared MSBuild properties (language version 10, treat warnings as errors, suppressed warning codes). |
| `AN.MediatR.snk` | Strong-name signing key for both `AN.MediatR` and `AN.MediatR.Contracts`. |
| `NuGet.Config` | NuGet feed configuration. |
| `LICENSE` | Apache-2.0 full license text. |
| `README.md` | Quickstart, also packed as the NuGet README for `MediatR`. |
| `assets/logo/gradient_128x128.png` | Package icon. |
