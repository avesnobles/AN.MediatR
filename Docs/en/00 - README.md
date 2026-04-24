# AN.MediatR Documentation

Welcome to the full documentation of **AN.MediatR**, a fork of the well-known [MediatR](https://github.com/jbogard/MediatR) library originally created by **Jimmy Bogard** and currently maintained as a commercial product by **Lucky Penny Software** (the organization behind the **Aves Nobles** / **AN** ecosystem).

AN.MediatR is a **simple, unambitious mediator implementation for .NET**. It provides in-process messaging with zero external dependencies beyond `Microsoft.Extensions.DependencyInjection.Abstractions` and `Microsoft.Extensions.Logging.Abstractions`, supporting request/response, commands, queries, notifications, events, and streaming — both synchronous and asynchronous — with intelligent dispatching via C# generic variance.

This fork adds an **enterprise licensing system** (JWT-based) on top of the original open-source mediator, which is the key functional difference against the upstream `jbogard/MediatR`.

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
| [Licensing](13%20-%20Licensing.md) | Lucky Penny licensing system — JWT, editions, perpetual licenses |
| [Contracts Package](14%20-%20Contracts_Package.md) | `MediatR.Contracts` NuGet package and `TypeForwardings` |
| [Usage Examples](15%20-%20Usage_Examples.md) | Typical scenarios with code: Ping/Pong, notifications, streams, exceptions |
| [DI Container Integration](16%20-%20DI_Container_Integration.md) | ASP.NET Core, Autofac, DryIoc, Lamar, LightInject, SimpleInjector, Stashbox, Windsor |
| [Build, Test & Publish](17%20-%20Build_Test_Publish.md) | `Build.ps1`, `BuildContracts.ps1`, `Push.ps1`, tests, benchmarks, signing |
| [Best Practices & FAQ](18%20-%20Best_Practices_and_FAQ.md) | Patterns, anti-patterns, common questions |
| [Glossary](19%20-%20Glossary.md) | Glossary of terms used throughout the documentation |

---

## Recommended reading path

Depending on your role, prioritize different documents:

- **New application developer** (using MediatR in their app): 03 → 04 → 15 → 06 → 07 → 09 → 11 → 18
- **Library contributor / Maintainer**: 01 → 02 → 05 → 12 → 11 → 08 → 13 → 17
- **DevOps / Release engineer**: 02 → 17 → 13 → 14
- **Architect / CQRS lead**: 03 → 06 → 09 → 10 → 18
- **License administrator / Procurement**: 13 → 14 → 18

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
| `src/MediatR` | Library (NuGet) | Core mediator, pipeline, DI extensions, **licensing** |
| `src/MediatR.Contracts` | Library (NuGet) | Minimal contracts: `IRequest`, `INotification`, `IStreamRequest`, `Unit` |
| `samples/MediatR.Examples` | Sample | Ping/Pong, notifications, processors, exceptions |
| `samples/MediatR.Examples.AspNetCore` | Sample | ASP.NET Core DI integration |
| `samples/MediatR.Examples.PublishStrategies` | Sample | 6 notification publishing strategies |
| `samples/MediatR.Examples.*` | Samples | Integration with Autofac, DryIoc, Lamar, LightInject, SimpleInjector, Stashbox, Windsor |
| `test/MediatR.Tests` | xUnit | Core functionality tests |
| `test/MediatR.DependencyInjectionTests` | xUnit | DI/registration tests |
| `test/MediatR.Benchmarks` | BenchmarkDotNet | Performance benchmarks |

---

## Key differences vs. upstream MediatR

| Feature | jbogard/MediatR | AN.MediatR (LuckyPennySoftware) |
|---------|-----------------|---------------------------------|
| Core mediator API | Same | Same |
| Pipeline behaviors, processors, stream requests | Same | Same |
| License (source code) | Apache-2.0 (≤ v12) / Commercial (v13+) | RPL 1.5 or commercial |
| License key required at runtime | No | Yes (warning logged if missing) |
| JWT-based license validation | No | Yes (`LicenseAccessor`, `LicenseValidator`) |
| Perpetual license support | No | Yes (build date check) |
| `Mediator.LicenseKey` / `cfg.LicenseKey` | No | Yes |
| ILogger integration for licensing | No | Yes (`LuckyPennySoftware.MediatR.License` category) |

---

## How to read this documentation

1. Each section lives in its own Markdown file with a numeric prefix indicating reading order.
2. Cross-references use relative links and URL-encoded spaces (e.g. `01%20-%20Architecture.md`).
3. Code snippets use the exact names as they appear in the code. File paths follow the convention `src/MediatR/...`.
4. A Spanish version of this documentation is available at [`Docs/es/`](../es/).

---

## Contributing to this documentation

- Keep each section in sync with the codebase — review after significant changes.
- Reference file paths when documenting implementation details (`src/MediatR/Mediator.cs:42`).
- Do not duplicate information; link to the relevant section instead.
- Keep both language versions (`en` and `es`) aligned when adding or editing content.
