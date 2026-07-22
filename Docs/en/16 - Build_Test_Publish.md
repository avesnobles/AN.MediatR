# Build, Test & Publish

This chapter documents the build pipeline, test projects, and NuGet publishing flow for AN.MediatR.

---

## Build.ps1

Source: [Build.ps1](../../Build.ps1).

```powershell
# Taken from psake
function Exec { ... }  # helper that throws when $lastexitcode != 0

$artifacts = ".\artifacts"
if (Test-Path $artifacts) { Remove-Item $artifacts -Force -Recurse }

exec { & dotnet clean -c Release }
exec { & dotnet build -c Release }
exec { & dotnet test  -c Release --no-build -l trx --verbosity=normal }
exec { & dotnet pack  .\src\MediatR\MediatR.csproj -c Release -o $artifacts --no-build }
```

What it does:

1. Wipes the `artifacts/` folder.
2. `dotnet clean -c Release` — clears bin/obj.
3. `dotnet build -c Release` — restores and compiles everything in the solution.
4. `dotnet test -c Release --no-build -l trx` — runs all test projects, emitting TRX results for CI integration.
5. `dotnet pack src/AN.MediatR/AN.MediatR.csproj -c Release -o ./artifacts --no-build` — packs only the main `AN.MediatR` package.

The `exec` helper is a tiny psake-style wrapper that throws a .NET exception when the previous `dotnet` command fails.

Output: `AN.MediatR.<version>.nupkg` and `AN.MediatR.Contracts.<version>.nupkg` (plus their `.snupkg` symbols) in `artifacts/`.

> Note: `Build.ps1` packs **both** `AN.MediatR` and `AN.MediatR.Contracts`. `BuildContracts.ps1` is kept as a convenience for packing only the contracts package independently.

---

## BuildContracts.ps1

Builds and packs the contracts package separately. Typical shape:

```powershell
dotnet clean ./src/AN.MediatR.Contracts/AN.MediatR.Contracts.csproj -c Release
dotnet build ./src/AN.MediatR.Contracts/AN.MediatR.Contracts.csproj -c Release -p:ContinuousIntegrationBuild=true
dotnet pack  ./src/AN.MediatR.Contracts/AN.MediatR.Contracts.csproj -c Release -o ./artifacts
```

- `ContinuousIntegrationBuild=true` enables deterministic builds — important for `Microsoft.SourceLink.GitHub` to embed reproducible commit metadata.
- Contracts are released independently (version `2.0.1` hardcoded in the csproj), not tied to the main package's MinVer versioning.

---

## Push.ps1

Pushes every `.nupkg` in `./artifacts` to the NuGet feed set by environment variables:

```powershell
if ($env:NUGET_API_KEY) {
    Get-ChildItem ./artifacts -Filter "*.nupkg" | ForEach-Object {
        dotnet nuget push $_.FullName --source $env:NUGET_URL --api-key $env:NUGET_API_KEY --skip-duplicate
    }
}
```

- `--skip-duplicate` is idempotent — re-running the push on a version already uploaded is a no-op.
- Environment variables: `NUGET_URL` (feed URL) and `NUGET_API_KEY` (API key). Set them in your CI secrets.

For internal feeds (Azure Artifacts, GitHub Packages, MyGet), override `NUGET_URL` and generate an API key scoped to push.

---

## MinVer versioning

Source: [src/AN.MediatR/AN.MediatR.csproj](../../src/AN.MediatR/AN.MediatR.csproj) — `<PackageReference Include="MinVer" ... />` + `<MinVerTagPrefix>v</MinVerTagPrefix>`.

MinVer computes the NuGet package version from git tags:

- The latest tag matching `v*` (e.g. `v12.5.0`) is the base version.
- If the current commit is **tagged**, the version is exactly the tag.
- If not, MinVer appends a pre-release label and height (`v12.5.1-alpha.0.3`).
- CI builds with no tags get `0.0.0-alpha.0.<height>` by default.

To cut a release:

1. Commit on your release branch.
2. `git tag v12.5.0`.
3. `git push origin <branch> --tags`.
4. CI builds the tag → publishes the matching `.nupkg`.

> AN.MediatR starts numbering its own releases from the v12.5 fork point. The next version number chosen by the AN team will depend on the fork's semantic-versioning policy going forward.

---

## Determinism and source linking

`Directory.Build.props` sets `<Deterministic>true</Deterministic>` and each csproj sets `<ContinuousIntegrationBuild>true</ContinuousIntegrationBuild>` when running under GitHub Actions. Combined with `Microsoft.SourceLink.GitHub`, this produces reproducible binaries: anyone can verify that a published `.nupkg` was produced from a specific commit.

---

## Tests overview

### `test/AN.MediatR.Tests`

The full xUnit test suite. Covers:

