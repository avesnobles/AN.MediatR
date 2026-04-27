# Inyección de Dependencias

AN.MediatR se integra nativamente con `Microsoft.Extensions.DependencyInjection` mediante el método extensión `AddMediatR`. Otros contenedores (Autofac, DryIoc, Lamar, LightInject, SimpleInjector, Stashbox, Windsor) se soportan mediante patrones adaptadores mostrados en la carpeta `samples/` — ver [Integración de Contenedores DI](15%20-%20Integracion_Contenedores_DI.md).

Este documento se centra en la integración nativa con `IServiceCollection`.

---

## Punto de entrada

```csharp
namespace Microsoft.Extensions.DependencyInjection;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddMediatR(
        this IServiceCollection services,
        Action<MediatRServiceConfiguration> configuration);

    public static IServiceCollection AddMediatR(
        this IServiceCollection services,
        MediatRServiceConfiguration configuration);
}
```

Fuente: [src/MediatR/MicrosoftExtensionsDI/ServiceCollectionExtensions.cs](../../src/MediatR/MicrosoftExtensionsDI/ServiceCollectionExtensions.cs).

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
4. **`INotificationPublisher`** según `cfg.NotificationPublisher` o `cfg.NotificationPublisherType`.
5. **Todos los `IRequestHandler<>`, `IRequestHandler<,>`, `INotificationHandler<>`, `IStreamRequestHandler<,>`** descubiertos como transient.
6. **Todos los `IRequestExceptionHandler<,,>`, `IRequestExceptionAction<,>`** descubiertos como transient (multi-instancia).
7. **Decoradores de procesadores pre/post** (si hay procesadores registrados).
8. **Decoradores de actions / handlers de excepciones** (si hay handlers / actions — controlado por `RequestExceptionActionProcessorStrategy`).
9. **Todos los comportamientos (pipeline y stream) explícitamente añadidos** en `cfg.BehaviorsToRegister` / `cfg.StreamBehaviorsToRegister`.

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

Registra una subclase de `Mediator` en lugar del default.

### Sobreescritura de lifetime

```csharp
cfg.Lifetime = ServiceLifetime.Scoped;
```

Aplica a `IMediator`, `ISender`, `IPublisher` y al `INotificationPublisher` (cuando `NotificationPublisherType` está definido). Los handlers y comportamientos siguen siendo transient.

### Publisher de notificaciones

```csharp
cfg.NotificationPublisher = new TaskWhenAllPublisher();     // instancia
cfg.NotificationPublisherType = typeof(TelemetryPublisher); // resuelto por DI
```

Ver [Publicadores de Notificaciones](09%20-%20Publicadores_Notificaciones.md).

### Registro automático de procesadores

```csharp
cfg.AutoRegisterRequestProcessors = true;
```

Habilita escaneo de implementaciones de `IRequestPreProcessor<>` / `IRequestPostProcessor<,>`. Desactivado por defecto.

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

### Límites de registro de genéricos

```csharp
cfg.MaxGenericTypeParameters = 10;        // 0 lo desactiva
cfg.MaxTypesClosing = 100;                // 0 lo desactiva
cfg.MaxGenericTypeRegistrations = 125000; // 0 lo desactiva
cfg.RegistrationTimeout = 15000;          // ms, 0 lo desactiva
cfg.RegisterGenericHandlers = false;
```

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
3. Registra los servicios requeridos (mediator, publisher, comportamientos, procesadores, decoradores de excepciones).

### Dentro de `AddMediatRClasses`

Para cada "interfaz handler abierta" (`IRequestHandler<,>`, `IRequestHandler<>`, `INotificationHandler<>`, `IStreamRequestHandler<,>`, `IRequestExceptionHandler<,,>`, `IRequestExceptionAction<,>`, y opcionalmente `IRequestPreProcessor<>` / `IRequestPostProcessor<,>`), llama a `ConnectImplementationsToTypesClosing`, que:

1. Encuentra cada **tipo concreto** (`!IsAbstract && !IsInterface`) que implementa la interfaz abierta.
2. Los divide en **concreciones cerradas** y **concreciones abiertas** (`ContainsGenericParameters`).
3. Para cada interfaz cerrada implementada, registra la concreción. Single-handler → `TryAddTransient` (gana el primero); multi-instancia → `AddTransient` (todos registrados).
4. Para interfaces de genérico abierto, `AddAllConcretionsThatClose` genera cada combinación válida de tipos de request × tipos de handler abierto.

### Por qué importan los límites

