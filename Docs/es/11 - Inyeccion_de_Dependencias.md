# Inyección de Dependencias

AN.MediatR se integra nativamente con `Microsoft.Extensions.DependencyInjection` mediante el método extensión `AddMediatR`. Otros contenedores (Autofac, DryIoc, Lamar, LightInject, SimpleInjector, Stashbox, Windsor) se soportan mediante patrones adaptadores mostrados en la carpeta `samples/` — ver [Integración de Contenedores DI](16%20-%20Integracion_Contenedores_DI.md).

Este documento se centra en la integración nativa con `IServiceCollection`.

---

## Punto de entrada

```csharp
namespace Microsoft.Extensions.DependencyInjection;

public static class MediatRServiceCollectionExtensions
{
    public static IServiceCollection AddMediatR(
        this IServiceCollection services,
        Action<MediatRServiceConfiguration> configuration);

    public static IServiceCollection AddMediatR(
        this IServiceCollection services,
        MediatRServiceConfiguration configuration);
}
```

Fuente: [src/MediatR/MicrosoftExtensionsDI/MediatRServiceCollectionExtensions.cs](../../src/MediatR/MicrosoftExtensionsDI/MediatRServiceCollectionExtensions.cs).

> Las extensiones viven en el namespace `Microsoft.Extensions.DependencyInjection` así que no necesitas un `using` adicional si ya tienes `AddControllers()`, `AddLogging()`, etc.

### Registro mínimo

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
});
```

Equivale a: "escanea el ensamblado actual en busca de todos los handlers / comportamientos / procesadores / handlers de excepciones y regístralos como transient".

### Qué obtienes tras `AddMediatR`

`ServiceRegistrar` dentro de `AddMediatR(...)` registra:

1. **`IMediator`** → `Mediator` (lifetime = configuración, `Transient` por defecto).
2. **`ISender`** e **`IPublisher`** → factory que devuelve el `IMediator` resuelto (comparten la misma instancia por scope).
3. **`MediatRServiceConfiguration`** como singleton (para introspección aguas abajo).
4. **`LicenseAccessor`** y **`LicenseValidator`** como singletons (requieren `ILoggerFactory`).
5. **`INotificationPublisher`** según `cfg.NotificationPublisher` o `cfg.NotificationPublisherType`.
6. **Todos los `IRequestHandler<>`, `IRequestHandler<,>`, `INotificationHandler<>`, `IStreamRequestHandler<,>`** descubiertos como transient.
7. **Todos los `IRequestExceptionHandler<,,>`, `IRequestExceptionAction<,>`** descubiertos como transient (multi-instancia).
8. **Decoradores de procesadores pre/post** (si hay procesadores registrados).
9. **Decoradores de actions / handlers de excepciones** (si hay handlers / actions — controlado por `RequestExceptionActionProcessorStrategy`).
10. **Todos los comportamientos (pipeline y stream) explícitamente añadidos** en `cfg.BehaviorsToRegister` / `cfg.StreamBehaviorsToRegister`.

El escaneo de ensamblados no es idempotente por defecto — `AddMediatR` puede llamarse varias veces, cada vez con un conjunto distinto de ensamblados, pero prefiere una llamada única con todos.

---

## `MediatRServiceConfiguration`

Fuente: [src/MediatR/MicrosoftExtensionsDI/MediatrServiceConfiguration.cs](../../src/MediatR/MicrosoftExtensionsDI/MediatrServiceConfiguration.cs).

Configuración fluida. Todos los métodos devuelven `this` para encadenarlos.

### Registro de ensamblados

```csharp
cfg.RegisterServicesFromAssembly(Assembly assembly);
cfg.RegisterServicesFromAssemblies(params Assembly[] assemblies);
cfg.RegisterServicesFromAssemblyContaining<T>();
cfg.RegisterServicesFromAssemblyContaining(Type type);
```

La lista se almacena en `AssembliesToRegister`. Si llamas a `AddMediatR(...)` con lista vacía obtienes:

```
ArgumentException: No assemblies found to scan. Supply at least one assembly to scan for handlers.
```

### Filtrado de tipos

```csharp
cfg.TypeEvaluator = t => !t.Name.EndsWith("Skip");
```

Aplicado a cada tipo candidato durante el escaneo; devuelve `false` para saltarlo.

### Reemplazo del mediator

```csharp
cfg.MediatorImplementationType = typeof(MyMediator);
```

Registra una subclase de `Mediator` en lugar del default. Útil para sobrescribir `PublishCore` o añadir telemetría a nivel de dispatch.

### Sobreescritura de lifetime

```csharp
cfg.Lifetime = ServiceLifetime.Scoped;
```

Aplica a `IMediator`, `ISender`, `IPublisher` y al `INotificationPublisher` (cuando `NotificationPublisherType` está definido). Los handlers y comportamientos siguen siendo transient — usa `AddXxx(typeof(...), ServiceLifetime.Singleton)` explícito para sobrescribir por-tipo.

### Publisher de notificaciones

```csharp
cfg.NotificationPublisher = new TaskWhenAllPublisher();     // instancia
cfg.NotificationPublisherType = typeof(TelemetryPublisher); // resuelto por DI, prevalece sobre la instancia
```

Ver [Publicadores de Notificaciones](09%20-%20Publicadores_Notificaciones.md).

### Clave de licencia

```csharp
cfg.LicenseKey = "<JWT>";
```

Alternativamente define `Mediator.LicenseKey` estáticamente. Ver [Licenciamiento](13%20-%20Licenciamiento.md).

### Registro automático de procesadores

```csharp
cfg.AutoRegisterRequestProcessors = true;
```

Habilita escaneo de implementaciones de `IRequestPreProcessor<>` / `IRequestPostProcessor<,>`. Desactivado por defecto (debes llamar a `AddRequestPreProcessor` / `AddRequestPostProcessor` explícitamente).

### Registro de comportamientos / procesadores (ver [Interfaces Principales](04%20-%20Interfaces_Principales.md))

```csharp
cfg.AddBehavior<TImpl>();
cfg.AddBehavior<TService, TImpl>();
cfg.AddOpenBehavior(typeof(LoggingBehavior<,>));
cfg.AddOpenBehaviors(new[] { typeof(A<,>), typeof(B<,>) });

