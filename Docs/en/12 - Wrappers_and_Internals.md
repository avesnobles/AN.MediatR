# Wrappers and Internals

This chapter lifts the curtain on the *how* of AN.MediatR. Read it if you want to debug unusual DI issues, contribute to the library, or understand the library's performance characteristics.

Most of the types covered here are `internal`, so they are not part of the public API.

---

## Why wrappers exist

The `IMediator` API is intentionally small:

```csharp
Task<TResponse> Send<TResponse>(IRequest<TResponse> request, CancellationToken ct = default);
```

But the actual request type is only known at runtime — `IRequest<TResponse>` is the compile-time contract, the concrete `GetOrderById : IRequest<Order>` is the runtime type. To dispatch correctly, `Mediator` must:

1. Figure out the concrete `TRequest` (runtime type of `request`).
2. Resolve the right `IRequestHandler<TRequest, TResponse>` from the container.
3. Resolve all `IPipelineBehavior<TRequest, TResponse>` behaviors and wire them into a pipeline.
4. Call the result.

Doing this via reflection on every send would be extremely slow. Instead, AN.MediatR uses a **type-erasure** trick: for each `(TRequest, TResponse)` pair, it builds a generic **wrapper** class once, caches it in a static `ConcurrentDictionary<Type, ...>`, and reuses it forever. The cached wrapper carries the generic type information in its class definition, so subsequent dispatches only cost a dictionary lookup + a virtual call.

---

## Request wrappers

Source: [src/MediatR/Wrappers/RequestHandlerWrapper.cs](../../src/MediatR/Wrappers/RequestHandlerWrapper.cs).

```csharp
public abstract class RequestHandlerBase
{
    public abstract Task<object?> Handle(object request, IServiceProvider serviceProvider, CancellationToken ct);
}

public abstract class RequestHandlerWrapper<TResponse> : RequestHandlerBase
{
    public abstract Task<TResponse> Handle(IRequest<TResponse> request, IServiceProvider sp, CancellationToken ct);
}

public abstract class RequestHandlerWrapper : RequestHandlerBase
{
    public abstract Task<Unit> Handle(IRequest request, IServiceProvider sp, CancellationToken ct);
}
```

Three abstract levels:

- `RequestHandlerBase` — the fully type-erased base used as the cache value.
- `RequestHandlerWrapper<TResponse>` — preserves `TResponse` for typed `Send<TResponse>`.
- `RequestHandlerWrapper` — for void requests (`IRequest`), returns `Unit` uniformly.

### `RequestHandlerWrapperImpl<TRequest, TResponse>`

```csharp
public class RequestHandlerWrapperImpl<TRequest, TResponse> : RequestHandlerWrapper<TResponse>
    where TRequest : IRequest<TResponse>
{
    public override async Task<object?> Handle(object request, IServiceProvider sp, CancellationToken ct)
        => await Handle((IRequest<TResponse>)request, sp, ct).ConfigureAwait(false);

    public override Task<TResponse> Handle(IRequest<TResponse> request, IServiceProvider sp, CancellationToken ct)
    {
        Task<TResponse> Handler(CancellationToken t = default) =>
            sp.GetRequiredService<IRequestHandler<TRequest, TResponse>>()
              .Handle((TRequest)request, t == default ? ct : t);

        return sp.GetServices<IPipelineBehavior<TRequest, TResponse>>()
            .Reverse()
            .Aggregate(
                (RequestHandlerDelegate<TResponse>)Handler,
                (next, pipeline) => (t) => pipeline.Handle((TRequest)request, next, t == default ? ct : t))();
    }
}
```

What happens on each call:

1. **Local function `Handler`** resolves the concrete `IRequestHandler<TRequest, TResponse>` from the container and invokes its `Handle`. This is the innermost step of the pipeline.
2. **`sp.GetServices<IPipelineBehavior<TRequest, TResponse>>()`** enumerates every registered behavior. If you called `AddMediatR(cfg => cfg.AddOpenBehavior(typeof(LoggingBehavior<,>)))`, that behavior — closed over `<TRequest, TResponse>` — is included here, alongside any closed-generic registrations and the pre/post/exception decorators.
3. **`.Reverse()`** ensures that the **first** registered behavior ends up as the **outermost** layer of the pipeline.
4. **`.Aggregate(seed, (next, pipeline) => (t) => pipeline.Handle(request, next, t))`** folds the enumerable into a single `RequestHandlerDelegate<TResponse>`. Each behavior's `Handle(request, next, ct)` becomes the new `next` for the outer behavior.
5. **`()`** invokes the assembled chain.

