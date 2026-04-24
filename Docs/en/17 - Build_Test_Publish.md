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
5. `dotnet pack src/MediatR/MediatR.csproj -c Release -o ./artifacts --no-build` — packs only the main `MediatR` package.

The `exec` helper is a tiny psake-style wrapper that throws a .NET exception when the previous `dotnet` command fails, so pipeline failures bubble up clearly.

Output: a single `MediatR.<version>.nupkg` (plus its `.snupkg` symbols) in `artifacts/`.

> Note: `Build.ps1` does **not** pack `MediatR.Contracts` — that's `BuildContracts.ps1`'s job.

---

## BuildContracts.ps1

Builds and packs the contracts package separately. Typical shape:

```powershell
dotnet clean ./src/MediatR.Contracts/MediatR.Contracts.csproj -c Release
dotnet build ./src/MediatR.Contracts/MediatR.Contracts.csproj -c Release -p:ContinuousIntegrationBuild=true
dotnet pack  ./src/MediatR.Contracts/MediatR.Contracts.csproj -c Release -o ./artifacts
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

Source: [src/MediatR/MediatR.csproj](../../src/MediatR/MediatR.csproj) — `<PackageReference Include="MinVer" ... />` + `<MinVerTagPrefix>v</MinVerTagPrefix>`.

MinVer computes the NuGet package version from git tags:

- The latest tag matching `v*` (e.g. `v13.2.0`) is the base version.
- If the current commit is **tagged**, the version is exactly the tag.
- If not, MinVer appends a pre-release label and height (`v13.2.1-alpha.0.3`).
- CI builds with no tags get `0.0.0-alpha.0.<height>` by default.

To cut a release:

1. Commit on `main`.
2. `git tag v13.2.0`.
3. `git push origin main --tags`.
4. CI builds the tag → publishes `MediatR.13.2.0.nupkg`.

---

## Build metadata: git log, build date, determinism

The `MediatR.csproj` has a custom target that embeds the build date into the assembly:

```xml
<Target Name="EmbedBuildDate" BeforeTargets="CoreCompile">
    <Exec Command="git log -1 --format=%25cI" ConsoleToMSBuild="true" IgnoreExitCode="true">
        <Output TaskParameter="ConsoleOutput" PropertyName="BuildDateUtc" />
    </Exec>
    <PropertyGroup>
        <BuildDateUtc Condition="'$(BuildDateUtc)' == ''">$([System.DateTime]::UtcNow.ToString("O"))</BuildDateUtc>
    </PropertyGroup>
    <WriteLinesToFile File="$(IntermediateOutputPath)BuildDateGenerated.cs"
        Lines="[assembly: System.Reflection.AssemblyMetadata(&quot;BuildDateUtc&quot;, &quot;$(BuildDateUtc)&quot;)]"
        Overwrite="true" />
    <ItemGroup>
        <Compile Include="$(IntermediateOutputPath)BuildDateGenerated.cs" />
    </ItemGroup>
