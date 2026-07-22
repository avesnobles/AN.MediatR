# Glossary

Terminology used throughout this documentation, in alphabetical order.

---

**Action (exception action)**  
An `IRequestExceptionAction<TRequest, TException>` implementation. Fires when a request handler throws, runs its side-effects (logging, metrics), and **always** rethrows. Cannot recover.

**Assembly scanning**  
Reflection-based discovery of types that implement handler / behavior / processor interfaces. Performed by `ServiceRegistrar.AddMediatRClasses` during `AddMediatR(...)`. Controlled by `RegisterServicesFromAssembly(...)` and friends.

**Behavior (pipeline behavior)**  
An `IPipelineBehavior<TRequest, TResponse>` implementation. Wraps every request handler with cross-cutting logic (logging, validation, caching, transactions, ...). Receives a `next` delegate and can choose to invoke it, short-circuit, wrap the response, or catch exceptions.

**Behavior (stream pipeline behavior)**  
An `IStreamPipelineBehavior<TRequest, TResponse>` implementation. Same idea as a regular behavior but for `IStreamRequest` messages — yields items as they pass through.

**Cache (wrapper cache)**  
The three static `ConcurrentDictionary<Type, ...>` fields on the `Mediator` class (`_requestHandlers`, `_notificationHandlers`, `_streamRequestHandlers`) that cache generic wrapper instances keyed by the runtime type of the message. Shared process-wide.

**Command**  
In CQRS, a request that mutates state. Expressed in AN.MediatR as either `IRequest` (void) or `IRequest<TResponse>` (when a result like an identifier is returned).

**Contracts (`AN.MediatR.Contracts`)**  
Separate NuGet package containing the minimal marker interfaces (`IBaseRequest`, `IRequest`, `IRequest<T>`, `IStreamRequest<T>`, `INotification`) and the `Unit` value type. Licensed Apache-2.0 for use in contract-only assemblies.

**CQRS**  
*Command Query Responsibility Segregation*. Architectural pattern separating write-path (commands) from read-path (queries). Maps naturally to AN.MediatR's `IRequest` / `IRequest<T>` / `INotification` triad.

**Dispatch**  
The act of sending a message through the mediator — `Send`, `Publish`, `CreateStream`.

**Dynamic dispatch**  
The object-typed overloads: `Send(object)`, `Publish(object)`, `CreateStream(object)`. The runtime type is introspected for the right marker interface. Useful for generic hosts, API gateways, test harnesses.

**ForeachAwaitPublisher**  
Default `INotificationPublisher`. Runs handlers sequentially, awaits each. Fail-fast semantics.

**Handler (request handler)**  
Implementation of `IRequestHandler<TRequest, TResponse>` or `IRequestHandler<TRequest>`. Receives a single request and returns a single response. Exactly one per request type.

**Handler (notification handler)**  
Implementation of `INotificationHandler<TNotification>`. Multiple handlers per notification allowed; all run (order depends on the publisher).

**Handler (stream request handler)**  
Implementation of `IStreamRequestHandler<TRequest, TResponse>`. Returns `IAsyncEnumerable<TResponse>` instead of `Task<TResponse>`.

**Handler (exception handler)**  
Implementation of `IRequestExceptionHandler<TRequest, TResponse, TException>`. Runs when the handler throws; can recover by calling `state.SetHandled(response)`.

**HandlersOrderer**  
Internal static helper (`AN.MediatR.Internal.HandlersOrderer`) that prioritizes exception handlers / actions by assembly and namespace proximity to the request type.

**IMediator**  
The combined mediator interface. Inherits `ISender` and `IPublisher`.

**INotificationPublisher**  
Strategy interface deciding **how** notification handlers are invoked (sequentially, in parallel, with error aggregation, ...). See [Notification Publishers](09%20-%20Notification_Publishers.md).

**IPublisher**  
Interface for the publish-subscribe side of the mediator (`Publish` / `Publish<T>`). Subset of `IMediator`.

**IRequest**  
Marker for a void-returning request.

**IRequest&lt;TResponse&gt;**  
Marker for a request that returns `TResponse`.

**ISender**  
Interface for the request/stream side of the mediator (`Send`, `Send<TResponse>`, `Send(object)`, `CreateStream`, `CreateStream(object)`). Subset of `IMediator`.

**IStreamRequest&lt;TResponse&gt;**  
Marker for a streaming request that returns `IAsyncEnumerable<TResponse>`.

**Marker interface**  
An interface with no members, used purely for type constraints and polymorphic dispatch (e.g. `IRequest`, `INotification`).

**Mediator**  
The concrete class implementing `IMediator`. See [Mediator Implementation](05%20-%20Mediator_Implementation.md).

**MediatR.Contracts**  
See **Contracts**.

**MediatRServiceConfiguration**  
Fluent configuration object passed to `AddMediatR(cfg => ...)`. Collects assemblies, behaviors, processors, etc.

