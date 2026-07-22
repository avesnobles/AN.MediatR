# Interfaces Principales

Este documento es la **referencia de la API** de todos los tipos públicos en AN.MediatR. Úsalo como tabla de consulta; para contexto conceptual ver [Conceptos Fundamentales](03%20-%20Conceptos_Fundamentales.md).

Todos los tipos viven en el namespace `AN.MediatR` salvo indicación contraria.

---

## Interfaces marcador (de `AN.MediatR.Contracts`)

### `IBaseRequest`

```csharp
public interface IBaseRequest { }
```

Usado como restricción genérica cuando necesitas aceptar "cualquier tipo de request" (sea void o con respuesta). Rara vez se implementa directamente — implementa `IRequest` o `IRequest<TResponse>` en su lugar.

### `IRequest`

```csharp
public interface IRequest : IBaseRequest { }
```

Interfaz marcador para un request sin respuesta (un "comando" en CQRS).

### `IRequest<TResponse>`

```csharp
public interface IRequest<out TResponse> : IBaseRequest { }
```

Interfaz marcador para un request que devuelve `TResponse`. `TResponse` es covariante (`out`), así que `IRequest<Derivado>` es asignable a `IRequest<Base>`.

### `IStreamRequest<TResponse>`

```csharp
public interface IStreamRequest<out TResponse> { }
```

Interfaz marcador para un request que devuelve `IAsyncEnumerable<TResponse>`. Covariante en `TResponse`.

### `INotification`

```csharp
public interface INotification { }
```

Interfaz marcador para una notificación (un evento). Los implementadores se despachan a cero, uno o varios `INotificationHandler<TNotification>`.

### `Unit`

```csharp
public readonly struct Unit : IEquatable<Unit>, IComparable<Unit>, IComparable
{
    public static ref readonly Unit Value { get; }
    public static Task<Unit> Task { get; }
    // CompareTo -> 0, Equals -> true, GetHashCode -> 0, ToString -> "()"
}
```

Tipo de valor sustituto de void. Dos helpers útiles:

- `Unit.Value` — el valor singleton.
- `Unit.Task` — un `Task.FromResult(Unit.Value)` preasignado.

Usado internamente como tipo de respuesta para `IRequest` (void) en el pipeline, de forma que `IPipelineBehavior<TRequest, Unit>` aplica uniformemente. En código de aplicación, generalmente no usas `Unit` directamente.

---

## Superficie del mediator

### `ISender`

Fuente: [src/AN.MediatR/ISender.cs](../../src/AN.MediatR/ISender.cs).

```csharp
public interface ISender
{
    Task<TResponse> Send<TResponse>(IRequest<TResponse> request, CancellationToken ct = default);

    Task Send<TRequest>(TRequest request, CancellationToken ct = default)
        where TRequest : IRequest;

    Task<object?> Send(object request, CancellationToken ct = default);

    IAsyncEnumerable<TResponse> CreateStream<TResponse>(
        IStreamRequest<TResponse> request, CancellationToken ct = default);

    IAsyncEnumerable<object?> CreateStream(object request, CancellationToken ct = default);
}
```

Despachador de requests. Tres sobrecargas de `Send`:

- **Tipado con respuesta** — elige el handler que devuelve `TResponse`.
- **Tipado void** — con restricción `IRequest`, devuelve `Task`.
- **Dinámico** — introspecta el tipo en runtime buscando `IRequest<T>` / `IRequest`.

Dos sobrecargas de `CreateStream` reflejan el mismo patrón para stream requests.

### `IPublisher`

Fuente: [src/AN.MediatR/IPublisher.cs](../../src/AN.MediatR/IPublisher.cs).

```csharp
public interface IPublisher
{
    Task Publish(object notification, CancellationToken ct = default);

    Task Publish<TNotification>(TNotification notification, CancellationToken ct = default)
        where TNotification : INotification;
}
```

Despachador de notificaciones. Dos sobrecargas de `Publish` — tipada y dinámica.

### `IMediator`

Fuente: [src/AN.MediatR/IMediator.cs](../../src/AN.MediatR/IMediator.cs).

```csharp
public interface IMediator : ISender, IPublisher { }
```

