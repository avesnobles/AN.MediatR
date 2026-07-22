# Best Practices and FAQ

A pragmatic guide to using AN.MediatR well — based on how the library is designed, the patterns the community has adopted over the years, and observations from the codebase.

---

## Design conventions

### 1. One handler per request, many per notification

- `IRequest<TResponse>` and `IRequest` are **1-to-1**. If two handlers match, the DI container will either throw (`GetRequiredService`) or silently pick one — neither is what you want.
- `INotification` is **1-to-many**. Multiple handlers are expected; if you find yourself writing logic that needs "the result" of a notification, convert it into a request.

### 2. Name types after intent

- Requests: imperative (`CreateOrder`, `DeleteCustomer`) or interrogative (`GetOrderById`, `FindCustomersByName`).
- Notifications: past tense (`OrderCreated`, `CustomerDeleted`).
- Handlers: `<RequestName>Handler` / `<NotificationName>Handler` — concise and predictable.
- Pipeline behaviors: `<Responsibility>Behavior` (e.g. `ValidationBehavior`, `LoggingBehavior`).
- Pre/post-processors: `<Responsibility>PreProcessor` / `<Responsibility>PostProcessor`.

### 3. Put handlers next to their requests

Co-locate `CreateOrder.cs` and `CreateOrderHandler.cs` in the same folder. When a new feature is added, the entire slice is in one place — this works well with "vertical slice architecture".

### 4. Keep requests immutable data

Requests are DTOs. Prefer `record` / `record struct` with `init`-only properties. Don't mutate a request inside its handler — mutate domain entities, not the message.

### 5. Inject `ISender` / `IPublisher` instead of `IMediator` when possible

`ISender` says "this class sends commands/queries". `IPublisher` says "this class raises events". `IMediator` says "both". Narrower dependencies = clearer intent + cheaper tests.

### 6. Prefer pipeline behaviors over duplicated logic in handlers

If the same try/catch or same logging appears in more than two handlers, extract it into a pipeline behavior. If the same validation appears everywhere, use `ValidationBehavior<,>` with FluentValidation (or similar).

### 7. Keep behaviors thin and focused

A behavior should do **one** thing. "Log + open transaction + catch exceptions + validate" is four behaviors, not one.

---

## CQRS integration

AN.MediatR is a natural fit for CQRS ("Command Query Responsibility Segregation"):

- **Queries** → `IRequest<TResponse>`.
- **Commands** → `IRequest` or `IRequest<TResponse>` (when you need the new identifier back).
- **Domain events** → `INotification`.
- **Integration events** → `INotification` that triggers a handler which publishes to a message bus.

Typical folder structure:

```
Application/
├── Orders/
│   ├── Commands/
│   │   ├── CreateOrder.cs
│   │   └── CreateOrderHandler.cs
│   ├── Queries/
│   │   ├── GetOrderById.cs
│   │   └── GetOrderByIdHandler.cs
│   └── Events/
│       ├── OrderCreated.cs
│       └── NotifyShippingOnOrderCreated.cs
```

Tip: even if you're not strictly CQRS, the directory-per-feature split keeps discovery fast.

---

## Pipeline composition recipes

### Typical behavior stack (commands)

Registered in this order (first = outer):

1. **LoggingBehavior** — outermost, always.
2. **RequestExceptionActionProcessorBehavior** (auto-injected) — observational.
3. **RequestExceptionProcessorBehavior** (auto-injected) — recovery.
4. **RequestPreProcessorBehavior** (auto-injected) — pre-processors run inside here.
5. **ValidationBehavior** — throw on invalid inputs before hitting anything expensive.
6. **AuthorizationBehavior** — check auth after validation.
7. **TransactionBehavior** — outer boundary of the transactional scope.
8. **CachingBehavior** — last before the handler, so caching sees the authoritative response.
9. **RequestPostProcessorBehavior** (auto-injected) — post-processors run here.

Rule of thumb: **expensive work should live as close to the handler as possible**. Fast rejections (auth, validation) should be at the outside.

### Queries

Queries usually need a smaller subset: logging, caching, and maybe validation. Skip transactions.

### Notifications

No pipeline. Any cross-cutting logic should either live in an `INotificationPublisher` or be applied inside a wrapper that calls `mediator.Publish(...)`.

---

## Common anti-patterns

### ❌ Calling `IMediator` from inside a handler ("mediator recursion")