**Middleware (pipeline)**  
Loose synonym for **pipeline behavior**. Reflects the similarity with ASP.NET Core middleware.

**MinVer**  
MSBuild versioning tool used by `AN.MediatR.csproj`. Derives version numbers from git tags (`v*` prefix).

**Notification**  
A fan-out event dispatched via `IPublisher.Publish(...)`. Zero-to-many handlers per notification, no response.

**NotificationHandlerExecutor**  
Record (`object HandlerInstance, Func<INotification, CancellationToken, Task> HandlerCallback`) that pairs a resolved handler with a closure that knows how to invoke it. Materialized by `NotificationHandlerWrapperImpl<T>`. Passed to `INotificationPublisher.Publish`.

**ObjectDetails**  
Internal `IComparer<ObjectDetails>` implementation used by `HandlersOrderer` to sort handlers by assembly / namespace / location.

**OpenBehavior**  
Value object (`AN.MediatR.Entities.OpenBehavior`) used by `cfg.AddOpenBehaviors(IEnumerable<OpenBehavior>)` to register an open-generic behavior with an explicit `ServiceLifetime`.

**Open generic**  
A generic type definition (`LoggingBehavior<,>`) as opposed to a closed generic (`LoggingBehavior<CreateOrder, int>`).

**Pipeline**  
The composed chain of `IPipelineBehavior<TRequest, TResponse>` wrappers + the final handler. Built by `RequestHandlerWrapperImpl` with `Reverse().Aggregate(...)`.

**Post-processor**  
Implementation of `IRequestPostProcessor<TRequest, TResponse>`. Runs **after** the handler, receives request and response, returns `Task`. Cannot replace the response.

**Pre-processor**  
Implementation of `IRequestPreProcessor<TRequest>`. Runs **before** the handler, receives request, returns `Task`. Cannot short-circuit.

**Publisher**  
See **INotificationPublisher**.

**Query**  
In CQRS, a request that returns data without mutating state. `IRequest<TResponse>` in AN.MediatR.

**Request**  
Single-handler message dispatched via `ISender.Send(...)`. Either `IRequest` (void) or `IRequest<TResponse>`.

**RequestExceptionActionProcessorBehavior**  
Internal behavior that invokes `IRequestExceptionAction<TRequest, TException>` instances on exception and rethrows.

**RequestExceptionProcessorBehavior**  
Internal behavior that invokes `IRequestExceptionHandler<TRequest, TResponse, TException>` instances on exception, allowing recovery.

**RequestExceptionHandlerState&lt;TResponse&gt;**  
Mutable state object passed to exception handlers. `SetHandled(response)` recovers the request.

**RequestExceptionActionProcessorStrategy**  
Enum controlling whether actions run **only for unhandled exceptions** (default) or **for all exceptions** (including recovered ones).

**RequestHandlerDelegate&lt;TResponse&gt;**  
`delegate Task<TResponse> RequestHandlerDelegate<TResponse>(CancellationToken t = default)`. The "next step in the pipeline" callback.

**RequestHandlerWrapper**  
Abstract type-erasure wrapper over `IRequestHandler<,>`. See [Wrappers and Internals](12%20-%20Wrappers_and_Internals.md).

**ServiceRegistrar**  
Static class (`AN.MediatR.Registration.ServiceRegistrar`) that performs the assembly scanning and registers services into an `IServiceCollection`. The heart of `AddMediatR`.

**Short-circuit**  
A pipeline behavior choosing **not** to call `next`, returning a response directly instead. Used for caching, authorization, feature flags, idempotency.

**Stream**  
A request/response pattern where the response is `IAsyncEnumerable<TResponse>`. Handled by `IStreamRequestHandler`, composed by `IStreamPipelineBehavior`.

**StreamHandlerDelegate&lt;TResponse&gt;**  
`delegate IAsyncEnumerable<TResponse> StreamHandlerDelegate<out TResponse>()`. Stream equivalent of `RequestHandlerDelegate`.

**TaskWhenAllPublisher**  
Built-in `INotificationPublisher` that starts every handler concurrently and awaits `Task.WhenAll`.

**Type erasure**  
Technique of converting a generic interface (`IRequestHandler<TRequest, TResponse>`) into a non-generic base class so instances can share a common cache. Implemented by the wrapper hierarchy in `AN.MediatR.Wrappers`.

**TypeForwardings**  
CLR mechanism that lets one assembly "redirect" a type lookup to another. Used by `MediatR.dll` to forward `IRequest`, `INotification`, `Unit`, etc. to `MediatR.Contracts.dll`.

**Unit**  
Singleton value type (`MediatR.Unit`) used as a stand-in for `void` in generic contexts. `Unit.Value` is the singleton; `Unit.Task` is a preallocated `Task<Unit>`.

**Wrapper**  
Any of the internal classes in `AN.MediatR.Wrappers` that translate a generic handler call into a type-erased virtual call. See **Type erasure**.