### `RequestHandlerWrapperImpl<TRequest>` (void)

```csharp
public class RequestHandlerWrapperImpl<TRequest> : RequestHandlerWrapper
    where TRequest : IRequest
{
    public override Task<Unit> Handle(IRequest request, IServiceProvider sp, CancellationToken ct)
    {
        async Task<Unit> Handler(CancellationToken t = default)
        {
            await sp.GetRequiredService<IRequestHandler<TRequest>>()
                    .Handle((TRequest)request, t == default ? ct : t);
            return Unit.Value;
        }

        return sp.GetServices<IPipelineBehavior<TRequest, Unit>>()
            .Reverse()
            .Aggregate(
                (RequestHandlerDelegate<Unit>)Handler,
                (next, pipeline) => (t) => pipeline.Handle((TRequest)request, next, t == default ? ct : t))();
    }
}
```

Differences from the typed version:

- `IRequestHandler<TRequest>` has no response, so `Handler` returns `Unit.Value` after the handler completes.
- Pipeline behaviors are `IPipelineBehavior<TRequest, Unit>` — void requests are unified with the typed request pipeline by pretending `Unit` is the response type.

---

## Notification wrappers

Source: [src/MediatR/Wrappers/NotificationHandlerWrapper.cs](../../src/MediatR/Wrappers/NotificationHandlerWrapper.cs).

```csharp
public abstract class NotificationHandlerWrapper
{
    public abstract Task Handle(INotification notification, IServiceProvider sp,
        Func<IEnumerable<NotificationHandlerExecutor>, INotification, CancellationToken, Task> publish,
        CancellationToken ct);
}

public class NotificationHandlerWrapperImpl<TNotification> : NotificationHandlerWrapper
    where TNotification : INotification
{
    public override Task Handle(INotification notification, IServiceProvider sp,
        Func<IEnumerable<NotificationHandlerExecutor>, INotification, CancellationToken, Task> publish,
        CancellationToken ct)
    {
        var handlers = sp
            .GetServices<INotificationHandler<TNotification>>()
            .GroupBy(static x => x.GetType())
            .Select(static g => g.First())
            .Select(static x => new NotificationHandlerExecutor(x,
                (theNotification, theToken) => x.Handle((TNotification)theNotification, theToken)));

        return publish(handlers, notification, ct);
    }
}
```

Responsibilities:

- Resolve all notification handlers for `TNotification`.
- Deduplicate by concrete handler type (`GroupBy(x => x.GetType()).Select(g => g.First())`).
- Wrap each handler in a `NotificationHandlerExecutor` that casts `INotification` → `TNotification` inside its callback.
- Hand off the enumerable to the `publish` delegate supplied by the mediator — that delegate is `Mediator.PublishCore`, which in turn calls `INotificationPublisher.Publish(...)`.

---

## Stream wrappers

Source: [src/MediatR/Wrappers/StreamRequestHandlerWrapper.cs](../../src/MediatR/Wrappers/StreamRequestHandlerWrapper.cs).

```csharp
internal abstract class StreamRequestHandlerBase
{
    public abstract IAsyncEnumerable<object?> Handle(object request, IServiceProvider sp, CancellationToken ct);
}

internal abstract class StreamRequestHandlerWrapper<TResponse> : StreamRequestHandlerBase
{
    public abstract IAsyncEnumerable<TResponse> Handle(IStreamRequest<TResponse> request, IServiceProvider sp, CancellationToken ct);
}

internal class StreamRequestHandlerWrapperImpl<TRequest, TResponse> : StreamRequestHandlerWrapper<TResponse>
    where TRequest : IStreamRequest<TResponse>
{
    public override async IAsyncEnumerable<object?> Handle(object request, IServiceProvider sp, [EnumeratorCancellation] CancellationToken ct)
    {
        await foreach (var item in Handle((IStreamRequest<TResponse>)request, sp, ct))
            yield return item;
    }

    public override async IAsyncEnumerable<TResponse> Handle(IStreamRequest<TResponse> request, IServiceProvider sp, [EnumeratorCancellation] CancellationToken ct)
    {
        IAsyncEnumerable<TResponse> Handler() =>
            sp.GetRequiredService<IStreamRequestHandler<TRequest, TResponse>>()
              .Handle((TRequest)request, ct);

        var items = sp
            .GetServices<IStreamPipelineBehavior<TRequest, TResponse>>()
            .Reverse()
            .Aggregate(
                (StreamHandlerDelegate<TResponse>)Handler,
                (next, pipeline) => () => pipeline.Handle((TRequest)request, () => NextWrapper(next(), ct), ct))();

        await foreach (var item in items.WithCancellation(ct))
            yield return item;
    }

    private static async IAsyncEnumerable<T> NextWrapper<T>(IAsyncEnumerable<T> items, [EnumeratorCancellation] CancellationToken ct)
    {
        await foreach (var item in items.WithCancellation(ct).ConfigureAwait(false))
            yield return item;
    }
}
```