```csharp
public class CreateOrderHandler : IRequestHandler<CreateOrder, int>
{
    private readonly IMediator _mediator;
    public CreateOrderHandler(IMediator mediator) => _mediator = mediator;

    public async Task<int> Handle(CreateOrder cmd, CancellationToken ct)
    {
        var customer = await _mediator.Send(new GetCustomerById(cmd.CustomerId), ct);   // ← coupling
        // ...
    }
}
```

This works, but tangles handlers together. Prefer direct service dependencies (`ICustomerRepository`) unless you explicitly need the pipeline around the inner call.

### ❌ Notification handlers that return data

```csharp
public class BadHandler : INotificationHandler<OrderCreated>
{
    public Task Handle(OrderCreated n, CancellationToken ct)
    {
        // Tries to "return" something via shared state
        SharedBag.LastOrderId = n.Id;
        return Task.CompletedTask;
    }
}
```

Notifications are fire-and-forget. If you need a response, make it a request.

### ❌ `INotificationHandler` with side effects in a parallel publisher

Mixing `TaskWhenAllPublisher` with handlers that write to the same database row / cache key / file creates race conditions. Choose sequential (`ForeachAwaitPublisher`) or design handlers to be truly independent.

### ❌ Pipeline behaviors that throw instead of using exception handlers

```csharp
public async Task<TResponse> Handle(TRequest r, ..., CancellationToken ct)
{
    try { return await next(ct); }
    catch (Exception ex) { throw new MyWrappedException(ex); }   // ← bypasses IRequestExceptionHandler
}
```

If you need exception translation, prefer `IRequestExceptionHandler<TRequest, TResponse, TException>` — it's ordered, deduplicated, and composable. Only fall back to try/catch in behaviors for behaviors that are themselves about exception handling.

### ❌ Relying on handler registration order for behavior

Handler registration order is not a contract. Don't write code that depends on which handler "wins" when multiple match — design the system so only one matches per request.

### ❌ Reusing a scoped `IMediator` across threads

If `IMediator` is scoped (common in ASP.NET Core), don't pass it to `Task.Run(...)`. That task may outlive the scope, at which point the service provider is disposed. Resolve a fresh `IMediator` inside the task via `IServiceScopeFactory`.

---

## Performance tips

1. **Reuse behavior instances**. Register as transient unless a behavior genuinely needs state; transient is the safest default.
2. **Prefer explicit registrations for hot paths**. `services.AddTransient<IRequestHandler<Hot, HotResponse>, HotHandler>()` avoids scanning cost if you're starting up many times (tests).
3. **Avoid reflection inside behaviors**. Everything needed to invoke the next step is already in your closure.
4. **Benchmark before optimizing**. `test/AN.MediatR.Benchmarks` gives you the baseline cost; AN.MediatR is already very fast for most workloads.
5. **Cache composed pipelines if you call `Send` inside a hot loop**. You can't cache the fully-resolved chain because DI services may be scoped, but you can cache **immutable state** the behaviors need.

---

## Testing advice

- **Test handlers directly**. They're plain classes with injected dependencies — no mediator needed.
- **Test pipeline behaviors with a fake `next`** — a lambda that returns a fixed response or throws.
- **Test `IMediator` only when you're verifying the composed pipeline**. This is integration testing; use the real container.
- **Avoid mocking `IMediator`** in controllers / services unless you must. Prefer real DI and assert at the handler level.

---

## FAQ

### What's the difference between AN.MediatR and jbogard/MediatR?

AN.MediatR is a **free and open-source fork** based on **MediatR v12.5**, the last Apache-2.0 licensed release before the upstream project (v13+, now owned by Lucky Penny Software) switched to a commercial/RPL-1.5 dual licensing model with a JWT-based runtime license check.

At the fork point (v12.5) the two codebases are identical. Going forward:

- AN.MediatR stays Apache-2.0. No runtime license validation. No JWT. No logging category `LuckyPennySoftware.MediatR.License`.
- AN.MediatR has no `Licensing/` folder, no `Mediator.LicenseKey` property, no `cfg.LicenseKey` setting, no `LicenseAccessor` / `LicenseValidator` / `BuildInfo` types.
- The AN team will evolve the library independently from upstream — bug fixes, performance improvements, new features — without tracking every upstream change.
- Upstream (jbogard/MediatR v13+) has gained a JWT licensing subsystem and is a commercial product. Features added there after v12.5 are not automatically ported here.