cfg.AddStreamBehavior<TImpl>();
cfg.AddOpenStreamBehavior(typeof(LoggingStreamBehavior<,>));

cfg.AddRequestPreProcessor<TImpl>();
cfg.AddOpenRequestPreProcessor(typeof(ValidationPreProcessor<>));

cfg.AddRequestPostProcessor<TImpl>();
cfg.AddOpenRequestPostProcessor(typeof(AuditPostProcessor<,>));
```

Cada método tiene sobrecargas para tipo de servicio explícito, implementación cerrada, implementación de genérico abierto y `ServiceLifetime` opcional.

### Límites de registro de genéricos

```csharp
cfg.MaxGenericTypeParameters = 10;        // 0 lo desactiva
cfg.MaxTypesClosing = 100;                // 0 lo desactiva
cfg.MaxGenericTypeRegistrations = 125000; // 0 lo desactiva
cfg.RegistrationTimeout = 15000;          // ms, 0 lo desactiva
cfg.RegisterGenericHandlers = false;      // si escanear handlers de genéricos abiertos
```

Protegen contra explosión combinatoria. Ver abajo para detalles.

---

## `ServiceRegistrar` — cómo funciona el escaneo

Fuente: [src/MediatR/Registration/ServiceRegistrar.cs](../../src/MediatR/Registration/ServiceRegistrar.cs).

### Flujo de alto nivel

```csharp
public static IServiceCollection AddMediatR(this IServiceCollection services, MediatRServiceConfiguration configuration)
{
    if (!configuration.AssembliesToRegister.Any())
        throw new ArgumentException("No assemblies found to scan. ...");

    ServiceRegistrar.SetGenericRequestHandlerRegistrationLimitations(configuration);
    ServiceRegistrar.AddMediatRClassesWithTimeout(services, configuration);
    ServiceRegistrar.AddRequiredServices(services, configuration);

    return services;
}
```

1. Copia los límites de configuración a los campos estáticos de `ServiceRegistrar`.
2. Escanea todos los ensamblados bajo un `CancellationTokenSource` con `RegistrationTimeout` — cualquier timeout se traduce en `TimeoutException`.
3. Registra los servicios requeridos (mediator, publisher, licenciamiento, comportamientos, procesadores, decoradores de excepciones).

### Dentro de `AddMediatRClasses`

Para cada "interfaz handler abierta" (`IRequestHandler<,>`, `IRequestHandler<>`, `INotificationHandler<>`, `IStreamRequestHandler<,>`, `IRequestExceptionHandler<,,>`, `IRequestExceptionAction<,>`, y opcionalmente `IRequestPreProcessor<>` / `IRequestPostProcessor<,>` si `AutoRegisterRequestProcessors` es true), llama a:

```csharp
ConnectImplementationsToTypesClosing(openInterface, services, assembliesToScan, addIfAlreadyExists, configuration, ct);
```

Que:

1. Encuentra cada **tipo concreto** (`!IsAbstract && !IsInterface`) que implementa la interfaz abierta.
2. Los divide en **concreciones cerradas** (no de genérico abierto) y **concreciones abiertas** (`ContainsGenericParameters`).
3. Para cada interfaz cerrada implementada (p. ej. `IRequestHandler<CreateOrder, int>`), registra la concreción. Si `addIfAlreadyExists == false` (interfaces single-handler), usa `TryAddTransient` (gana el primero); si `true` (multi-instancia), usa `AddTransient` (todos registrados).
4. Para interfaces de genérico abierto, llama a `AddAllConcretionsThatClose` que genera cada combinación válida de tipos de request × tipos de handler abierto y registra cada una.

Después hace una segunda pasada para **handlers multi-genéricos abiertos** (handlers de notificaciones abiertos, handlers/actions de excepciones, y — si auto-register está activado — procesadores) y registra el mapeo abierto-a-abierto directamente:

```csharp
foreach (var multiOpenInterface in new[]
    { typeof(INotificationHandler<>), typeof(IRequestExceptionHandler<,,>), typeof(IRequestExceptionAction<,>), ... })
{
    foreach (var type in scannedOpenConcretions)
    {
        services.AddTransient(multiOpenInterface, type);
    }
}
```

### Por qué importan los límites

`GenerateCombinations` explora cada cierre válido de los parámetros de un handler genérico. Para un handler como:

```csharp
public class LoggingHandler<TRequest, TResponse> : IRequestHandler<TRequest, TResponse>
    where TRequest : IRequest<TResponse>
