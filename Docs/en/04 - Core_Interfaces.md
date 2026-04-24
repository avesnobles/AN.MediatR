# Core Interfaces

This document is the **API reference** for every public type in AN.MediatR. Use it as a lookup table; for conceptual context see [Core Concepts](03%20-%20Core_Concepts.md).

All types below live in namespace `MediatR` unless stated otherwise.

---

## Marker interfaces (from `MediatR.Contracts`)

### `IBaseRequest`

```csharp
public interface IBaseRequest { }
```

Used as a generic type constraint when you need to accept "any kind of request" (either void or with a response). You rarely implement it directly — implement `IRequest` or `IRequest<TResponse>` instead.

### `IRequest`

```csharp
public interface IRequest : IBaseRequest { }
```

Marker interface for a request without a response (a "command" in CQRS parlance).

### `IRequest<TResponse>`

```csharp
public interface IRequest<out TResponse> : IBaseRequest { }
```

Marker interface for a request that returns `TResponse`. `TResponse` is covariant (`out`), so `IRequest<Derived>` is assignable to `IRequest<Base>`.

### `IStreamRequest<TResponse>`

```csharp
public interface IStreamRequest<out TResponse> { }
```

Marker interface for a request that returns `IAsyncEnumerable<TResponse>`. Covariant on `TResponse`.

### `INotification`

```csharp
public interface INotification { }
```

Marker interface for a notification (an event). Implementers are dispatched to zero, one or many `INotificationHandler<TNotification>` instances.

### `Unit`

```csharp
public readonly struct Unit : IEquatable<Unit>, IComparable<Unit>, IComparable
{
    public static ref readonly Unit Value { get; }
    public static Task<Unit> Task { get; }
    // CompareTo -> 0, Equals -> true, GetHashCode -> 0, ToString -> "()"
}
```

Void-substitute value type. Two handy helpers:

- `Unit.Value` — the singleton value.
- `Unit.Task` — a pre-allocated `Task.FromResult(Unit.Value)`.

Used internally as the response type for `IRequest` (void) in the pipeline, so `IPipelineBehavior<TRequest, Unit>` applies uniformly. You generally don't use `Unit` directly in application code.

---

## Mediator surface

### `ISender`

Source: [src/MediatR/ISender.cs](../../src/MediatR/ISender.cs).

```csharp
public interface ISender
{
    Task<TResponse> Send<TResponse>(IRequest<TResponse> request, CancellationToken ct = default);

    Task Send<TRequest>(TRequest request, CancellationToken ct = default)
        where TRequest : IRequest;

    Task<object?> Send(object request, CancellationToken ct = default);

    IAsyncEnumerable<TResponse> CreateStream<TResponse>(
        IStreamRequest<TResponse> request, CancellationToken ct = default);

    IAsyncEnumerable<object?> CreateStream(object request, CancellationToken ct = default);
}
```

Request dispatcher. Three `Send` overloads:

- **Typed with response** — picks the handler that returns `TResponse`.
- **Typed void** — constrained to `IRequest`, returns `Task`.
- **Dynamic** — introspects the runtime type for `IRequest<T>` / `IRequest`.

Two `CreateStream` overloads mirror the same pattern for stream requests.

### `IPublisher`

Source: [src/MediatR/IPublisher.cs](../../src/MediatR/IPublisher.cs).

```csharp
public interface IPublisher
{
    Task Publish(object notification, CancellationToken ct = default);

    Task Publish<TNotification>(TNotification notification, CancellationToken ct = default)
        where TNotification : INotification;
}
```

Notification dispatcher. Two `Publish` overloads — typed and dynamic.

### `IMediator`

Source: [src/MediatR/IMediator.cs](../../src/MediatR/IMediator.cs).

```csharp
public interface IMediator : ISender, IPublisher { }
```

Combined interface. Exposed by the DI container (with `ISender` and `IPublisher` resolving to the same `IMediator` instance — see [Dependency Injection](11%20-%20Dependency_Injection.md)).

---

## Handler interfaces

### `IRequestHandler<TRequest, TResponse>`

Source: [src/MediatR/IRequestHandler.cs](../../src/MediatR/IRequestHandler.cs).

```csharp
public interface IRequestHandler<in TRequest, TResponse>
    where TRequest : IRequest<TResponse>
{
    Task<TResponse> Handle(TRequest request, CancellationToken cancellationToken);
}
```

Implement this for every `IRequest<TResponse>` you define. Exactly one implementation per request type is expected; the DI container resolves it via `GetRequiredService<IRequestHandler<TRequest, TResponse>>()`.

### `IRequestHandler<TRequest>`

```csharp
public interface IRequestHandler<in TRequest>
    where TRequest : IRequest
{
    Task Handle(TRequest request, CancellationToken cancellationToken);
}
```