Interfaz combinada. Expuesta por el contenedor DI (con `ISender` e `IPublisher` resolviendo a la misma instancia de `IMediator` — ver [Inyección de Dependencias](11%20-%20Inyeccion_de_Dependencias.md)).

---

## Interfaces de handlers

### `IRequestHandler<TRequest, TResponse>`

Fuente: [src/AN.MediatR/IRequestHandler.cs](../../src/AN.MediatR/IRequestHandler.cs).

```csharp
public interface IRequestHandler<in TRequest, TResponse>
    where TRequest : IRequest<TResponse>
{
    Task<TResponse> Handle(TRequest request, CancellationToken cancellationToken);
}
```

Implementa esto para cada `IRequest<TResponse>` que definas. Se espera exactamente una implementación por tipo de request; el contenedor DI la resuelve con `GetRequiredService<IRequestHandler<TRequest, TResponse>>()`.

### `IRequestHandler<TRequest>`

```csharp
public interface IRequestHandler<in TRequest>
    where TRequest : IRequest
{
    Task Handle(TRequest request, CancellationToken cancellationToken);
}
```

Variante void. Internamente se envuelve para devolver `Task<Unit>` manteniendo el pipeline uniforme.

### `INotificationHandler<TNotification>`

Fuente: [src/AN.MediatR/INotificationHandler.cs](../../src/AN.MediatR/INotificationHandler.cs).

```csharp
public interface INotificationHandler<in TNotification>
    where TNotification : INotification
{
    Task Handle(TNotification notification, CancellationToken cancellationToken);
}
```

Se implementa una vez por cada par `(TNotification, clase-de-handler)`. Se permiten varios handlers por notificación — esa es la idea.

### `NotificationHandler<TNotification>` (clase base abstracta)

```csharp
public abstract class NotificationHandler<TNotification> : INotificationHandler<TNotification>
    where TNotification : INotification
{
    Task INotificationHandler<TNotification>.Handle(TNotification notification, CancellationToken ct)
    {
        Handle(notification);
        return Task.CompletedTask;
    }

    protected abstract void Handle(TNotification notification);
}
```

Clase base conveniente cuando tu handler es síncrono. La envoltura `Task` se hace automáticamente.

### `IStreamRequestHandler<TRequest, TResponse>`

Fuente: [src/AN.MediatR/IStreamRequestHandler.cs](../../src/AN.MediatR/IStreamRequestHandler.cs).

```csharp
public interface IStreamRequestHandler<in TRequest, out TResponse>
    where TRequest : IStreamRequest<TResponse>
{
    IAsyncEnumerable<TResponse> Handle(TRequest request, CancellationToken cancellationToken);
}
```

Implementa para mensajes `IStreamRequest<TResponse>`. Usa `async IAsyncEnumerable<TResponse>` con `[EnumeratorCancellation]` en el parámetro `CancellationToken`.

---

## Interfaces del pipeline

### `RequestHandlerDelegate<TResponse>`

```csharp
public delegate Task<TResponse> RequestHandlerDelegate<TResponse>(CancellationToken t = default);
```

El delegate "llamar al siguiente paso del pipeline" entregado a cada `IPipelineBehavior`. El parámetro opcional `CancellationToken` permite a un behavior propagar un token alternativo aguas abajo (pasa `default` para mantener el original).

### `IPipelineBehavior<TRequest, TResponse>`

Fuente: [src/AN.MediatR/IPipelineBehavior.cs](../../src/AN.MediatR/IPipelineBehavior.cs).

```csharp
public interface IPipelineBehavior<in TRequest, TResponse> where TRequest : notnull
{
    Task<TResponse> Handle(
        TRequest request,
        RequestHandlerDelegate<TResponse> next,
        CancellationToken cancellationToken);
}
```

Implementa para añadir comportamiento transversal alrededor del handler. Puede cortocircuitar saltándose `next()`, devolver una respuesta distinta, envolver la llamada en try/catch, iniciar una actividad de tracing, etc.

### `StreamHandlerDelegate<TResponse>`

```csharp
public delegate IAsyncEnumerable<TResponse> StreamHandlerDelegate<out TResponse>();
```

