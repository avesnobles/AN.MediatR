# Core Concepts

Before diving into the API surface, make sure you understand the four message kinds AN.MediatR supports, the three roles it plays for your application, and the pipeline model that sits between them.

---

## The Mediator pattern

AN.MediatR is an implementation of the classic Mediator behavioral pattern from the Gang of Four book:

> Define an object that encapsulates how a set of objects interact. Mediator promotes loose coupling by keeping objects from referring to each other explicitly.

In practice, callers do not reference their handlers directly. They publish messages to a single `IMediator` instance, which knows how to resolve the appropriate handler(s) from the DI container and invoke them.

**Why this matters**:

- Controllers, background services, and UI code depend on a single abstraction (`IMediator`) instead of dozens of handler interfaces.
- Cross-cutting concerns (logging, validation, caching, transactions, retries) plug in as **pipeline behaviors** without touching handlers.
- Handlers are single-purpose, easy to test, and independent of each other.

---

## The three roles: `ISender`, `IPublisher`, `IMediator`

Although `IMediator` is the public face, it is split into two narrower interfaces:

| Interface | Responsibility | Methods |
|-----------|----------------|---------|
| `ISender` | Dispatches a message to exactly **one** handler and returns a result | `Send<TResponse>`, `Send` (void), `Send(object)`, `CreateStream`, `CreateStream(object)` |
| `IPublisher` | Fans out a notification to **zero or more** handlers | `Publish<TNotification>`, `Publish(object)` |
| `IMediator` | `ISender` + `IPublisher` | All of the above |

Why the split? So callers can declare the narrowest dependency possible. A command handler that needs to raise events but never sends requests can ask for `IPublisher`. A query-only controller can ask for `ISender`. Each interface also makes the test doubles easier to write.

---

## The four message kinds

AN.MediatR classifies every message as one of four kinds. Each has its own marker interface from the `AN.MediatR.Contracts` package.

### 1. Request with response — `IRequest<TResponse>`

```csharp
public class GetCustomerById : IRequest<Customer>
{
    public int Id { get; init; }
}

public class GetCustomerByIdHandler : IRequestHandler<GetCustomerById, Customer>
{
    public Task<Customer> Handle(GetCustomerById request, CancellationToken ct)
        => Task.FromResult(/* ... */);
}

Customer customer = await mediator.Send(new GetCustomerById { Id = 42 });
```

- **Exactly one** handler is required (`GetRequiredService` is used — DI throws if none exists).
- Returns `Task<TResponse>`.
- Supports dynamic dispatch via `Send(object)` for scenarios where the type is only known at runtime.

### 2. Request without response — `IRequest`

```csharp
public class DeleteCustomer : IRequest
{
    public int Id { get; init; }
}

public class DeleteCustomerHandler : IRequestHandler<DeleteCustomer>
{
    public Task Handle(DeleteCustomer request, CancellationToken ct) { /* ... */ }
}

await mediator.Send(new DeleteCustomer { Id = 42 });
```

- Same cardinality as `IRequest<TResponse>`: **exactly one** handler.
- Internally the response is `Unit` (`MediatR.Unit`), a singleton value type that stands in for `void`. You never see it in your handler signature.

### 3. Notification (event) — `INotification`

```csharp
public class CustomerCreated : INotification
{
    public int Id { get; init; }
}

public class SendWelcomeEmail : INotificationHandler<CustomerCreated>
{
    public Task Handle(CustomerCreated n, CancellationToken ct) { /* ... */ }
}

public class PushToAnalytics : INotificationHandler<CustomerCreated>
{
    public Task Handle(CustomerCreated n, CancellationToken ct) { /* ... */ }
}

await mediator.Publish(new CustomerCreated { Id = 42 });
```

- **Zero or more** handlers.
- Returns `Task` (no response).
- Handlers are deduplicated by concrete type before dispatch (if the same handler type is registered twice, only the first instance runs).
- The dispatch strategy — sequential vs. parallel — is controlled by an `INotificationPublisher` (see [Notification Publishers](09%20-%20Notification_Publishers.md)).

### 4. Stream request — `IStreamRequest<TResponse>`

```csharp
public class TailLogs : IStreamRequest<LogEntry>
{
    public string Category { get; init; }
}

public class TailLogsHandler : IStreamRequestHandler<TailLogs, LogEntry>
{
    public async IAsyncEnumerable<LogEntry> Handle(TailLogs request, [EnumeratorCancellation] CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            yield return await _logs.NextAsync(ct);
        }
    }
}

await foreach (var entry in mediator.CreateStream(new TailLogs { Category = "api" }))
{
    Console.WriteLine(entry);
}
```

- Exactly one handler.
- Returns `IAsyncEnumerable<TResponse>` — perfect for SignalR streaming hubs, gRPC server-streaming endpoints, tailing logs, processing large data sets in chunks, and so on.
- Supports its own dedicated pipeline via `IStreamPipelineBehavior<TRequest, TResponse>`.

---

## Command vs. Query vs. Event (CQRS)

AN.MediatR doesn't enforce CQRS terminology, but the pattern maps naturally:

| CQRS role | AN.MediatR type |
|-----------|-----------------|
| **Query** — reads data, returns something | `IRequest<TResponse>` |
| **Command** — mutates state, typically no return | `IRequest` (void) or `IRequest<TResponse>` (when you need the new id, etc.) |
| **Domain event / Integration event** | `INotification` |

A common convention is to name request types with the imperative (`CreateOrder`) or interrogative (`GetOrderById`) mood, and notification types in past tense (`OrderCreated`).

---

## The pipeline

Around every request handler, AN.MediatR builds a **pipeline** — a chain of `IPipelineBehavior<TRequest, TResponse>` decorators. Each behavior receives the request and a `next` delegate, can run code before and after calling `next`, and can short-circuit by skipping `next`.

```
Request ─► Behavior1 ─► Behavior2 ─► ... ─► BehaviorN ─► Handler
            │              │                 │            │
            │              │                 │            ▼
            │              │                 │          Response
            ▼              ▼                 ▼
         wraps the call   wraps the call   wraps the call
```

This is conceptually identical to ASP.NET Core middleware, except typed to `(TRequest, TResponse)` pairs. See [Pipeline Behaviors](06%20-%20Pipeline_Behaviors.md) for the full mechanics.

AN.MediatR provides four built-in decorators out of the box:

1. `RequestPreProcessorBehavior<,>` — runs `IRequestPreProcessor<>` instances **before** the handler.
2. `RequestPostProcessorBehavior<,>` — runs `IRequestPostProcessor<,>` instances **after** the handler.
3. `RequestExceptionActionProcessorBehavior<,>` — runs `IRequestExceptionAction<,>` instances when the handler throws (always rethrows).
4. `RequestExceptionProcessorBehavior<,>` — runs `IRequestExceptionHandler<,,>` instances; if one marks the exception as handled, that response is returned instead.

For streaming, a parallel structure exists: `IStreamPipelineBehavior<TRequest, TResponse>`. Pre/post/exception processors are **not** available for streams.

---

## Handler cardinality summary

| Message kind | Required handlers | Multiple allowed? | Pipeline? | Returns |
|--------------|-------------------|-------------------|-----------|---------|
| `IRequest<TResponse>` | 1 | ❌ (throws if multiple) | `IPipelineBehavior<,>` | `Task<TResponse>` |
| `IRequest` | 1 | ❌ | `IPipelineBehavior<TRequest, Unit>` | `Task` |
| `INotification` | 0+ | ✅ | ❌ (no pipeline for notifications) | `Task` |
| `IStreamRequest<TResponse>` | 1 | ❌ | `IStreamPipelineBehavior<,>` | `IAsyncEnumerable<TResponse>` |

> Note: notifications have **no** pipeline. If you need cross-cutting behavior around events, implement it in an `INotificationPublisher` (custom strategy) or in a wrapping service.

---

## Dispatch modes: typed vs. dynamic

Every sending method comes in two flavors:

```csharp
// Typed (compile-time): the compiler picks the right Send overload
Pong pong = await mediator.Send(new Ping { Message = "hi" });

// Dynamic (runtime): the request type is only known at runtime, e.g. via reflection
object response = await mediator.Send((object)pingInstance);
```

Dynamic dispatch is slightly slower (uses `Type.GetInterfaces()` to discover `IRequest<T>`) but is useful for generic host code, API gateways, tests, and introspection tools.

Same pattern for notifications (`Publish(object)`) and streams (`CreateStream(object)`).

---

## Why `Unit` instead of `void`?

C# `void` is not a first-class type: `Task<void>` is not valid, and you cannot express "a generic method returning void" uniformly with one returning a concrete type. AN.MediatR defines the `Unit` value type as a stand-in:

```csharp
public readonly struct Unit : IEquatable<Unit>, IComparable<Unit>, IComparable
{
    public static ref readonly Unit Value => ref _value;
    public static Task<Unit> Task { get; } = System.Threading.Tasks.Task.FromResult(_value);
    // All instances are equal; GetHashCode() == 0; ToString() == "()"
}
```

Wherever a "void-returning request" appears internally, the response type is `Unit`. This keeps the pipeline type uniform: an `IPipelineBehavior<TRequest, TResponse>` with `TResponse = Unit` handles void requests exactly the same way as other requests.

---

## Summary mental model

- **Send one message, get one response** → `IRequest<TResponse>`.
- **Send one message, no response** → `IRequest`.
- **Broadcast an event, zero-or-many handlers** → `INotification`.
- **Stream items as they become available** → `IStreamRequest<TResponse>`.
- **Wrap cross-cutting behavior around a handler** → `IPipelineBehavior<TRequest, TResponse>`.
- **Run code before/after a handler, or on exception** → `IRequestPreProcessor`, `IRequestPostProcessor`, `IRequestExceptionHandler`, `IRequestExceptionAction`.
- **Choose how notifications are dispatched** → `INotificationPublisher` (sequential `ForeachAwaitPublisher` by default, parallel `TaskWhenAllPublisher` optionally, or custom).
