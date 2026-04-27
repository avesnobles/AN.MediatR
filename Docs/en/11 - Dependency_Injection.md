# Dependency Injection

AN.MediatR integrates natively with `Microsoft.Extensions.DependencyInjection` via the `AddMediatR` extension method. Other containers (Autofac, DryIoc, Lamar, LightInject, SimpleInjector, Stashbox, Windsor) are supported through adapter patterns shown in the `samples/` folder — see [DI Container Integration](15%20-%20DI_Container_Integration.md).

This document focuses on the native `IServiceCollection` integration.

---

## The entry point

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

Source: [src/MediatR/MicrosoftExtensionsDI/ServiceCollectionExtensions.cs](../../src/MediatR/MicrosoftExtensionsDI/ServiceCollectionExtensions.cs).

> The extensions live in the `Microsoft.Extensions.DependencyInjection` namespace so you don't need an extra `using` once you have `AddControllers()`, `AddLogging()`, etc.

### Minimal registration

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
});
```

Equivalent to: "scan the current assembly for every handler / behavior / processor / exception-handler and register them as transient."

### What you get after `AddMediatR`

`ServiceRegistrar` inside `AddMediatR(...)` registers:

1. **`IMediator`** → `Mediator` (lifetime = configuration, default `Transient`).
2. **`ISender`** and **`IPublisher`** → factory that returns the resolved `IMediator` (so they share the same instance per scope).
3. **`MediatRServiceConfiguration`** as a singleton (for downstream introspection).
4. **`INotificationPublisher`** based on `cfg.NotificationPublisher` or `cfg.NotificationPublisherType`.
5. **All discovered `IRequestHandler<>`, `IRequestHandler<,>`, `INotificationHandler<>`, `IStreamRequestHandler<,>`** as transient.
6. **All discovered `IRequestExceptionHandler<,,>`, `IRequestExceptionAction<,>`** as transient (multi-instance).
7. **Pre/post-processor decorators** (if any processor was registered).
8. **Exception action / handler decorators** (if any exception handler / action exists — controlled by `RequestExceptionActionProcessorStrategy`).
9. **All explicitly added pipeline and stream behaviors** via `cfg.BehaviorsToRegister` / `cfg.StreamBehaviorsToRegister`.

Assembly-scanning is not idempotent by default — `AddMediatR` can be called multiple times, each scanning a different set of assemblies, but prefer calling it once with all assemblies.

---

## `MediatRServiceConfiguration`

Source: [src/MediatR/MicrosoftExtensionsDI/MediatrServiceConfiguration.cs](../../src/MediatR/MicrosoftExtensionsDI/MediatrServiceConfiguration.cs).

Fluent configuration. All methods return `this` so you can chain them.

### Assembly registration

```csharp
cfg.RegisterServicesFromAssembly(Assembly assembly);
cfg.RegisterServicesFromAssemblies(params Assembly[] assemblies);
cfg.RegisterServicesFromAssemblyContaining<T>();
cfg.RegisterServicesFromAssemblyContaining(Type type);
```

The assembly list is stored internally in `AssembliesToRegister`. If you call `AddMediatR(...)` with an empty list you get:

```
ArgumentException: No assemblies found to scan. Supply at least one assembly to scan for handlers.
```

### Type filtering

```csharp
cfg.TypeEvaluator = t => !t.Name.EndsWith("Skip");
```

Applied to every candidate type during scanning; return `false` to skip.

### Mediator replacement

```csharp
cfg.MediatorImplementationType = typeof(MyMediator);
```

Register a subclass of `Mediator` instead of the default. Useful for custom `PublishCore` overrides or adding telemetry at the dispatch level.

### Lifetime override

```csharp
cfg.Lifetime = ServiceLifetime.Scoped;
```

Applies to `IMediator`, `ISender`, `IPublisher`, and the `INotificationPublisher` (when `NotificationPublisherType` is set). Handlers and behaviors remain transient — use explicit `AddXxx(typeof(...), ServiceLifetime.Singleton)` to override per-type.

### Notification publisher

```csharp
cfg.NotificationPublisher = new TaskWhenAllPublisher();     // instance
cfg.NotificationPublisherType = typeof(TelemetryPublisher); // DI-resolved, overrides the instance
```

See [Notification Publishers](09%20-%20Notification_Publishers.md).

### Auto-register processors

```csharp
cfg.AutoRegisterRequestProcessors = true;
```

Enables scanning for `IRequestPreProcessor<>` / `IRequestPostProcessor<,>` implementations. Off by default (you must call `AddRequestPreProcessor` / `AddRequestPostProcessor` explicitly).

### Behavior / processor registration (see [Core Interfaces](04%20-%20Core_Interfaces.md))

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

Each method has overloads for explicit service type, closed generic impl, open generic impl, and optional `ServiceLifetime`.

### Generic registration limits

```csharp
cfg.MaxGenericTypeParameters = 10;        // 0 disables
cfg.MaxTypesClosing = 100;                // 0 disables
cfg.MaxGenericTypeRegistrations = 125000; // 0 disables
cfg.RegistrationTimeout = 15000;          // ms, 0 disables
cfg.RegisterGenericHandlers = false;      // whether to bother scanning open-generic handlers
```

These limits protect you from runaway combinatorial explosion. See below for details.

---

## `ServiceRegistrar` — how scanning works

Source: [src/MediatR/Registration/ServiceRegistrar.cs](../../src/MediatR/Registration/ServiceRegistrar.cs).

### Top-level flow

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

1. Copy the limits from the configuration into `ServiceRegistrar` static fields.
2. Scan all assemblies under a `CancellationTokenSource` with `RegistrationTimeout` — any timeout translates into `TimeoutException`.
3. Register the required services (mediator, publisher, behaviors, processors, exception decorators).

### Inside `AddMediatRClasses`

For each "open handler interface" (`IRequestHandler<,>`, `IRequestHandler<>`, `INotificationHandler<>`, `IStreamRequestHandler<,>`, `IRequestExceptionHandler<,,>`, `IRequestExceptionAction<,>`, and optionally `IRequestPreProcessor<>` / `IRequestPostProcessor<,>` when `AutoRegisterRequestProcessors` is true), it calls:

```csharp
ConnectImplementationsToTypesClosing(openInterface, services, assembliesToScan, addIfAlreadyExists, configuration, ct);
```

Which:

1. Finds every **concrete type** (`!IsAbstract && !IsInterface`) in the scanned assemblies that implements the open interface.
2. Splits those into **closed concretions** (non-open-generic) and **open-generic concretions** (`ContainsGenericParameters`).
3. For each closed interface implemented (e.g. `IRequestHandler<CreateOrder, int>`), registers the concretion. If `addIfAlreadyExists == false` (single-handler interfaces) it uses `TryAddTransient` (first wins); if `true` (multi-instance interfaces like notification handlers) it uses `AddTransient` (all registered).
4. For open-generic interfaces, calls `AddAllConcretionsThatClose` which generates every valid combination of request types × open-generic handler types and registers each one.

After that, it makes a second pass for **multi-open-generic handlers** (open-generic notification handlers, exception handlers, actions, and — if auto-register enabled — processors) and registers the open-generic-to-open-generic mapping directly.

### Why the limits matter

`GenerateCombinations` explores every valid closing of a generic handler's type parameters. For a handler like:

```csharp
public class GenericHandler<TRequest, TResponse> : IRequestHandler<TRequest, TResponse>
    where TRequest : IRequest<TResponse>