The void variant. Internally wrapped to return `Task<Unit>` so the pipeline stays uniform.

### `INotificationHandler<TNotification>`

Source: [src/MediatR/INotificationHandler.cs](../../src/MediatR/INotificationHandler.cs).

```csharp
public interface INotificationHandler<in TNotification>
    where TNotification : INotification
{
    Task Handle(TNotification notification, CancellationToken cancellationToken);
}
```

Implement once per `(TNotification, handler-class)` pair. Multiple handlers per notification are allowed — that's the whole point.

### `NotificationHandler<TNotification>` (abstract base class)

```csharp
public abstract class NotificationHandler<TNotification> : INotificationHandler<TNotification>
    where TNotification : INotification
{
    Task INotificationHandler<TNotification>.Handle(TNotification notification, CancellationToken ct)
    {
        Handle(notification);
        return Task.CompletedTask;
    }

    protected abstract void Handle(TNotification notification);
}
```

Convenience base class when your handler is synchronous. The `Task` wrapping is done for you.

### `IStreamRequestHandler<TRequest, TResponse>`

Source: [src/MediatR/IStreamRequestHandler.cs](../../src/MediatR/IStreamRequestHandler.cs).

```csharp
public interface IStreamRequestHandler<in TRequest, out TResponse>
    where TRequest : IStreamRequest<TResponse>
{
    IAsyncEnumerable<TResponse> Handle(TRequest request, CancellationToken cancellationToken);
}
```

Implement for `IStreamRequest<TResponse>` messages. Use `async IAsyncEnumerable<TResponse>` with `[EnumeratorCancellation]` on the `CancellationToken` parameter.

---

## Pipeline interfaces

### `RequestHandlerDelegate<TResponse>`

```csharp
public delegate Task<TResponse> RequestHandlerDelegate<TResponse>(CancellationToken t = default);
```

The "call the next step of the pipeline" delegate handed to every `IPipelineBehavior`. The optional `CancellationToken` parameter allows a behavior to forward a scoped/linked token downstream (pass `default` to keep the original).

### `IPipelineBehavior<TRequest, TResponse>`

Source: [src/MediatR/IPipelineBehavior.cs](../../src/MediatR/IPipelineBehavior.cs).

```csharp
public interface IPipelineBehavior<in TRequest, TResponse> where TRequest : notnull
{
    Task<TResponse> Handle(
        TRequest request,
        RequestHandlerDelegate<TResponse> next,
        CancellationToken cancellationToken);
}
```

Implement to add cross-cutting behavior around request handling. Can short-circuit by skipping `next()`, return a different response, wrap the call in a try/catch, start an activity for tracing, etc.

### `StreamHandlerDelegate<TResponse>`

```csharp
public delegate IAsyncEnumerable<TResponse> StreamHandlerDelegate<out TResponse>();
```

The stream-pipeline equivalent of `RequestHandlerDelegate`.

### `IStreamPipelineBehavior<TRequest, TResponse>`

Source: [src/MediatR/IStreamPipelineBehavior.cs](../../src/MediatR/IStreamPipelineBehavior.cs).

```csharp
public interface IStreamPipelineBehavior<in TRequest, TResponse> where TRequest : notnull
{
    IAsyncEnumerable<TResponse> Handle(
        TRequest request,
        StreamHandlerDelegate<TResponse> next,
        CancellationToken cancellationToken);
}
```

Stream pipeline equivalent of `IPipelineBehavior`. Compose by `await foreach`-ing over `next()` and yielding elements.

---

## Processor interfaces (namespace `MediatR.Pipeline`)

### `IRequestPreProcessor<TRequest>`

```csharp
public interface IRequestPreProcessor<in TRequest> where TRequest : notnull
{
    Task Process(TRequest request, CancellationToken cancellationToken);
}
```

Run code before a handler. Multiple pre-processors allowed per request (they run in DI-resolution order).

### `IRequestPostProcessor<TRequest, TResponse>`

```csharp
public interface IRequestPostProcessor<in TRequest, in TResponse> where TRequest : notnull
{
    Task Process(TRequest request, TResponse response, CancellationToken cancellationToken);
}
```

Run code after a handler, with access to the response. The response can be inspected but not replaced (use a pipeline behavior to replace responses).

### `IRequestExceptionAction<TRequest, TException>`

```csharp
public interface IRequestExceptionAction<in TRequest, in TException>
    where TRequest : notnull
    where TException : Exception
{
    Task Execute(TRequest request, TException exception, CancellationToken cancellationToken);
}
```

"Fire-and-observe" exception reactors. Always execute when the request handler throws `TException` (or a subclass). **Always rethrow afterward** — use for logging / metrics, not for recovery.

### `IRequestExceptionHandler<TRequest, TResponse, TException>`

