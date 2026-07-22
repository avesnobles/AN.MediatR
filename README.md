AN.MediatR
==========

A free, open-source (Apache-2.0) fork of [MediatR](https://github.com/jbogard/MediatR), maintained by **Aves Nobles**.

Simple, in-process mediator implementation in .NET — request/response, commands, queries, notifications and events, synchronous and async with intelligent dispatching via C# generic variance.

This fork is based on **MediatR v12.5** (the last upstream release published under Apache-2.0, before the upstream switched to a commercial / RPL-1.5 dual license with runtime JWT licensing). AN.MediatR keeps the original semantics, stays free, and cherry-picks selected non-licensing improvements from upstream.

> Throughout this README and the codebase: **MediatR** refers to the original upstream project (Jimmy Bogard / Lucky Penny Software); **AN.MediatR** refers to this fork.

### Installing AN.MediatR

```
dotnet add package AN.MediatR
```

The `AN.MediatR` package transitively includes `AN.MediatR.Contracts`.

### Using the contracts-only package

To reference only the contracts for AN.MediatR, which includes:

- `IRequest` (including generic variants)
- `INotification`
- `IStreamRequest`

Add a package reference to **`AN.MediatR.Contracts`**.

This package is useful in scenarios where your contract types live in a separate assembly/project from handlers. Example scenarios:

- API contracts
- gRPC contracts
- Blazor WASM clients

### Registering with `IServiceCollection`

AN.MediatR supports `Microsoft.Extensions.DependencyInjection.Abstractions` directly. To register the mediator and discover handlers:

```csharp
services.AddMediatR(cfg => cfg.RegisterServicesFromAssemblyContaining<Startup>());
```

Or with an assembly:

```csharp
services.AddMediatR(cfg => cfg.RegisterServicesFromAssembly(typeof(Startup).Assembly));
```

This registers:

- `IMediator` as transient
- `ISender` as transient
- `IPublisher` as transient
- `IRequestHandler<,>` concrete implementations as transient
- `IRequestHandler<>` concrete implementations as transient
- `INotificationHandler<>` concrete implementations as transient
- `IStreamRequestHandler<>` concrete implementations as transient
- `IRequestExceptionHandler<,,>` concrete implementations as transient
- `IRequestExceptionAction<,>` concrete implementations as transient

It also registers open generic implementations for:

- `INotificationHandler<>`
- `IRequestExceptionHandler<,,>`
- `IRequestExceptionAction<,>`

To register behaviors, stream behaviors, pre/post processors:

```csharp
services.AddMediatR(cfg => {
    cfg.RegisterServicesFromAssembly(typeof(Startup).Assembly);
    cfg.AddBehavior<PingPongBehavior>();
    cfg.AddStreamBehavior<PingPongStreamBehavior>();
    cfg.AddRequestPreProcessor<PingPreProcessor>();
    cfg.AddRequestPostProcessor<PingPongPostProcessor>();
    cfg.AddOpenBehavior(typeof(GenericBehavior<,>));
});
```

With additional methods for open generics and overloads for explicit service types.

### Differences vs upstream MediatR

- **License**: AN.MediatR stays Apache-2.0. No JWT runtime license check, no `LicenseKey` property, no logging requirement.
- **Improvements cherry-picked from upstream v13+ (non-licensing)**:
  - Notification handler deduplication at dispatch (fixes upstream issue #1118).
  - F# / `inref` assembly scanning resilience (`ServiceRegistrar` catches `ReflectionTypeLoadException`).
  - Nested-generic pipeline behavior support (`AddOpenBehavior(typeof(MyBehavior<,>))` works for `IPipelineBehavior<TRequest, List<T>>`, `IPipelineBehavior<TRequest, Result<T>>`, etc.).
  - Target frameworks: `netstandard2.0;net8.0;net9.0;net10.0` (+ `net462` on Windows).
  - Dependencies bumped to `Microsoft.Extensions.DependencyInjection.Abstractions` v10.

### Documentation

Comprehensive documentation lives in [`Docs/en/`](Docs/en/) (English) and [`Docs/es/`](Docs/es/) (Spanish), organized in 19 numbered Markdown files covering architecture, every interface, internals, dependency injection, build/publish, and best practices.

### Original credit

AN.MediatR is a fork. The original MediatR was created by **Jimmy Bogard** and is now maintained commercially by **Lucky Penny Software**. AN.MediatR retains the Apache-2.0 license inherited from MediatR v12.5 and credits Jimmy Bogard alongside Aves Nobles in the package metadata.
