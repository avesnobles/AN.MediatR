# Comportamientos del Pipeline

Los comportamientos del pipeline son el punto de extensión más importante de AN.MediatR. Son el equivalente al **middleware** de ASP.NET Core: decoradores que envuelven a cada handler en una composición tipo matrioska, para implementar preocupaciones transversales sin tocar los handlers.

---

## El contrato

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

Fuente: [src/MediatR/IPipelineBehavior.cs](../../src/MediatR/IPipelineBehavior.cs).

Un comportamiento:

- Recibe el request.
- Recibe un delegate `next` que llama al siguiente paso del pipeline (otro comportamiento o — finalmente — el propio handler).
- Recibe un `CancellationToken`.
- Devuelve `Task<TResponse>`.

`RequestHandlerDelegate<TResponse>` admite un `CancellationToken` opcional. Si el comportamiento pasa `default`, se reusa el token exterior; si pasa un token distinto (enlazado o de reemplazo), los pasos aguas abajo lo reciben. Útil para timeouts o scopes por paso.

---

## Cómo se construye el pipeline

El pipeline se construye dentro de `RequestHandlerWrapperImpl<TRequest, TResponse>.Handle(...)`:

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

Fuente: [src/MediatR/Wrappers/RequestHandlerWrapper.cs](../../src/MediatR/Wrappers/RequestHandlerWrapper.cs).

Desglose:

1. **`Handler`** es una función local que representa la llamada más interna — resuelve `IRequestHandler<TRequest, TResponse>` y lo invoca.
2. **`sp.GetServices<IPipelineBehavior<TRequest, TResponse>>()`** devuelve todos los comportamientos registrados para esa pareja `(TRequest, TResponse)`, **en orden de registro**.
3. **`.Reverse()`** invierte la lista para que el **primer** comportamiento registrado quede como el **más externo** en la cadena final.
4. **`.Aggregate(seed, (next, pipeline) => ...)`** pliega la lista: empezando por `Handler`, cada comportamiento produce un nuevo delegate que, al invocarse, llama a `pipeline.Handle(request, next, ct)`. Tras el fold, tienes un único `RequestHandlerDelegate<TResponse>` que representa toda la cadena.
5. **`()`** invoca el delegate resultante para ejecutar el request.

### Ejemplo de orden de ejecución

Suponiendo que registras:

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(...);
    cfg.AddOpenBehavior(typeof(LoggingBehavior<,>));      // 1º
    cfg.AddOpenBehavior(typeof(ValidationBehavior<,>));   // 2º
    cfg.AddOpenBehavior(typeof(TransactionBehavior<,>));  // 3º
});
```

En ejecución:

```
caller → mediator.Send(request)
        │
        ▼
   LoggingBehavior.Handle(request, next1)
        │  log "start"
        ▼
   ValidationBehavior.Handle(request, next2)
        │  validar
        ▼
   TransactionBehavior.Handle(request, next3)
        │  abrir tx
        ▼
   Handler.Handle(request)
        │  (lógica de negocio)
        ▲  commit/rollback
        │
        ▲  (post-fase de validación, si la hay)
        │
        ▲  log "end"
        │
