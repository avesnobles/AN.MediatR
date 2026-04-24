# Build, Tests y Publicación

Este capítulo documenta el pipeline de build, los proyectos de test y el flujo de publicación a NuGet de AN.MediatR.

---

## Build.ps1

Fuente: [Build.ps1](../../Build.ps1).

```powershell
# Tomado de psake
function Exec { ... }  # helper que lanza excepción cuando $lastexitcode != 0

$artifacts = ".\artifacts"
if (Test-Path $artifacts) { Remove-Item $artifacts -Force -Recurse }

exec { & dotnet clean -c Release }
exec { & dotnet build -c Release }
exec { & dotnet test  -c Release --no-build -l trx --verbosity=normal }
exec { & dotnet pack  .\src\MediatR\MediatR.csproj -c Release -o $artifacts --no-build }
```

Lo que hace:

1. Limpia la carpeta `artifacts/`.
2. `dotnet clean -c Release` — limpia bin/obj.
3. `dotnet build -c Release` — restaura y compila todo.
4. `dotnet test -c Release --no-build -l trx` — ejecuta todos los tests, produciendo TRX para integración CI.
5. `dotnet pack src/MediatR/MediatR.csproj -c Release -o ./artifacts --no-build` — empaqueta solo el paquete principal `MediatR`.

Salida: un único `MediatR.<version>.nupkg` (más su `.snupkg` de símbolos) en `artifacts/`.

> Nota: `Build.ps1` **no** empaqueta `MediatR.Contracts` — eso es trabajo de `BuildContracts.ps1`.

---

## BuildContracts.ps1

Build y pack del paquete de contratos por separado. Forma típica:

```powershell
dotnet clean ./src/MediatR.Contracts/MediatR.Contracts.csproj -c Release
dotnet build ./src/MediatR.Contracts/MediatR.Contracts.csproj -c Release -p:ContinuousIntegrationBuild=true
dotnet pack  ./src/MediatR.Contracts/MediatR.Contracts.csproj -c Release -o ./artifacts
```

- `ContinuousIntegrationBuild=true` habilita builds deterministas — importante para que `Microsoft.SourceLink.GitHub` embeba metadatos de commit reproducibles.
- Los contratos se publican de forma independiente (versión `2.0.1` hardcodeada en el csproj), no atados al versionado MinVer del paquete principal.

---

## Push.ps1

Sube cada `.nupkg` de `./artifacts` al feed NuGet especificado por variables de entorno:

```powershell
if ($env:NUGET_API_KEY) {
    Get-ChildItem ./artifacts -Filter "*.nupkg" | ForEach-Object {
        dotnet nuget push $_.FullName --source $env:NUGET_URL --api-key $env:NUGET_API_KEY --skip-duplicate
    }
}
```

- `--skip-duplicate` es idempotente.
- Variables de entorno: `NUGET_URL` y `NUGET_API_KEY`. Ponlas como secrets del CI.

---

## Versionado con MinVer

MinVer calcula la versión del paquete a partir de tags git:

- El último tag que casa `v*` (p. ej. `v12.5.0`) es la versión base.
- Si el commit actual está **taggeado**, la versión es exactamente el tag.
- Si no, MinVer añade una etiqueta pre-release y altura (`v12.5.1-alpha.0.3`).
- Builds de CI sin tags quedan como `0.0.0-alpha.0.<altura>` por defecto.

Para cortar una release:

1. Commit en tu rama de release.
2. `git tag v12.5.0`.
3. `git push origin <rama> --tags`.
4. CI construye el tag → publica el `.nupkg` correspondiente.

> AN.MediatR arranca su numeración desde el punto de fork v12.5. Los futuros números de versión dependerán de la política SemVer que adopte el equipo AN.

---

## Determinismo y source linking

`Directory.Build.props` pone `<Deterministic>true</Deterministic>` y cada csproj pone `<ContinuousIntegrationBuild>true</ContinuousIntegrationBuild>` bajo GitHub Actions. Combinado con `Microsoft.SourceLink.GitHub`, produce binarios reproducibles.

---

## Resumen de tests

### `test/MediatR.Tests`

Suite xUnit completa. Cubre:

- Dispatch request/response (genérico, void, dinámico).
- Publicación de notificaciones (secuencial y paralela, publishers custom).
- Composición de pipeline behaviors (orden, propagación de cancelación, cortocircuito).
- Procesadores pre y post.
- Handlers y actions de excepciones (orden de prioridad, `ApplyForUnhandledExceptions` vs. `ApplyForAllExceptions`).
- Dispatch de stream requests y composición de stream pipeline behaviors.
- Casos extremos de `HandlersOrderer` / `ObjectDetails`.
- Semántica de `Unit.Value`, `Unit.Task`, comparación y equality.
- Registro y escaneo DI (dentro de `test/MediatR.Tests/MicrosoftExtensionsDI/`): escaneo, filtro `TypeEvaluator`, `AutoRegisterRequestProcessors`, límites de registro, idempotencia ante duplicados, accesibilidad.

> En v12.5 no hay proyecto separado `MediatR.DependencyInjectionTests` — todo vive en `MediatR.Tests`.

### `test/MediatR.Benchmarks`

Microbenchmarks con `BenchmarkDotNet`:

- Latencia de `IMediator.Send` (frío vs. caliente).
- Latencia de `IMediator.Publish` (1 vs. N handlers).
- Coste de arranque de `CreateStream`.
- Overhead de pipeline behaviors por paso.
- Dispatch dinámico vs. tipado.

Ejecuta con:

```bash
dotnet run -c Release --project test/MediatR.Benchmarks
```

---

## Firma de ensamblados

Ambos proyectos están **strong-named** con `MediatR.snk`:

```xml
<SignAssembly>true</SignAssembly>
<AssemblyOriginatorKeyFile>..\..\MediatR.snk</AssemblyOriginatorKeyFile>
```

En v12.5 **no hay `InternalsVisibleTo`** en `MediatR.csproj` — el proyecto de tests no necesita acceso a tipos internos.

---

## CI/CD

El repositorio es CI-friendly: `Build.ps1` corre el pipeline completo local o en CI, `Push.ps1` publica los artefactos.

Variables de entorno usadas por `Push.ps1`:

| Variable | Propósito |
|----------|-----------|
| `NUGET_URL` | Endpoint del feed NuGet |
| `NUGET_API_KEY` | API key para empujar paquetes |
| `GITHUB_ACTIONS` | Auto-definida por CI; activa `<ContinuousIntegrationBuild>true</ContinuousIntegrationBuild>` |

---

## Matriz de frameworks destino

`MediatR` produce binarios para dos TFMs:

| TFM | Notas |
|-----|-------|
| `netstandard2.0` | Compatibilidad más amplia. Depende de `Microsoft.Bcl.AsyncInterfaces` para `IAsyncEnumerable`. |
| `net6.0` | .NET 6 (el actual en el momento de MediatR v12.5). |

`MediatR.Contracts` apunta solo a `netstandard2.0`.

> Si el fork AN necesita TFMs más nuevos (net8.0, net9.0, etc.), puede añadirlos en `<TargetFrameworks>` de `MediatR.csproj` — nada en la librería exige los antiguos específicamente.

### Polyfills

- `IsExternalInit` (solo-dev): habilita accesores C# `init` en `netstandard2.0`.
- `Microsoft.Bcl.AsyncInterfaces` (solo `netstandard2.0`): aporta `IAsyncEnumerable<T>` e `IAsyncDisposable`.

---

## Warnings como errores

`Directory.Build.props`:

```xml
<PropertyGroup>
  <LangVersion>10.0</LangVersion>
  <NoWarn>$(NoWarn);CS1701;CS1702;CS1591</NoWarn>
  <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
</PropertyGroup>
```

- `TreatWarningsAsErrors` mantiene el código limpio.
- `CS1591` (falta docstring XML) se suprime porque solo se documentan tipos públicos selectivamente.
- `CS1701` / `CS1702` son warnings de redirección de binding.

---

## Reproducir una release local

```powershell
# 1. Limpiar todo
dotnet clean -c Release

# 2. Build + test
dotnet build -c Release
dotnet test -c Release --no-build -l trx --verbosity=normal

# 3. Empaquetar ambos
dotnet pack ./src/MediatR/MediatR.csproj -c Release -o ./artifacts --no-build
dotnet pack ./src/MediatR.Contracts/MediatR.Contracts.csproj -c Release -o ./artifacts -p:ContinuousIntegrationBuild=true

# 4. (Opcional) Push
$env:NUGET_URL = "https://api.nuget.org/v3/index.json"
$env:NUGET_API_KEY = "<key>"
./Push.ps1
```

O simplemente:

```powershell
./Build.ps1
./BuildContracts.ps1
./Push.ps1
```
