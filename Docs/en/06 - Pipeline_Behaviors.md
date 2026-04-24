# Pipeline Behaviors

Pipeline behaviors are AN.MediatR's most important extensibility point. They are the equivalent of **middleware** in ASP.NET Core: decorators that wrap every request handler, in a Russian-doll composition, to implement cross-cutting concerns without touching the handlers themselves.

---

## The contract

```csharp
public delegate Task<TResponse> RequestHandlerDelegate<TResponse>(CancellationToken t = default);

public interface IPipelineBehavior<in TRequest, TResponse> where TRequest : notnull
{
    Task<TResponse> Handle(
        TRequest request,
        RequestHandlerDelegate<TResponse> next,
        CancellationToken cancellationToken);
}
```

Source: [src/MediatR/IPipelineBehavior.cs](../../src/MediatR/IPipelineBehavior.cs).

A behavior:

- Receives the request.
- Receives a `next` delegate that calls the next step of the pipeline (either the next behavior or — eventually — the handler itself).
- Receives a `CancellationToken`.
- Returns `Task<TResponse>`.

The `RequestHandlerDelegate<TResponse>` takes an optional `CancellationToken` parameter. If the behavior passes `default`, the outer token is reused; otherwise the behavior can pass a linked/replacement token to downstream steps (useful for timeouts, per-step scopes, etc.).

---

## How the pipeline is built

The pipeline is constructed inside `RequestHandlerWrapperImpl<TRequest, TResponse>.Handle(...)`:

```csharp
public override Task<TResponse> Handle(IRequest<TResponse> request, IServiceProvider sp, CancellationToken cancellationToken)
{
    Task<TResponse> Handler(CancellationToken t = default) =>
        sp.GetRequiredService<IRequestHandler<TRequest, TResponse>>()
          .Handle((TRequest)request, t == default ? cancellationToken : t);

    return sp.GetServices<IPipelineBehavior<TRequest, TResponse>>()
        .Reverse()
        .Aggregate(
            (RequestHandlerDelegate<TResponse>)Handler,
            (next, pipeline) => (t) => pipeline.Handle((TRequest)request, next, t == default ? cancellationToken : t))();
}
```

Source: [src/MediatR/Wrappers/RequestHandlerWrapper.cs](../../src/MediatR/Wrappers/RequestHandlerWrapper.cs).

Break this down piece by piece:

1. **`Handler`** is a local function representing the innermost call — it resolves `IRequestHandler<TRequest, TResponse>` and invokes it.
2. **`sp.GetServices<IPipelineBehavior<TRequest, TResponse>>()`** returns every registered behavior for this `(TRequest, TResponse)` pair, **in registration order**.
3. **`.Reverse()`** flips the list so the **first** registered behavior ends up **outermost** in the final chain.
4. **`.Aggregate(seed, (next, pipeline) => ...)`** folds the list: starting from `Handler`, each behavior produces a new delegate that, when invoked, calls `pipeline.Handle(request, next, ct)`. After the fold, you have a single `RequestHandlerDelegate<TResponse>` representing the entire chain.
5. **`()`** invokes the resulting delegate to actually run the request.

### Execution order example

Suppose you register:

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(...);
    cfg.AddOpenBehavior(typeof(LoggingBehavior<,>));      // 1st
    cfg.AddOpenBehavior(typeof(ValidationBehavior<,>));   // 2nd
    cfg.AddOpenBehavior(typeof(TransactionBehavior<,>));  // 3rd
});
```

Runtime execution looks like:

```
caller → mediator.Send(request)
        │
        ▼
   LoggingBehavior.Handle(request, next1)
        │  log "start"
        ▼
   ValidationBehavior.Handle(request, next2)
        │  validate
        ▼
   TransactionBehavior.Handle(request, next3)
        │  begin tx
        ▼
   Handler.Handle(request)
        │  (business logic)
        ▲  commit/rollback
        │
        ▲  (validation post-phase, if any)
        │
        ▲  log "end"
        │