Equivalente para streams de `RequestHandlerDelegate`.

### `IStreamPipelineBehavior<TRequest, TResponse>`

Fuente: [src/AN.MediatR/IStreamPipelineBehavior.cs](../../src/AN.MediatR/IStreamPipelineBehavior.cs).

```csharp
public interface IStreamPipelineBehavior<in TRequest, TResponse> where TRequest : notnull
{
    IAsyncEnumerable<TResponse> Handle(
        TRequest request,
        StreamHandlerDelegate<TResponse> next,
        CancellationToken cancellationToken);
}
```

Versión streaming de `IPipelineBehavior`. Se compone iterando `await foreach` sobre `next()` y usando `yield return`.

---

## Interfaces de procesadores (namespace `AN.MediatR.Pipeline`)

### `IRequestPreProcessor<TRequest>`

```csharp
public interface IRequestPreProcessor<in TRequest> where TRequest : notnull
{
    Task Process(TRequest request, CancellationToken cancellationToken);
}
```

Ejecuta código antes del handler. Se permiten varios procesadores pre por request (se ejecutan en orden de resolución DI).

### `IRequestPostProcessor<TRequest, TResponse>`

```csharp
public interface IRequestPostProcessor<in TRequest, in TResponse> where TRequest : notnull
{
    Task Process(TRequest request, TResponse response, CancellationToken cancellationToken);
}
```

Ejecuta código después del handler, con acceso a la respuesta. La respuesta se puede inspeccionar pero no reemplazar (usa un pipeline behavior para eso).

### `IRequestExceptionAction<TRequest, TException>`

```csharp
public interface IRequestExceptionAction<in TRequest, in TException>
    where TRequest : notnull
    where TException : Exception
{
    Task Execute(TRequest request, TException exception, CancellationToken cancellationToken);
}
```

"Reactores" de excepciones de fuego-y-observa. Se ejecutan cuando el handler lanza `TException` (o subclase). **Siempre relanzan** — úsalos para logging/métricas, no para recuperación.

### `IRequestExceptionHandler<TRequest, TResponse, TException>`

```csharp
public interface IRequestExceptionHandler<in TRequest, TResponse, in TException>
    where TRequest : notnull
    where TException : Exception
{
    Task Handle(
        TRequest request,
        TException exception,
        RequestExceptionHandlerState<TResponse> state,
        CancellationToken cancellationToken);
}
```

Recuperadores de excepciones. Llama a `state.SetHandled(response)` para suprimir la excepción y devolver `response`. Si ningún handler pone `Handled`, la excepción original se relanza.

### `RequestExceptionHandlerState<TResponse>`

```csharp
public class RequestExceptionHandlerState<TResponse>
{
    public bool Handled { get; private set; }
    public TResponse? Response { get; private set; }
    public void SetHandled(TResponse response) { Handled = true; Response = response; }
}
```

Objeto de estado mutable pasado a los handlers de excepciones. Solo un handler necesita llamar a `SetHandled` para tragarse la excepción.

---

## Contrato del publisher

### `INotificationPublisher`

Fuente: [src/AN.MediatR/INotificationPublisher.cs](../../src/AN.MediatR/INotificationPublisher.cs).

```csharp
public interface INotificationPublisher
{
    Task Publish(
        IEnumerable<NotificationHandlerExecutor> handlerExecutors,
        INotification notification,
        CancellationToken cancellationToken);
}
```

Interfaz de estrategia que decide **cómo** se invocan los handlers de notificaciones (secuencial, paralelo, con agregación de errores, etc.). Ver [Publicadores de Notificaciones](09%20-%20Publicadores_Notificaciones.md).

### `NotificationHandlerExecutor`

Fuente: [src/AN.MediatR/NotificationHandlerExecutor.cs](../../src/AN.MediatR/NotificationHandlerExecutor.cs).

```csharp
public record NotificationHandlerExecutor(
    object HandlerInstance,
    Func<INotification, CancellationToken, Task> HandlerCallback);
```

Objeto de valor que empareja una instancia de handler con un closure que sabe cómo llamarlo con una `INotification` con tipo borrado. Los publishers iteran una secuencia de estos para invocar handlers.