### Do I need a license to use AN.MediatR?

No. AN.MediatR is Apache-2.0. You can use it in any project, commercial or otherwise, subject to the Apache-2.0 terms (which are minimal).

### Can I use `IRequest<TResponse>` where `TResponse` is a value type / record struct?

Yes. Value types work exactly like reference types.

### Why does `Send<TResponse>` not take a `where TResponse : notnull`?

Because `TResponse` might be a nullable reference type (`Customer?`) or a nullable value type (`int?`). The library doesn't care.

### Does cancellation propagate through the pipeline?

Yes. The `CancellationToken` is:

- Passed to every pipeline behavior's `Handle`.
- Passed to the final handler.
- Honored by `Task.WhenAll` and `IAsyncEnumerable.WithCancellation` inside streams.

Each behavior can pass a different token downstream by using the optional parameter on `RequestHandlerDelegate<TResponse>`.

### Is `Mediator` thread-safe?

Yes. The only mutable state is the three static wrapper caches, which use `ConcurrentDictionary`. Handler resolution goes through a fresh `IServiceProvider.GetServices` call on every dispatch, so the usual scope / thread-safety rules of your DI container apply.

### Can I register handlers as singletons?

Technically yes, but: singleton handlers must be thread-safe, must not depend on scoped services (DbContext, IHttpContextAccessor, etc.), and must not hold request-specific state. Default to transient unless profiling proves otherwise.

### How do I get an `IServiceScope` inside a handler?

Inject `IServiceScopeFactory` and create a scope explicitly:

```csharp
public class MyHandler(IServiceScopeFactory scopeFactory) : IRequestHandler<MyReq>
{
    public async Task Handle(MyReq r, CancellationToken ct)
    {
        using var scope = scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<DbContext>();
        // ...
    }
}
```

This is uncommon — usually your handler is already scoped.

### What happens if no handler matches a request?

`IServiceProvider.GetRequiredService<IRequestHandler<TRequest, TResponse>>()` throws `InvalidOperationException`:

```
No service for type 'MediatR.IRequestHandler`2[MyRequest, MyResponse]' has been registered.
```

### What happens if multiple handlers match a request?

DI returns the **first** registered (via `TryAddTransient` in `ServiceRegistrar`). The wrapper calls `GetRequiredService` (not `GetServices`), so only one is invoked. Two handlers for the same request is almost always a bug.

### What happens if no notification handler matches?

Nothing — `GetServices<INotificationHandler<TNotification>>()` returns an empty sequence, and the publisher runs over zero executors. `Publish` returns a completed task.

### Why are wrappers cached statically?

Because their identity depends only on message types, which are immutable per-process. The caches survive service-provider rebuilds (e.g. in test fixtures), which is desirable — you don't pay the reflection cost on every test.

### Can I customize `Mediator`?

Yes. Subclass it and set `cfg.MediatorImplementationType = typeof(MyMediator)`. Override `PublishCore` for notification dispatch tweaks.

### Can I use AN.MediatR with AOT / trimming?

Trimming is possible with care: every handler must be **root-reachable** for the IL linker. Explicit registration (instead of assembly scanning) helps. AOT support is not officially advertised — the library uses reflection in `ServiceRegistrar` and `Mediator`, so verify with your specific scenario.

### What's `Unit` for?

A stand-in for `void` in generic contexts. `Task<Unit>` is a valid type; `Task<void>` is not. See [Contracts Package](13%20-%20Contracts_Package.md).

---

## When *not* to use AN.MediatR

- **You have < 10 handlers**. The abstraction cost outweighs the benefit.
- **Your commands / queries chain tightly**. If every handler calls three other handlers, the loose coupling becomes false coupling via `IMediator` recursion. Prefer direct method calls.
- **You need distributed messaging**. AN.MediatR is **in-process** only. Use MassTransit, NServiceBus, or similar for cross-process / cross-machine messaging.
- **You want a fully statically-typed dispatch**. AN.MediatR resolves handlers via DI at runtime — so "missing handler" is a runtime error, not a compile error.

---

## Further reading

- [Original MediatR wiki](https://github.com/jbogard/MediatR/wiki) — more examples and patterns (most still applies).
- [Jimmy Bogard's posts](https://www.jimmybogard.com/) — the original author's writing on CQRS and mediator patterns.
- `samples/AN.MediatR.Examples.*` — runnable demos in the repo.
