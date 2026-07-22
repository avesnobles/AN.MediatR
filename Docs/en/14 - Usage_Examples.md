# Usage Examples

Practical recipes covering the most common scenarios. Each example is self-contained and uses only the public AN.MediatR surface.

Every sample assumes you've wired up DI with logging:

```csharp
var services = new ServiceCollection();
services.AddLogging(); // optional — AN.MediatR does no logging on its own
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
});
var provider = services.BuildServiceProvider();
var mediator = provider.GetRequiredService<IMediator>();
```

---

## 1. Simple request / response

```csharp
public record GetCustomerById(int Id) : IRequest<Customer>;

public class GetCustomerByIdHandler : IRequestHandler<GetCustomerById, Customer>
{
    private readonly ICustomerRepository _repo;
    public GetCustomerByIdHandler(ICustomerRepository repo) => _repo = repo;

    public Task<Customer> Handle(GetCustomerById request, CancellationToken ct)
        => _repo.FindAsync(request.Id, ct);
}

// Dispatch
Customer customer = await mediator.Send(new GetCustomerById(42));
```

Exactly one handler per request type. Exceptions bubble up to the caller.

---

## 2. Void command

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

Internally the return type is `Task<Unit>`, but the `Mediator.Send<TRequest>(TRequest)` overload returns `Task` so you never see `Unit`.

---

## 3. Notification with multiple handlers

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

By default handlers run sequentially (`ForeachAwaitPublisher`). If the first throws, the second does **not** run.

### Parallel dispatch

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
    cfg.NotificationPublisher = new TaskWhenAllPublisher();
});
```

See [Notification Publishers](09%20-%20Notification_Publishers.md).

---

## 4. Synchronous notification handler

```csharp
public class LogCustomer : NotificationHandler<CustomerCreated>
{
    protected override void Handle(CustomerCreated n)
        => Console.WriteLine($"Customer {n.Id} created.");
}
```

`NotificationHandler<TNotification>` wraps your sync `Handle` in `Task.CompletedTask` automatically.

---

## 5. Cross-cutting pipeline behavior

Open-generic logging + timing behavior that applies to every request:

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

## 6. Validation behavior

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

// Register validators (any, e.g. FluentValidation) + the behavior
cfg.AddOpenBehavior(typeof(ValidationBehavior<,>));
```

---

## 7. Caching behavior (short-circuit)

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

The `where TRequest : ICacheable` constraint means this behavior is only resolved (and therefore invoked) for requests that implement `ICacheable`. DI handles this for you.

---

## 8. Transaction behavior

```csharp
public interface ITransactional { }   // marker

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

Commit on success, let the caller's unhandled exception roll back via `DisposeAsync`.

---

## 9. Pre-processor (enrichment)

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

## 10. Post-processor (audit)

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

## 11. Exception action (log + rethrow)

```csharp
public class LogException<TRequest> : IRequestExceptionAction<TRequest, Exception>
    where TRequest : notnull
{
    private readonly ILogger<LogException<TRequest>> _logger;
    public LogException(ILogger<LogException<TRequest>> logger) => _logger = logger;

    public Task Execute(TRequest request, Exception ex, CancellationToken ct)
    {
        _logger.LogError(ex, "Error while handling {Request}: {Message}", typeof(TRequest).Name, ex.Message);
        return Task.CompletedTask;
    }
}
```

Assembly scanning automatically picks this up. Always rethrows — use for observation, not recovery.

---

## 12. Exception handler (recovery with default response)

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

If the handler throws `EntityNotFoundException`, the pipeline swallows it and the caller receives a default-constructed `TResponse`.

---

## 13. Streaming — minimal

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

## 14. Streaming with pipeline behavior

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

## 15. Dynamic dispatch

```csharp
object request = LoadRequestFromQueue();           // runtime type only
object? response = await mediator.Send(request);   // dynamic
```

Also available for notifications:

```csharp
INotification notification = BuildNotification();
await mediator.Publish((object)notification);
```

Useful for API gateways, message relays, and generic test harnesses.

---

## 16. ASP.NET Core minimal API

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

## 17. ASP.NET Core controller

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

Prefer injecting `ISender` (or `IPublisher`) over `IMediator` when you only need one direction — it makes the method's intent clearer and tests simpler.

---

## 18. Unit-testing a handler

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

Note: you can test handlers directly — no need to resolve them via `IMediator`. That's one of the advantages of the mediator pattern.

---

## 19. Unit-testing a behavior

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
            _ => Task.FromResult(new Pong()),   // fake "next"
            default));
}
```

---

## 20. Integration test with a real container

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

## 21. Multiple assemblies

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssemblies(
        typeof(Program).Assembly,            // Web
        typeof(CreateOrderHandler).Assembly, // Application
        typeof(OrderCreated).Assembly);      // Domain
});
```

All assemblies are scanned in one pass.

---

## 22. Conditional behavior registration

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
    cfg.TypeEvaluator = t => t.GetCustomAttribute<HandlerAttribute>() != null;
});
```

Only types decorated with `[Handler]` are registered. Useful for opting types in/out explicitly.

---

## Further reading

- The `samples/AN.MediatR.Examples*` projects contain runnable end-to-end demos for each feature — start there when experimenting.
- Most common CQRS frameworks (Ardalis.Specification, Clean.Architecture templates, etc.) are already built on MediatR-compatible contracts. Our pipeline behaviors plug into them verbatim.
