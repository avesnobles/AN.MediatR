# Licenciamiento

AN.MediatR (tal como lo distribuye **Lucky Penny Software**) incluye un **sistema de validación de licencia** que no existe en el MediatR original de código abierto (`jbogard/MediatR`). Es la mayor diferencia funcional entre ambos.

El sistema de licenciamiento es:

- **Basado en JWT** — las claves de licencia son JSON Web Tokens firmados.
- **No bloqueante** — una clave ausente o inválida produce **warnings en el log**, nunca una excepción en runtime.
- **Perezoso** — la licencia se valida una sola vez por aplicación (en la primera construcción de `Mediator`), no por request.
- **Consciente de licencias perpetuas** — las licencias pueden marcarse "perpetuas": tras expirar siguen aplicando a cualquier build producida **antes** de la fecha de expiración.

Todos los tipos de licenciamiento viven en el namespace `MediatR.Licensing` y están declarados como `internal` — los consumes solo indirectamente vía configuración o la propiedad estática `Mediator.LicenseKey`.

---

## Archivos y roles

| Archivo | Rol |
|---------|-----|
| [Edition.cs](../../src/MediatR/Licensing/Edition.cs) | `Community = 0`, `Standard = 1`, `Professional = 2`, `Enterprise = 3` |
| [ProductType.cs](../../src/MediatR/Licensing/ProductType.cs) | `AutoMapper = 0`, `MediatR = 1`, `Bundle = 2` |
| [License.cs](../../src/MediatR/Licensing/License.cs) | Parsea un `ClaimsPrincipal` en propiedades tipadas |
| [BuildInfo.cs](../../src/MediatR/Licensing/BuildInfo.cs) | Lee el atributo embebido `[assembly: AssemblyMetadata("BuildDateUtc", ...)]` |
| [LicenseAccessor.cs](../../src/MediatR/Licensing/LicenseAccessor.cs) | Resuelve la clave de licencia, valida la firma JWT, produce un `License` |
| [LicenseValidator.cs](../../src/MediatR/Licensing/LicenseValidator.cs) | Aplica las reglas de negocio (expiración, perpetua, tipo de producto) y registra el resultado |

---

## Los claims de una licencia

Una licencia JWT válida contiene los siguientes claims (ver `License.cs`):

| Claim | Tipo | Significado |
|-------|------|-------------|
| `account_id` | `Guid` | Identificador de cuenta de Lucky Penny |
| `customer_id` | `string` | Identificador de cliente |
| `sub_id` | `string` | Identificador de suscripción |
| `iat` | `long` (seg Unix) | Fecha de emisión / inicio |
| `exp` | `long` (seg Unix) | Fecha de expiración |
| `edition` | `Edition` | Community / Standard / Professional / Enterprise |
| `type` | `ProductType` | AutoMapper / MediatR / Bundle |
| `perpetual` | `"true"` / `"1"` / otro | Si está habilitada la licencia perpetua |

El JWT está firmado con la clave RSA privada de Lucky Penny Software. AN.MediatR incluye la **clave pública** correspondiente hardcodeada en `LicenseAccessor.ValidateKey`:

```csharp
var rsa = new RSAParameters
{
    Exponent = Convert.FromBase64String("AQAB"),
    Modulus = Convert.FromBase64String("2LTtdJV2b0mYoRqChRCfcqnbpKvsiCcDYwJ+qPtvQXWXozOhGo02/V0SWMFBdb...==")
};

var key = new RsaSecurityKey(rsa) { KeyId = "LuckyPennySoftwareLicenseKey/bbb13acb59904d89b4cb1c85f088ccf9" };

var parms = new TokenValidationParameters
{
    ValidIssuer = "https://luckypennysoftware.com",
    ValidAudience = "LuckyPennySoftware",
    IssuerSigningKey = key,
    ValidateLifetime = false    // ← el lifetime lo comprueba LicenseValidator aparte
};
```

`ValidateLifetime` se deja deliberadamente en `false` porque AN.MediatR quiere aplicar su lógica **perpetua** antes de fallar por `exp`.

---

## De dónde viene la clave de licencia

`LicenseAccessor.Initialize()` busca la clave en este orden:

```csharp
var key = _configuration?.LicenseKey
          ?? Mediator.LicenseKey
          ?? null;
```

Así que puedes proveerla:

1. **Mediante configuración DI**:
    ```csharp
    services.AddMediatR(cfg =>
    {
        cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
        cfg.LicenseKey = "<JWT>";
    });
    ```

2. **Mediante la propiedad estática** (útil cuando no usas DI, p. ej. Blazor WASM):
    ```csharp
    Mediator.LicenseKey = "<JWT>";
    ```