caller ← response
```

Rule of thumb: **earlier registration = outer layer**.

---

## Writing a behavior

```csharp
public class LoggingBehavior<TRequest, TResponse> : IPipelineBehavior<TRequest, TResponse>
    where TRequest : notnull
{
    private readonly ILogger<LoggingBehavior<TRequest, TResponse>> _logger;

    public LoggingBehavior(ILogger<LoggingBehavior<TRequest, TResponse>> logger) => _logger = logger;

    public async Task<TResponse> Handle(
        TRequest request,
        RequestHandlerDelegate<TResponse> next,
        CancellationToken cancellationToken)
    {
        _logger.LogInformation("Handling {Request}", typeof(TRequest).Name);
        var sw = Stopwatch.StartNew();
        try
        {
            return await next(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _logger.LogInformation("Handled {Request} in {Elapsed}ms", typeof(TRequest).Name, sw.ElapsedMilliseconds);
        }
    }
}
```

Key patterns:

- **Use `ConfigureAwait(false)`** in library-style code to avoid forcing a synchronization context.
- **Always forward the token** to `next(cancellationToken)` unless you have a specific reason to swap it.
- **Prefer open generics** (`<TRequest, TResponse>`) for truly cross-cutting concerns. Register with `AddOpenBehavior(typeof(LoggingBehavior<,>))`.
- **Constrain `TRequest`** if the behavior should only run for some requests (e.g. `where TRequest : ICommand`). DI will then only inject it for matching types.

---

## Short-circuiting

A behavior can **skip** calling `next` and return a response directly. This is how caching, idempotency, and authorization layers typically work:

```csharp
public async Task<TResponse> Handle(
    TRequest request,
    RequestHandlerDelegate<TResponse> next,
    CancellationToken cancellationToken)
{
    if (_cache.TryGet<TResponse>(request, out var cached))
        return cached; // handler is never invoked

    var response = await next(cancellationToken).ConfigureAwait(false);
    _cache.Set(request, response);
    return response;
}
```

Short-circuiting is fully supported — AN.MediatR makes no assumption that `next` will be called.

---

## Replacing the response

Because the behavior owns the `Task<TResponse>` return, it can inspect the response, wrap it, or replace it entirely:

```csharp
public async Task<Result<T>> Handle(
    ValidatedQuery<T> request,
    RequestHandlerDelegate<Result<T>> next,
    CancellationToken cancellationToken)
{
    var validation = _validator.Validate(request);
    if (!validation.IsValid)
        return Result<T>.Failure(validation.Errors);

    return await next(cancellationToken).ConfigureAwait(false);
}
```

---

## Stream pipeline behaviors

For `IStreamRequest<TResponse>` messages, use `IStreamPipelineBehavior<TRequest, TResponse>`:

```csharp
public interface IStreamPipelineBehavior<in TRequest, TResponse> where TRequest : notnull
{
    IAsyncEnumerable<TResponse> Handle(
        TRequest request,
        StreamHandlerDelegate<TResponse> next,
        CancellationToken cancellationToken);
}

public delegate IAsyncEnumerable<TResponse> StreamHandlerDelegate<out TResponse>();
```

Typical implementation:

```csharp
public class LoggingStreamBehavior<TRequest, TResponse>
    : IStreamPipelineBehavior<TRequest, TResponse>
    where TRequest : notnull
{
    public async IAsyncEnumerable<TResponse> Handle(
        TRequest request,
        StreamHandlerDelegate<TResponse> next,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var count = 0;
        await foreach (var item in next().WithCancellation(cancellationToken).ConfigureAwait(false))
        {
            count++;
            yield return item;
        }
        Console.WriteLine($"Streamed {count} items");
    }
}
```

Notes:

- The `next` delegate takes **no arguments** (the token is captured from the outer call).
- Use `[EnumeratorCancellation]` on the `CancellationToken` parameter.
- `await foreach` over `next()` and `yield return` each item individually.
- Register with `AddOpenStreamBehavior(typeof(LoggingStreamBehavior<,>))` or explicit service type.

See [Streaming](10%20-%20Streaming.md) for details.

---

## Built-in behaviors

AN.MediatR ships four built-in behaviors, all living in `MediatR.Pipeline`:

| Behavior | Purpose | Automatic registration |
|----------|---------|------------------------|
| `RequestPreProcessorBehavior<TRequest, TResponse>` | Runs `IRequestPreProcessor<TRequest>` instances before the handler | Yes, if any pre-processors are registered |
| `RequestPostProcessorBehavior<TRequest, TResponse>` | Runs `IRequestPostProcessor<TRequest, TResponse>` instances after the handler | Yes, if any post-processors are registered |
| `RequestExceptionActionProcessorBehavior<TRequest, TResponse>` | Runs `IRequestExceptionAction<TRequest, TException>` instances on exception (always rethrows) | Yes, if any actions are registered |
| `RequestExceptionProcessorBehavior<TRequest, TResponse>` | Runs `IRequestExceptionHandler<TRequest, TResponse, TException>` instances on exception (can swallow) | Yes, if any handlers are registered |

See [Processors](07%20-%20Processors.md) and [Exception Handling](08%20-%20Exception_Handling.md) for their precise semantics.

---

## Registration reference

All registration APIs live on `MediatRServiceConfiguration` (`cfg`):

```csharp
cfg.AddBehavior<MyBehavior>();                                    // generic closed
cfg.AddBehavior<IPipelineBehavior<Ping, Pong>, MyBehavior>();    // explicit service type
cfg.AddBehavior(typeof(MyBehavior));                              // non-generic
cfg.AddBehavior(typeof(IPipelineBehavior<Ping, Pong>), typeof(MyBehavior));

cfg.AddOpenBehavior(typeof(LoggingBehavior<,>));                  // open generic
cfg.AddOpenBehaviors(new[] { typeof(LoggingBehavior<,>), typeof(TimingBehavior<,>) });
cfg.AddOpenBehaviors(new[] { new OpenBehavior(typeof(LoggingBehavior<,>), ServiceLifetime.Singleton) });

// Stream variants:
cfg.AddStreamBehavior<MyStreamBehavior>();
cfg.AddOpenStreamBehavior(typeof(LoggingStreamBehavior<,>));
```

Every method accepts an optional `ServiceLifetime` (default `Transient`).

The configuration only records **what** to register, in order. Actual registration happens in `ServiceRegistrar.AddRequiredServices`, which calls `services.TryAddEnumerable(...)` for each behavior so they accumulate rather than replacing each other.

---

## Special case: open behaviors with nested-generic response types

If your open behavior looks like:

```csharp
public class UnwrapResultBehavior<TRequest, T> : IPipelineBehavior<TRequest, Result<T>>
    where TRequest : IRequest<Result<T>>
{
    public Task<Result<T>> Handle(...) { ... }
}
```

then the response type contains a nested generic (`Result<T>`). `Microsoft.Extensions.DependencyInjection`'s positional-mapping of open generics can't close `Result<T>` from `(TRequest, TResponse)` alone.

AN.MediatR detects this (`HasNestedGenericResponseType` in `ServiceRegistrar`) and **explicitly closes** the behavior for every matching request/response pair found in the scanned assemblies. This is a silent, automatic feature — you just register the open behavior as usual.

---

## Lifetime considerations

- Behaviors are resolved via `IServiceProvider.GetServices(...)` on every dispatch — **`Transient` is the safe default**.
- If you register a behavior as `Scoped` and resolve the mediator outside of a scope, you'll get an exception. When in doubt, stay transient.
- `Singleton` behaviors must be thread-safe and must not depend on scoped services.

---

## Summary checklist for writing a new behavior

- [ ] Implement `IPipelineBehavior<TRequest, TResponse>`.
- [ ] Constrain `TRequest` if the behavior is selective.
- [ ] Always `await next(cancellationToken)` (unless intentionally short-circuiting).
- [ ] Use `ConfigureAwait(false)`.
- [ ] Register via `cfg.AddOpenBehavior(typeof(MyBehavior<,>))` or a closed variant.
- [ ] Register **in the order you want them executed** (first registered = outer).
- [ ] Keep it transient unless you can prove thread-safety.
