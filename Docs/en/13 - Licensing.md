# Licensing

AN.MediatR (as distributed by **Lucky Penny Software**) includes a **license validation system** that does not exist in the original `jbogard/MediatR` open-source version. This is the single biggest functional difference between the two.

The licensing system is:

- **JWT-based** — license keys are signed JSON Web Tokens.
- **Non-blocking** — a missing or invalid key produces **warning logs**, never a runtime failure.
- **Lazy** — the license is validated once per application (on first `Mediator` construction), not on every request.
- **Perpetual-aware** — licenses can be marked "perpetual": after expiration they still apply to any build produced *before* the expiration date.

All licensing types live in namespace `MediatR.Licensing` and are declared `internal` — you consume the feature only indirectly via configuration or the static `Mediator.LicenseKey` property.

---

## Files and roles

| File | Role |
|------|------|
| [Edition.cs](../../src/MediatR/Licensing/Edition.cs) | `Community = 0`, `Standard = 1`, `Professional = 2`, `Enterprise = 3` |
| [ProductType.cs](../../src/MediatR/Licensing/ProductType.cs) | `AutoMapper = 0`, `MediatR = 1`, `Bundle = 2` |
| [License.cs](../../src/MediatR/Licensing/License.cs) | Parses a `ClaimsPrincipal` into typed properties |
| [BuildInfo.cs](../../src/MediatR/Licensing/BuildInfo.cs) | Reads the embedded `[assembly: AssemblyMetadata("BuildDateUtc", ...)]` attribute |
| [LicenseAccessor.cs](../../src/MediatR/Licensing/LicenseAccessor.cs) | Resolves the license key, validates the JWT signature, produces a `License` |
| [LicenseValidator.cs](../../src/MediatR/Licensing/LicenseValidator.cs) | Applies the business rules (expiration, perpetual, product type) and logs the result |

---

## The claims in a license

A valid license JWT contains the following claims (see `License.cs`):

| Claim | Type | Meaning |
|-------|------|---------|
| `account_id` | `Guid` | Lucky Penny account identifier |
| `customer_id` | `string` | Customer-facing identifier |
| `sub_id` | `string` | Subscription identifier |
| `iat` | `long` (Unix seconds) | Issued-at / license start date |
| `exp` | `long` (Unix seconds) | Expiration date |
| `edition` | `Edition` | Community / Standard / Professional / Enterprise |
| `type` | `ProductType` | AutoMapper / MediatR / Bundle |
| `perpetual` | `"true"` / `"1"` / other | Whether perpetual licensing is enabled |

The JWT is signed by Lucky Penny Software's RSA private key. AN.MediatR ships the corresponding **public key** hardcoded inside `LicenseAccessor.ValidateKey`:

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
    ValidateLifetime = false    // ← lifetime checked separately by LicenseValidator
};
```

`ValidateLifetime` is deliberately `false` here because AN.MediatR wants to apply its **perpetual** logic before failing on `exp`.

---

## Where the license key comes from

`LicenseAccessor.Initialize()` looks for the key in this order:

```csharp
var key = _configuration?.LicenseKey
          ?? Mediator.LicenseKey
          ?? null;
```

So you can supply it either:

1. **Via DI configuration**:
    ```csharp
    services.AddMediatR(cfg =>
    {
        cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
        cfg.LicenseKey = "<JWT>";
    });
    ```

2. **Via the static property** (useful when you don't use DI, e.g. Blazor WASM):
    ```csharp
    Mediator.LicenseKey = "<JWT>";
    ```

3. **Not at all** — your app will log a warning but continue to work.

If the key is `null`, `LicenseAccessor` returns an **empty `License()`** (`IsConfigured == false`), and `LicenseValidator.Validate(...)` logs a warning but does not throw.

---

## Validation sequence

1. Your app calls `services.AddMediatR(cfg => { cfg.LicenseKey = "..."; ... });`.
2. `ServiceRegistrar.AddRequiredServices` registers singletons:
   - `LicenseAccessor` (factory — requires `ILoggerFactory`).
   - `LicenseValidator` (factory — requires `ILoggerFactory`).
3. `MediatRServiceCollectionExtensions.LicenseChecked = false;` (reset flag).
4. First time `IMediator` is resolved from a scope:
   - The `Mediator` constructor runs: `_serviceProvider.CheckLicense()`.
   - `CheckLicense()` (see below) runs validation once.

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

The `LicenseChecked` flag is a `static bool` in `MediatRServiceCollectionExtensions`. Once set, no more `LicenseAccessor.Current` accesses happen. The flag is reset by `AddRequiredServices` (e.g. if the service collection is rebuilt during tests).

---

## Sync-context safety (commit `b383fa2`)

`LicenseAccessor.ValidateKey` calls the async `JsonWebTokenHandler.ValidateTokenAsync` **synchronously**:

```csharp
var validateResult = Task.Run(() => handler.ValidateTokenAsync(licenseKey, parms)).GetAwaiter().GetResult();
```

The use of `Task.Run(...)` here was introduced in commit `b383fa2` — "Fix license validation deadlock when called from sync context". Without it, resolving `IMediator` from code without a synchronization context (classic ASP.NET, WPF UI thread, `.Result` call) could deadlock because `ValidateTokenAsync` captured and awaited the context.

If you maintain a fork, **do not remove** the `Task.Run(...)` wrapper — it's the deliberate workaround for the deadlock.

---

## `LicenseAccessor` threading model

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

- Field-level lazy initialization guarded by `lock`.
- Idempotent (double-check inside the lock).
- Thread-safe for concurrent first-time reads.

---

## `LicenseValidator.Validate`

Logs all diagnostic output on the `LuckyPennySoftware.MediatR.License` logger category.

### Case 1 — no license

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

`LogWarning` — never throws, never blocks. Suppressible via logging filters.

### Case 2 — expired, non-perpetual

```csharp
_logger.LogError("Your license for the Lucky Penny software MediatR expired {days} days ago.");
_logger.LogError("Please visit https://luckypennysoftware.com to obtain a valid license for the Lucky Penny software MediatR.");
```

### Case 3 — expired, perpetual, build date ≤ expiration

```csharp
_logger.LogInformation(
    "Your license for the Lucky Penny software MediatR expired {expiredDaysAgo} days ago, " +
    "but perpetual licensing is active because the build date ({buildDate:O}) is before the license expiration date ({licenseExpiration:O}).",
    diff, _buildDate, license.ExpirationDate);
