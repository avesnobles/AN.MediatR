# Exception Handling

AN.MediatR provides **two** parallel mechanisms for reacting to exceptions thrown by request handlers:

1. **Exception actions** (`IRequestExceptionAction<TRequest, TException>`) — observe and react (logging, metrics). Always rethrow.
2. **Exception handlers** (`IRequestExceptionHandler<TRequest, TResponse, TException>`) — recover and return an alternate response.

Both are implemented as decorator `IPipelineBehavior` instances automatically wired by `ServiceRegistrar`. Both live in namespace `MediatR.Pipeline`.

---

## Exception **actions** — fire and rethrow

### Contract

```csharp
public interface IRequestExceptionAction<in TRequest, in TException>
    where TRequest : notnull
    where TException : Exception
{
    Task Execute(TRequest request, TException exception, CancellationToken cancellationToken);
}
```

Source: [src/MediatR/Pipeline/IRequestExceptionAction.cs](../../src/MediatR/Pipeline/IRequestExceptionAction.cs).

### Semantics

- Runs when the handler throws `TException` **or any subclass** of it.
- Used for logging, tracing, metrics, notifications, and other side-effects that should not change control flow.
- **The exception is always rethrown** after all matching actions have executed.
- Multiple actions per exception type are supported; they run sequentially in priority order (see `HandlersOrderer` below).

### Implementing

```csharp
public class LogException<TRequest> : IRequestExceptionAction<TRequest, Exception>
    where TRequest : notnull
{
    private readonly ILogger<LogException<TRequest>> _logger;
    public LogException(ILogger<LogException<TRequest>> logger) => _logger = logger;

    public Task Execute(TRequest request, Exception exception, CancellationToken cancellationToken)
    {
        _logger.LogError(exception, "Error handling {Request}", typeof(TRequest).Name);
        return Task.CompletedTask;
    }
}
```

The generic parameter `Exception` means "run for any exception". To narrow down, use a subclass like `TimeoutException` or `ValidationException`.

---

## Exception **handlers** — recover with a response

### Contract

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

Source: [src/MediatR/Pipeline/IRequestExceptionHandler.cs](../../src/MediatR/Pipeline/IRequestExceptionHandler.cs).

### `RequestExceptionHandlerState<TResponse>`

```csharp
public class RequestExceptionHandlerState<TResponse>
{
    public bool Handled { get; private set; }
    public TResponse? Response { get; private set; }

    public void SetHandled(TResponse response)
    {
        Handled = true;
        Response = response;
    }
}
```

Mutable state object passed by reference to every handler. Call `state.SetHandled(response)` to suppress the exception and return `response` instead.

### Semantics

- Runs when the handler throws `TException` **or any subclass** of it.
- If any handler calls `state.SetHandled(response)`, the exception is swallowed and `response` is returned to the caller.
- If **no** handler sets `Handled`, the original exception is rethrown.
- After `Handled` becomes `true`, remaining handlers are **not** invoked.
- If a handler sets `Handled` but `response` is `null`, the behavior still rethrows (null is treated as "no response").

### Implementing

```csharp
public class TranslateNotFound<TRequest, TResponse> : IRequestExceptionHandler<TRequest, TResponse, EntityNotFoundException>
    where TRequest : notnull
    where TResponse : new()
{
    public Task Handle(
        TRequest request,
        EntityNotFoundException exception,
        RequestExceptionHandlerState<TResponse> state,
        CancellationToken cancellationToken)
    {
        state.SetHandled(new TResponse());   // return a default-constructed response
        return Task.CompletedTask;
    }
}
```

---

## Inside the pipeline behaviors

### `RequestExceptionProcessorBehavior<TRequest, TResponse>`

Source: [src/MediatR/Pipeline/RequestExceptionProcessorBehavior.cs](../../src/MediatR/Pipeline/RequestExceptionProcessorBehavior.cs).

