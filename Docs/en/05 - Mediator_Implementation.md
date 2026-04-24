# Mediator Implementation

This document walks through the actual `Mediator` class — the default implementation of `IMediator` — from top to bottom. If you want to understand **how** AN.MediatR dispatches messages (not just **what** the API does), read this.

Source file: [src/MediatR/Mediator.cs](../../src/MediatR/Mediator.cs).

---

## Class signature

```csharp
namespace MediatR;

public class Mediator : IMediator
{
    private readonly IServiceProvider _serviceProvider;
    private readonly INotificationPublisher _publisher;

    private static readonly ConcurrentDictionary<Type, RequestHandlerBase> _requestHandlers = new();
    private static readonly ConcurrentDictionary<Type, NotificationHandlerWrapper> _notificationHandlers = new();
    private static readonly ConcurrentDictionary<Type, StreamRequestHandlerBase> _streamRequestHandlers = new();

    public Mediator(IServiceProvider serviceProvider)
        : this(serviceProvider, new ForeachAwaitPublisher()) { }

    public Mediator(IServiceProvider serviceProvider, INotificationPublisher publisher)
    {
        _serviceProvider = serviceProvider;
        _publisher = publisher;
    }
}
```

Two things to note:

1. **Two private fields**: an `IServiceProvider` (for resolving handlers and behaviors on every call) and an `INotificationPublisher` (the strategy for multi-handler dispatch).
2. **Three static dictionaries**: these are the **global wrapper caches**, shared across every `Mediator` instance in the process. The key is the **runtime** type of a message; the value is a cached wrapper that knows how to invoke handlers for that type.

The two constructors form a small **chain**: if you don't pass an `INotificationPublisher`, you get `ForeachAwaitPublisher` (sequential handler execution). The constructor does no other work — no license check, no network call, no logging.

---

## The three static caches

```csharp
private static readonly ConcurrentDictionary<Type, RequestHandlerBase> _requestHandlers = new();
private static readonly ConcurrentDictionary<Type, NotificationHandlerWrapper> _notificationHandlers = new();
private static readonly ConcurrentDictionary<Type, StreamRequestHandlerBase> _streamRequestHandlers = new();
```

The caches store **wrappers**, not handlers. See [Wrappers and Internals](12%20-%20Wrappers_and_Internals.md) for the full wrapper hierarchy. For now it's enough to know:

- Wrappers are **stateless** — they just hold generic-type information.
- Wrappers are shared across all `Mediator` instances and scopes.
- On first use, the wrapper for a given `(request type)` is created via `Activator.CreateInstance` (one reflection call) and then cached forever.

This design is a deliberate trade-off: small amount of static, process-global state in exchange for zero reflection on the hot path.

> The caches live on `Mediator`, not on a static helper — that means a subclass that overrides `PublishCore` shares the same caches as the base. This is fine because the caches only depend on message types, never on `IMediator` instance behavior.

---

## `Send<TResponse>(IRequest<TResponse>)`

```csharp
public Task<TResponse> Send<TResponse>(IRequest<TResponse> request, CancellationToken cancellationToken = default)
{
    if (request == null) throw new ArgumentNullException(nameof(request));

    var handler = (RequestHandlerWrapper<TResponse>)_requestHandlers.GetOrAdd(request.GetType(), static requestType =>
    {
        var wrapperType = typeof(RequestHandlerWrapperImpl<,>).MakeGenericType(requestType, typeof(TResponse));
        var wrapper = Activator.CreateInstance(wrapperType)
                      ?? throw new InvalidOperationException($"Could not create wrapper type for {requestType}");
        return (RequestHandlerBase)wrapper;
    });

    return handler.Handle(request, _serviceProvider, cancellationToken);
}
```

Step by step:

1. **Null check**. Very fast path.
2. **Cache lookup** by the **runtime** type of the request (not the compile-time type). So a `GetOrderById` request that implements `IRequest<Order>` goes under key `typeof(GetOrderById)`.
3. **Cache miss factory** (`static` lambda — no captured state): close `RequestHandlerWrapperImpl<TRequest, TResponse>` over `(requestType, typeof(TResponse))`, instantiate it via `Activator.CreateInstance`. This is the only reflection cost, paid once per request type.
4. **Cast** to `RequestHandlerWrapper<TResponse>` (safe — we just built it) and **invoke** `Handle(request, _serviceProvider, cancellationToken)`.

That call is where the pipeline is actually built and executed — see [Wrappers and Internals](12%20-%20Wrappers_and_Internals.md) and [Pipeline Behaviors](06%20-%20Pipeline_Behaviors.md).