```

you could have **thousands** of valid `(TRequest, TResponse)` pairs in your assemblies. Without limits, registration would silently take minutes and leak memory.

The limits therefore act as **guard rails**:

- `MaxGenericTypeParameters`: "refuse to register if this handler has more than N type parameters" (default 10).
- `MaxTypesClosing`: "refuse if any single type parameter could be closed by more than N types" (default 100).
- `MaxGenericTypeRegistrations`: "refuse if the total number of combinations exceeds N" (default 125,000).
- `RegistrationTimeout`: a hard wall-clock limit on the whole registration process (default 15 seconds).

Any violation throws a descriptive exception. Set a limit to `0` to disable.

---

## Inside `AddRequiredServices`

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

    // 2) Configuration singleton
    services.TryAddSingleton(serviceConfiguration);

    // 3) Notification publisher
    var descriptor = serviceConfiguration.NotificationPublisherType != null
        ? new ServiceDescriptor(typeof(INotificationPublisher),
              serviceConfiguration.NotificationPublisherType, serviceConfiguration.Lifetime)
        : new ServiceDescriptor(typeof(INotificationPublisher), serviceConfiguration.NotificationPublisher);
    services.TryAdd(descriptor);

    // 4) Exception behaviors (order depends on strategy)
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

    // 5) Pre/post-processor behaviors
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

    // 6) Explicit pipeline behaviors
    foreach (var serviceDescriptor in serviceConfiguration.BehaviorsToRegister)
    {
        services.TryAddEnumerable(serviceDescriptor);

        // For open behaviors whose TResponse is a nested generic (e.g. List<T>, Result<T>),
        // the DI container cannot close them correctly via positional mapping.
        // Register explicitly-closed versions by scanning assemblies for matching request types.
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

    // 7) Explicit stream behaviors
    foreach (var sd in serviceConfiguration.StreamBehaviorsToRegister)
        services.TryAddEnumerable(sd);
}
```

