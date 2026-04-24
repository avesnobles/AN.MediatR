# Streaming

Los stream requests devuelven muchos items a lo largo del tiempo en lugar de una única respuesta. El soporte de streaming de AN.MediatR se apoya en `IAsyncEnumerable<T>` y un pipeline paralelo dedicado (`IStreamPipelineBehavior<,>`).

Usa streaming cuando:

- Quieras empezar a devolver items **antes** de terminar todo el trabajo (queries paginadas, tail de logs, datos en vivo).
- El tamaño total sea desconocido o no acotado.
- Quieras server-streaming de gRPC, hubs de streaming de SignalR o endpoints de minimal API con `IAsyncEnumerable`.

---

## Los contratos

### `IStreamRequest<TResponse>`

```csharp
public interface IStreamRequest<out TResponse> { }
```

Fuente: [src/MediatR.Contracts/IStreamRequest.cs](../../src/MediatR.Contracts/IStreamRequest.cs).

Interfaz marcador. `TResponse` es covariante.

### `IStreamRequestHandler<TRequest, TResponse>`

```csharp
public interface IStreamRequestHandler<in TRequest, out TResponse>
    where TRequest : IStreamRequest<TResponse>
{
    IAsyncEnumerable<TResponse> Handle(TRequest request, CancellationToken cancellationToken);
}
```

Fuente: [src/MediatR/IStreamRequestHandler.cs](../../src/MediatR/IStreamRequestHandler.cs).

El handler devuelve `IAsyncEnumerable<TResponse>`. El llamador controla la enumeración con `await foreach`.

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

Fuente: [src/MediatR/IStreamPipelineBehavior.cs](../../src/MediatR/IStreamPipelineBehavior.cs).

Estructuralmente idéntico a `IPipelineBehavior`, con la respuesta reemplazada por un `IAsyncEnumerable<TResponse>`.

---

## Ejemplo de principio a fin

```csharp
// 1. El request
public class TailOrders : IStreamRequest<Order>
{
    public int StartId { get; init; }
}

// 2. El handler
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

// 3. Consumo
await foreach (var order in mediator.CreateStream(new TailOrders { StartId = 0 }))
{
    Console.WriteLine(order);
}
```

---

## Cómo se construye el pipeline de stream

Fuente: [src/MediatR/Wrappers/StreamRequestHandlerWrapper.cs](../../src/MediatR/Wrappers/StreamRequestHandlerWrapper.cs).

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

Mismo patrón `Reverse().Aggregate(...)` que los behaviors regulares — ver [Comportamientos del Pipeline](06%20-%20Comportamientos_del_Pipeline.md).

Dos sutilezas específicas de streams:

1. `NextWrapper` es un helper `async IAsyncEnumerable<T>` que re-envuelve el enumerable aguas abajo con `WithCancellation(...)`, asegurando que cada `yield` en cada behavior observe el token de cancelación.
2. El wrapper usa `[EnumeratorCancellation]` en su propio parámetro `CancellationToken` para que el token que el llamador pase con `await foreach (... .WithCancellation(ct))` se enlace correctamente.

---

## Escribir un stream pipeline behavior

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

Destacados:

- Decora el parámetro con `[EnumeratorCancellation]` para que el token del consumidor se propague.
- Usa `await foreach` + `yield return` para formar el relay.
- No tragues excepciones sin un motivo fuerte — deben surgir al llamador cuando itere con `await foreach`.

---

## Registro

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(TailOrdersHandler).Assembly);

    // Stream behavior cerrado
    cfg.AddStreamBehavior<IStreamPipelineBehavior<TailOrders, Order>, LoggingStreamBehavior<TailOrders, Order>>();

    // O genérico
    cfg.AddStreamBehavior(typeof(LoggingStreamBehavior<TailOrders, Order>));

    // O genérico abierto (recomendado para transversales)
    cfg.AddOpenStreamBehavior(typeof(LoggingStreamBehavior<,>));
});
```

Los stream handlers (`IStreamRequestHandler<,>`) se descubren y registran automáticamente con `ServiceRegistrar.AddMediatRClasses` al llamar a `RegisterServicesFromAssembly(...)`.

---

## Cancelación

La cancelación es crítica en streams porque el handler puede iterar sin fin. Buenas prácticas:

- **Siempre pasa** `[EnumeratorCancellation] CancellationToken ct` en métodos de handler y behaviors.
- **Siempre comprueba** `cancellationToken.IsCancellationRequested` dentro de bucles largos.
- **Siempre propaga** `cancellationToken` a `await Task.Delay(...)`, `await _repo.GetAsync(..., ct)`, etc.
- **Del lado del llamador**, usa `WithCancellation` o `CancellationTokenSource` para cancelar un stream:

    ```csharp
    using var cts = new CancellationTokenSource();
    cts.CancelAfter(TimeSpan.FromSeconds(30));

    await foreach (var item in mediator.CreateStream(request).WithCancellation(cts.Token))
    {
        // ...
    }
    ```

`StreamRequestHandlerWrapperImpl` hilvana el token por el pipeline con `NextWrapper`, así cada behavior observa el mismo token que el llamador suministró.

---

## Dispatch dinámico

Como `Send`, `CreateStream` tiene una sobrecarga dinámica que acepta `object`:

```csharp
public IAsyncEnumerable<object?> CreateStream(object request, CancellationToken cancellationToken = default);
```

Usada cuando el tipo concreto solo se conoce en runtime. Internamente introspecta el tipo runtime buscando `IStreamRequest<T>` una sola vez y cachea el wrapper cerrado.

Si el objeto no implementa `IStreamRequest<T>`, se lanza `ArgumentException`.

---

## Lo que los streams NO soportan

- **Procesadores pre/post (`IRequestPreProcessor` / `IRequestPostProcessor`)** — solo conectados a `IPipelineBehavior`, no a `IStreamPipelineBehavior`.
- **Handlers y actions de excepciones (`IRequestExceptionHandler` / `IRequestExceptionAction`)** — también solo conectados a `IPipelineBehavior`.

Si los necesitas para streams, implementa la lógica equivalente directamente en un `IStreamPipelineBehavior` (p. ej. try/catch alrededor de `await foreach (var item in next())`).

- **Streams void** — no existe `IStreamRequest` (sin `<TResponse>`). Los streams siempre tienen tipo de elemento. Un stream vacío es una respuesta perfectamente válida.
- **Varios handlers por request** — `IStreamRequestHandler<TRequest, TResponse>` es uno-a-uno, como `IRequestHandler`.

---

## Proyecto de ejemplo

`samples/MediatR.Examples/Streams/` contiene el sample canónico:

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

Y un pipeline behavior demostrando el patrón decorador:

```csharp
// samples/MediatR.Examples/Streams/GenericStreamPipelineBehavior.cs
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