3. **Sin ponerla** — tu app mostrará un warning pero seguirá funcionando.

Si la clave es `null`, `LicenseAccessor` devuelve una **`License()` vacía** (`IsConfigured == false`), y `LicenseValidator.Validate(...)` registra un warning sin lanzar.

---

## Secuencia de validación

1. Tu app llama a `services.AddMediatR(cfg => { cfg.LicenseKey = "..."; ... });`.
2. `ServiceRegistrar.AddRequiredServices` registra singletons:
   - `LicenseAccessor` (factory — requiere `ILoggerFactory`).
   - `LicenseValidator` (factory — requiere `ILoggerFactory`).
3. `MediatRServiceCollectionExtensions.LicenseChecked = false;` (reset).
4. La primera vez que se resuelve `IMediator` desde un scope:
   - El constructor de `Mediator` ejecuta `_serviceProvider.CheckLicense()`.
   - `CheckLicense()` (ver abajo) ejecuta la validación una vez.

```csharp
internal static void CheckLicense(this IServiceProvider serviceProvider)
{
    if (LicenseChecked == false)
    {
        var licenseAccessor = serviceProvider.GetRequiredService<LicenseAccessor>();
        var licenseValidator = serviceProvider.GetRequiredService<LicenseValidator>();

        var license = licenseAccessor.Current;
        licenseValidator.Validate(license);
    }

    LicenseChecked = true;
}
```

La bandera `LicenseChecked` es un `static bool` en `MediatRServiceCollectionExtensions`. Una vez puesta, no hay más accesos a `LicenseAccessor.Current`. `AddRequiredServices` la resetea (p. ej. si la service collection se reconstruye en tests).

---

## Seguridad en contexto síncrono (commit `b383fa2`)

`LicenseAccessor.ValidateKey` llama al asíncrono `JsonWebTokenHandler.ValidateTokenAsync` **síncronamente**:

```csharp
var validateResult = Task.Run(() => handler.ValidateTokenAsync(licenseKey, parms)).GetAwaiter().GetResult();
```

El uso de `Task.Run(...)` aquí se introdujo en el commit `b383fa2` — "Fix license validation deadlock when called from sync context". Sin él, resolver `IMediator` desde código sin contexto de sincronización (ASP.NET clásico, hilo de UI WPF, llamada `.Result`) podía deadlockear porque `ValidateTokenAsync` capturaba y esperaba el contexto.

Si mantienes un fork, **no elimines** el wrapper `Task.Run(...)` — es el workaround deliberado del deadlock.

---

## Modelo de threading de `LicenseAccessor`

```csharp
private License? _license;
private readonly object _lock = new();

public License Current => _license ??= Initialize();

private License Initialize()
{
    lock (_lock)
    {
        if (_license != null) return _license;

        var key = _configuration?.LicenseKey ?? Mediator.LicenseKey ?? null;
        if (key == null) return new License();

        var licenseClaims = ValidateKey(key);
        return licenseClaims.Any()
            ? new License(new ClaimsPrincipal(new ClaimsIdentity(licenseClaims)))
            : new License();
    }
}
```

- Inicialización perezosa a nivel de campo protegida por `lock`.
- Idempotente (double-check dentro del lock).
- Thread-safe para lecturas concurrentes en el primer uso.

---

## `LicenseValidator.Validate`

Todo el output de diagnóstico usa la categoría de logger `LuckyPennySoftware.MediatR.License`.

### Caso 1 — sin licencia

```csharp
if (license is not { IsConfigured: true })
{
    _logger.LogWarning(
        "You do not have a valid license key for the Lucky Penny software MediatR. " +
        "This is allowed for development and testing scenarios. " +
        "If you are running in production you are required to have a licensed version. " +
        "Please visit https://luckypennysoftware.com to obtain a valid license.");
    return;
}
```

`LogWarning` — nunca lanza, nunca bloquea. Suprimible mediante filtros de logging.

### Caso 2 — expirada, no perpetua

```csharp
_logger.LogError("Your license for the Lucky Penny software MediatR expired {days} days ago.");
_logger.LogError("Please visit https://luckypennysoftware.com to obtain a valid license for the Lucky Penny software MediatR.");
```

### Caso 3 — expirada, perpetua, fecha de build ≤ expiración

```csharp
_logger.LogInformation(
    "Your license for the Lucky Penny software MediatR expired {expiredDaysAgo} days ago, " +
    "but perpetual licensing is active because the build date ({buildDate:O}) is before the license expiration date ({licenseExpiration:O}).",
    diff, _buildDate, license.ExpirationDate);
```

No se registra error — la build se considera licenciada.

### Caso 4 — expirada, perpetua, fecha de build desconocida

