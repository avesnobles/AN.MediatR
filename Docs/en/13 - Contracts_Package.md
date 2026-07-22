# Contracts Package

`AN.MediatR.Contracts` is a separate, dependency-free NuGet package that contains just the marker interfaces every request / notification / stream-request type needs. This chapter explains what's in it, why it's split out, and how `TypeForwardings.cs` keeps everything binary-compatible.

---

## What's inside

Source: [src/AN.MediatR.Contracts/](../../src/AN.MediatR.Contracts/).

```
src/AN.MediatR.Contracts/
├── INotification.cs      # public interface INotification { }
├── IRequest.cs           # IBaseRequest, IRequest, IRequest<TResponse>
├── IStreamRequest.cs     # public interface IStreamRequest<out TResponse> { }
├── Unit.cs               # void-substitute value type
└── MediatR.Contracts.csproj
```

And that is **the entire package**. Five source files. No implementation — just markers and one value type.

### csproj summary

```xml
<PropertyGroup>
  <TargetFramework>netstandard2.0</TargetFramework>
  <MinVerTagPrefix>v</MinVerTagPrefix>
  <PackageLicenseExpression>Apache-2.0</PackageLicenseExpression>
  <RootNamespace>MediatR</RootNamespace>
  <!-- SignAssembly, strong-named with AN.MediatR.snk -->
</PropertyGroup>
```

- **Only netstandard2.0**. Since the package has no logic, one target framework is enough and keeps it reachable from every modern and legacy .NET runtime.
- **Apache-2.0 license**. Both packages are Apache-2.0 in AN.MediatR; historically the contracts package was split so that request/notification types could be placed in contract-only libraries without any licensing friction. In v13+ upstream the main package switched to RPL-1.5 / commercial, making the separation critical — AN.MediatR keeps the same split for consistency and so that contract-only libraries stay ultra-lean (no DI / no MinVer / tiny dependency graph).
- **Versioning**: `MinVer` with tag prefix `v`, like the main and Autofac package projects.
- **Namespace `MediatR`** — same namespace as the main library, so consumers only ever write `using AN.MediatR;` regardless of which package defines a given type.

---

## Why a separate package

### 1. Slimmer dependency graph for contract-only projects

`AN.MediatR.Contracts` has **zero** runtime dependencies; `AN.MediatR` depends on `AN.MediatR.Contracts` plus `Microsoft.Extensions.DependencyInjection.Abstractions`. Libraries that only need to declare `IRequest` / `INotification` types (API contracts, gRPC contracts, Blazor WASM clients) can reference the smaller package and ship fewer transitive assemblies.

### 2. API-contract projects

It's common to have a dedicated project for API contracts (e.g. `MyApp.Contracts`) referenced by both the server implementation and several clients (Blazor, gRPC-net, worker services, etc.). Those clients don't need the mediator — they only need the types to serialize / deserialize.

```
MyApp.Api       → references MediatR + MyApp.Contracts (has handlers, uses the mediator)
MyApp.Contracts → references MediatR.Contracts          (just defines IRequest types)
MyApp.Client    → references MyApp.Contracts             (sends requests via HTTP/gRPC)
```

### 3. Blazor WebAssembly / client-only scenarios

From the README:

> This package is useful in scenarios where your MediatR contracts are in a separate assembly/project from handlers. Example scenarios include:
> - API contracts
> - gRPC contracts
> - Blazor

A Blazor WASM app often wants to share DTOs with the server but doesn't host a mediator itself. Pulling only `AN.MediatR.Contracts` keeps the WASM payload minimal.

### 4. Clean separation of concerns

Markers + data model go in `AN.MediatR.Contracts`. Dispatch mechanics + pipeline + DI + licensing go in `MediatR`. The split follows the natural seam.

---

## How both packages coexist: `TypeForwardings`

Source: [src/AN.MediatR/TypeForwardings.cs](../../src/AN.MediatR/TypeForwardings.cs).

```csharp
using System.Runtime.CompilerServices;
using AN.MediatR;

[assembly: TypeForwardedTo(typeof(IBaseRequest))]
[assembly: TypeForwardedTo(typeof(IRequest<>))]
[assembly: TypeForwardedTo(typeof(IRequest))]
[assembly: TypeForwardedTo(typeof(INotification))]
[assembly: TypeForwardedTo(typeof(Unit))]
```

`TypeForwardedTo` instructs the CLR type resolver: *"if someone looks up `MediatR.IRequest` in the `MediatR` assembly, forward them to the actual definition in `AN.MediatR.Contracts`."*

### Why this matters

Without type forwarding, you'd have two problems:

1. **Duplicate definitions**. If `MediatR.IRequest` existed in both `MediatR.Contracts.dll` and `MediatR.dll`, any code referencing both would get ambiguous-reference errors. Worse, the CLR would treat them as two different types even though they have the same namespace and name.
2. **Binary compatibility break**. Existing consumers compiled against an older `MediatR` that defined `IRequest` locally would break when upgrading to a version that moved `IRequest` into a separate contracts assembly.

Type forwarding solves both: the definitions physically live in one place (`AN.MediatR.Contracts`), and the `MediatR` assembly advertises "I still vend these types — just ask and I'll redirect you."