### Nested-generic response types

If your open behavior's `TResponse` is itself generic (e.g. `IPipelineBehavior<TRequest, List<T>>` or `IPipelineBehavior<TRequest, Result<T>>`), `Microsoft.Extensions.DependencyInjection` cannot close it purely by positional mapping of the outer generics. `ServiceRegistrar.RegisterClosedBehaviorsFromAssemblies` detects this case via `HasNestedGenericResponseType`, walks every `IRequest<T>` in the scanned assemblies, matches the nested pattern (via the internal `TryMatchType`), and registers an explicitly-closed `IPipelineBehavior<ConcreteRequest, ConcreteResponse>` for each match.

You don't need to do anything special — just register the open behavior with `cfg.AddOpenBehavior(typeof(MyBehavior<,>))` and AN.MediatR handles the closing.

### F# and other awkward assemblies

`ServiceRegistrar` uses a `GetLoadableDefinedTypes()` helper that catches `ReflectionTypeLoadException` and falls back to `ex.Types.OfType<Type>()`. This makes assembly scanning robust against F# assemblies (which can throw on `DefinedTypes` when they contain `inref` parameters or other reflection-unfriendly types) and dynamically-generated assemblies where some types fail to load. If you hit a `ReflectionTypeLoadException` during `AddMediatR(...)`, the registrar simply ignores the unloadable types and continues scanning the rest.

---

## Requirements

- **At least one assembly** must be passed via `RegisterServicesFromAssembly(...)` or its variants.
- No other DI services are required. There is **no `ILoggerFactory` requirement** — AN.MediatR does not do any logging on its own.

---

## Calling `AddMediatR` twice

If you call `AddMediatR(...)` twice:

- The second call repeats assembly scanning — handlers that were already registered as `Transient` via `TryAddTransient` are not re-added (idempotent).
- Multi-instance interfaces (notification handlers, exception handlers, actions) **will** get duplicates if the same assembly is scanned twice. The wrapper's `GroupBy(x => x.GetType()).Select(g => g.First())` deduplicates notification handlers at dispatch time.
- `ServiceRegistrar.AddRequiredServices` uses `TryAdd`, so `IMediator`, `ISender`, `IPublisher`, and the publisher are only registered once.

Best practice: a single `AddMediatR(cfg => cfg.RegisterServicesFromAssemblies(asm1, asm2, ...))` call with every assembly.

---

## Debugging registrations

To inspect what's actually in the service collection:

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

## Container-specific notes

Every DI container has its own quirks for open generics and scanning. Check the relevant sample project:

| Container | Sample |
|-----------|--------|
| `Microsoft.Extensions.DependencyInjection` | `samples/MediatR.Examples.AspNetCore/` |
| Autofac | `samples/MediatR.Examples.Autofac/` |
| DryIoc | `samples/MediatR.Examples.DryIoc/` |
| Lamar | `samples/MediatR.Examples.Lamar/` |
| LightInject | `samples/MediatR.Examples.LightInject/` |
| SimpleInjector | `samples/MediatR.Examples.SimpleInjector/` |
| Stashbox | `samples/MediatR.Examples.Stashbox/` |
| Castle Windsor | `samples/MediatR.Examples.Windsor/` |

For each, see [DI Container Integration](15%20-%20DI_Container_Integration.md).
