# DI Container Integration

AN.MediatR depends on `Microsoft.Extensions.DependencyInjection.Abstractions` — any container that exposes its services as an `IServiceProvider` can be used. The repository ships ready-to-run samples for the most popular alternatives.

Each sample resolves `IMediator` from the container and calls the shared `Runner.Run(mediator, writer, projectName, testStreams: true)` defined in `samples/MediatR.Examples/Runner.cs`. The runner sends `Ping`, publishes `Pinged`, triggers `Ponged` (which is designed to fail), sends `Jing` (also designed to fail), optionally streams `Sing`, then exercises exception handlers / actions.

---

## Native: `Microsoft.Extensions.DependencyInjection`

Sample: `samples/MediatR.Examples.AspNetCore/Program.cs`.

```csharp
var services = new ServiceCollection();
services.AddSingleton<TextWriter>(writer);

services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssemblies(typeof(Ping).Assembly, typeof(Sing).Assembly);
});

// Stream handler registered manually for illustration
services.AddScoped(typeof(IStreamRequestHandler<Sing, Song>), typeof(SingHandler));

// Open-generic pipeline behaviors
services.AddScoped(typeof(IPipelineBehavior<,>), typeof(GenericPipelineBehavior<,>));
services.AddScoped(typeof(IRequestPreProcessor<>), typeof(GenericRequestPreProcessor<>));
services.AddScoped(typeof(IRequestPostProcessor<,>), typeof(GenericRequestPostProcessor<,>));
services.AddScoped(typeof(IStreamPipelineBehavior<,>), typeof(GenericStreamPipelineBehavior<,>));

var provider = services.BuildServiceProvider();
var mediator = provider.GetRequiredService<IMediator>();
```

Notes:

- `services.AddLogging()` is optional — AN.MediatR itself does no logging, but most applications want it anyway.
- `AddMediatR` can register open-generic behaviors directly through `cfg.AddOpenBehavior(typeof(GenericPipelineBehavior<,>))`, but using `services.AddScoped(typeof(IPipelineBehavior<,>), typeof(GenericPipelineBehavior<,>))` after `AddMediatR` also works.

---

## Autofac

Sample: `samples/MediatR.Examples.Autofac/`.

Autofac supports open generics natively. The typical pattern:

```csharp
var builder = new ContainerBuilder();

// Register MediatR types
builder.RegisterSource(new ScopedRegistrationSource());   // if using MediatR.Extensions.Autofac
builder.RegisterType<Mediator>().As<IMediator>().InstancePerLifetimeScope();

// Assembly scan for handlers
var assembly = typeof(Ping).Assembly;
builder.RegisterAssemblyTypes(assembly)
    .AsClosedTypesOf(typeof(IRequestHandler<,>))
    .AsImplementedInterfaces();
builder.RegisterAssemblyTypes(assembly)
    .AsClosedTypesOf(typeof(INotificationHandler<>))
    .AsImplementedInterfaces();

// Open generic behavior
builder.RegisterGeneric(typeof(GenericPipelineBehavior<,>))
    .As(typeof(IPipelineBehavior<,>))
    .InstancePerLifetimeScope();

var container = builder.Build();
var mediator = container.Resolve<IMediator>();
```

Autofac-specific callouts:

- Open generics are registered with `RegisterGeneric(...).As(typeof(Interface<,>))`.
- `AsClosedTypesOf(...)` finds every closed instance of an open generic interface in an assembly — exactly what AN.MediatR's `ServiceRegistrar` does, just with Autofac semantics.

---

## DryIoc

Sample: `samples/MediatR.Examples.DryIoc/`.

```csharp
var container = new Container();

container.Register<TextWriter>(reuse: Reuse.Singleton, made: Made.Of(() => writer));

container.Register<IMediator, Mediator>(Reuse.Scoped);

// Assembly scanning for handlers
container.RegisterMany(new[] { typeof(Ping).Assembly, typeof(Sing).Assembly },
    serviceTypeCondition: t => t.IsGenericType && (
        t.GetGenericTypeDefinition() == typeof(IRequestHandler<,>) ||
        t.GetGenericTypeDefinition() == typeof(INotificationHandler<>) ||
        t.GetGenericTypeDefinition() == typeof(IStreamRequestHandler<,>)));

// Open generic behavior
container.Register(typeof(IPipelineBehavior<,>), typeof(GenericPipelineBehavior<,>));

var mediator = container.Resolve<IMediator>();
```

DryIoc is famously fast and supports `RegisterMany(...)` for assembly scanning with custom predicates.

---

## Lamar

Sample: `samples/MediatR.Examples.Lamar/`.

Lamar is a drop-in replacement for `ServiceCollection` with better open-generic support. Its idiomatic assembly scan looks like:

```csharp
var container = new Container(cfg =>
{
    cfg.Scan(scanner =>
    {
        scanner.AssemblyContainingType<Ping>();
        scanner.ConnectImplementationsToTypesClosing(typeof(IRequestHandler<,>));
        scanner.ConnectImplementationsToTypesClosing(typeof(INotificationHandler<>));
        scanner.AddAllTypesOf(typeof(IPipelineBehavior<,>));
    });

    cfg.For<IMediator>().Use<Mediator>();
    cfg.For(typeof(IPipelineBehavior<,>)).Add(typeof(GenericPipelineBehavior<,>));
});

var mediator = container.GetInstance<IMediator>();
```

`Scan.ConnectImplementationsToTypesClosing(...)` is conceptually identical to AN.MediatR's `ServiceRegistrar.ConnectImplementationsToTypesClosing(...)`.

---

## LightInject

Sample: `samples/MediatR.Examples.LightInject/`.

