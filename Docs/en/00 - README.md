# AN.MediatR Documentation

Welcome to the full documentation of **AN.MediatR**, a free and open-source fork of the well-known [MediatR](https://github.com/jbogard/MediatR) library originally created by **Jimmy Bogard**.

This fork is based on **MediatR v12.5** — the **last Apache-2.0 licensed** release before the upstream project moved to a commercial licensing model — and is maintained by the **Aves Nobles (AN)** team. From v12.5 onwards, AN.MediatR will diverge from the upstream `jbogard/MediatR` and evolve as an independent open-source library.

AN.MediatR is a **simple, unambitious mediator implementation for .NET**. It provides in-process messaging with zero external dependencies beyond `Microsoft.Extensions.DependencyInjection.Abstractions`, supporting request/response, commands, queries, notifications, events, and streaming — both synchronous and asynchronous — with intelligent dispatching via C# generic variance.

---

## Table of contents

| Document | Description |
|----------|-------------|
| [Architecture](01%20-%20Architecture.md) | Technology stack, target frameworks and high-level structure |
| [Project Structure](02%20-%20Project_Structure.md) | Solution layout, projects, dependencies and tooling |
| [Core Concepts](03%20-%20Core_Concepts.md) | Mediator pattern, CQRS, requests, notifications, streams |
| [Core Interfaces](04%20-%20Core_Interfaces.md) | `IMediator`, `ISender`, `IPublisher`, `IRequest`, `INotification`, handlers, `Unit` |
| [Mediator Implementation](05%20-%20Mediator_Implementation.md) | Internals of the `Mediator` class: caching, dispatching |
| [Pipeline Behaviors](06%20-%20Pipeline_Behaviors.md) | `IPipelineBehavior`, Reverse+Aggregate pipeline construction |
| [Processors](07%20-%20Processors.md) | Pre and post-processors, how they plug into the pipeline |
| [Exception Handling](08%20-%20Exception_Handling.md) | Exception handlers and actions, ordering, strategy |
| [Notification Publishers](09%20-%20Notification_Publishers.md) | `ForeachAwaitPublisher`, `TaskWhenAllPublisher`, custom publishers |
| [Streaming](10%20-%20Streaming.md) | `IStreamRequest`, `IStreamRequestHandler`, stream pipeline behaviors |
| [Dependency Injection](11%20-%20Dependency_Injection.md) | `AddMediatR`, `MediatRServiceConfiguration`, `ServiceRegistrar`, assembly scanning, generic limits |
| [Wrappers and Internals](12%20-%20Wrappers_and_Internals.md) | Type-erasure wrappers, `HandlersOrderer`, `ObjectDetails` |
| [Contracts Package](13%20-%20Contracts_Package.md) | `AN.MediatR.Contracts` NuGet package and `TypeForwardings` |
| [Usage Examples](14%20-%20Usage_Examples.md) | Typical scenarios with code: Ping/Pong, notifications, streams, exceptions |
| [DI Container Integration](15%20-%20DI_Container_Integration.md) | ASP.NET Core, Autofac, DryIoc, Lamar, LightInject, SimpleInjector, Stashbox, Windsor |
| [Build, Test & Publish](16%20-%20Build_Test_Publish.md) | `Build.ps1`, `BuildContracts.ps1`, `Push.ps1`, tests, benchmarks |
| [Best Practices & FAQ](17%20-%20Best_Practices_and_FAQ.md) | Patterns, anti-patterns, common questions |
| [Glossary](18%20-%20Glossary.md) | Glossary of terms used throughout the documentation |

---

## Recommended reading path

Depending on your role, prioritize different documents:

- **New application developer** (using MediatR in their app): 03 → 04 → 14 → 06 → 07 → 09 → 11 → 17
- **Library contributor / Maintainer**: 01 → 02 → 05 → 12 → 11 → 08 → 16
- **DevOps / Release engineer**: 02 → 16 → 13
- **Architect / CQRS lead**: 03 → 06 → 09 → 10 → 17

---

## High-level overview

AN.MediatR implements the **Mediator behavioral pattern**: callers talk to a single `IMediator` instance instead of resolving and invoking handlers directly. The mediator routes each message to the correct handler(s) through a **pipeline of cross-cutting behaviors** (logging, validation, caching, exception handling, etc.).

It supports three message kinds:

- **Requests** (`IRequest`, `IRequest<TResponse>`): one caller → exactly **one** handler. Can return a response (`IRequest<TResponse>`) or be void (`IRequest`).
- **Notifications** (`INotification`): one caller → **zero, one or many** handlers. No response.
- **Stream requests** (`IStreamRequest<TResponse>`): one caller → exactly **one** handler that returns `IAsyncEnumerable<TResponse>`. Used for streaming pipelines.

### Solution projects

| Project | Type | Description |
|---------|------|-------------|
| `src/MediatR` | Library (NuGet) | Core mediator, pipeline, DI extensions |
| `src/MediatR.Contracts` | Library (NuGet) | Minimal contracts: `IRequest`, `INotification`, `IStreamRequest`, `Unit` |
| `samples/AN.MediatR.Examples` | Sample | Ping/Pong, notifications, processors, exceptions |
| `samples/AN.MediatR.Examples.AspNetCore` | Sample | ASP.NET Core DI integration |
| `samples/AN.MediatR.Examples.PublishStrategies` | Sample | 6 notification publishing strategies |
| `samples/AN.MediatR.Examples.*` | Samples | Integration with Autofac, DryIoc, Lamar, LightInject, SimpleInjector, Stashbox, Windsor |
| `test/AN.MediatR.Tests` | xUnit | Core functionality + DI registration tests |
| `test/AN.MediatR.Benchmarks` | BenchmarkDotNet | Performance benchmarks |

---

## Licensing and upstream relationship

| Aspect | AN.MediatR (this fork) | jbogard/MediatR v12.5 (source) | jbogard/MediatR v13+ |
|--------|------------------------|--------------------------------|----------------------|
| License | **Apache-2.0** | Apache-2.0 | Dual RPL-1.5 / commercial, JWT licensing required |
| Runtime license check | ❌ None | ❌ None | ✅ JWT validation, warnings if missing |
| Maintainer | Aves Nobles (AN) | Jimmy Bogard (upstream state at v12.5) | Lucky Penny Software |
| Future direction | Independent open-source fork | N/A (upstream abandoned at this version) | Commercial product |

**Why we forked**: we wanted a mediator library with identical semantics to the MediatR most .NET developers know, but:
- staying fully open source (Apache-2.0);
- without a runtime licensing subsystem;
- free to evolve in the direction our projects need.

**Changes relative to stock v12.5** (cherry-picked from upstream v13+, licensing excluded):
- Notification handler **deduplication** at dispatch time — fixes #1118 where DI containers with contravariant notification-handler resolution (e.g. DryIoc) invoked the same handler twice for derived notifications.
- **Nested-generic pipeline behavior support** — `AddOpenBehavior(typeof(MyBehavior<,>))` now works correctly when `TResponse` is itself generic (e.g. `List<T>`, `Result<T>`).
- **F# assembly scanning resilience** — `ServiceRegistrar` catches `ReflectionTypeLoadException` and falls back to the loadable types, so F# assemblies (and other reflection-unfriendly assemblies) no longer crash `AddMediatR(...)`.
- **Target frameworks** bumped from `netstandard2.0;net6.0` to `netstandard2.0;net8.0;net9.0;net10.0` plus `net462` on Windows.
- `Microsoft.Extensions.DependencyInjection.Abstractions` and `Microsoft.Bcl.AsyncInterfaces` bumped to **v10.0.0**.
- `LangVersion` bumped to **C# 13**.

---

## How to read this documentation

1. Each section lives in its own Markdown file with a numeric prefix indicating reading order.
2. Cross-references use relative links and URL-encoded spaces (e.g. `01%20-%20Architecture.md`).
3. Code snippets use the exact names as they appear in the code. File paths follow the convention `src/AN.MediatR/...`.
4. A Spanish version of this documentation is available at [`Docs/es/`](../es/).

---

## Contributing to this documentation

- Keep each section in sync with the codebase — review after significant changes.
- Reference file paths when documenting implementation details (`src/AN.MediatR/Mediator.cs:42`).
- Do not duplicate information; link to the relevant section instead.
- Keep both language versions (`en` and `es`) aligned when adding or editing content.