</Target>
```

- Runs `git log -1 --format=%cI` to get the latest commit's committer date in ISO 8601.
- Falls back to `DateTime.UtcNow` if git is not available.
- Writes a `BuildDateGenerated.cs` containing an `AssemblyMetadata` attribute.
- Compiles that file into the assembly.

Runtime consumers (`BuildInfo.cs`) read the attribute for perpetual licensing — see [Licensing](13%20-%20Licensing.md).

### Determinism

`Directory.Build.props` sets `<Deterministic>true</Deterministic>` + `<ContinuousIntegrationBuild>true</ContinuousIntegrationBuild>` when running under GitHub Actions, which, combined with SourceLink, gives reproducible binaries. Anyone can verify that a published `MediatR.13.2.0.nupkg` was produced from a specific commit.

---

## Tests overview

### `test/MediatR.Tests`

The primary xUnit suite. Located at `test/MediatR.Tests/`. Covers:

- Request/response dispatch (generic, void, dynamic).
- Notification publishing (sequential and parallel, custom publishers).
- Pipeline behavior composition (order, cancellation propagation, short-circuiting).
- Pre and post-processors.
- Exception handlers and actions (priority ordering, `ApplyForUnhandledExceptions` vs. `ApplyForAllExceptions`).
- Stream request dispatch and stream pipeline behavior composition.
- Licensing: valid, invalid, expired, perpetual, wrong product type, no key.
- `HandlersOrderer` / `ObjectDetails` edge cases.
- Thread-safety of the static wrapper caches.
- `Unit.Value`, `Unit.Task`, `Unit` comparison and equality semantics.

Because `MediatR.csproj` includes an `InternalsVisibleTo` for this test assembly, tests can exercise `internal` types (`Licensing`, `Internal`, wrappers).

### `test/MediatR.DependencyInjectionTests`

Focuses on registration:

- `AddMediatR(Action<MediatRServiceConfiguration>)` behavior.
- `ServiceRegistrar` scanning (closed handlers, open-generic handlers, notifications, exception handlers).
- `TypeEvaluator` filter.
- `AutoRegisterRequestProcessors` flag.
- Generic registration limits (`MaxGenericTypeParameters`, `MaxTypesClosing`, `MaxGenericTypeRegistrations`, `RegistrationTimeout`).
- Duplicate registration idempotence.
- Accessibility of handlers (public vs internal vs nested).

### `test/MediatR.Benchmarks`

`BenchmarkDotNet` microbenchmarks:

- `IMediator.Send` latency (cold vs. warm).
- `IMediator.Publish` latency (1 vs. N handlers).
- `CreateStream` start-up cost.
- Pipeline behavior overhead per step.
- Reflection-heavy dynamic dispatch vs. typed dispatch.

Run with:

```bash
dotnet run -c Release --project test/MediatR.Benchmarks
```

Use these to verify that refactors do not regress dispatch performance.

---

## Assembly signing

All projects are **strong-named** via the shared key file `MediatR.snk`:

```xml
<SignAssembly>true</SignAssembly>
<AssemblyOriginatorKeyFile>..\..\MediatR.snk</AssemblyOriginatorKeyFile>
```

This produces a public/private signed assembly. Benefits:

- **Binary compatibility for legacy loaders** — some enterprise host environments still distinguish signed vs unsigned.
- **InternalsVisibleTo via public key** — `MediatR.csproj` exposes internals to `MediatR.Tests` by pinning the test assembly's public key:

    ```xml
    <AssemblyAttribute Include="System.Runtime.CompilerServices.InternalsVisibleToAttribute">
        <_Parameter1>MediatR.Tests, PublicKey=002400000480000094000000060200000024000052534131000400000100010091986edd141861f402457659cb82b56cf6a0d60b3bd2e5aa4ea73d88afa929d278462d6c4c0e2ecbce21948c15514a310a82e6b2e6beaab6cb14230a03bc026609be59f938423f2490fa0033ae87a982fb4950db77d1a4635e14f7727161e93e5511de766ed8e515efd801464b7820a27fca30a32161485824e442cc5ffecfbe</_Parameter1>
    </AssemblyAttribute>
    ```

This ensures only the tests **built against the same private key** can see internals — no other assembly can.

---

## CI/CD

The repository runs GitHub Actions CI (see the `CI` badge in `README.md`). The typical flow:

1. Push to `main` / PR → run `Build.ps1` (build + tests).
2. Tag `v*` on `main` → publish to NuGet via `Push.ps1`.

Environment variables used in CI:

| Variable | Purpose |
|----------|---------|
| `NUGET_URL` | NuGet feed endpoint (usually `https://api.nuget.org/v3/index.json`) |
| `NUGET_API_KEY` | API key to push packages |
| `GITHUB_ACTIONS` | Auto-set by CI; enables `<ContinuousIntegrationBuild>true</ContinuousIntegrationBuild>` in csproj |

---

## Target framework matrix

`MediatR` produces binaries for five TFMs:

| TFM | Notes |
|-----|-------|
| `netstandard2.0` | The widest compatibility target — used from any runtime that supports .NET Standard 2.0 (Xamarin, Unity, older .NET Framework). Depends on `Microsoft.Bcl.AsyncInterfaces` for `IAsyncEnumerable` support. |
| `net462` | Only on Windows builds. Supports classic WinForms / WPF / ASP.NET applications. |
| `net8.0` | Current LTS .NET. |
| `net9.0` | Current STS .NET. |
| `net10.0` | Upcoming LTS — supported as soon as the SDK is available. |

`MediatR.Contracts` targets only `netstandard2.0`. Since it has no runtime logic, one TFM suffices.

### Polyfills

- `IsExternalInit` (dev-only reference): enables C# `init` accessors on `netstandard2.0` / `net462`.
- `Microsoft.Bcl.AsyncInterfaces` (`netstandard2.0` only): provides `IAsyncEnumerable<T>` and `IAsyncDisposable` for the streaming API.

---

## Warnings as errors

`Directory.Build.props`:

```xml
<PropertyGroup>
  <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
  <NoWarn>$(NoWarn);CS1701;CS1702;CS1591;NU1900</NoWarn>
</PropertyGroup>
```

- `TreatWarningsAsErrors` keeps the codebase clean.
- `CS1591` (missing XML doc) is suppressed because the library only documents public types selectively.
- `CS1701` / `CS1702` are binding-redirect version-mismatch warnings, always noisy in multi-TFM libraries.
- `NU1900` is a NuGet vulnerability warning override, used when a transitive dependency has a warning that cannot be resolved at the library level.

---

## Reproducing a release build locally

```powershell
# 1. Clean everything
dotnet clean -c Release

# 2. Build + test
dotnet build -c Release
dotnet test -c Release --no-build -l trx --verbosity=normal

# 3. Pack both packages
dotnet pack ./src/MediatR/MediatR.csproj -c Release -o ./artifacts --no-build
dotnet pack ./src/MediatR.Contracts/MediatR.Contracts.csproj -c Release -o ./artifacts -p:ContinuousIntegrationBuild=true

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
