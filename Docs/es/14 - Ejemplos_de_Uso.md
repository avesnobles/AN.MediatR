# Ejemplos de Uso

Recetas prácticas cubriendo los escenarios más comunes. Cada ejemplo es autocontenido y usa solo la superficie pública de AN.MediatR.

Cada muestra asume que has configurado DI con logging:

```csharp
var services = new ServiceCollection();
services.AddLogging(); // opcional — AN.MediatR no hace logging por sí misma
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
});
var provider = services.BuildServiceProvider();
var mediator = provider.GetRequiredService<IMediator>();
```

---

## 1. Request/response simple

```csharp
public record GetCustomerById(int Id) : IRequest<Customer>;

public class GetCustomerByIdHandler : IRequestHandler<GetCustomerById, Customer>
{
    private readonly ICustomerRepository _repo;
    public GetCustomerByIdHandler(ICustomerRepository repo) => _repo = repo;

    public Task<Customer> Handle(GetCustomerById request, CancellationToken ct)
        => _repo.FindAsync(request.Id, ct);
}

// Despacho
Customer customer = await mediator.Send(new GetCustomerById(42));
```

Exactamente un handler por tipo de request. Las excepciones suben al llamador.

---

## 2. Comando void

```csharp
public record DeleteCustomer(int Id) : IRequest;

public class DeleteCustomerHandler : IRequestHandler<DeleteCustomer>
{
    private readonly ICustomerRepository _repo;
    public DeleteCustomerHandler(ICustomerRepository repo) => _repo = repo;

    public Task Handle(DeleteCustomer request, CancellationToken ct)
        => _repo.DeleteAsync(request.Id, ct);
}

await mediator.Send(new DeleteCustomer(42));
```

Internamente el tipo de retorno es `Task<Unit>`, pero `Mediator.Send<TRequest>(TRequest)` devuelve `Task` así que nunca ves `Unit`.

---

## 3. Notificación con varios handlers

```csharp
public record CustomerCreated(int Id, string Email) : INotification;

public class SendWelcomeEmail : INotificationHandler<CustomerCreated>
{
    public Task Handle(CustomerCreated n, CancellationToken ct) { /* ... */ return Task.CompletedTask; }
}

public class IndexForSearch : INotificationHandler<CustomerCreated>
{
    public Task Handle(CustomerCreated n, CancellationToken ct) { /* ... */ return Task.CompletedTask; }
}

await mediator.Publish(new CustomerCreated(42, "alice@example.com"));
```

Por defecto los handlers corren secuencialmente (`ForeachAwaitPublisher`). Si el primero lanza, el segundo **no** corre.

### Dispatch paralelo

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
    cfg.NotificationPublisher = new TaskWhenAllPublisher();
});
```

Ver [Publicadores de Notificaciones](09%20-%20Publicadores_Notificaciones.md).

---

## 4. Handler de notificación síncrono

```csharp
public class LogCustomer : NotificationHandler<CustomerCreated>
{
    protected override void Handle(CustomerCreated n)
        => Console.WriteLine($"Customer {n.Id} created.");
}
```

`NotificationHandler<TNotification>` envuelve tu `Handle` síncrono en `Task.CompletedTask` automáticamente.

---

## 5. Pipeline behavior transversal

Behavior abierto de logging + timing que aplica a cada request:

```csharp
public class LoggingBehavior<TRequest, TResponse> : IPipelineBehavior<TRequest, TResponse>
    where TRequest : notnull
{
    private readonly ILogger<LoggingBehavior<TRequest, TResponse>> _logger;
    public LoggingBehavior(ILogger<LoggingBehavior<TRequest, TResponse>> logger) => _logger = logger;

    public async Task<TResponse> Handle(TRequest request, RequestHandlerDelegate<TResponse> next, CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();
        _logger.LogInformation("Handling {Request}", typeof(TRequest).Name);
        try { return await next(ct).ConfigureAwait(false); }
        finally { _logger.LogInformation("Handled {Request} in {Elapsed}ms", typeof(TRequest).Name, sw.ElapsedMilliseconds); }
    }
}