Same structure as `RequestHandlerWrapperImpl`, but:

- Return type is `IAsyncEnumerable<TResponse>`.
- `StreamHandlerDelegate<TResponse>` has **no arguments** (the cancellation token is captured in the closure instead of being passed in).
- `NextWrapper` is a helper method used so every step in the pipeline re-wraps the downstream enumerable with `WithCancellation(...)` — critical for cooperative cancellation across behaviors.

Note that `StreamRequestHandlerBase`, `StreamRequestHandlerWrapper<TResponse>`, and `StreamRequestHandlerWrapperImpl<TRequest, TResponse>` are `internal`. That's a deliberate asymmetry with the request wrappers (which are public, for historical reasons).

---

## `HandlersOrderer` and `ObjectDetails`

Used exclusively by the exception-handling behaviors (`RequestExceptionProcessorBehavior<,>` and `RequestExceptionActionProcessorBehavior<,>`) to sort handlers by relevance before running them.

### `HandlersOrderer`

Source: [src/MediatR/Internal/HandlersOrderer.cs](../../src/MediatR/Internal/HandlersOrderer.cs).

```csharp
internal static class HandlersOrderer
{
    public static IList<object> Prioritize<TRequest>(IList<object> handlers, TRequest request) where TRequest : notnull
    {
        if (handlers.Count < 2) return handlers;

        var requestObjectDetails = new ObjectDetails(request);
        var handlerObjectsDetails = handlers.Select(static s => new ObjectDetails(s)).ToList();

        var uniqueHandlers = RemoveOverridden(handlerObjectsDetails).ToArray();
        Array.Sort(uniqueHandlers, requestObjectDetails);      // request acts as the comparer

        return uniqueHandlers.Select(static s => s.Value).ToList();
    }

    private static IEnumerable<ObjectDetails> RemoveOverridden(IList<ObjectDetails> handlersData)
    {
        for (var i = 0; i < handlersData.Count - 1; i++)
            for (var j = i + 1; j < handlersData.Count; j++)
            {
                if (handlersData[i].IsOverridden || handlersData[j].IsOverridden) continue;

                if (handlersData[i].Type.IsAssignableFrom(handlersData[j].Type))
                    handlersData[i].IsOverridden = true;
                else if (handlersData[j].Type.IsAssignableFrom(handlersData[i].Type))
                    handlersData[j].IsOverridden = true;
            }

        return handlersData.Where(static w => !w.IsOverridden);
    }
}
```

- **`RemoveOverridden`**: if one handler's type is assignable from another's, the less-derived one is dropped. Lets a subclass override a base handler.
- **`Array.Sort(..., requestObjectDetails)`**: the `ObjectDetails` instance built from the request is used as `IComparer<ObjectDetails>`. Its comparison rules (see below) rank handler locations by proximity to the request.

### `ObjectDetails`

Source: [src/MediatR/Internal/ObjectDetails.cs](../../src/MediatR/Internal/ObjectDetails.cs).

```csharp
internal class ObjectDetails : IComparer<ObjectDetails>
{
    public string Name { get; }
    public string? AssemblyName { get; }
    public string? Location { get; }   // namespace stripped of the AssemblyName prefix
    public object Value { get; }
    public Type Type { get; }
    public bool IsOverridden { get; set; }

    public ObjectDetails(object value)
    {
        Value = value;
        Type = value.GetType();
        Name = Type.Name;
        AssemblyName = Type.Assembly.GetName().Name;
        Location = Type.Namespace?.Replace($"{AssemblyName}.", string.Empty);
    }

    public int Compare(ObjectDetails? x, ObjectDetails? y)
    {
        if (x == null) return 1;
        if (y == null) return -1;
        return CompareByAssembly(x, y) ?? CompareByNamespace(x, y) ?? CompareByLocation(x, y);
    }

    // CompareByAssembly — same-assembly-as-request wins
    // CompareByNamespace — namespace prefix match wins
    // CompareByLocation — longer location length (more specific) wins
}
```