```csharp
_logger.LogWarning(
    "Your license for the Lucky Penny software MediatR has perpetual licensing enabled, " +
    "but the build date could not be determined. Perpetual licensing cannot be applied. " +
    "Please ensure the assembly metadata is correctly embedded at build time.");
// + el LogError del caso 2
```

Cae a la ruta de error de expiración.

### Caso 5 — tipo de producto incorrecto

```csharp
if (license.ProductType!.Value != ProductType.MediatR && license.ProductType.Value != ProductType.Bundle)
    errors.Add("Your Lucky Penny software license does not include MediatR.");
```

Una licencia `ProductType.AutoMapper` **no** es válida para MediatR.

### Caso 6 — licencia válida

```csharp
_logger.LogInformation(
    "You have a valid license key for the Lucky Penny software {type} {edition} edition. The license expires on {licenseExpiration}.",
    license.ProductType, license.Edition, license.ExpirationDate);
```

---

## Licenciamiento perpetuo explicado

Una licencia perpetua te permite **seguir ejecutando cualquier versión de la librería construida antes de la fecha de expiración**, incluso después de expirar. Es un patrón común en librerías comerciales .NET.

El mecanismo requiere saber **cuándo se construyó el ensamblado**. `MediatR.csproj` embebe esa información con un target MSBuild custom:

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

- Ejecuta `git log -1 --format=%cI` (fecha del último commit en ISO 8601) antes de `CoreCompile`.
- Cae a `DateTime.UtcNow` si git no está disponible.
- Emite `[assembly: AssemblyMetadata("BuildDateUtc", "<ISO8601>")]` en un archivo C# generado que se añade a la compilación.

En runtime, `BuildInfo.GetBuildDate()` lee ese atributo:

```csharp
internal static class BuildInfo
{
    public static DateTimeOffset? BuildDate { get; } = GetBuildDate();

    private static DateTimeOffset? GetBuildDate()
    {
        var assembly = typeof(BuildInfo).Assembly;
        var attr = assembly
            .GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(a => a.Key == "BuildDateUtc");
        return attr?.Value != null && DateTimeOffset.TryParse(attr.Value, out var d) ? d : null;
    }
}
```

`LicenseValidator` lo recibe por constructor:

```csharp
public LicenseValidator(ILoggerFactory loggerFactory) : this(loggerFactory, BuildInfo.BuildDate) { }
public LicenseValidator(ILoggerFactory loggerFactory, DateTimeOffset? buildDate) { ... }
```

Así los tests pueden sobrescribir `buildDate` para probar escenarios perpetuos sin reconstruir el ensamblado.

---

## Silenciar el warning de licencia

El autor soporta explícitamente filtros de logging como forma de silenciar el warning de "no valid license":

> Turn off the license warning by configuring logging in your logging start configuration:
> `builder.Logging.AddFilter("LuckyPennySoftware.MediatR.License", LogLevel.None);`

¿Por qué no un flag para desactivarlo? Porque los filtros son el mecanismo estándar de .NET, funcionan con cualquier provider y evitan otro switch de configuración.

---

## Requisitos

- **`ILoggerFactory` debe estar en el contenedor** al llamar a `AddMediatR(...)`. Si no, los registros factory de `LicenseAccessor` y `LicenseValidator` lanzan:
    ```
    InvalidOperationException: MediatR requires ILoggerFactory to be registered.
    Call services.AddLogging() before services.AddMediatR().
    ```
- La librería JWT (`Microsoft.IdentityModel.JsonWebTokens`) es dependencia transitiva de `MediatR`. No la instalas tú.
- `LicenseChecked` es estática a nivel de proceso. Llamar a `AddMediatR(...)` la resetea, así que la siguiente construcción de `Mediator` revalida.

---

## FAQ

### ¿AN.MediatR hace phone-home?

No. La validación es puramente local — el JWT se verifica con una clave pública hardcodeada. No hay llamadas de red.

### ¿Y si estoy en Blazor WASM / app cliente?

El README lo dice explícitamente: *"The license key does not need to be set on client applications (such as Blazor WASM)."* Puedes ponerla si quieres, pero no es necesaria.

### ¿Mi app crasheará si mi licencia expira?

No. Verás errores de log pero el mediator sigue funcionando.

### ¿Puedo desactivar el licenciamiento por completo?

No sin forkear. Sí puedes silenciar los logs con un filtro de logging (ver arriba).

### ¿Dónde compro una licencia?

https://luckypennysoftware.com.

### ¿Qué diferencia hay entre ediciones?

Las ediciones se trackean en el enum `Edition` (Community / Standard / Professional / Enterprise) y se loguean como información, pero el validator actualmente no impone diferentes conjuntos de funciones por edición. Cualquier `ProductType` que no sea `AutoMapper` se acepta.