- Request/response dispatch (generic, void, dynamic).
- Notification publishing (sequential and parallel, custom publishers).
- Pipeline behavior composition (order, cancellation propagation, short-circuiting).
- Pre and post-processors.
- Exception handlers and actions (priority ordering, `ApplyForUnhandledExceptions` vs. `ApplyForAllExceptions`).
- Stream request dispatch and stream pipeline behavior composition.
- `ObjectDetails` and `HandlersOrderer` edge cases.
- `Unit.Value`, `Unit.Task`, `Unit` comparison and equality semantics.
- DI registration and scanning (inside `test/AN.MediatR.Tests/MicrosoftExtensionsDI/`): assembly scanning, `TypeEvaluator` filter, `AutoRegisterRequestProcessors`, generic-registration limits, duplicate registration idempotence, accessibility edge cases.

> In v12.5 there is no separate `MediatR.DependencyInjectionTests` project — everything lives under `MediatR.Tests`.

### `test/AN.MediatR.Benchmarks`

`BenchmarkDotNet` microbenchmarks:

- `IMediator.Send` latency (cold vs. warm).
- `IMediator.Publish` latency (1 vs. N handlers).
- `CreateStream` start-up cost.
- Pipeline behavior overhead per step.
- Reflection-heavy dynamic dispatch vs. typed dispatch.

Run with:

```bash
dotnet run -c Release --project test/AN.MediatR.Benchmarks
```

---

## Assembly signing

Both projects are **strong-named** via the shared key file `AN.MediatR.snk`:

```xml
<SignAssembly>true</SignAssembly>
<AssemblyOriginatorKeyFile>..\..\AN.MediatR.snk</AssemblyOriginatorKeyFile>
```

This produces a public/private signed assembly. In v12.5 there is **no `InternalsVisibleTo`** declared in `AN.MediatR.csproj` — the test project does not need access to internal types.

---

## CI/CD

The repository is CI-friendly: `Build.ps1` runs the full pipeline locally or in CI, and `Push.ps1` publishes the artifacts.

Environment variables used by `Push.ps1`:

| Variable | Purpose |
|----------|---------|
| `NUGET_URL` | NuGet feed endpoint (usually `https://api.nuget.org/v3/index.json` or your internal feed) |
| `NUGET_API_KEY` | API key to push packages |
| `GITHUB_ACTIONS` | Auto-set by CI; enables `<ContinuousIntegrationBuild>true</ContinuousIntegrationBuild>` in csproj |

---

## Target framework matrix

`AN.MediatR` produces binaries for several TFMs:

| TFM | Notes |
|-----|-------|
| `netstandard2.0` | The widest compatibility target — used from any runtime that supports .NET Standard 2.0 (Xamarin, Unity, older .NET Framework). Depends on `Microsoft.Bcl.AsyncInterfaces` for `IAsyncEnumerable` support. |
| `net8.0` | Current LTS .NET. |
| `net9.0` | Current STS .NET. |
| `net10.0` | Upcoming LTS — supported as soon as the SDK is available. |
| `net462` | .NET Framework 4.6.2, only produced on Windows builds (conditional in `AN.MediatR.csproj`). |

`AN.MediatR.Contracts` targets only `netstandard2.0`. Since it has no runtime logic, one TFM suffices.

### Polyfills

- `IsExternalInit` (dev-only reference): enables C# `init` accessors on `netstandard2.0` and `net462`.
- `Microsoft.Bcl.AsyncInterfaces` (`netstandard2.0` only): provides `IAsyncEnumerable<T>` and `IAsyncDisposable` for the streaming API.

---

## Warnings as errors

`Directory.Build.props`:

```xml
<PropertyGroup>
  <IsMac>$([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform($([System.Runtime.InteropServices.OSPlatform]::get_OSX())))</IsMac>
  <IsWindows>$([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform($([System.Runtime.InteropServices.OSPlatform]::get_Windows())))</IsWindows>

  <LangVersion>13.0</LangVersion>
  <NoWarn>$(NoWarn);CS1701;CS1702;CS1591;NU1900</NoWarn>
  <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
</PropertyGroup>
```

- `TreatWarningsAsErrors` keeps the codebase clean.
- `CS1591` (missing XML doc) is suppressed because the library only documents public types selectively.
- `CS1701` / `CS1702` are binding-redirect version-mismatch warnings, typically noisy in multi-TFM libraries.

---

## Reproducing a release build locally

```powershell
# 1. Clean everything
dotnet clean -c Release

# 2. Build + test
dotnet build -c Release
dotnet test -c Release --no-build -l trx --verbosity=normal

# 3. Pack both packages
dotnet pack ./src/AN.MediatR/AN.MediatR.csproj -c Release -o ./artifacts --no-build
dotnet pack ./src/AN.MediatR.Contracts/AN.MediatR.Contracts.csproj -c Release -o ./artifacts -p:ContinuousIntegrationBuild=true

# 4. (Optional) Push
$env:NUGET_URL = "https://api.nuget.org/v3/index.json"
$env:NUGET_API_KEY = "<key>"
./Push.ps1
```

Or just:

```powershell
./Build.ps1
./BuildContracts.ps1
./Push.ps1
```