services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
    cfg.AddOpenBehavior(typeof(LoggingBehavior<,>));
});
```

---

## 6. Behavior de validación

```csharp
public class ValidationBehavior<TRequest, TResponse> : IPipelineBehavior<TRequest, TResponse>
    where TRequest : notnull
{
    private readonly IEnumerable<IValidator<TRequest>> _validators;
    public ValidationBehavior(IEnumerable<IValidator<TRequest>> validators) => _validators = validators;

    public async Task<TResponse> Handle(TRequest request, RequestHandlerDelegate<TResponse> next, CancellationToken ct)
    {
        if (_validators.Any())
        {
            var failures = _validators
                .Select(v => v.Validate(request))
                .SelectMany(r => r.Errors)
                .Where(e => e != null)
                .ToList();

            if (failures.Any())
                throw new ValidationException(failures);
        }

        return await next(ct).ConfigureAwait(false);
    }
}

// Registra validadores (cualquier FluentValidation etc.) + el behavior
cfg.AddOpenBehavior(typeof(ValidationBehavior<,>));
```

---

## 7. Behavior de caching (cortocircuito)

```csharp
public interface ICacheable { string CacheKey { get; } }

public class CachingBehavior<TRequest, TResponse> : IPipelineBehavior<TRequest, TResponse>
    where TRequest : ICacheable, notnull
{
    private readonly IMemoryCache _cache;
    public CachingBehavior(IMemoryCache cache) => _cache = cache;

    public async Task<TResponse> Handle(TRequest request, RequestHandlerDelegate<TResponse> next, CancellationToken ct)
    {
        if (_cache.TryGetValue(request.CacheKey, out TResponse cached))
            return cached;

        var response = await next(ct).ConfigureAwait(false);
        _cache.Set(request.CacheKey, response, TimeSpan.FromMinutes(5));
        return response;
    }
}
```

La restricción `where TRequest : ICacheable` hace que este behavior solo se resuelva (y por tanto invoque) para requests que implementen `ICacheable`. DI lo gestiona por ti.

---

## 8. Behavior de transacción

```csharp
public interface ITransactional { }   // marcador

public class TransactionBehavior<TRequest, TResponse> : IPipelineBehavior<TRequest, TResponse>
    where TRequest : ITransactional, notnull
{
    private readonly DbContext _db;
    public TransactionBehavior(DbContext db) => _db = db;

    public async Task<TResponse> Handle(TRequest request, RequestHandlerDelegate<TResponse> next, CancellationToken ct)
    {
        await using var tx = await _db.Database.BeginTransactionAsync(ct);
        var response = await next(ct).ConfigureAwait(false);
        await tx.CommitAsync(ct);
        return response;
    }
}
```

Commit en éxito; deja que una excepción del llamador haga rollback vía `DisposeAsync`.

---

## 9. Procesador pre (enriquecimiento)

```csharp
public interface IHasUserContext { string? UserId { get; set; } }

public class EnrichWithUserContext<TRequest> : IRequestPreProcessor<TRequest>
    where TRequest : IHasUserContext
{
    private readonly IHttpContextAccessor _http;
    public EnrichWithUserContext(IHttpContextAccessor http) => _http = http;

    public Task Process(TRequest request, CancellationToken ct)
    {
        request.UserId = _http.HttpContext?.User?.FindFirst("sub")?.Value;
        return Task.CompletedTask;
    }
}

services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
    cfg.AddOpenRequestPreProcessor(typeof(EnrichWithUserContext<>));
});
```

---

## 10. Procesador post (auditoría)

```csharp
public class AuditCommand<TRequest, TResponse> : IRequestPostProcessor<TRequest, TResponse>
    where TRequest : IRequest<TResponse>
{
    private readonly IAuditSink _audit;
    public AuditCommand(IAuditSink audit) => _audit = audit;

    public Task Process(TRequest request, TResponse response, CancellationToken ct)
        => _audit.WriteAsync(new AuditEntry(typeof(TRequest).Name, request, response), ct);
}

