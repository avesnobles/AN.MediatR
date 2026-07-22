# Streaming

Streaming requests return many items over time instead of a single response. AN.MediatR's streaming support is built on `IAsyncEnumerable<T>` and a dedicated parallel pipeline (`IStreamPipelineBehavior<,>`).

Use streaming when:

- You want to start returning items **before** all the work is done (paginated queries, tail logs, live data).
- The total size is unknown or unbounded.
- You want gRPC server-streaming, SignalR streaming hubs, or minimal-API `IAsyncEnumerable` endpoints.

---

## The contracts

### `IStreamRequest<TResponse>`

```csharp
public interface IStreamRequest<out TResponse> { }
```

Source: [src/AN.MediatR.Contracts/IStreamRequest.cs](../../src/AN.MediatR.Contracts/IStreamRequest.cs).

Marker interface. `TResponse` is covariant.

### `IStreamRequestHandler<TRequest, TResponse>`

```csharp
public interface IStreamRequestHandler<in TRequest, out TResponse>
    where TRequest : IStreamRequest<TResponse>
{
    IAsyncEnumerable<TResponse> Handle(TRequest request, CancellationToken cancellationToken);
}
```

Source: [src/AN.MediatR/IStreamRequestHandler.cs](../../src/AN.MediatR/IStreamRequestHandler.cs).

The handler returns `IAsyncEnumerable<TResponse>`. The caller drives enumeration with `await foreach`.

### `IStreamPipelineBehavior<TRequest, TResponse>`

```csharp
public delegate IAsyncEnumerable<TResponse> StreamHandlerDelegate<out TResponse>();

public interface IStreamPipelineBehavior<in TRequest, TResponse> where TRequest : notnull
{
    IAsyncEnumerable<TResponse> Handle(
        TRequest request,
        StreamHandlerDelegate<TResponse> next,
        CancellationToken cancellationToken);
}
```

Source: [src/AN.MediatR/IStreamPipelineBehavior.cs](../../src/AN.MediatR/IStreamPipelineBehavior.cs).

Structurally identical to `IPipelineBehavior`, with the response replaced by an `IAsyncEnumerable<TResponse>`.

---

## End-to-end example

```csharp
// 1. The request
public class TailOrders : IStreamRequest<Order>
{
    public int StartId { get; init; }
}

// 2. The handler
public class TailOrdersHandler : IStreamRequestHandler<TailOrders, Order>
{
    private readonly IOrderRepository _repo;
    public TailOrdersHandler(IOrderRepository repo) => _repo = repo;

    public async IAsyncEnumerable<Order> Handle(
        TailOrders request,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var lastId = request.StartId;
        while (!cancellationToken.IsCancellationRequested)
        {
            var batch = await _repo.GetNewerThanAsync(lastId, cancellationToken);
            foreach (var order in batch)
            {
                lastId = order.Id;
                yield return order;
            }
            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
        }
    }
}

// 3. Consuming
await foreach (var order in mediator.CreateStream(new TailOrders { StartId = 0 }))
{
    Console.WriteLine(order);
}
```

---

## How the stream pipeline is built

Source: [src/AN.MediatR/Wrappers/StreamRequestHandlerWrapper.cs](../../src/AN.MediatR/Wrappers/StreamRequestHandlerWrapper.cs).

```csharp
public override async IAsyncEnumerable<TResponse> Handle(
    IStreamRequest<TResponse> request,
    IServiceProvider serviceProvider,
    [EnumeratorCancellation] CancellationToken cancellationToken)
{
    IAsyncEnumerable<TResponse> Handler() => serviceProvider
        .GetRequiredService<IStreamRequestHandler<TRequest, TResponse>>()
        .Handle((TRequest)request, cancellationToken);

    var items = serviceProvider
        .GetServices<IStreamPipelineBehavior<TRequest, TResponse>>()
        .Reverse()
        .Aggregate(
            (StreamHandlerDelegate<TResponse>)Handler,
            (next, pipeline) => () => pipeline.Handle(
                (TRequest)request,
                () => NextWrapper(next(), cancellationToken),
                cancellationToken
            )
        )();

    await foreach (var item in items.WithCancellation(cancellationToken))
    {
        yield return item;
    }
}
```

Same `Reverse().Aggregate(...)` pattern as regular pipeline behaviors — see [Pipeline Behaviors](06%20-%20Pipeline_Behaviors.md).

Two subtleties specific to streams:

1. `NextWrapper` is a helper `async IAsyncEnumerable<T>` that re-wraps the downstream enumerable with `WithCancellation(...)`, ensuring every `yield` in every behavior observes the cancellation token.
2. The wrapper itself uses `[EnumeratorCancellation]` on its own `CancellationToken` parameter so that the token passed to `await foreach (... .WithCancellation(ct))` by the caller is bound correctly.

---

## Writing a stream pipeline behavior