```

No error raised — build is considered licensed.

### Case 4 — expired, perpetual, build date not known

```csharp
_logger.LogWarning(
    "Your license for the Lucky Penny software MediatR has perpetual licensing enabled, " +
    "but the build date could not be determined. Perpetual licensing cannot be applied. " +
    "Please ensure the assembly metadata is correctly embedded at build time.");
// + the LogError from Case 2
```

Falls back to the expired-error path.

### Case 5 — wrong product type

```csharp
if (license.ProductType!.Value != ProductType.MediatR && license.ProductType.Value != ProductType.Bundle)
    errors.Add("Your Lucky Penny software license does not include MediatR.");
```

A `ProductType.AutoMapper` license is **not** accepted for MediatR.

### Case 6 — valid license

```csharp
_logger.LogInformation(
    "You have a valid license key for the Lucky Penny software {type} {edition} edition. The license expires on {licenseExpiration}.",
    license.ProductType, license.Edition, license.ExpirationDate);
```

---

## Perpetual licensing explained

A perpetual license allows you to **keep running any version of the library built before the expiration date**, even after it expires. It's a common pattern in commercial .NET libraries.

The mechanism requires knowing **when the assembly was built**. `MediatR.csproj` embeds that information via a custom MSBuild target:

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

- Runs `git log -1 --format=%cI` (latest commit ISO 8601 date) before `CoreCompile`.
- Falls back to `DateTime.UtcNow` if git is not available.
- Emits `[assembly: AssemblyMetadata("BuildDateUtc", "<ISO8601>")]` into a generated C# file that is added to the compilation.

At runtime, `BuildInfo.GetBuildDate()` reads that attribute:

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

`LicenseValidator` receives this via its constructor:

```csharp
public LicenseValidator(ILoggerFactory loggerFactory) : this(loggerFactory, BuildInfo.BuildDate) { }
public LicenseValidator(ILoggerFactory loggerFactory, DateTimeOffset? buildDate) { ... }
```

So tests can override `buildDate` to exercise perpetual scenarios without rebuilding the assembly.

---

## Quieting the license warning

The library's author explicitly supports log filtering as a way to silence the "no valid license" warning:

> Turn off the license warning by configuring logging in your logging start configuration:
> `builder.Logging.AddFilter("LuckyPennySoftware.MediatR.License", LogLevel.None);`

Why not an opt-out flag? Because logging filters are the standard .NET mechanism for adjusting log noise, work with any logging provider, and avoid yet another configuration switch.

---

## Requirements

- **`ILoggerFactory` must be in the container** when `AddMediatR(...)` is called. If not, the singleton factory registrations for `LicenseAccessor` and `LicenseValidator` throw:
    ```
    InvalidOperationException: MediatR requires ILoggerFactory to be registered.
    Call services.AddLogging() before services.AddMediatR().
    ```
- The JWT library (`Microsoft.IdentityModel.JsonWebTokens`) is a transitive dependency of `MediatR`. You don't install it yourself.
- `LicenseChecked` is static and process-wide. Calling `AddMediatR(...)` resets it, so the next `Mediator` construction re-validates.

---

## FAQ

**Q: Does AN.MediatR phone home?**  
No. License validation is purely local — the JWT is verified with a hardcoded public key. No network requests are made.

**Q: What if I'm on Blazor WASM / a client app?**  
The README states explicitly: *"The license key does not need to be set on client applications (such as Blazor WASM)."* You can set it if you want, but you don't need to.

**Q: Will my app crash if my license expires?**  
No. You'll see log errors but the mediator continues to work.

**Q: Can I disable licensing entirely?**  
Not without forking. You can, however, silence the logs with a logging filter (see above).

**Q: Where do I buy a license?**  
https://luckypennysoftware.com.

**Q: What's the difference between editions?**  
Editions are tracked in the `Edition` enum (Community / Standard / Professional / Enterprise) and logged as information, but the validator does not currently enforce different feature sets per edition. Any non-`AutoMapper` `ProductType` is accepted.