cfg.AddOpenRequestPostProcessor(typeof(AuditCommand<,>));
```

---

## 11. Exception action (log + relanzar)

```csharp
public class LogException<TRequest> : IRequestExceptionAction<TRequest, Exception>
    where TRequest : notnull
{
    private readonly ILogger<LogException<TRequest>> _logger;
    public LogException(ILogger<LogException<TRequest>> logger) => _logger = logger;

    public Task Execute(TRequest request, Exception ex, CancellationToken ct)
    {
        _logger.LogError(ex, "Error handling {Request}: {Message}", typeof(TRequest).Name, ex.Message);
        return Task.CompletedTask;
    }
}
```

El escaneo lo recoge automáticamente. Siempre relanza — úsalo para observación, no recuperación.

---

## 12. Exception handler (recuperación con respuesta por defecto)

```csharp
public class TranslateNotFoundToDefault<TRequest, TResponse>
    : IRequestExceptionHandler<TRequest, TResponse, EntityNotFoundException>
    where TRequest : notnull
    where TResponse : new()
{
    public Task Handle(TRequest request, EntityNotFoundException ex,
        RequestExceptionHandlerState<TResponse> state, CancellationToken ct)
    {
        state.SetHandled(new TResponse());
        return Task.CompletedTask;
    }
}
```

Si el handler lanza `EntityNotFoundException`, el pipeline la traga y el llamador recibe un `TResponse` por defecto.

---

## 13. Streaming — mínimo

```csharp
public record TailLogs(string Category) : IStreamRequest<LogEntry>;

public class TailLogsHandler : IStreamRequestHandler<TailLogs, LogEntry>
{
    private readonly ILogStore _store;
    public TailLogsHandler(ILogStore store) => _store = store;

    public async IAsyncEnumerable<LogEntry> Handle(TailLogs request, [EnumeratorCancellation] CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            var batch = await _store.GetBatchAsync(request.Category, ct);
            foreach (var e in batch) yield return e;
            await Task.Delay(TimeSpan.FromSeconds(1), ct);
        }
    }
}

await foreach (var entry in mediator.CreateStream(new TailLogs("api")))
{
    Console.WriteLine(entry);
}
```

---

## 14. Streaming con pipeline behavior

```csharp
public class TimingStreamBehavior<TRequest, TResponse> : IStreamPipelineBehavior<TRequest, TResponse>
    where TRequest : notnull
{
    public async IAsyncEnumerable<TResponse> Handle(
        TRequest request,
        StreamHandlerDelegate<TResponse> next,
        [EnumeratorCancellation] CancellationToken ct)
    {
        var count = 0;
        var sw = Stopwatch.StartNew();
        await foreach (var item in next().WithCancellation(ct).ConfigureAwait(false))
        {
            count++;
            yield return item;
        }
        Console.WriteLine($"Streamed {count} {typeof(TResponse).Name}s in {sw.ElapsedMilliseconds}ms");
    }
}

cfg.AddOpenStreamBehavior(typeof(TimingStreamBehavior<,>));
```

---

## 15. Dispatch dinámico

```csharp
object request = LoadRequestFromQueue();           // tipo solo en runtime
object? response = await mediator.Send(request);   // dinámico
```

También disponible para notificaciones:

```csharp
INotification notification = BuildNotification();
await mediator.Publish((object)notification);
```

Útil para API gateways, relays de mensajes y arneses genéricos de test.

---

## 16. Minimal API de ASP.NET Core

```csharp
var builder = WebApplication.CreateBuilder(args);
builder.Services.AddMediatR(cfg => cfg.RegisterServicesFromAssemblyContaining<Program>());

var app = builder.Build();

app.MapGet("/customers/{id:int}", async (int id, IMediator mediator) =>
{
    var customer = await mediator.Send(new GetCustomerById(id));
    return Results.Ok(customer);
});