This means:

- You can reference either package and `MediatR.IRequest` always refers to the same CLR type.
- Assemblies compiled against old versions of `MediatR` continue to load correctly.

---

## `Unit` in depth

The `Unit` value type is the most substantial member of the contracts package.

Source: [src/AN.MediatR.Contracts/Unit.cs](../../src/AN.MediatR.Contracts/Unit.cs).

```csharp
public readonly struct Unit : IEquatable<Unit>, IComparable<Unit>, IComparable
{
    private static readonly Unit _value = new();

    public static ref readonly Unit Value => ref _value;
    public static Task<Unit> Task { get; } = System.Threading.Tasks.Task.FromResult(_value);

    public int CompareTo(Unit other) => 0;
    int IComparable.CompareTo(object? obj) => 0;

    public override int GetHashCode() => 0;
    public bool Equals(Unit other) => true;
    public override bool Equals(object? obj) => obj is Unit;

    public static bool operator ==(Unit first, Unit second) => true;
    public static bool operator !=(Unit first, Unit second) => false;

    public override string ToString() => "()";
}
```

### Key properties

- **`readonly struct`** — zero-sized value type, no allocation cost.
- **`static ref readonly Unit Value`** — exposes a reference to a shared singleton, so callers can pass it around without implicitly copying.
- **`static Task<Unit> Task`** — preallocated `Task.FromResult(Unit.Value)`, useful as a cheap "done" completion.
- **Equality semantics** — every `Unit` is equal to every other `Unit`. `GetHashCode()` always returns `0`. `CompareTo` always returns `0`.
- **`ToString() => "()"`** — so logs / debuggers show `()` for void responses.

### How the library uses it

- Void requests (`IRequest`) are internally unified with typed requests by using `Unit` as their response:
    - `RequestHandlerWrapperImpl<TRequest>.Handle(...)` returns `Task<Unit>`.
    - Pipeline behaviors registered for void requests have service type `IPipelineBehavior<TRequest, Unit>`.
- In your application code you rarely type `Unit` — the `Mediator.Send<TRequest>(TRequest)` overload already returns `Task`, not `Task<Unit>`, hiding `Unit` from callers.

### `Unit.Task` as a nice-to-have

When you implement a synchronous handler that must conform to `Task<Unit>`, you can return `Unit.Task` directly:

```csharp
public class LogPingHandler : IRequestHandler<Ping, Unit>   // explicit Unit for illustration
{
    public Task<Unit> Handle(Ping request, CancellationToken ct)
    {
        Console.WriteLine(request.Message);
        return Unit.Task;
    }
}
```

— saves one allocation vs. `Task.FromResult(Unit.Value)`.

---

## Stability contract

Because `AN.MediatR.Contracts` is a public API exposed to many downstream libraries, its version is calculated by MinVer from the same release tag as the main package:

```xml
<ProjectReference Include="..\AN.MediatR.Contracts\AN.MediatR.Contracts.csproj" />
```

`Publish.ps1` verifies that the package and symbol versions generated for all three projects match the release tag before copying them to the feed.

---

## When to depend on which package

| Scenario | Depend on |
|----------|-----------|
| You're hosting the mediator (server, worker, desktop app) | `MediatR` |
| You're defining request / notification types in a contract-only library | `AN.MediatR.Contracts` |
| You're writing a Blazor WASM client that just dispatches HTTP calls with typed requests | `AN.MediatR.Contracts` |
| You're writing a gRPC contract project | `AN.MediatR.Contracts` |
| You're writing pipeline behaviors or handlers | `MediatR` |
| You're building a client that will *resolve* `IMediator` (even if it proxies to HTTP) | `MediatR` |

Rule of thumb: *if you call `.Send(...)` or `.Publish(...)` you need `MediatR`; if you only declare types, `AN.MediatR.Contracts` is enough.*

---

## The full public type list (both packages combined)

Namespace `MediatR`:

- From `AN.MediatR.Contracts`: `IBaseRequest`, `IRequest`, `IRequest<TResponse>`, `IStreamRequest<TResponse>`, `INotification`, `Unit`.
- From `MediatR`: `IMediator`, `ISender`, `IPublisher`, `IRequestHandler<TRequest, TResponse>`, `IRequestHandler<TRequest>`, `NotificationHandler<TNotification>`, `INotificationHandler<TNotification>`, `IStreamRequestHandler<TRequest, TResponse>`, `IPipelineBehavior<TRequest, TResponse>`, `IStreamPipelineBehavior<TRequest, TResponse>`, `RequestHandlerDelegate<TResponse>`, `StreamHandlerDelegate<TResponse>`, `INotificationPublisher`, `NotificationHandlerExecutor`, `Mediator`.

Namespace `AN.MediatR.Pipeline`: processors and exception handlers.

Namespace `AN.MediatR.NotificationPublishers`: the two built-in publishers.

Namespace `AN.MediatR.Entities`: `OpenBehavior`.

Namespace `Microsoft.Extensions.DependencyInjection`: `AddMediatR`, `MediatRServiceConfiguration`, `RequestExceptionActionProcessorStrategy`.