```csharp
public interface IRequestExceptionHandler<in TRequest, TResponse, in TException>
    where TRequest : notnull
    where TException : Exception
{
    Task Handle(
        TRequest request,
        TException exception,
        RequestExceptionHandlerState<TResponse> state,
        CancellationToken cancellationToken);
}
```

Exception recoverers. Call `state.SetHandled(response)` to suppress the exception and return `response` instead. If no handler sets `Handled`, the original exception is rethrown.

### `RequestExceptionHandlerState<TResponse>`

```csharp
public class RequestExceptionHandlerState<TResponse>
{
    public bool Handled { get; private set; }
    public TResponse? Response { get; private set; }
    public void SetHandled(TResponse response) { Handled = true; Response = response; }
}
```

Mutable state object passed to exception handlers. Only one handler needs to call `SetHandled` for the exception to be swallowed.

---

## Publisher contract

### `INotificationPublisher`

Source: [src/MediatR/INotificationPublisher.cs](../../src/MediatR/INotificationPublisher.cs).

```csharp
public interface INotificationPublisher
{
    Task Publish(
        IEnumerable<NotificationHandlerExecutor> handlerExecutors,
        INotification notification,
        CancellationToken cancellationToken);
}
```

Strategy interface that decides **how** notification handlers are invoked (sequentially, in parallel, with error aggregation, etc.). See [Notification Publishers](09%20-%20Notification_Publishers.md).

### `NotificationHandlerExecutor`

Source: [src/MediatR/NotificationHandlerExecutor.cs](../../src/MediatR/NotificationHandlerExecutor.cs).

```csharp
public record NotificationHandlerExecutor(
    object HandlerInstance,
    Func<INotification, CancellationToken, Task> HandlerCallback);
```

Value object that pairs a handler instance with a closure that knows how to call it with a (type-erased) `INotification`. Publishers iterate a sequence of these to invoke the handlers.

---

## Registration entity

### `OpenBehavior` (namespace `MediatR.Entities`)

Source: [src/MediatR/Entities/OpenBehavior.cs](../../src/MediatR/Entities/OpenBehavior.cs).

```csharp
public class OpenBehavior
{
    public OpenBehavior(Type openBehaviorType, ServiceLifetime serviceLifetime = ServiceLifetime.Transient);
    public Type OpenBehaviorType { get; }
    public ServiceLifetime ServiceLifetime { get; }
}
```

Value object used with `AddOpenBehaviors(IEnumerable<OpenBehavior>)` to register multiple open-generic pipeline behaviors with explicit lifetimes. The constructor validates that the type implements `IPipelineBehavior<,>`.

---

## DI configuration types (namespace `Microsoft.Extensions.DependencyInjection`)

### `MediatRServiceConfiguration`

Source: [src/MediatR/MicrosoftExtensionsDI/MediatrServiceConfiguration.cs](../../src/MediatR/MicrosoftExtensionsDI/MediatrServiceConfiguration.cs).

The fluent configuration object passed to the `AddMediatR(cfg => ...)` action. Main properties:

| Property | Default | Purpose |
|----------|---------|---------|
| `TypeEvaluator` | `t => true` | Filter applied to every candidate handler type during scanning |
| `MediatorImplementationType` | `typeof(Mediator)` | Subclass to register for `IMediator` |
| `NotificationPublisher` | `new ForeachAwaitPublisher()` | Default strategy instance |
| `NotificationPublisherType` | `null` | If set, resolves the publisher from the container; overrides `NotificationPublisher` |
| `Lifetime` | `Transient` | Lifetime for `IMediator`, `ISender`, `IPublisher` |
| `RequestExceptionActionProcessorStrategy` | `ApplyForUnhandledExceptions` | Ordering of exception actions vs. handlers |
| `AutoRegisterRequestProcessors` | `false` | Auto-scan `IRequestPreProcessor` / `IRequestPostProcessor` |
| `MaxGenericTypeParameters` | `10` | Safety limit for open-generic handler registration |
| `MaxTypesClosing` | `100` | Max types that can close a single generic constraint |
| `MaxGenericTypeRegistrations` | `125000` | Max total combinations |
| `RegistrationTimeout` | `15000` ms | Timeout for the registration process |
| `RegisterGenericHandlers` | `false` | Whether to register handlers with generic type parameters |

Registration methods (chainable — each returns `this`):