The comparison is three-tiered:

1. **Assembly**: `x.AssemblyName == requestAssembly && y.AssemblyName != requestAssembly` ⇒ `x` wins.
2. **Namespace prefix**: `x.Location.StartsWith(requestLocation)` && `!y.Location.StartsWith(requestLocation)` ⇒ `x` wins.
3. **Location depth / length**: within equal categories, the longer `Location` (more specific namespace) wins; finally it falls back to equality.

Practical consequence: a `MyApp.Orders.InvalidOrderExceptionHandler` will run before a `MyApp.Infra.GenericExceptionLogger` when the request is `MyApp.Orders.CreateOrder`.

---

## `OpenBehavior` entity

Source: [src/MediatR/Entities/OpenBehavior.cs](../../src/MediatR/Entities/OpenBehavior.cs).

A public-value object for registering multiple open-generic pipeline behaviors with explicit lifetimes:

```csharp
public class OpenBehavior
{
    public OpenBehavior(Type openBehaviorType, ServiceLifetime serviceLifetime = ServiceLifetime.Transient)
    {
        ValidatePipelineBehaviorType(openBehaviorType);
        OpenBehaviorType = openBehaviorType;
        ServiceLifetime = serviceLifetime;
    }

    public Type OpenBehaviorType { get; }
    public ServiceLifetime ServiceLifetime { get; }

    private static void ValidatePipelineBehaviorType(Type openBehaviorType)
    {
        if (openBehaviorType == null) throw new ArgumentNullException("Open behavior type can not be null.");

        var isPipelineBehavior = openBehaviorType.GetInterfaces()
            .Any(i => i.IsGenericType && i.GetGenericTypeDefinition() == typeof(IPipelineBehavior<,>));

        if (!isPipelineBehavior)
            throw new InvalidOperationException($"The type \"{openBehaviorType.Name}\" must implement IPipelineBehavior<,> interface.");
    }
}
```

Used by `cfg.AddOpenBehaviors(IEnumerable<OpenBehavior>)` — a minor ergonomic sugar over passing `Type` + `ServiceLifetime` tuples.

---

## Type forwardings

Source: [src/MediatR/TypeForwardings.cs](../../src/MediatR/TypeForwardings.cs).

```csharp
[assembly: TypeForwardedTo(typeof(IBaseRequest))]
[assembly: TypeForwardedTo(typeof(IRequest<>))]
[assembly: TypeForwardedTo(typeof(IRequest))]
[assembly: TypeForwardedTo(typeof(INotification))]
[assembly: TypeForwardedTo(typeof(Unit))]
```

Physically these types live in `MediatR.Contracts`. The `MediatR` assembly forwards their definitions so that existing code referencing `MediatR.IRequest`, `MediatR.INotification`, etc. keeps working without an explicit reference to `MediatR.Contracts` — and without duplicating type definitions in both assemblies (which would be a CLR identity disaster).

See [Contracts Package](13%20-%20Contracts_Package.md) for the rationale.

---

## Recap — performance contract

| Operation | Cost |
|-----------|------|
| First send of a given request type | One `Type.MakeGenericType` + `Activator.CreateInstance` for the wrapper. One `IServiceProvider.GetServices(...)` + `Reverse().Aggregate(...)` to build the pipeline (materializes the behaviors list). |
| Subsequent sends | One `ConcurrentDictionary.TryGetValue`. One virtual call (`RequestHandlerBase.Handle`). One `GetServices` + `Aggregate` (still — because pipeline composition needs the fresh services list). |
| First publish of a given notification type | Wrapper construction + `GetServices<INotificationHandler<TNotification>>()`. |
| Subsequent publishes | Dictionary lookup + virtual call + `GetServices` + publisher strategy call. |
| Stream dispatch | Same as request; the enumerable is lazy. |

The pipeline behaviors list is **re-materialized** on every call — this is necessary because DI may return different instances for scoped/transient services. Keep behavior instantiation cheap.
