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

El helper `exec` es un wrapper estilo psake que lanza una excepción .NET cuando el comando `dotnet` anterior falla, para que los fallos en pipeline suban claramente.

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

- `--skip-duplicate` es idempotente — re-ejecutar un push de una versión ya subida es no-op.
- Variables de entorno: `NUGET_URL` (URL del feed) y `NUGET_API_KEY` (API key). Ponlas como secrets del CI.

Para feeds internos (Azure Artifacts, GitHub Packages, MyGet), sobrescribe `NUGET_URL` y genera una API key con permiso de push.

---

## Versionado con MinVer

Fuente: [src/MediatR/MediatR.csproj](../../src/MediatR/MediatR.csproj) — `<PackageReference Include="MinVer" ... />` + `<MinVerTagPrefix>v</MinVerTagPrefix>`.

MinVer calcula la versión del paquete a partir de tags git:

- El último tag que casa `v*` (p. ej. `v13.2.0`) es la versión base.
- Si el commit actual está **taggeado**, la versión es exactamente el tag.
- Si no, MinVer añade una etiqueta pre-release y altura (`v13.2.1-alpha.0.3`).
- Builds de CI sin tags quedan como `0.0.0-alpha.0.<altura>` por defecto.

Para cortar una release:

1. Commit en `main`.
2. `git tag v13.2.0`.
3. `git push origin main --tags`.
4. CI construye el tag → publica `MediatR.13.2.0.nupkg`.

---

## Metadatos de build: git log, fecha de build, determinismo

`MediatR.csproj` tiene un target custom que embebe la fecha de build en el ensamblado:

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

- Ejecuta `git log -1 --format=%cI` para la fecha del último commit en ISO 8601.
- Cae a `DateTime.UtcNow` si git no está disponible.
- Escribe un `BuildDateGenerated.cs` con un atributo `AssemblyMetadata`.
- Compila ese archivo dentro del ensamblado.

Consumidores runtime (`BuildInfo.cs`) leen el atributo para licenciamiento perpetuo — ver [Licenciamiento](13%20-%20Licenciamiento.md).

### Determinismo

`Directory.Build.props` pone `<Deterministic>true</Deterministic>` + `<ContinuousIntegrationBuild>true</ContinuousIntegrationBuild>` cuando corre bajo GitHub Actions, lo cual, combinado con SourceLink, produce binarios reproducibles. Cualquiera puede verificar que un `MediatR.13.2.0.nupkg` publicado proviene de un commit específico.

---

## Resumen de tests

### `test/MediatR.Tests`

Suite xUnit principal. Localizada en `test/MediatR.Tests/`. Cubre:

- Dispatch request/response (genérico, void, dinámico).
- Publicación de notificaciones (secuencial y paralela, publishers custom).
- Composición de pipeline behaviors (orden, propagación de cancelación, cortocircuito).
- Procesadores pre y post.
- Handlers y actions de excepciones (orden de prioridad, `ApplyForUnhandledExceptions` vs. `ApplyForAllExceptions`).
- Dispatch de stream requests y composición de stream pipeline behaviors.
- Licenciamiento: válido, inválido, expirado, perpetuo, tipo de producto incorrecto, sin clave.
- Casos extremos de `HandlersOrderer` / `ObjectDetails`.
- Thread-safety de las cachés estáticas de wrappers.
- Semántica de `Unit.Value`, `Unit.Task`, comparación y equality.

Como `MediatR.csproj` incluye un `InternalsVisibleTo` para este ensamblado de tests, los tests pueden ejercitar tipos `internal` (`Licensing`, `Internal`, wrappers).

### `test/MediatR.DependencyInjectionTests`

Se centra en el registro:

- Comportamiento de `AddMediatR(Action<MediatRServiceConfiguration>)`.
- Escaneo de `ServiceRegistrar` (handlers cerrados, handlers de genéricos abiertos, notificaciones, handlers de excepciones).
- Filtro `TypeEvaluator`.
- Bandera `AutoRegisterRequestProcessors`.
- Límites de registro (`MaxGenericTypeParameters`, `MaxTypesClosing`, `MaxGenericTypeRegistrations`, `RegistrationTimeout`).
- Idempotencia ante registros duplicados.
- Accesibilidad de handlers (public vs internal vs anidado).

### `test/MediatR.Benchmarks`

Microbenchmarks con `BenchmarkDotNet`:

- Latencia de `IMediator.Send` (frío vs. caliente).
- Latencia de `IMediator.Publish` (1 vs. N handlers).
- Coste de arranque de `CreateStream`.
- Overhead de pipeline behaviors por paso.
- Dispatch dinámico (reflexivo) vs. tipado.

Ejecuta con:

```bash
dotnet run -c Release --project test/MediatR.Benchmarks
```

Úsalos para verificar que refactorizaciones no regresan el rendimiento del dispatch.

---

## Firma de ensamblados

Todos los proyectos están **strong-named** con la clave compartida `MediatR.snk`:

```xml
<SignAssembly>true</SignAssembly>
<AssemblyOriginatorKeyFile>..\..\MediatR.snk</AssemblyOriginatorKeyFile>
```

Produce un ensamblado firmado público/privado. Beneficios:

- **Compatibilidad binaria con loaders legacy** — algunos entornos empresariales de hosting aún distinguen firmado vs. no firmado.
- **InternalsVisibleTo vía clave pública** — `MediatR.csproj` expone internos a `MediatR.Tests` fijando la clave pública del ensamblado de test:

    ```xml
    <AssemblyAttribute Include="System.Runtime.CompilerServices.InternalsVisibleToAttribute">
        <_Parameter1>MediatR.Tests, PublicKey=002400000480000094000000060200000024000052534131000400000100010091986edd141861f402457659cb82b56cf6a0d60b3bd2e5aa4ea73d88afa929d278462d6c4c0e2ecbce21948c15514a310a82e6b2e6beaab6cb14230a03bc026609be59f938423f2490fa0033ae87a982fb4950db77d1a4635e14f7727161e93e5511de766ed8e515efd801464b7820a27fca30a32161485824e442cc5ffecfbe</_Parameter1>
    </AssemblyAttribute>
    ```

Esto asegura que solo los tests **construidos con la misma clave privada** pueden ver internos — ningún otro ensamblado.

---

## CI/CD

El repositorio corre GitHub Actions CI (ver el badge `CI` en `README.md`). Flujo típico:

1. Push a `main` / PR → ejecuta `Build.ps1` (build + tests).
2. Tag `v*` en `main` → publica a NuGet vía `Push.ps1`.

Variables de entorno usadas en CI:

| Variable | Propósito |
|----------|-----------|
| `NUGET_URL` | Endpoint del feed NuGet (usualmente `https://api.nuget.org/v3/index.json`) |
| `NUGET_API_KEY` | API key para empujar paquetes |
| `GITHUB_ACTIONS` | Auto-definida por CI; activa `<ContinuousIntegrationBuild>true</ContinuousIntegrationBuild>` en csproj |

---

## Matriz de frameworks destino

`MediatR` produce binarios para cinco TFMs:

| TFM | Notas |
|-----|-------|
| `netstandard2.0` | Compatibilidad más amplia — usable desde cualquier runtime que soporte .NET Standard 2.0 (Xamarin, Unity, .NET Framework antiguo). Depende de `Microsoft.Bcl.AsyncInterfaces` para `IAsyncEnumerable`. |
| `net462` | Solo en builds Windows. Soporta WinForms / WPF / ASP.NET clásico. |
| `net8.0` | LTS actual. |
| `net9.0` | STS actual. |
| `net10.0` | Próxima LTS — soportado en cuanto el SDK esté disponible. |

`MediatR.Contracts` apunta solo a `netstandard2.0`. Al no tener lógica, un TFM basta.

### Polyfills

- `IsExternalInit` (referencia solo-dev): habilita accesores C# `init` en `netstandard2.0` / `net462`.
- `Microsoft.Bcl.AsyncInterfaces` (solo `netstandard2.0`): provee `IAsyncEnumerable<T>` e `IAsyncDisposable` para la API de streaming.

---

## Warnings como errores

`Directory.Build.props`:

```xml
<PropertyGroup>
  <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
  <NoWarn>$(NoWarn);CS1701;CS1702;CS1591;NU1900</NoWarn>
</PropertyGroup>
```

- `TreatWarningsAsErrors` mantiene el código limpio.
- `CS1591` (falta docstring XML) se suprime porque la librería solo documenta tipos públicos selectivamente.
- `CS1701` / `CS1702` son warnings de redirección de binding entre versiones, siempre ruidosos en librerías multi-TFM.
- `NU1900` es override de warning de vulnerabilidad NuGet, usado cuando una dependencia transitiva tiene un warning no resoluble a nivel de librería.

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