```

podrías tener **miles** de parejas `(TRequest, TResponse)` válidas. Sin límites, el registro podría tardar minutos silenciosamente y consumir memoria.

Los límites actúan como **guardarraíles**:

- `MaxGenericTypeParameters`: "rechaza si este handler tiene más de N parámetros genéricos" (default 10).
- `MaxTypesClosing`: "rechaza si algún parámetro podría cerrarse con más de N tipos" (default 100).
- `MaxGenericTypeRegistrations`: "rechaza si el total de combinaciones excede N" (default 125.000).
- `RegistrationTimeout`: límite wall-clock duro del proceso de registro (default 15 segundos).

Cualquier violación lanza una excepción descriptiva. Ponlo a `0` para desactivar.

### Precedencia de handlers en `ConnectImplementationsToTypesClosing`

Cuando varios handlers concretos casan con una interfaz cerrada, el registrar usa `IsMatchingWithInterface` para conservar solo los cuyos argumentos genéricos coinciden exactamente. Previene que un `Handler<TRequest, TResponse>` genérico se registre para todos los requests cuando hay un handler más específico.

### `HasNestedGenericResponseType` y cierre explícito

Para comportamientos abiertos cuyo `TResponse` es en sí mismo genérico (p. ej. `IPipelineBehavior<TRequest, Result<T>>`), el contenedor DI no puede deducir el cierre. `ServiceRegistrar.RegisterClosedBehaviorsFromAssemblies` recorre los ensamblados escaneados buscando cada `IRequest<Result<X>>`, empareja el patrón y registra un behavior explícitamente cerrado para ese par.

Transparente — tú solo registras el behavior abierto y funciona para genéricos anidados.

---

## Dentro de `AddRequiredServices`

```csharp
public static void AddRequiredServices(IServiceCollection services, MediatRServiceConfiguration serviceConfiguration)
{
    // 1) IMediator, ISender, IPublisher
    services.TryAdd(new ServiceDescriptor(typeof(IMediator),
        serviceConfiguration.MediatorImplementationType, serviceConfiguration.Lifetime));
    services.TryAdd(new ServiceDescriptor(typeof(ISender),
        sp => sp.GetRequiredService<IMediator>(), serviceConfiguration.Lifetime));
    services.TryAdd(new ServiceDescriptor(typeof(IPublisher),
        sp => sp.GetRequiredService<IMediator>(), serviceConfiguration.Lifetime));

    // 2) Reset de la bandera LicenseChecked
    MediatRServiceCollectionExtensions.LicenseChecked = false;

    // 3) Configuración + accessor de licencia + validator (singletons, requieren ILoggerFactory)
    services.TryAddSingleton(serviceConfiguration);
    services.TryAddSingleton<LicenseAccessor>(sp =>
    {
        var loggerFactory = sp.GetService<ILoggerFactory>()
            ?? throw new InvalidOperationException("MediatR requires ILoggerFactory to be registered. Call services.AddLogging() before services.AddMediatR().");
        var config = sp.GetService<MediatRServiceConfiguration>();
        return config != null ? new LicenseAccessor(config, loggerFactory) : new LicenseAccessor(loggerFactory);
    });
    services.TryAddSingleton<LicenseValidator>(sp =>
    {
        var loggerFactory = sp.GetService<ILoggerFactory>()
            ?? throw new InvalidOperationException("MediatR requires ILoggerFactory to be registered. Call services.AddLogging() before services.AddMediatR().");
        return new LicenseValidator(loggerFactory);
    });

    // 4) Publisher de notificaciones
    var descriptor = serviceConfiguration.NotificationPublisherType != null
        ? new ServiceDescriptor(typeof(INotificationPublisher),
              serviceConfiguration.NotificationPublisherType, serviceConfiguration.Lifetime)
        : new ServiceDescriptor(typeof(INotificationPublisher), serviceConfiguration.NotificationPublisher);
    services.TryAdd(descriptor);

    // 5) Behaviors de excepciones (orden depende de la estrategia)
    if (serviceConfiguration.RequestExceptionActionProcessorStrategy == RequestExceptionActionProcessorStrategy.ApplyForUnhandledExceptions)
    {
        RegisterBehaviorIfImplementationsExist(services,
            typeof(RequestExceptionActionProcessorBehavior<,>), typeof(IRequestExceptionAction<,>));
        RegisterBehaviorIfImplementationsExist(services,
            typeof(RequestExceptionProcessorBehavior<,>), typeof(IRequestExceptionHandler<,,>));
    }
    else
    {
        RegisterBehaviorIfImplementationsExist(services,
            typeof(RequestExceptionProcessorBehavior<,>), typeof(IRequestExceptionHandler<,,>));
        RegisterBehaviorIfImplementationsExist(services,
            typeof(RequestExceptionActionProcessorBehavior<,>), typeof(IRequestExceptionAction<,>));
    }

    // 6) Behaviors pre/post-procesadores
    if (serviceConfiguration.RequestPreProcessorsToRegister.Any())
    {
        services.TryAddEnumerable(new ServiceDescriptor(typeof(IPipelineBehavior<,>),
            typeof(RequestPreProcessorBehavior<,>), ServiceLifetime.Transient));
        services.TryAddEnumerable(serviceConfiguration.RequestPreProcessorsToRegister);
    }
    if (serviceConfiguration.RequestPostProcessorsToRegister.Any())
    {
        services.TryAddEnumerable(new ServiceDescriptor(typeof(IPipelineBehavior<,>),
            typeof(RequestPostProcessorBehavior<,>), ServiceLifetime.Transient));
        services.TryAddEnumerable(serviceConfiguration.RequestPostProcessorsToRegister);
    }

    // 7) Pipeline behaviors explícitos
    foreach (var serviceDescriptor in serviceConfiguration.BehaviorsToRegister)
    {
        services.TryAddEnumerable(serviceDescriptor);

        // Caso especial: tipo de respuesta genérico anidado necesita cierre explícito
        if (serviceDescriptor.ImplementationType != null
            && serviceDescriptor.ServiceType == typeof(IPipelineBehavior<,>)
            && serviceDescriptor.ImplementationType.IsOpenGeneric()
            && HasNestedGenericResponseType(serviceDescriptor.ImplementationType))
        {
            RegisterClosedBehaviorsFromAssemblies(
                serviceDescriptor.ImplementationType, services,
                serviceConfiguration.AssembliesToRegister, serviceDescriptor.Lifetime);
        }
    }

    // 8) Stream behaviors explícitos
    foreach (var sd in serviceConfiguration.StreamBehaviorsToRegister)
    {
        services.TryAddEnumerable(sd);
    }
}
```

---

## Requisitos

- **`ILoggerFactory` debe estar registrado antes de `AddMediatR`**. Si olvidas, `LicenseAccessor` / `LicenseValidator` lanzan `InvalidOperationException` al resolver. El arreglo sencillo: `services.AddLogging();`.
- **Al menos un ensamblado** debe pasarse mediante `RegisterServicesFromAssembly(...)` o variantes.

---

## Llamar `AddMediatR` dos veces

Si llamas `AddMediatR(...)` dos veces:

- La segunda llamada repite el escaneo — los handlers ya registrados como `Transient` vía `TryAddTransient` no se vuelven a añadir (idempotente).
- Las interfaces multi-instancia (handlers de notificaciones, handlers/actions de excepciones) **sí** pueden duplicarse si el mismo ensamblado se escanea dos veces. La deduplicación del wrapper (`GroupBy(x => x.GetType()).Select(g => g.First())`) lo soluciona en tiempo de dispatch para notificaciones.
- `ServiceRegistrar.AddRequiredServices` usa `TryAdd`, así que `IMediator`, `ISender`, `IPublisher`, servicios de licencia y el publisher solo se registran una vez.
- La bandera de verificación de licencia se **resetea** a `false` en cada llamada, así que la licencia se revalida en la siguiente construcción de `Mediator`.

Buena práctica: una sola llamada `AddMediatR(cfg => cfg.RegisterServicesFromAssemblies(asm1, asm2, ...))` con todos los ensamblados.

---

## Depurando registros

Para inspeccionar qué hay realmente en la service collection:

```csharp
foreach (var sd in services)
{
    if (sd.ServiceType.Namespace?.StartsWith("MediatR") == true
     || sd.ServiceType.Name.Contains("Handler")
     || sd.ServiceType.Name.Contains("Behavior"))
    {
        Console.WriteLine($"{sd.ServiceType.FullName} → {sd.ImplementationType?.FullName ?? "factory"} ({sd.Lifetime})");
    }
}
```

Alternativamente, engancha `ILogger` a la categoría `LuckyPennySoftware.MediatR.License` para ver el estado de licencia y activa logging a nivel `Information` para diagnósticos DI.

---

## Notas específicas de contenedores

Cada contenedor DI tiene sus quirks con genéricos abiertos y escaneo. Revisa el proyecto sample correspondiente:

| Contenedor | Sample |
|------------|--------|
| `Microsoft.Extensions.DependencyInjection` | `samples/MediatR.Examples.AspNetCore/` |
| Autofac | `samples/MediatR.Examples.Autofac/` |
| DryIoc | `samples/MediatR.Examples.DryIoc/` |
| Lamar | `samples/MediatR.Examples.Lamar/` |
| LightInject | `samples/MediatR.Examples.LightInject/` |
| SimpleInjector | `samples/MediatR.Examples.SimpleInjector/` |
| Stashbox | `samples/MediatR.Examples.Stashbox/` |
| Castle Windsor | `samples/MediatR.Examples.Windsor/` |

Para cada uno, ver [Integración de Contenedores DI](16%20-%20Integracion_Contenedores_DI.md).
