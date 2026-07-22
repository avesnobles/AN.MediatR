# Notification Publishers

Notifications are AN.MediatR's fan-out mechanism: a single `INotification` is dispatched to zero, one or many `INotificationHandler<TNotification>` instances. The **strategy** that decides *how* those handlers are invoked — sequentially? in parallel? with error aggregation? — is encapsulated by `INotificationPublisher`.

---

## The contract

```csharp
public interface INotificationPublisher
{
    Task Publish(
        IEnumerable<NotificationHandlerExecutor> handlerExecutors,
        INotification notification,
        CancellationToken cancellationToken);
}
```

Source: [src/AN.MediatR/INotificationPublisher.cs](../../src/AN.MediatR/INotificationPublisher.cs).

The publisher receives:

- A pre-built sequence of `NotificationHandlerExecutor`s — each a `(HandlerInstance, HandlerCallback)` record.
- The original notification (type-erased to `INotification`).
- A cancellation token.

Its job: drive the executor callbacks however it wants and return a single `Task` that completes when "all the handlers are considered done".

```csharp
public record NotificationHandlerExecutor(
    object HandlerInstance,
    Func<INotification, CancellationToken, Task> HandlerCallback);
```

Source: [src/AN.MediatR/NotificationHandlerExecutor.cs](../../src/AN.MediatR/NotificationHandlerExecutor.cs).

---

## How the executors are built

In `NotificationHandlerWrapperImpl<TNotification>.Handle(...)`:

```csharp
var handlers = serviceFactory
    .GetServices<INotificationHandler<TNotification>>()
    .GroupBy(static x => x.GetType())           // dedupe by concrete handler type
    .Select(static g => g.First())              // pick first instance of each type
    .Select(static x => new NotificationHandlerExecutor(x,
        (theNotification, theToken) => x.Handle((TNotification)theNotification, theToken)));

return publish(handlers, notification, cancellationToken);
```

Source: [src/AN.MediatR/Wrappers/NotificationHandlerWrapper.cs](../../src/AN.MediatR/Wrappers/NotificationHandlerWrapper.cs).

Important behaviors:

- **Deduplication by concrete type**. If the same handler type was registered twice (e.g. via explicit registration **and** via assembly scanning), only one instance runs per notification.
- **Handlers are captured into closures** — the closure casts the `INotification` back to `TNotification` before calling `Handle`. This adds a tiny bit of type safety at the cost of an allocation per publish.
- **The enumerable is lazy** — the publisher decides when (or whether) to enumerate it. If a publisher calls `ToArray()` first, all handler instances are materialized eagerly.

---

## Built-in publishers

### `ForeachAwaitPublisher` (default)

Source: [src/AN.MediatR/NotificationPublishers/ForeachAwaitPublisher.cs](../../src/AN.MediatR/NotificationPublishers/ForeachAwaitPublisher.cs).

```csharp
public class ForeachAwaitPublisher : INotificationPublisher
{
    public async Task Publish(
        IEnumerable<NotificationHandlerExecutor> handlerExecutors,
        INotification notification,
        CancellationToken cancellationToken)
    {
        foreach (var handler in handlerExecutors)
        {
            await handler.HandlerCallback(notification, cancellationToken).ConfigureAwait(false);
        }
    }
}
```

**Behavior**: sequential, await-each, fail-fast.

- Handlers run **one at a time**, in DI-resolution order.
- If a handler throws, subsequent handlers are **not** invoked and the exception propagates to `mediator.Publish(...)`'s caller.
- Guarantees ordering and transactional consistency.
- Safe default for handlers that touch shared state (databases, caches, etc.).

### `TaskWhenAllPublisher`

Source: [src/AN.MediatR/NotificationPublishers/TaskWhenAllPublisher.cs](../../src/AN.MediatR/NotificationPublishers/TaskWhenAllPublisher.cs).

