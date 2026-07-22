# Request Processors

**Pre-processors** and **post-processors** are a thinner alternative to full pipeline behaviors: they run before (or after) a handler but **cannot short-circuit it, replace the response, or catch exceptions**. If all you need is "run this code before every matching command", use a processor — it's simpler and makes intent clearer.

All processor types live in namespace `AN.MediatR.Pipeline`.

---

## `IRequestPreProcessor<TRequest>`

```csharp
public interface IRequestPreProcessor<in TRequest> where TRequest : notnull
{
    Task Process(TRequest request, CancellationToken cancellationToken);
}
```

Source: [src/AN.MediatR/Pipeline/IRequestPreProcessor.cs](../../src/AN.MediatR/Pipeline/IRequestPreProcessor.cs).

Runs **before** the handler. Multiple pre-processors are allowed per request; they execute sequentially in DI resolution order.

### Example

```csharp
public class EnrichWithUserContext<TRequest> : IRequestPreProcessor<TRequest>
    where TRequest : IHasUserId
{
    private readonly IHttpContextAccessor _http;
    public EnrichWithUserContext(IHttpContextAccessor http) => _http = http;

    public Task Process(TRequest request, CancellationToken ct)
    {
        request.UserId = _http.HttpContext?.User?.FindFirst("sub")?.Value;
        return Task.CompletedTask;
    }
}
```

---

## `IRequestPostProcessor<TRequest, TResponse>`

```csharp
public interface IRequestPostProcessor<in TRequest, in TResponse> where TRequest : notnull
{
    Task Process(TRequest request, TResponse response, CancellationToken cancellationToken);
}
```

Source: [src/AN.MediatR/Pipeline/IRequestPostProcessor.cs](../../src/AN.MediatR/Pipeline/IRequestPostProcessor.cs).

Runs **after** the handler, receiving both the request and the response. Multiple post-processors allowed. Note that post-processors see the **response as returned by the handler**, after any pipeline behaviors have done their work.

### Example

```csharp
public class AuditLog<TRequest, TResponse> : IRequestPostProcessor<TRequest, TResponse>
    where TRequest : ICommand
{
    private readonly IAuditSink _audit;
    public AuditLog(IAuditSink audit) => _audit = audit;

    public Task Process(TRequest request, TResponse response, CancellationToken ct) =>
        _audit.WriteAsync(new AuditEntry(typeof(TRequest).Name, request, response), ct);
}
```

---

## How processors plug into the pipeline

Processors are **not** called directly by the `Mediator`. Instead, AN.MediatR provides two `IPipelineBehavior` decorators that run registered processors at the right time.

### `RequestPreProcessorBehavior<TRequest, TResponse>`

Source: [src/AN.MediatR/Pipeline/RequestPreProcessorBehavior.cs](../../src/AN.MediatR/Pipeline/RequestPreProcessorBehavior.cs).

```csharp
public class RequestPreProcessorBehavior<TRequest, TResponse> : IPipelineBehavior<TRequest, TResponse>
    where TRequest : notnull
{
    private readonly IEnumerable<IRequestPreProcessor<TRequest>> _preProcessors;

    public RequestPreProcessorBehavior(IEnumerable<IRequestPreProcessor<TRequest>> preProcessors)
        => _preProcessors = preProcessors;

    public async Task<TResponse> Handle(TRequest request, RequestHandlerDelegate<TResponse> next, CancellationToken cancellationToken)
    {
        foreach (var processor in _preProcessors)
        {
            await processor.Process(request, cancellationToken).ConfigureAwait(false);
        }
        return await next(cancellationToken).ConfigureAwait(false);
    }
}
```

Behavior: resolves all `IRequestPreProcessor<TRequest>` instances, `await`s each in order, then calls `next`.

### `RequestPostProcessorBehavior<TRequest, TResponse>`

Source: [src/AN.MediatR/Pipeline/RequestPostProcessorBehavior.cs](../../src/AN.MediatR/Pipeline/RequestPostProcessorBehavior.cs).

```csharp
public class RequestPostProcessorBehavior<TRequest, TResponse> : IPipelineBehavior<TRequest, TResponse>
    where TRequest : notnull
{
    private readonly IEnumerable<IRequestPostProcessor<TRequest, TResponse>> _postProcessors;

    public RequestPostProcessorBehavior(IEnumerable<IRequestPostProcessor<TRequest, TResponse>> postProcessors)
        => _postProcessors = postProcessors;

    public async Task<TResponse> Handle(TRequest request, RequestHandlerDelegate<TResponse> next, CancellationToken cancellationToken)
    {
        var response = await next(cancellationToken).ConfigureAwait(false);
        foreach (var processor in _postProcessors)
        {
            await processor.Process(request, response, cancellationToken).ConfigureAwait(false);
        }
        return response;
    }
}
```

Behavior: awaits `next`, then awaits each post-processor, finally returns the response unchanged.

---

## Automatic registration

You register the pre/post-processor behaviors implicitly by calling the processor registration methods on the configuration:

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);

    cfg.AddRequestPreProcessor<EnrichWithUserContext<ICommand>>();
    cfg.AddRequestPostProcessor<AuditLog<ICommand, Unit>>();

    cfg.AddOpenRequestPreProcessor(typeof(EnrichWithUserContext<>));
    cfg.AddOpenRequestPostProcessor(typeof(AuditLog<,>));
});
```

Inside `ServiceRegistrar.AddRequiredServices`:

```csharp
if (serviceConfiguration.RequestPreProcessorsToRegister.Any())
{
    services.TryAddEnumerable(new ServiceDescriptor(
        typeof(IPipelineBehavior<,>),
        typeof(RequestPreProcessorBehavior<,>),
        ServiceLifetime.Transient));
    services.TryAddEnumerable(serviceConfiguration.RequestPreProcessorsToRegister);
}