caller ← respuesta
```

Regla mnemotécnica: **registro más temprano = capa más externa**.

---

## Escribir un comportamiento

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

Patrones clave:

- **Usar `ConfigureAwait(false)`** en código de librería para no forzar un contexto de sincronización.
- **Propagar siempre el token** a `next(cancellationToken)` salvo que haya motivo para cambiarlo.
- **Preferir genéricos abiertos** (`<TRequest, TResponse>`) para preocupaciones realmente transversales. Registra con `AddOpenBehavior(typeof(LoggingBehavior<,>))`.
- **Restringir `TRequest`** si el comportamiento solo aplica a algunos requests (p. ej. `where TRequest : ICommand`). DI solo lo inyectará para los que casen.

---

## Cortocircuitar

Un comportamiento puede **saltarse** `next` y devolver una respuesta directamente. Así funcionan típicamente los layers de caching, idempotencia y autorización:

```csharp
public async Task<TResponse> Handle(
    TRequest request,
    RequestHandlerDelegate<TResponse> next,
    CancellationToken cancellationToken)
{
    if (_cache.TryGet<TResponse>(request, out var cached))
        return cached; // el handler no se invoca

    var response = await next(cancellationToken).ConfigureAwait(false);
    _cache.Set(request, response);
    return response;
}
```

El cortocircuito está totalmente soportado — AN.MediatR no asume que `next` se vaya a llamar.

---

## Reemplazar la respuesta

Como el comportamiento es dueño del `Task<TResponse>` retornado, puede inspeccionar la respuesta, envolverla o reemplazarla:

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

## Comportamientos de streaming

Para mensajes `IStreamRequest<TResponse>`, usa `IStreamPipelineBehavior<TRequest, TResponse>`:

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

Implementación típica:

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

Notas:

- El delegate `next` **no lleva argumentos** (el token se captura en el closure).
- Usa `[EnumeratorCancellation]` en el parámetro `CancellationToken`.
- `await foreach` sobre `next()` y `yield return` cada item.
- Registra con `AddOpenStreamBehavior(typeof(LoggingStreamBehavior<,>))` o tipo de servicio explícito.

Ver [Streaming](10%20-%20Streaming.md) para detalles.

---

## Comportamientos built-in

AN.MediatR incluye cuatro comportamientos integrados, todos en `MediatR.Pipeline`:

| Comportamiento | Propósito | Registro automático |
|----------------|-----------|---------------------|
| `RequestPreProcessorBehavior<TRequest, TResponse>` | Ejecuta `IRequestPreProcessor<TRequest>` antes del handler | Sí, si hay procesadores pre registrados |
| `RequestPostProcessorBehavior<TRequest, TResponse>` | Ejecuta `IRequestPostProcessor<TRequest, TResponse>` después del handler | Sí, si hay procesadores post registrados |
| `RequestExceptionActionProcessorBehavior<TRequest, TResponse>` | Ejecuta `IRequestExceptionAction<TRequest, TException>` en excepción (siempre relanza) | Sí, si hay actions registradas |
| `RequestExceptionProcessorBehavior<TRequest, TResponse>` | Ejecuta `IRequestExceptionHandler<TRequest, TResponse, TException>` en excepción (puede tragar) | Sí, si hay handlers registrados |

Ver [Procesadores](07%20-%20Procesadores.md) y [Gestión de Excepciones](08%20-%20Gestion_de_Excepciones.md) para su semántica exacta.

---

## Referencia de registro

Todas las APIs de registro viven en `MediatRServiceConfiguration` (`cfg`):

```csharp
cfg.AddBehavior<MyBehavior>();                                    // genérico cerrado
cfg.AddBehavior<IPipelineBehavior<Ping, Pong>, MyBehavior>();    // tipo de servicio explícito
cfg.AddBehavior(typeof(MyBehavior));                              // no genérico
cfg.AddBehavior(typeof(IPipelineBehavior<Ping, Pong>), typeof(MyBehavior));

cfg.AddOpenBehavior(typeof(LoggingBehavior<,>));                  // genérico abierto
cfg.AddOpenBehaviors(new[] { typeof(LoggingBehavior<,>), typeof(TimingBehavior<,>) });
cfg.AddOpenBehaviors(new[] { new OpenBehavior(typeof(LoggingBehavior<,>), ServiceLifetime.Singleton) });

// Variantes streaming:
cfg.AddStreamBehavior<MyStreamBehavior>();
cfg.AddOpenStreamBehavior(typeof(LoggingStreamBehavior<,>));
```

Cada método admite un `ServiceLifetime` opcional (por defecto `Transient`).

La configuración solo registra **qué** registrar y en qué orden. El registro real ocurre en `ServiceRegistrar.AddRequiredServices`, que llama a `services.TryAddEnumerable(...)` para cada comportamiento — se acumulan en lugar de reemplazarse.

---

## Caso especial: comportamientos abiertos con tipo de respuesta genérico anidado

Si tu comportamiento abierto es así:

```csharp
public class UnwrapResultBehavior<TRequest, T> : IPipelineBehavior<TRequest, Result<T>>
    where TRequest : IRequest<Result<T>>
{
    public Task<Result<T>> Handle(...) { ... }
}
```

entonces el tipo de respuesta contiene un genérico anidado (`Result<T>`). El mapeo posicional de genéricos abiertos de `Microsoft.Extensions.DependencyInjection` no puede cerrar `Result<T>` a partir de `(TRequest, TResponse)`.

AN.MediatR lo detecta (`HasNestedGenericResponseType` en `ServiceRegistrar`) y **cierra explícitamente** el comportamiento para cada par request/response encontrado en los ensamblados escaneados. Es una característica silenciosa y automática — tú solo registras el comportamiento abierto como siempre.

---

## Consideraciones de lifetime

- Los comportamientos se resuelven vía `IServiceProvider.GetServices(...)` en cada dispatch — **`Transient` es el valor seguro por defecto**.
- Si registras un comportamiento como `Scoped` y resuelves el mediator fuera de un scope, obtendrás excepción. En la duda, mantén transient.
- Los comportamientos `Singleton` deben ser thread-safe y no depender de servicios scoped.

---

## Checklist para escribir un comportamiento nuevo

- [ ] Implementa `IPipelineBehavior<TRequest, TResponse>`.
- [ ] Restringe `TRequest` si el comportamiento es selectivo.
- [ ] Siempre `await next(cancellationToken)` (salvo cortocircuito intencional).
- [ ] Usa `ConfigureAwait(false)`.
- [ ] Registra con `cfg.AddOpenBehavior(typeof(MyBehavior<,>))` o variante cerrada.
- [ ] Regístralos **en el orden en que quieres que se ejecuten** (primero registrado = más externo).
- [ ] Mantén transient salvo que puedas demostrar thread-safety.