```csharp
var container = new ServiceContainer();

container.Register<IMediator, Mediator>();
container.Register(typeof(IPipelineBehavior<,>), typeof(GenericPipelineBehavior<,>));

container.RegisterAssembly(typeof(Ping).Assembly, (type, implementation) =>
    type.IsGenericType
    && (type.GetGenericTypeDefinition() == typeof(IRequestHandler<,>)
        || type.GetGenericTypeDefinition() == typeof(INotificationHandler<>)));

var mediator = container.GetInstance<IMediator>();
```

---

## SimpleInjector

Sample: `samples/MediatR.Examples.SimpleInjector/`.

SimpleInjector is notoriously strict about decorator ordering and lifetime mismatches — it's a useful test bed for verifying that AN.MediatR's registrations are correct.

Key pattern:

```csharp
var container = new Container();

container.Register<IMediator, Mediator>(Lifestyle.Singleton);

var assembly = typeof(Ping).Assembly;

container.Register(typeof(IRequestHandler<,>), new[] { assembly });
container.Collection.Register(typeof(INotificationHandler<>), new[] { assembly });

// Register open-generic behaviors as decorators
container.RegisterDecorator(typeof(IPipelineBehavior<,>), typeof(GenericPipelineBehavior<,>));

var mediator = container.GetInstance<IMediator>();
```

Notes:

- Notification handlers must use `container.Collection.Register` because there can be many.
- `RegisterDecorator(...)` ensures the decorator is applied around the innermost handler.
- SimpleInjector enforces verification on `container.Verify()` — call it during startup in development.

---

## Stashbox

Sample: `samples/MediatR.Examples.Stashbox/`.

```csharp
var container = new StashboxContainer();

container.Register<IMediator, Mediator>();
container.Register(typeof(IPipelineBehavior<,>), typeof(GenericPipelineBehavior<,>));

container.RegisterAssemblyContaining<Ping>(typeSelector: t =>
    t.GetInterfaces().Any(i => i.IsGenericType && (
        i.GetGenericTypeDefinition() == typeof(IRequestHandler<,>) ||
        i.GetGenericTypeDefinition() == typeof(INotificationHandler<>))));

var mediator = container.Resolve<IMediator>();
```

---

## Castle Windsor

Sample: `samples/MediatR.Examples.Windsor/`.

```csharp
var container = new WindsorContainer();

container.Register(Component.For<IMediator>().ImplementedBy<Mediator>());

container.Register(Classes.FromAssemblyContaining<Ping>()
    .BasedOn(typeof(IRequestHandler<,>))
    .WithServiceAllInterfaces());

container.Register(Classes.FromAssemblyContaining<Ping>()
    .BasedOn(typeof(INotificationHandler<>))
    .WithServiceAllInterfaces()
    .AllowMultipleMatches());

container.Register(Component.For(typeof(IPipelineBehavior<,>))
    .ImplementedBy(typeof(GenericPipelineBehavior<,>)));

var mediator = container.Resolve<IMediator>();
```

`AllowMultipleMatches()` is important for notification handlers — without it, Windsor only registers the first match.

---

## Common pitfalls across containers

### 1. Single-instance notification registration

Many containers register only the first matching implementation by default for a given interface. For `INotificationHandler<>` you explicitly need collection-style registration (`AllowMultipleMatches`, `Collection.Register`, `RegisterMany`, etc.). Otherwise `mediator.Publish(...)` silently invokes only one handler.

### 2. Scoping `IMediator` vs. `IServiceProvider`

If you register `IMediator` as a scoped service, you must **resolve it within a scope**. Most containers expose a child-scope API — prefer scoped for ASP.NET Core, transient for console/host scenarios. For classic ASP.NET (pre-Core) use `PerRequest` or equivalent.

### 3. Open-generic behavior registration

If your behavior has a nested-generic response type (e.g. `IPipelineBehavior<TRequest, Result<T>>`), most containers cannot auto-close it. For third-party containers, you may need to register each closed variant manually or use container-specific open-generic closing features.

### 4. Caching of wrappers

The `Mediator` class holds `static ConcurrentDictionary` caches **per process**. The choice of DI container doesn't affect that — but if you spin up multiple containers in the same process (integration tests!) the caches are shared. Normally this is fine because the wrappers are stateless.

---

## Cross-container checklist

Regardless of container, make sure:

- [ ] `IMediator` resolves to `Mediator` (or your subclass).
- [ ] `ISender` and `IPublisher` resolve to the same `IMediator` instance per scope.
- [ ] `IServiceProvider` is available (either the container's own or an adapter — `Microsoft.Extensions.DependencyInjection.Abstractions` support is mandatory).
- [ ] `INotificationHandler<T>` is registered as a **collection** / `AllowMultipleMatches`.
- [ ] `IPipelineBehavior<,>` and `IStreamPipelineBehavior<,>` are registered as collections, with order preserved.

If you tick all those boxes, `Mediator.Send(...)` / `Publish(...)` / `CreateStream(...)` will behave identically to the native DI path.

---

## Deep dive: why assembly scanning is optional

You can skip `RegisterServicesFromAssembly(...)` entirely and register handlers by hand:

```csharp
services.AddMediatR(cfg => cfg.RegisterServicesFromAssemblyContaining<Ping>());   // still required to pass at least one assembly
services.AddTransient<IRequestHandler<Ping, Pong>, PingHandler>();
services.AddTransient<INotificationHandler<Pinged>, PingedHandler>();
```

Pros of explicit registration:

- Faster startup for large assemblies.
- Clearer intent — no reflection magic.
- Better for AOT / trimming scenarios where reflection is restricted.

Cons:

- Every new handler requires editing the composition root.
- Open-generic behaviors are harder to register without scanning.

Pick the approach that best fits your codebase; both are fully supported.