```csharp
public class LoggingStreamBehavior<TRequest, TResponse> : IStreamPipelineBehavior<TRequest, TResponse>
    where TRequest : notnull
{
    private readonly ILogger<LoggingStreamBehavior<TRequest, TResponse>> _logger;
    public LoggingStreamBehavior(ILogger<LoggingStreamBehavior<TRequest, TResponse>> logger) => _logger = logger;

    public async IAsyncEnumerable<TResponse> Handle(
        TRequest request,
        StreamHandlerDelegate<TResponse> next,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        _logger.LogInformation("Streaming {Request}", typeof(TRequest).Name);
        var count = 0;
        try
        {
            await foreach (var item in next().WithCancellation(cancellationToken).ConfigureAwait(false))
            {
                count++;
                yield return item;
            }
        }
        finally
        {
            _logger.LogInformation("Streamed {Count} items from {Request}", count, typeof(TRequest).Name);
        }
    }
}
```

Pattern highlights:

- Decorate the method parameter with `[EnumeratorCancellation]` so the consumer's cancellation token is propagated.
- Use `await foreach` + `yield return` to form the relay.
- Don't swallow exceptions unless you have a very good reason — exceptions must surface to the caller as `await foreach` throws.

---

## Registration

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(TailOrdersHandler).Assembly);

    // Closed stream behavior
    cfg.AddStreamBehavior<IStreamPipelineBehavior<TailOrders, Order>, LoggingStreamBehavior<TailOrders, Order>>();

    // Or generic
    cfg.AddStreamBehavior(typeof(LoggingStreamBehavior<TailOrders, Order>));

    // Or open generic (recommended for cross-cutting)
    cfg.AddOpenStreamBehavior(typeof(LoggingStreamBehavior<,>));
});
```

Stream handlers (`IStreamRequestHandler<,>`) are discovered and registered automatically by `ServiceRegistrar.AddMediatRClasses` when you call `RegisterServicesFromAssembly(...)`.

---

## Cancellation

Cancellation is critical for streams because the handler may loop forever. Best practices:

- **Always pass** `[EnumeratorCancellation] CancellationToken ct` on handler and behavior methods.
- **Always check** `cancellationToken.IsCancellationRequested` inside long loops.
- **Always forward** `cancellationToken` to `await Task.Delay(...)`, `await _repo.GetAsync(..., ct)`, etc.
- **On the caller side**, use `WithCancellation` or `CancellationTokenSource` to cancel a stream:

    ```csharp
    using var cts = new CancellationTokenSource();
    cts.CancelAfter(TimeSpan.FromSeconds(30));

    await foreach (var item in mediator.CreateStream(request).WithCancellation(cts.Token))
    {
        // ...
    }
    ```

The `StreamRequestHandlerWrapperImpl` threads the cancellation token through the pipeline via `NextWrapper`, so every behavior observes the same token the caller provided.

---

## Dynamic dispatch

Like `Send`, `CreateStream` has a dynamic overload that accepts `object`:

```csharp
public IAsyncEnumerable<object?> CreateStream(object request, CancellationToken cancellationToken = default);
```

Used when the concrete request type is only known at runtime. Internally it introspects the runtime type for `IStreamRequest<T>` once and caches the closed wrapper.

If the object doesn't implement `IStreamRequest<T>`, `ArgumentException` is thrown.

---

## What streams do NOT support

- **Pre/post-processors (`IRequestPreProcessor` / `IRequestPostProcessor`)** — wired only to `IPipelineBehavior`, not `IStreamPipelineBehavior`.
- **Exception handlers and actions (`IRequestExceptionHandler` / `IRequestExceptionAction`)** — also wired only to `IPipelineBehavior`.

If you need these for streams, implement equivalent logic directly inside a `IStreamPipelineBehavior` (e.g. try/catch around `await foreach (var item in next())`).

- **Void streams** — there is no `IStreamRequest` (without `<TResponse>`). Streams always have an element type. An empty stream is a perfectly valid response.

- **Multiple handlers per request** — `IStreamRequestHandler<TRequest, TResponse>` is one-to-one, like `IRequestHandler`.

---

## Sample project

`samples/AN.MediatR.Examples/Streams/` contains the canonical sample:

```csharp
public class Sing : IStreamRequest<Song>
{
    public string Message { get; set; }
}

public class SingHandler : IStreamRequestHandler<Sing, Song>
{
    private readonly TextWriter _writer;
    public SingHandler(TextWriter writer) => _writer = writer;

    public async IAsyncEnumerable<Song> Handle(Sing request, [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        await _writer.WriteLineAsync($"--- Handled Sing: {request.Message}, Song");
        yield return await Task.Run(() => new Song { Message = request.Message + "ing do" });
        yield return await Task.Run(() => new Song { Message = request.Message + "ing re" });
        // ...
    }
}
```

And a pipeline behavior demonstrating the decorator pattern:

```csharp
// samples/AN.MediatR.Examples/Streams/GenericStreamPipelineBehavior.cs
public class GenericStreamPipelineBehavior<TRequest, TResponse> : IStreamPipelineBehavior<TRequest, TResponse>
{
    private readonly TextWriter _writer;
    public GenericStreamPipelineBehavior(TextWriter writer) => _writer = writer;

    public async IAsyncEnumerable<TResponse> Handle(TRequest request, StreamHandlerDelegate<TResponse> next, [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        await _writer.WriteLineAsync("-- Handling Stream Request");
        await foreach (var item in next().WithCancellation(cancellationToken))
        {
            yield return item;
        }
        await _writer.WriteLineAsync("-- Finished Stream Request");
    }
}
```