```csharp
public class TaskWhenAllPublisher : INotificationPublisher
{
    public Task Publish(
        IEnumerable<NotificationHandlerExecutor> handlerExecutors,
        INotification notification,
        CancellationToken cancellationToken)
    {
        var tasks = handlerExecutors
            .Select(handler => handler.HandlerCallback(notification, cancellationToken))
            .ToArray();
        return Task.WhenAll(tasks);
    }
}
```

**Behavior**: parallel start, single `WhenAll` await.

- Every handler is invoked synchronously in a loop; if a handler's first synchronous portion throws, all subsequent handlers still start.
- Awaited via `Task.WhenAll`. If **any** task fails, the returned `Task` transitions to faulted with the **first** exception; additional exceptions are on `Task.Exception.InnerExceptions`.
- Handlers must be independent and non-order-sensitive.
- Suitable for fire-and-forget-ish integration events where throughput matters more than ordering.

> Strictly speaking the handlers aren't guaranteed to run in parallel — they all start synchronously and will only yield on `await`. But once they do yield, the remaining tasks run concurrently.

---

## Configuring the publisher

### By instance

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
    cfg.NotificationPublisher = new TaskWhenAllPublisher();
});
```

The instance is registered as the singleton `INotificationPublisher`.

### By type (DI-resolved)

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
    cfg.NotificationPublisherType = typeof(MyCustomPublisher);
});
```

When `NotificationPublisherType` is set, it takes precedence over `NotificationPublisher`. AN.MediatR registers it via the configuration's `Lifetime`, giving your publisher access to DI services. This is the right choice when the publisher needs `ILogger`, `IMetrics`, `IOptions<...>`, etc.

Inside `ServiceRegistrar.AddRequiredServices`:

```csharp
var notificationPublisherServiceDescriptor = serviceConfiguration.NotificationPublisherType != null
    ? new ServiceDescriptor(typeof(INotificationPublisher),
          serviceConfiguration.NotificationPublisherType,
          serviceConfiguration.Lifetime)
    : new ServiceDescriptor(typeof(INotificationPublisher),
          serviceConfiguration.NotificationPublisher);

services.TryAdd(notificationPublisherServiceDescriptor);
```

---

## Writing a custom publisher

A custom publisher can be as simple or as complex as you need. Here are several recipes.

### 1. Continue on exceptions (sequential)

```csharp
public class SequentialCollectExceptions : INotificationPublisher
{
    public async Task Publish(IEnumerable<NotificationHandlerExecutor> handlers, INotification notification, CancellationToken ct)
    {
        var exceptions = new List<Exception>();
        foreach (var h in handlers)
        {
            try { await h.HandlerCallback(notification, ct).ConfigureAwait(false); }
            catch (Exception ex) when (!(ex is OutOfMemoryException or StackOverflowException)) { exceptions.Add(ex); }
        }
        if (exceptions.Count > 0) throw new AggregateException(exceptions);
    }
}
```

### 2. Fully parallel with `Task.Run`

```csharp
public class ParallelOnThreadPool : INotificationPublisher
{
    public Task Publish(IEnumerable<NotificationHandlerExecutor> handlers, INotification notification, CancellationToken ct)
    {
        var tasks = handlers
            .Select(h => Task.Run(() => h.HandlerCallback(notification, ct), ct))
            .ToArray();
        return Task.WhenAll(tasks);
    }
}
```

### 3. Fire-and-forget

```csharp
public class FireAndForget : INotificationPublisher
{
    public Task Publish(IEnumerable<NotificationHandlerExecutor> handlers, INotification notification, CancellationToken ct)
    {
        foreach (var h in handlers)
        {
            _ = Task.Run(() => h.HandlerCallback(notification, ct), ct);
        }
        return Task.CompletedTask;
    }
}
```

> Warning: fire-and-forget drops exceptions and can race against host shutdown. Only use it if you have an external mechanism to observe failures (e.g. a telemetry pipeline).

### 4. With telemetry