```csharp
public async Task<TResponse> Handle(TRequest request, RequestHandlerDelegate<TResponse> next, CancellationToken cancellationToken)
{
    try
    {
        return await next(cancellationToken).ConfigureAwait(false);
    }
    catch (Exception exception)
    {
        var state = new RequestExceptionHandlerState<TResponse>();
        var exceptionTypes = GetExceptionTypes(exception.GetType());   // climbs the Exception.BaseType chain

        var handlersForException = exceptionTypes
            .SelectMany(t => GetHandlersForException(t, request))   // service provider resolves handlers for each type
            .GroupBy(x => x.Handler.GetType())
            .Select(g => g.First())                                 // dedupe by handler type
            .Select(x => (MethodInfo: GetMethodInfoForHandler(x.ExceptionType), x.Handler))
            .ToList();

        foreach (var (methodInfo, handler) in handlersForException)
        {
            try { await ((Task)methodInfo.Invoke(handler, new object[] { request, exception, state, cancellationToken })!).ConfigureAwait(false); }
            catch (TargetInvocationException tie) when (tie.InnerException != null) { ExceptionDispatchInfo.Capture(tie.InnerException).Throw(); }

            if (state.Handled) break;
        }

        if (!state.Handled) throw;                 // no handler recovered
        if (state.Response is null) throw;         // handler forgot to set a response
        return state.Response;
    }
}
```

Key points:

- **Exception-type walk**: starts with the concrete exception type and follows `BaseType` to `Exception`, collecting all handlers registered for each level.
- **Priority**: within each level, `HandlersOrderer.Prioritize(handlers, request)` reorders them (see below).
- **Early exit**: as soon as `state.Handled` becomes `true`, further handlers are skipped.
- **Rethrow semantics**: a bare `throw;` preserves the original stack trace; `TargetInvocationException` unwrapping uses `ExceptionDispatchInfo` so the inner stack trace is preserved.

### `RequestExceptionActionProcessorBehavior<TRequest, TResponse>`

Source: [src/MediatR/Pipeline/RequestExceptionActionProcessorBehavior.cs](../../src/MediatR/Pipeline/RequestExceptionActionProcessorBehavior.cs).

Same exception-type-walk + prioritization + dedupe pattern, but:

- No state object; actions simply "fire and return".
- After all actions complete, the exception is **always rethrown** (`throw;`).

---

## Priority via `HandlersOrderer`

Both behaviors use `MediatR.Internal.HandlersOrderer.Prioritize(handlers, request)` to sort handlers before execution.

Source: [src/MediatR/Internal/HandlersOrderer.cs](../../src/MediatR/Internal/HandlersOrderer.cs), [src/MediatR/Internal/ObjectDetails.cs](../../src/MediatR/Internal/ObjectDetails.cs).

### Rules, in order of precedence

1. **Remove overridden**: if handler type A is assignable from handler type B (i.e. B is more derived), A is marked overridden and dropped. This lets a concrete subclass "win" over a base generic handler.
2. **Prefer the request's assembly**: handlers that live in the same assembly as the request type run before handlers in other assemblies.
3. **Prefer the same/descendant namespace**: within the request's assembly, handlers whose namespace starts with the request's namespace prefix run first.
4. **Prefer closer namespace depth**: among handlers that match the namespace prefix, the closer (shorter distance) wins; ties break by location length (longer wins — i.e., more specific).

The practical effect: local, specific handlers are given a chance to handle exceptions before generic infrastructure handlers. If you have `MyApp.Orders.CreateOrderException` and both a `CreateOrderExceptionHandler` in `MyApp.Orders` and a `GenericExceptionLogger` in `MyApp.Infra`, the orders handler runs first.

---

## Registration

### Implementations are discovered automatically

`ServiceRegistrar.AddMediatRClasses` scans every registered assembly for:

- `IRequestExceptionHandler<,,>` implementations (both closed and open generic).
- `IRequestExceptionAction<,>` implementations.

Both are registered as `Transient` with the concrete interface they close. Multiple registrations are allowed (it uses the "multi-instance" scanning path).

### The behaviors are added on demand

`ServiceRegistrar.AddRequiredServices` checks whether any `IRequestExceptionHandler<,,>` or `IRequestExceptionAction<,>` implementation is already in the service collection:

```csharp
private static void RegisterBehaviorIfImplementationsExist(
    IServiceCollection services, Type behaviorType, Type subBehaviorType)
{
    var hasAny = services
        .Where(s => !s.IsKeyedService)
        .Select(s => s.ImplementationType)
        .OfType<Type>()
        .SelectMany(t => t.GetInterfaces())
        .Where(t => t.IsGenericType)
        .Select(t => t.GetGenericTypeDefinition())
        .Any(t => t == subBehaviorType);

    if (hasAny)
    {
        services.TryAddEnumerable(new ServiceDescriptor(
            typeof(IPipelineBehavior<,>), behaviorType, ServiceLifetime.Transient));
    }
}
```

So:

- No handlers/actions registered → no exception behaviors in the pipeline. Zero runtime cost.
- At least one registered → the corresponding behavior is injected into every request's pipeline.

### Ordering: `RequestExceptionActionProcessorStrategy`

The relative order of the two behaviors is controlled by a configuration enum:

```csharp
public enum RequestExceptionActionProcessorStrategy
{
    ApplyForUnhandledExceptions,   // default
    ApplyForAllExceptions
}
```

Source: [src/MediatR/MicrosoftExtensionsDI/RequestExceptionActionProcessorStrategy.cs](../../src/MediatR/MicrosoftExtensionsDI/RequestExceptionActionProcessorStrategy.cs).

From `ServiceRegistrar.AddRequiredServices`:

```csharp
if (serviceConfiguration.RequestExceptionActionProcessorStrategy == RequestExceptionActionProcessorStrategy.ApplyForUnhandledExceptions)
{
    RegisterBehaviorIfImplementationsExist(services, typeof(RequestExceptionActionProcessorBehavior<,>), typeof(IRequestExceptionAction<,>));
    RegisterBehaviorIfImplementationsExist(services, typeof(RequestExceptionProcessorBehavior<,>), typeof(IRequestExceptionHandler<,,>));
}
else
{
    RegisterBehaviorIfImplementationsExist(services, typeof(RequestExceptionProcessorBehavior<,>), typeof(IRequestExceptionHandler<,,>));
    RegisterBehaviorIfImplementationsExist(services, typeof(RequestExceptionActionProcessorBehavior<,>), typeof(IRequestExceptionAction<,>));
}
```

#### `ApplyForUnhandledExceptions` (default)

Actions registered **before** handlers ⇒ in the pipeline, actions sit **outside** handlers ⇒ actions run **only** if handlers do not recover.

Timeline:

```
try next() throws Ex
  → ExceptionProcessor tries its handlers; suppose one recovers
  → Response is returned ✓
  → ExceptionAction decorator's inner try/catch sees a normal return and does nothing
```

If nothing recovers:

```
try next() throws Ex
  → ExceptionProcessor's handlers do nothing
  → rethrow
  → ExceptionAction catches, runs actions, rethrows
```

#### `ApplyForAllExceptions`

Handlers registered before actions ⇒ handlers sit outside actions ⇒ actions **always run**, even if a handler would have recovered later.

Timeline:

```
try next() throws Ex
  → ExceptionAction catches, runs actions, rethrows
  → ExceptionProcessor catches the rethrow, runs handlers
  → if handler recovers, response is returned
  → else rethrow
```

Choose `ApplyForAllExceptions` when you want actions (e.g. logging) to fire even for recovered exceptions — useful for audit trails.

---

## Edge cases and pitfalls

- **Don't `throw` from inside a handler** — use `state.SetHandled(...)` to control flow. A rethrow swaps the original exception for a new one mid-handling loop and can break the priority-walk invariants.
- **`TException` matches subclasses** — registering `IRequestExceptionHandler<MyReq, MyResp, Exception>` will match every exception, possibly swallowing things you didn't mean to. Be explicit.
- **Handler dedup by type** — registering the same handler type twice (e.g. explicitly and via scanning) still only runs it once per exception level.
- **Stream requests (`IStreamRequest<T>`) do not participate** — exception handling behaviors only apply to `IPipelineBehavior<TRequest, TResponse>`, not `IStreamPipelineBehavior<,>`. Use try/catch around `await foreach` or implement a stream pipeline behavior.
- **Notifications have no exception pipeline** — exceptions in notification handlers propagate through the `INotificationPublisher`. See [Notification Publishers](09%20-%20Notification_Publishers.md) for aggregation strategies.

---

## Summary

| Feature | Action | Handler |
|---------|--------|---------|
| Interface | `IRequestExceptionAction<TRequest, TException>` | `IRequestExceptionHandler<TRequest, TResponse, TException>` |
| Can recover? | ❌ | ✅ via `state.SetHandled(...)` |
| Rethrows? | Always | Only if nothing sets `Handled` |
| Typical use | Logging, metrics, notifications | Map domain exception → friendly response |
| Runs for subclasses of `TException`? | Yes | Yes |
| Ordered how? | `HandlersOrderer` (assembly → namespace → depth) | Same |
| Automatic behavior? | `RequestExceptionActionProcessorBehavior<,>` | `RequestExceptionProcessorBehavior<,>` |
| Controlled order between the two? | `RequestExceptionActionProcessorStrategy` |