---

## `Send<TRequest>(TRequest)` (void)

```csharp
public Task Send<TRequest>(TRequest request, CancellationToken cancellationToken = default)
    where TRequest : IRequest
{
    if (request == null) throw new ArgumentNullException(nameof(request));

    var handler = (RequestHandlerWrapper)_requestHandlers.GetOrAdd(request.GetType(), static requestType =>
    {
        var wrapperType = typeof(RequestHandlerWrapperImpl<>).MakeGenericType(requestType);
        var wrapper = Activator.CreateInstance(wrapperType)
                      ?? throw new InvalidOperationException($"Could not create wrapper type for {requestType}");
        return (RequestHandlerBase)wrapper;
    });

    return handler.Handle(request, _serviceProvider, cancellationToken);
}
```

Same shape as the typed version, except the wrapper is `RequestHandlerWrapperImpl<TRequest>` (single generic parameter). Internally this wrapper produces a `Task<Unit>` and exposes it as a `Task` to the caller.

---

## `Send(object)` (dynamic)

```csharp
public Task<object?> Send(object request, CancellationToken cancellationToken = default)
{
    if (request == null) throw new ArgumentNullException(nameof(request));

    var handler = _requestHandlers.GetOrAdd(request.GetType(), static requestType =>
    {
        Type wrapperType;

        var requestInterfaceType = requestType.GetInterfaces()
            .FirstOrDefault(static i => i.IsGenericType && i.GetGenericTypeDefinition() == typeof(IRequest<>));

        if (requestInterfaceType is null)
        {
            requestInterfaceType = requestType.GetInterfaces().FirstOrDefault(static i => i == typeof(IRequest));
            if (requestInterfaceType is null)
            {
                throw new ArgumentException($"{requestType.Name} does not implement {nameof(IRequest)}", nameof(request));
            }

            wrapperType = typeof(RequestHandlerWrapperImpl<>).MakeGenericType(requestType);
        }
        else
        {
            var responseType = requestInterfaceType.GetGenericArguments()[0];
            wrapperType = typeof(RequestHandlerWrapperImpl<,>).MakeGenericType(requestType, responseType);
        }

        var wrapper = Activator.CreateInstance(wrapperType)
                      ?? throw new InvalidOperationException($"Could not create wrapper for type {requestType}");
        return (RequestHandlerBase)wrapper;
    });

    return handler.Handle(request, _serviceProvider, cancellationToken);
}
```

The dynamic overload adds one extra piece of reflection: discovering whether the runtime type implements `IRequest<T>` or `IRequest`, then closing the wrapper accordingly. After the first use that cost is eliminated by the cache.

Any other object type throws `ArgumentException`.

---

## `Publish<TNotification>(TNotification)`

```csharp
public Task Publish<TNotification>(TNotification notification, CancellationToken cancellationToken = default)
    where TNotification : INotification
{
    if (notification == null) throw new ArgumentNullException(nameof(notification));
    return PublishNotification(notification, cancellationToken);
}

public Task Publish(object notification, CancellationToken cancellationToken = default) =>
    notification switch
    {
        null => throw new ArgumentNullException(nameof(notification)),
        INotification instance => PublishNotification(instance, cancellationToken),
        _ => throw new ArgumentException($"{nameof(notification)} does not implement ${nameof(INotification)}")
    };
```

Both overloads funnel into:

```csharp
private Task PublishNotification(INotification notification, CancellationToken cancellationToken = default)
{
    var handler = _notificationHandlers.GetOrAdd(notification.GetType(), static notificationType =>
    {
        var wrapperType = typeof(NotificationHandlerWrapperImpl<>).MakeGenericType(notificationType);
        var wrapper = Activator.CreateInstance(wrapperType)
                      ?? throw new InvalidOperationException($"Could not create wrapper for type {notificationType}");
        return (NotificationHandlerWrapper)wrapper;
    });

    return handler.Handle(notification, _serviceProvider, PublishCore, cancellationToken);
}
```

Notice `PublishCore` is passed as a `Func` — the publisher strategy is invoked from inside the wrapper.

### `PublishCore` — the extension point

```csharp
protected virtual Task PublishCore(
    IEnumerable<NotificationHandlerExecutor> handlerExecutors,
    INotification notification,
    CancellationToken cancellationToken)
    => _publisher.Publish(handlerExecutors, notification, cancellationToken);
```