if (serviceConfiguration.RequestPostProcessorsToRegister.Any())
{
    services.TryAddEnumerable(new ServiceDescriptor(
        typeof(IPipelineBehavior<,>),
        typeof(RequestPostProcessorBehavior<,>),
        ServiceLifetime.Transient));
    services.TryAddEnumerable(serviceConfiguration.RequestPostProcessorsToRegister);
}
```

So:

- Adding at least one pre-processor ⇒ `RequestPreProcessorBehavior<,>` is added to the pipeline.
- Adding at least one post-processor ⇒ `RequestPostProcessorBehavior<,>` is added to the pipeline.
- Pre-processors and post-processors are registered as `IEnumerable<IRequestPreProcessor<TRequest>>` / `IEnumerable<IRequestPostProcessor<TRequest, TResponse>>`.

### `AutoRegisterRequestProcessors`

Set this flag to `true` in the configuration to have `ServiceRegistrar` scan assemblies for processor implementations automatically:

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
    cfg.AutoRegisterRequestProcessors = true;   // scan for IRequestPreProcessor / IRequestPostProcessor
});
```

When enabled, `ServiceRegistrar.AddMediatRClasses` also calls `ConnectImplementationsToTypesClosing(typeof(IRequestPreProcessor<>), ...)` and the post-processor equivalent. Without this flag, processors are only registered when you call `cfg.AddRequestPreProcessor(...)` / `cfg.AddRequestPostProcessor(...)` explicitly.

---

## Pre/post vs. full pipeline behavior

| Need | Use |
|------|-----|
| Run code before a handler, don't touch the response | `IRequestPreProcessor<TRequest>` |
| Run code after a handler, don't change the response | `IRequestPostProcessor<TRequest, TResponse>` |
| Modify the request in-flight (pre) or the response (post) | `IPipelineBehavior<TRequest, TResponse>` |
| Short-circuit the handler (caching, auth, validation) | `IPipelineBehavior<TRequest, TResponse>` |
| Catch / handle exceptions | `IRequestExceptionHandler<,,>` or a full behavior |

Rule of thumb: **processors declare intent**. When you read a class name `AuditLog : IRequestPostProcessor<...>`, it's obvious it can't accidentally replace the response or swallow exceptions. When code audits care about these guarantees (security, compliance, side-effect reasoning), processors are more honest than pipeline behaviors.

---

## Ordering within pre/post phases

Inside `RequestPreProcessorBehavior`, processors run in the order the DI container returns them — which is the order of registration when using `TryAddEnumerable`. Post-processors behave identically.

If you need deterministic ordering **across** processors and behaviors, lean on the registration order: every behavior you add via `AddBehavior` / `AddOpenBehavior` is inserted into `BehaviorsToRegister`, and `RequestPreProcessorBehavior` / `RequestPostProcessorBehavior` are added at the beginning of that list by `ServiceRegistrar.AddRequiredServices`.

---

## Example: Ping sample

From `samples/AN.MediatR.Examples`:

```csharp
public class GenericRequestPreProcessor<TRequest> : IRequestPreProcessor<TRequest> where TRequest : notnull
{
    private readonly TextWriter _writer;
    public GenericRequestPreProcessor(TextWriter writer) => _writer = writer;

    public Task Process(TRequest request, CancellationToken cancellationToken)
        => _writer.WriteLineAsync("- Starting Up");
}

public class GenericRequestPostProcessor<TRequest, TResponse> : IRequestPostProcessor<TRequest, TResponse> where TRequest : notnull
{
    private readonly TextWriter _writer;
    public GenericRequestPostProcessor(TextWriter writer) => _writer = writer;

    public Task Process(TRequest request, TResponse response, CancellationToken cancellationToken)
        => _writer.WriteLineAsync("- All Done");
}
```

Wired in `samples/AN.MediatR.Examples.AspNetCore/Program.cs`:

```csharp
services.AddScoped(typeof(IRequestPreProcessor<>), typeof(GenericRequestPreProcessor<>));
services.AddScoped(typeof(IRequestPostProcessor<,>), typeof(GenericRequestPostProcessor<,>));
```

When `Runner.Run` sends `new Ping()`, the console prints:

```
- Starting Up
-- Handling Request
--- Handled Ping: Ping
-- Finished Request
- All Done
```

— i.e., pre-processor first, behavior wrapping the handler, handler, end of behavior, post-processor last.

---

## FAQ

**Q: Can I prevent the handler from running by throwing in a pre-processor?**  
Yes. Any exception thrown inside a pre-processor bubbles up and prevents `next()` from being called. If you want a clean "short-circuit with response", use a pipeline behavior instead.

**Q: Can a post-processor replace the response?**  
No — it receives the response by value (well, by parameter) but the return type of `Process` is `Task`, not `Task<TResponse>`. To replace responses, use a pipeline behavior.

**Q: Do processors run for streaming requests (`IStreamRequest<T>`)?**  
No. The pre/post-processor infrastructure is only wired into `IPipelineBehavior<TRequest, TResponse>`, not `IStreamPipelineBehavior<,>`. If you need per-item behavior on a stream, implement a stream pipeline behavior directly.

**Q: Do processors run for notifications (`INotification`)?**  
No. Notifications have no pipeline and no processors. Implement the logic in an `INotificationPublisher` or a wrapping service.
