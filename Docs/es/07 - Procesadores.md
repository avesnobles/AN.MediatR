# Procesadores de Request

Los **pre-procesadores** y **post-procesadores** son una alternativa más sencilla a los comportamientos completos del pipeline: se ejecutan antes (o después) de un handler pero **no pueden cortocircuitar, reemplazar la respuesta ni capturar excepciones**. Si solo necesitas "ejecuta este código antes de cada comando", usa un procesador — es más simple y deja la intención más clara.

Todos los tipos de procesador viven en el namespace `MediatR.Pipeline`.

---

## `IRequestPreProcessor<TRequest>`

```csharp
public interface IRequestPreProcessor<in TRequest> where TRequest : notnull
{
    Task Process(TRequest request, CancellationToken cancellationToken);
}
```

Fuente: [src/MediatR/Pipeline/IRequestPreProcessor.cs](../../src/MediatR/Pipeline/IRequestPreProcessor.cs).

Se ejecuta **antes** del handler. Se permiten varios procesadores pre por request; se ejecutan secuencialmente en orden de resolución DI.

### Ejemplo

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

Fuente: [src/MediatR/Pipeline/IRequestPostProcessor.cs](../../src/MediatR/Pipeline/IRequestPostProcessor.cs).

Se ejecuta **después** del handler, recibiendo tanto el request como la respuesta. Se permiten varios. La respuesta se ve **tal y como la devolvió el handler**, después de cualquier comportamiento.

### Ejemplo

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

## Cómo se conectan al pipeline

Los procesadores **no** los llama el `Mediator` directamente. AN.MediatR provee dos decoradores `IPipelineBehavior` que ejecutan los procesadores registrados en el momento correcto.

### `RequestPreProcessorBehavior<TRequest, TResponse>`

Fuente: [src/MediatR/Pipeline/RequestPreProcessorBehavior.cs](../../src/MediatR/Pipeline/RequestPreProcessorBehavior.cs).

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

Comportamiento: resuelve todos los `IRequestPreProcessor<TRequest>`, los espera secuencialmente y luego llama a `next`.

### `RequestPostProcessorBehavior<TRequest, TResponse>`

Fuente: [src/MediatR/Pipeline/RequestPostProcessorBehavior.cs](../../src/MediatR/Pipeline/RequestPostProcessorBehavior.cs).

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

Comportamiento: espera a `next`, ejecuta secuencialmente cada post-procesador y devuelve la respuesta intacta.

---

## Registro automático

Registras los comportamientos pre/post implícitamente invocando los métodos correspondientes en la configuración:

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

Dentro de `ServiceRegistrar.AddRequiredServices`:

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

Entonces:

- Añadir al menos un procesador pre ⇒ `RequestPreProcessorBehavior<,>` se añade al pipeline.
- Añadir al menos un procesador post ⇒ `RequestPostProcessorBehavior<,>` se añade al pipeline.
- Los procesadores se registran como `IEnumerable<IRequestPreProcessor<TRequest>>` / `IEnumerable<IRequestPostProcessor<TRequest, TResponse>>`.

### `AutoRegisterRequestProcessors`

Pon esta bandera a `true` en la configuración para que `ServiceRegistrar` escanee ensamblados automáticamente en busca de procesadores:

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
    cfg.AutoRegisterRequestProcessors = true;   // escanea IRequestPreProcessor / IRequestPostProcessor
});
```

Cuando está activada, `ServiceRegistrar.AddMediatRClasses` también llama a `ConnectImplementationsToTypesClosing(typeof(IRequestPreProcessor<>), ...)` y su equivalente post. Sin esta bandera, los procesadores solo se registran si llamas a `cfg.AddRequestPreProcessor(...)` / `cfg.AddRequestPostProcessor(...)` explícitamente.

---

## Pre/post vs. pipeline behavior completo

| Necesidad | Usa |
|-----------|-----|
| Ejecutar código antes de un handler, no tocar la respuesta | `IRequestPreProcessor<TRequest>` |
| Ejecutar código después de un handler, sin cambiar la respuesta | `IRequestPostProcessor<TRequest, TResponse>` |
| Modificar el request en vuelo (pre) o la respuesta (post) | `IPipelineBehavior<TRequest, TResponse>` |
| Cortocircuitar el handler (caching, auth, validación) | `IPipelineBehavior<TRequest, TResponse>` |
| Capturar / gestionar excepciones | `IRequestExceptionHandler<,,>` o un behavior completo |

Regla general: **los procesadores declaran intención**. Cuando lees una clase `AuditLog : IRequestPostProcessor<...>`, es obvio que no puede accidentalmente reemplazar la respuesta ni tragar excepciones. Cuando las auditorías de código exigen estas garantías (seguridad, compliance, razonamiento sobre side-effects), los procesadores son más honestos que los pipeline behaviors.

---

## Orden dentro de las fases pre/post

Dentro de `RequestPreProcessorBehavior`, los procesadores corren en el orden que el contenedor DI los devuelve — el orden de registro cuando se usa `TryAddEnumerable`. Los procesadores post se comportan igual.

Si necesitas orden determinista **entre** procesadores y comportamientos, apóyate en el orden de registro: cada comportamiento añadido con `AddBehavior` / `AddOpenBehavior` se inserta en `BehaviorsToRegister`, y `RequestPreProcessorBehavior` / `RequestPostProcessorBehavior` se añaden al inicio de esa lista por `ServiceRegistrar.AddRequiredServices`.

---

## Ejemplo: sample Ping

De `samples/MediatR.Examples`:

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

Registrado en `samples/MediatR.Examples.AspNetCore/Program.cs`:

```csharp
services.AddScoped(typeof(IRequestPreProcessor<>), typeof(GenericRequestPreProcessor<>));
services.AddScoped(typeof(IRequestPostProcessor<,>), typeof(GenericRequestPostProcessor<,>));
```

Cuando `Runner.Run` envía `new Ping()`, la consola muestra:

```
- Starting Up
-- Handling Request
--- Handled Ping: Ping
-- Finished Request
- All Done
```

— procesador pre primero, behavior envolviendo el handler, handler, fin del behavior, procesador post al final.

---

## FAQ

**P: ¿Puedo evitar que se ejecute el handler lanzando en un procesador pre?**  
Sí. Cualquier excepción dentro de un procesador pre burbujea y evita la llamada a `next()`. Si quieres un "cortocircuito con respuesta", usa un pipeline behavior.

**P: ¿Puede un procesador post reemplazar la respuesta?**  
No — la recibe como parámetro pero el tipo de retorno de `Process` es `Task`, no `Task<TResponse>`. Para reemplazar respuestas, usa un pipeline behavior.

**P: ¿Se ejecutan procesadores para stream requests (`IStreamRequest<T>`)?**  
No. La infraestructura de procesadores solo se conecta a `IPipelineBehavior<TRequest, TResponse>`, no a `IStreamPipelineBehavior<,>`. Si necesitas comportamiento por-item en un stream, implementa directamente un stream pipeline behavior.

**P: ¿Se ejecutan procesadores para notificaciones (`INotification`)?**  
No. Las notificaciones no tienen pipeline ni procesadores. Implementa la lógica en un `INotificationPublisher` o un servicio envoltorio.