```csharp
public class TelemetryPublisher : INotificationPublisher
{
    private readonly ILogger<TelemetryPublisher> _logger;
    public TelemetryPublisher(ILogger<TelemetryPublisher> logger) => _logger = logger;

    public async Task Publish(IEnumerable<NotificationHandlerExecutor> handlers, INotification notification, CancellationToken ct)
    {
        var notifName = notification.GetType().Name;
        using var activity = Activity.Current?.Source.StartActivity($"Publish {notifName}");

        foreach (var h in handlers)
        {
            var sw = Stopwatch.StartNew();
            try
            {
                await h.HandlerCallback(notification, ct).ConfigureAwait(false);
                _logger.LogDebug("{Handler} handled {Notification} in {Elapsed}ms",
                    h.HandlerInstance.GetType().Name, notifName, sw.ElapsedMilliseconds);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "{Handler} failed on {Notification}",
                    h.HandlerInstance.GetType().Name, notifName);
                throw;
            }
        }
    }
}
```

---

## Multiple strategies at once

If you need different strategies per notification, you can:

1. **Subclass `Mediator`** and override `PublishCore`:

    ```csharp
    public class MultiPublisherMediator : Mediator
    {
        private readonly INotificationPublisher _sequential = new ForeachAwaitPublisher();
        private readonly INotificationPublisher _parallel = new TaskWhenAllPublisher();

        public MultiPublisherMediator(IServiceProvider sp) : base(sp) { }

        protected override Task PublishCore(
            IEnumerable<NotificationHandlerExecutor> handlerExecutors,
            INotification notification,
            CancellationToken cancellationToken)
        {
            var publisher = notification is ICanRunInParallel ? _parallel : _sequential;
            return publisher.Publish(handlerExecutors, notification, cancellationToken);
        }
    }

    services.AddMediatR(cfg =>
    {
        cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
        cfg.MediatorImplementationType = typeof(MultiPublisherMediator);
    });
    ```

2. **Build a façade class** like the one in `samples/AN.MediatR.Examples.PublishStrategies/Publisher.cs`. It creates one `CustomMediator` per strategy and exposes a `Publish(notification, strategy)` method. See the sample for six strategies (`Async`, `ParallelNoWait`, `ParallelWhenAll`, `ParallelWhenAny`, `SyncContinueOnException`, `SyncStopOnException`).

---

## Notifications have no pipeline!

Unlike requests, notifications do **not** go through `IPipelineBehavior` or pre/post/exception processors. Any cross-cutting logic (logging, retry, telemetry) must live inside:

- The notification handlers themselves (coupled), or
- A custom `INotificationPublisher` (reusable), or
- A wrapping decorator of `IPublisher` in your application (flexible).

This is a deliberate design choice: notifications are meant to be one-way, best-effort events. If you find yourself wanting a full pipeline around notifications, you probably want a command instead.

---

## Choosing between `ForeachAwait` and `TaskWhenAll`

| Question | `ForeachAwait` | `TaskWhenAll` |
|----------|----------------|----------------|
| Do handlers share state / write to the same DB row? | ✅ Preferred (sequential, predictable) | ❌ Concurrency issues |
| Do handlers each call a different external service? | Works | ✅ Preferred (parallel = lower latency) |
| Do you need ordered side effects? | ✅ | ❌ |
| Do you want to run as much as possible even if one fails? | ❌ (stops) | Partial (starts all, faults once awaited) |
| Default choice for a new project | ✅ Safe | — |

When in doubt, start with `ForeachAwaitPublisher` (the default). Switch only if profiling proves it necessary.

---

## Observing errors

Because `Publish` returns a single `Task`, it's up to the publisher to decide what "completion" means:

- `ForeachAwaitPublisher` faults with the **first** exception, stopping further execution.
- `TaskWhenAllPublisher` faults with an `AggregateException` if any handler failed (but note that `await` unwraps to the first `InnerException`).
- Custom publishers can collect, aggregate, or swallow exceptions.

Always document the semantics of custom publishers clearly — different policies are valid, but surprising.