- `RegisterServicesFromAssembly(Assembly)` — add an assembly to the scan list.
- `RegisterServicesFromAssemblies(params Assembly[])` — same for many.
- `RegisterServicesFromAssemblyContaining<T>()` / `(Type)` — shortcut via marker type.
- `AddBehavior<T>()` / `AddBehavior<TService, TImpl>()` / `AddBehavior(Type)` / `AddBehavior(Type, Type)` — register closed pipeline behaviors.
- `AddOpenBehavior(Type)` / `AddOpenBehaviors(IEnumerable<Type>)` / `AddOpenBehaviors(IEnumerable<OpenBehavior>)` — register open-generic pipeline behaviors.
- `AddStreamBehavior<T>()` / `AddStreamBehavior<TService, TImpl>()` / `AddStreamBehavior(Type)` / `AddStreamBehavior(Type, Type)` / `AddOpenStreamBehavior(Type)` — same for streams.
- `AddRequestPreProcessor<T>()` / `AddRequestPreProcessor<TService, TImpl>()` / `AddRequestPreProcessor(Type)` / `AddRequestPreProcessor(Type, Type)` / `AddOpenRequestPreProcessor(Type)`.
- `AddRequestPostProcessor<T>()` / `AddRequestPostProcessor<TService, TImpl>()` / `AddRequestPostProcessor(Type)` / `AddRequestPostProcessor(Type, Type)` / `AddOpenRequestPostProcessor(Type)`.

### `RequestExceptionActionProcessorStrategy`

```csharp
public enum RequestExceptionActionProcessorStrategy
{
    ApplyForUnhandledExceptions,   // actions run only if no handler handled
    ApplyForAllExceptions           // actions run regardless
}
```

Controls the registration order of `RequestExceptionActionProcessorBehavior<,>` vs. `RequestExceptionProcessorBehavior<,>` — see [Exception Handling](08%20-%20Exception_Handling.md).

### `ServiceCollectionExtensions`

Source: [src/MediatR/MicrosoftExtensionsDI/ServiceCollectionExtensions.cs](../../src/MediatR/MicrosoftExtensionsDI/ServiceCollectionExtensions.cs).

- `services.AddMediatR(Action<MediatRServiceConfiguration>)` — idiomatic registration entry point.
- `services.AddMediatR(MediatRServiceConfiguration)` — overload accepting a prepared configuration.

---

## Internal types worth knowing

These types are `internal`, but understanding them helps when debugging or extending. See [Wrappers and Internals](12%20-%20Wrappers_and_Internals.md) for details.

- `MediatR.Wrappers.RequestHandlerBase`, `RequestHandlerWrapper<TResponse>`, `RequestHandlerWrapper`, `RequestHandlerWrapperImpl<TRequest, TResponse>`, `RequestHandlerWrapperImpl<TRequest>`.
- `MediatR.Wrappers.NotificationHandlerWrapper`, `NotificationHandlerWrapperImpl<TNotification>`.
- `MediatR.Wrappers.StreamRequestHandlerBase`, `StreamRequestHandlerWrapper<TResponse>`, `StreamRequestHandlerWrapperImpl<TRequest, TResponse>`.
- `MediatR.Internal.HandlersOrderer` — prioritizes exception handlers by assembly/namespace proximity.
- `MediatR.Internal.ObjectDetails` — the `IComparer<ObjectDetails>` used by `HandlersOrderer`.

---

## Quick reference card

```csharp
// Dispatching
Task<TResponse>             IMediator.Send<TResponse>(IRequest<TResponse>, CancellationToken)
Task                        IMediator.Send<TRequest>(TRequest, CancellationToken)       where TRequest : IRequest
Task<object?>               IMediator.Send(object, CancellationToken)
Task                        IMediator.Publish<TNotification>(TNotification, CancellationToken)
Task                        IMediator.Publish(object, CancellationToken)
IAsyncEnumerable<TResponse> IMediator.CreateStream<TResponse>(IStreamRequest<TResponse>, CancellationToken)
IAsyncEnumerable<object?>   IMediator.CreateStream(object, CancellationToken)

// Handling
IRequestHandler<TRequest, TResponse>.Handle(TRequest, CancellationToken) : Task<TResponse>
IRequestHandler<TRequest>.Handle(TRequest, CancellationToken)            : Task
INotificationHandler<TNotification>.Handle(TNotification, CancellationToken) : Task
IStreamRequestHandler<TRequest, TResponse>.Handle(TRequest, CancellationToken) : IAsyncEnumerable<TResponse>

// Cross-cutting
IPipelineBehavior<TRequest, TResponse>.Handle(TRequest, RequestHandlerDelegate<TResponse>, CancellationToken)
IStreamPipelineBehavior<TRequest, TResponse>.Handle(TRequest, StreamHandlerDelegate<TResponse>, CancellationToken)
IRequestPreProcessor<TRequest>.Process(TRequest, CancellationToken)
IRequestPostProcessor<TRequest, TResponse>.Process(TRequest, TResponse, CancellationToken)
IRequestExceptionAction<TRequest, TException>.Execute(TRequest, TException, CancellationToken)
IRequestExceptionHandler<TRequest, TResponse, TException>.Handle(TRequest, TException, RequestExceptionHandlerState<TResponse>, CancellationToken)
```