---

## Entidad de registro

### `OpenBehavior` (namespace `AN.MediatR.Entities`)

Fuente: [src/AN.MediatR/Entities/OpenBehavior.cs](../../src/AN.MediatR/Entities/OpenBehavior.cs).

```csharp
public class OpenBehavior
{
    public OpenBehavior(Type openBehaviorType, ServiceLifetime serviceLifetime = ServiceLifetime.Transient);
    public Type OpenBehaviorType { get; }
    public ServiceLifetime ServiceLifetime { get; }
}
```

Objeto de valor usado con `AddOpenBehaviors(IEnumerable<OpenBehavior>)` para registrar varios comportamientos de genéricos abiertos con lifetimes explícitos. El constructor valida que el tipo implemente `IPipelineBehavior<,>`.

---

## Tipos de configuración DI (namespace `Microsoft.Extensions.DependencyInjection`)

### `MediatRServiceConfiguration`

Fuente: [src/AN.MediatR/MicrosoftExtensionsDI/MediatrServiceConfiguration.cs](../../src/AN.MediatR/MicrosoftExtensionsDI/MediatrServiceConfiguration.cs).

Objeto de configuración fluida pasado al delegate `AddMediatR(cfg => ...)`. Propiedades principales:

| Propiedad | Por defecto | Propósito |
|-----------|-------------|-----------|
| `TypeEvaluator` | `t => true` | Filtro aplicado a cada tipo candidato durante el escaneo |
| `MediatorImplementationType` | `typeof(Mediator)` | Subclase a registrar para `IMediator` |
| `NotificationPublisher` | `new ForeachAwaitPublisher()` | Instancia por defecto |
| `NotificationPublisherType` | `null` | Si se define, se resuelve del contenedor; precede a `NotificationPublisher` |
| `Lifetime` | `Transient` | Lifetime para `IMediator`, `ISender`, `IPublisher` |
| `RequestExceptionActionProcessorStrategy` | `ApplyForUnhandledExceptions` | Orden de actions vs. handlers de excepciones |
| `AutoRegisterRequestProcessors` | `false` | Escaneo automático de `IRequestPreProcessor` / `IRequestPostProcessor` |
| `MaxGenericTypeParameters` | `10` | Límite de parámetros genéricos por handler |
| `MaxTypesClosing` | `100` | Tipos máximos que pueden cerrar una restricción |
| `MaxGenericTypeRegistrations` | `125000` | Combinaciones totales máximas |
| `RegistrationTimeout` | `15000` ms | Timeout del proceso de registro |
| `RegisterGenericHandlers` | `false` | Si se deben registrar handlers con parámetros genéricos |

Métodos de registro (encadenables — cada uno retorna `this`):

- `RegisterServicesFromAssembly(Assembly)` — añade un ensamblado a escanear.
- `RegisterServicesFromAssemblies(params Assembly[])` — añade varios.
- `RegisterServicesFromAssemblyContaining<T>()` / `(Type)` — atajo mediante tipo marcador.
- `AddBehavior<T>()` / `AddBehavior<TService, TImpl>()` / `AddBehavior(Type)` / `AddBehavior(Type, Type)` — registra comportamientos cerrados.
- `AddOpenBehavior(Type)` / `AddOpenBehaviors(IEnumerable<Type>)` / `AddOpenBehaviors(IEnumerable<OpenBehavior>)` — registra comportamientos de genéricos abiertos.
- `AddStreamBehavior<T>()` / `AddStreamBehavior<TService, TImpl>()` / `AddStreamBehavior(Type)` / `AddStreamBehavior(Type, Type)` / `AddOpenStreamBehavior(Type)` — equivalentes para streams.
- `AddRequestPreProcessor<T>()` / `AddRequestPreProcessor<TService, TImpl>()` / `AddRequestPreProcessor(Type)` / `AddRequestPreProcessor(Type, Type)` / `AddOpenRequestPreProcessor(Type)`.
- `AddRequestPostProcessor<T>()` / `AddRequestPostProcessor<TService, TImpl>()` / `AddRequestPostProcessor(Type)` / `AddRequestPostProcessor(Type, Type)` / `AddOpenRequestPostProcessor(Type)`.