app.MapPost("/customers", async (CreateCustomer cmd, IMediator mediator) =>
{
    var id = await mediator.Send(cmd);
    return Results.Created($"/customers/{id}", id);
});

app.Run();
```

---

## 17. Controlador de ASP.NET Core

```csharp
[ApiController]
[Route("orders")]
public class OrdersController : ControllerBase
{
    private readonly ISender _sender;
    public OrdersController(ISender sender) => _sender = sender;

    [HttpGet("{id:int}")]
    public async Task<ActionResult<Order>> Get(int id)
        => Ok(await _sender.Send(new GetOrderById(id)));

    [HttpPost]
    public async Task<ActionResult<int>> Create(CreateOrder cmd)
        => CreatedAtAction(nameof(Get), new { id = await _sender.Send(cmd) }, null);
}
```

Prefiere inyectar `ISender` (o `IPublisher`) sobre `IMediator` cuando solo necesitas una dirección — deja la intención clara y facilita los tests.

---

## 18. Test unitario de un handler

```csharp
[Fact]
public async Task GetCustomerById_returns_customer()
{
    var repo = new Mock<ICustomerRepository>();
    repo.Setup(r => r.FindAsync(42, It.IsAny<CancellationToken>()))
        .ReturnsAsync(new Customer { Id = 42, Email = "a@b" });

    var handler = new GetCustomerByIdHandler(repo.Object);
    var result = await handler.Handle(new GetCustomerById(42), default);

    Assert.Equal("a@b", result.Email);
}
```

Nota: los handlers se pueden testear directamente — no hace falta resolverlos vía `IMediator`. Una de las ventajas del patrón mediator.

---

## 19. Test unitario de un behavior

```csharp
[Fact]
public async Task ValidationBehavior_throws_on_validation_failure()
{
    var validator = new Mock<IValidator<Ping>>();
    validator.Setup(v => v.Validate(It.IsAny<Ping>()))
        .Returns(new ValidationResult(new[] { new ValidationFailure("Message", "required") }));

    var behavior = new ValidationBehavior<Ping, Pong>(new[] { validator.Object });

    await Assert.ThrowsAsync<ValidationException>(() =>
        behavior.Handle(
            new Ping(),
            _ => Task.FromResult(new Pong()),   // "next" falso
            default));
}
```

---

## 20. Test de integración con contenedor real

```csharp
[Fact]
public async Task Roundtrip_via_container()
{
    var services = new ServiceCollection();
    services.AddLogging();
    services.AddMediatR(cfg => cfg.RegisterServicesFromAssemblyContaining<Ping>());
    services.AddSingleton<TextWriter>(TextWriter.Null);

    using var sp = services.BuildServiceProvider();
    var mediator = sp.GetRequiredService<IMediator>();

    var pong = await mediator.Send(new Ping { Message = "hi" });
    Assert.Equal("hi Pong", pong.Message);
}
```

---

## 21. Múltiples ensamblados

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssemblies(
        typeof(Program).Assembly,            // Web
        typeof(CreateOrderHandler).Assembly, // Application
        typeof(OrderCreated).Assembly);      // Domain
});
```

Todos los ensamblados se escanean en una sola pasada.

---

## 22. Registro condicional de behaviors

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
    cfg.TypeEvaluator = t => t.GetCustomAttribute<HandlerAttribute>() != null;
});
```

Solo los tipos decorados con `[Handler]` se registran. Útil para opt-in/opt-out explícito.

---

## Lectura adicional

- Los proyectos `samples/AN.MediatR.Examples*` contienen demos ejecutables end-to-end para cada característica — empieza por ahí al experimentar.
- La mayoría de frameworks CQRS comunes (Ardalis.Specification, plantillas Clean.Architecture, etc.) ya están construidos sobre contratos compatibles con MediatR. Nuestros pipeline behaviors se enchufan sin modificaciones.