It delegates to the configured `INotificationPublisher`. You can override `PublishCore` in a `Mediator` subclass to inject per-message telemetry, error aggregation, ordering tweaks, etc., without replacing the publisher strategy outright.

---

## `CreateStream<TResponse>(IStreamRequest<TResponse>)`

```csharp
public IAsyncEnumerable<TResponse> CreateStream<TResponse>(
    IStreamRequest<TResponse> request, CancellationToken cancellationToken = default)
{
    if (request == null) throw new ArgumentNullException(nameof(request));

    var streamHandler = (StreamRequestHandlerWrapper<TResponse>)_streamRequestHandlers.GetOrAdd(request.GetType(), static requestType =>
    {
        var wrapperType = typeof(StreamRequestHandlerWrapperImpl<,>).MakeGenericType(requestType, typeof(TResponse));
        var wrapper = Activator.CreateInstance(wrapperType)
                      ?? throw new InvalidOperationException($"Could not create wrapper for type {requestType}");
        return (StreamRequestHandlerBase)wrapper;
    });

    return streamHandler.Handle(request, _serviceProvider, cancellationToken);
}
```

Identical shape to `Send<TResponse>`, but the wrapper returns `IAsyncEnumerable<TResponse>`. No awaiting happens here — the caller drives the enumeration with `await foreach`.

---

## `CreateStream(object)`

```csharp
public IAsyncEnumerable<object?> CreateStream(object request, CancellationToken cancellationToken = default)
{
    if (request == null) throw new ArgumentNullException(nameof(request));

    var handler = _streamRequestHandlers.GetOrAdd(request.GetType(), static requestType =>
    {
        var requestInterfaceType = requestType.GetInterfaces()
            .FirstOrDefault(static i => i.IsGenericType && i.GetGenericTypeDefinition() == typeof(IStreamRequest<>));

        if (requestInterfaceType is null)
            throw new ArgumentException($"{requestType.Name} does not implement IStreamRequest<TResponse>", nameof(request));

        var responseType = requestInterfaceType.GetGenericArguments()[0];
        var wrapperType = typeof(StreamRequestHandlerWrapperImpl<,>).MakeGenericType(requestType, responseType);
        var wrapper = Activator.CreateInstance(wrapperType)
                      ?? throw new InvalidOperationException($"Could not create wrapper for type {requestType}");
        return (StreamRequestHandlerBase)wrapper;
    });

    return handler.Handle(request, _serviceProvider, cancellationToken);
}
```

Mirror of `Send(object)` but for streams. Only `IStreamRequest<T>` is valid — there is no void equivalent, which makes sense: a stream with no items is just an empty `IAsyncEnumerable<T>`.

---

## Why `Mediator` is not sealed

`Mediator` is a regular (non-sealed) `public class`. You can inherit from it to:

- Override `PublishCore` for custom notification dispatch.
- Add telemetry / tracing spans around `Send` / `Publish` / `CreateStream`.
- Register a subclass via `cfg.MediatorImplementationType = typeof(MyMediator)`.

The `samples/MediatR.Examples.PublishStrategies` project does exactly that: its `CustomMediator` subclass accepts a delegate and calls it from `PublishCore` to implement six different strategies (Async, ParallelNoWait, ParallelWhenAll, ParallelWhenAny, SyncContinueOnException, SyncStopOnException).

---

## Null handling summary

| Method | On `null` request/notification |
|--------|---------------------------------|
| `Send<TResponse>(IRequest<TResponse>)` | `ArgumentNullException` |
| `Send<TRequest>(TRequest)` | `ArgumentNullException` |
| `Send(object)` | `ArgumentNullException` |
| `Publish<TNotification>` | `ArgumentNullException` |
| `Publish(object)` | `ArgumentNullException` (via switch) |
| `CreateStream<TResponse>` | `ArgumentNullException` |
| `CreateStream(object)` | `ArgumentNullException` |

Additionally, `Send(object)` / `CreateStream(object)` / `Publish(object)` throw `ArgumentException` if the object doesn't implement the right marker interface.

---

## Performance characteristics

- **Steady-state dispatch**: one dictionary lookup, one virtual call, one `IServiceProvider.GetServices(...)` enumeration per pipeline behavior. No reflection.
- **First-call dispatch**: additionally one `Activator.CreateInstance` + `MakeGenericType` per wrapper. Amortized over the application's lifetime.
- **Memory**: three static `ConcurrentDictionary` entries per distinct request / notification / stream-request type. Wrappers are tiny (just virtual method tables).

For the benchmark suite, see `test/MediatR.Benchmarks`.