`GenerateCombinations` explora cada cierre válido de los parámetros de un handler genérico. Sin límites, el registro podría tardar minutos y consumir memoria.

- `MaxGenericTypeParameters`: "rechaza si este handler tiene más de N parámetros genéricos" (default 10).
- `MaxTypesClosing`: "rechaza si algún parámetro podría cerrarse con más de N tipos" (default 100).
- `MaxGenericTypeRegistrations`: "rechaza si el total de combinaciones excede N" (default 125.000).
- `RegistrationTimeout`: límite wall-clock del proceso de registro (default 15 segundos).

Ponlo a `0` para desactivar.

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

    // 2) Configuración como singleton
    services.TryAddSingleton(serviceConfiguration);

    // 3) Publisher de notificaciones
    var descriptor = serviceConfiguration.NotificationPublisherType != null
        ? new ServiceDescriptor(typeof(INotificationPublisher),
              serviceConfiguration.NotificationPublisherType, serviceConfiguration.Lifetime)
        : new ServiceDescriptor(typeof(INotificationPublisher), serviceConfiguration.NotificationPublisher);
    services.TryAdd(descriptor);

    // 4) Behaviors de excepciones (orden según estrategia)
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

    // 5) Behaviors pre/post-procesadores
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

    // 6) Pipeline behaviors explícitos
    foreach (var serviceDescriptor in serviceConfiguration.BehaviorsToRegister)
    {
        services.TryAddEnumerable(serviceDescriptor);

        // Para behaviors abiertos cuyo TResponse es un genérico anidado (p. ej. List<T>, Result<T>),
        // el contenedor DI no puede cerrarlos con el mapping posicional estándar.
        // Registra versiones explícitamente cerradas escaneando los ensamblados.
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

    // 7) Stream behaviors explícitos
    foreach (var sd in serviceConfiguration.StreamBehaviorsToRegister)
        services.TryAddEnumerable(sd);
}
```

### Tipos de respuesta genéricos anidados

Si tu behavior abierto tiene un `TResponse` que es a su vez genérico (p. ej. `IPipelineBehavior<TRequest, List<T>>` o `IPipelineBehavior<TRequest, Result<T>>`), `Microsoft.Extensions.DependencyInjection` no puede cerrarlo mediante el mapping posicional habitual. `ServiceRegistrar.RegisterClosedBehaviorsFromAssemblies` detecta el caso vía `HasNestedGenericResponseType`, recorre cada `IRequest<T>` de los ensamblados escaneados, empareja el patrón anidado (con el helper interno `TryMatchType`) y registra un `IPipelineBehavior<RequestConcreto, RespuestaConcreta>` explícitamente cerrado por cada match.

No tienes que hacer nada especial — simplemente registra el behavior abierto con `cfg.AddOpenBehavior(typeof(MyBehavior<,>))` y AN.MediatR se encarga del cierre.

### F# y otros ensamblados problemáticos

`ServiceRegistrar` usa un helper `GetLoadableDefinedTypes()` que captura `ReflectionTypeLoadException` y cae a `ex.Types.OfType<Type>()`. Esto hace el escaneo robusto ante ensamblados F# (que pueden lanzar en `DefinedTypes` cuando contienen parámetros `inref` u otros tipos no amigables para la reflexión) y ante ensamblados generados dinámicamente con tipos que no cargan. Si aparece un `ReflectionTypeLoadException` durante `AddMediatR(...)`, el registrar ignora los tipos no-cargables y sigue con el resto.

---

## Requisitos

- **Al menos un ensamblado** debe pasarse mediante `RegisterServicesFromAssembly(...)` o variantes.
- No se necesitan otros servicios DI. **No hay requisito de `ILoggerFactory`** — AN.MediatR no emite logs por sí misma.

---

## Llamar `AddMediatR` dos veces

Si llamas `AddMediatR(...)` dos veces:

- La segunda llamada repite el escaneo — los handlers ya registrados como `Transient` vía `TryAddTransient` no se vuelven a añadir (idempotente).
- Las interfaces multi-instancia (handlers de notificaciones, handlers/actions de excepciones) **sí** pueden duplicarse si el mismo ensamblado se escanea dos veces. La deduplicación del wrapper lo soluciona en dispatch para notificaciones.
- `ServiceRegistrar.AddRequiredServices` usa `TryAdd`, así que `IMediator`, `ISender`, `IPublisher` y el publisher solo se registran una vez.

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

---

## Notas específicas de contenedores

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

Para cada uno, ver [Integración de Contenedores DI](15%20-%20Integracion_Contenedores_DI.md).