### `RequestExceptionActionProcessorStrategy`

```csharp
public enum RequestExceptionActionProcessorStrategy
{
    ApplyForUnhandledExceptions,   // actions solo si ningún handler gestionó
    ApplyForAllExceptions           // actions siempre
}
```

Controla el orden de registro de `RequestExceptionActionProcessorBehavior<,>` frente a `RequestExceptionProcessorBehavior<,>` — ver [Gestión de Excepciones](08%20-%20Gestion_de_Excepciones.md).

### `ServiceCollectionExtensions`

Fuente: [src/AN.MediatR/MicrosoftExtensionsDI/ServiceCollectionExtensions.cs](../../src/AN.MediatR/MicrosoftExtensionsDI/ServiceCollectionExtensions.cs).

- `services.AddMediatR(Action<MediatRServiceConfiguration>)` — punto de entrada idiomático.
- `services.AddMediatR(MediatRServiceConfiguration)` — sobrecarga aceptando una configuración ya preparada.

---

## Tipos internos relevantes

Estos tipos son `internal`, pero entenderlos ayuda al depurar o extender. Ver [Wrappers e Internos](12%20-%20Wrappers_e_Internos.md).

- `AN.MediatR.Wrappers.RequestHandlerBase`, `RequestHandlerWrapper<TResponse>`, `RequestHandlerWrapper`, `RequestHandlerWrapperImpl<TRequest, TResponse>`, `RequestHandlerWrapperImpl<TRequest>`.
- `AN.MediatR.Wrappers.NotificationHandlerWrapper`, `NotificationHandlerWrapperImpl<TNotification>`.
- `AN.MediatR.Wrappers.StreamRequestHandlerBase`, `StreamRequestHandlerWrapper<TResponse>`, `StreamRequestHandlerWrapperImpl<TRequest, TResponse>`.
- `AN.MediatR.Internal.HandlersOrderer` — prioriza handlers de excepciones por proximidad de ensamblado/namespace.
- `AN.MediatR.Internal.ObjectDetails` — el `IComparer<ObjectDetails>` usado por `HandlersOrderer`.

---

## Tarjeta de referencia rápida

```csharp
// Despacho
Task<TResponse>             IMediator.Send<TResponse>(IRequest<TResponse>, CancellationToken)
Task                        IMediator.Send<TRequest>(TRequest, CancellationToken)       where TRequest : IRequest
Task<object?>               IMediator.Send(object, CancellationToken)
Task                        IMediator.Publish<TNotification>(TNotification, CancellationToken)
Task                        IMediator.Publish(object, CancellationToken)
IAsyncEnumerable<TResponse> IMediator.CreateStream<TResponse>(IStreamRequest<TResponse>, CancellationToken)
IAsyncEnumerable<object?>   IMediator.CreateStream(object, CancellationToken)

// Manejo
IRequestHandler<TRequest, TResponse>.Handle(TRequest, CancellationToken) : Task<TResponse>
IRequestHandler<TRequest>.Handle(TRequest, CancellationToken)            : Task
INotificationHandler<TNotification>.Handle(TNotification, CancellationToken) : Task
IStreamRequestHandler<TRequest, TResponse>.Handle(TRequest, CancellationToken) : IAsyncEnumerable<TResponse>

// Transversales
IPipelineBehavior<TRequest, TResponse>.Handle(TRequest, RequestHandlerDelegate<TResponse>, CancellationToken)
IStreamPipelineBehavior<TRequest, TResponse>.Handle(TRequest, StreamHandlerDelegate<TResponse>, CancellationToken)
IRequestPreProcessor<TRequest>.Process(TRequest, CancellationToken)
IRequestPostProcessor<TRequest, TResponse>.Process(TRequest, TResponse, CancellationToken)
IRequestExceptionAction<TRequest, TException>.Execute(TRequest, TException, CancellationToken)
IRequestExceptionHandler<TRequest, TResponse, TException>.Handle(TRequest, TException, RequestExceptionHandlerState<TResponse>, CancellationToken)
```
