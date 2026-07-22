# Conceptos Fundamentales

Antes de profundizar en la API, asegúrate de entender los cuatro tipos de mensaje que AN.MediatR soporta, los tres roles que desempeña en tu aplicación y el modelo de pipeline que se interpone entre ambos.

---

## El patrón Mediator

AN.MediatR es una implementación del clásico patrón de comportamiento Mediator del libro de la Banda de los Cuatro:

> Define un objeto que encapsula cómo interactúan un conjunto de objetos. Mediator promueve un bajo acoplamiento al evitar que los objetos se referencien entre sí explícitamente.

En la práctica, los llamadores no referencian directamente a sus handlers. Publican mensajes a una única instancia `IMediator`, que sabe cómo resolver y ejecutar los handler(s) apropiados desde el contenedor DI.

**Por qué importa**:

- Controladores, background services y código de UI dependen de una sola abstracción (`IMediator`) en lugar de docenas de interfaces de handler.
- Las preocupaciones transversales (logging, validación, caching, transacciones, reintentos) se enchufan como **comportamientos de pipeline** sin tocar los handlers.
- Los handlers son de propósito único, fáciles de testear e independientes entre sí.

---

## Los tres roles: `ISender`, `IPublisher`, `IMediator`

Aunque `IMediator` es la cara pública, está dividido en dos interfaces más estrechas:

| Interfaz | Responsabilidad | Métodos |
|----------|-----------------|---------|
| `ISender` | Despacha un mensaje a exactamente **un** handler y devuelve un resultado | `Send<TResponse>`, `Send` (void), `Send(object)`, `CreateStream`, `CreateStream(object)` |
| `IPublisher` | Reparte una notificación a **cero o más** handlers | `Publish<TNotification>`, `Publish(object)` |
| `IMediator` | `ISender` + `IPublisher` | Todos los anteriores |

¿Por qué separarlas? Para que los llamadores declaren la dependencia más estrecha posible. Un handler de comando que solo levanta eventos pero nunca envía requests puede pedir `IPublisher`. Un controlador solo-lectura puede pedir `ISender`. Cada interfaz también facilita los mocks en tests.

---

## Los cuatro tipos de mensaje

AN.MediatR clasifica cada mensaje en uno de cuatro tipos. Cada uno tiene su propia interfaz marcador del paquete `AN.MediatR.Contracts`.

### 1. Request con respuesta — `IRequest<TResponse>`

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

- Se requiere **exactamente un** handler (`GetRequiredService` — DI lanza si no hay ninguno).
- Devuelve `Task<TResponse>`.
- Soporta dispatch dinámico vía `Send(object)` para escenarios donde el tipo solo se conoce en runtime.

### 2. Request sin respuesta — `IRequest`

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

- Misma cardinalidad que `IRequest<TResponse>`: **exactamente un** handler.
- Internamente la respuesta es `Unit` (`MediatR.Unit`), un tipo de valor singleton que sustituye `void`. Nunca lo ves en la firma de tu handler.

### 3. Notificación (evento) — `INotification`

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

- **Cero o más** handlers.
- Devuelve `Task` (sin respuesta).
- Los handlers se deduplican por tipo concreto antes del dispatch (si el mismo tipo de handler está registrado dos veces, solo se ejecuta la primera instancia).
- La estrategia de dispatch — secuencial vs. paralelo — la controla un `INotificationPublisher` (ver [Publicadores de Notificaciones](09%20-%20Publicadores_Notificaciones.md)).

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

- Exactamente un handler.
- Devuelve `IAsyncEnumerable<TResponse>` — perfecto para hubs de streaming de SignalR, endpoints server-streaming de gRPC, seguimiento de logs, procesamiento de datasets grandes en lotes, etc.
- Soporta su propio pipeline dedicado vía `IStreamPipelineBehavior<TRequest, TResponse>`.

---

## Command vs. Query vs. Event (CQRS)

AN.MediatR no impone terminología CQRS, pero el patrón mapea de forma natural:

| Rol CQRS | Tipo de AN.MediatR |
|----------|--------------------|
| **Query** — lee datos, devuelve algo | `IRequest<TResponse>` |
| **Command** — muta estado, típicamente sin retorno | `IRequest` (void) o `IRequest<TResponse>` (cuando necesitas el nuevo id, etc.) |
| **Evento de dominio / Evento de integración** | `INotification` |

Convención habitual: nombrar los requests con modo imperativo (`CreateOrder`) o interrogativo (`GetOrderById`), y las notificaciones en pasado (`OrderCreated`).

---

## El pipeline

Alrededor de cada handler de request, AN.MediatR construye un **pipeline** — una cadena de decoradores `IPipelineBehavior<TRequest, TResponse>`. Cada comportamiento recibe el request y un delegate `next`, puede ejecutar código antes y después de llamar a `next`, y puede cortocircuitar saltándose `next`.

```
Request ─► Behavior1 ─► Behavior2 ─► ... ─► BehaviorN ─► Handler
            │              │                 │            │
            │              │                 │            ▼
            │              │                 │          Respuesta
            ▼              ▼                 ▼
         envuelve         envuelve         envuelve
```

Conceptualmente es idéntico al middleware de ASP.NET Core, excepto que está tipado por parejas `(TRequest, TResponse)`. Ver [Comportamientos del Pipeline](06%20-%20Comportamientos_del_Pipeline.md) para la mecánica completa.

AN.MediatR provee cuatro decoradores built-in:

1. `RequestPreProcessorBehavior<,>` — ejecuta `IRequestPreProcessor<>` **antes** del handler.
2. `RequestPostProcessorBehavior<,>` — ejecuta `IRequestPostProcessor<,>` **después** del handler.
3. `RequestExceptionActionProcessorBehavior<,>` — ejecuta `IRequestExceptionAction<,>` cuando el handler lanza (siempre relanza).
4. `RequestExceptionProcessorBehavior<,>` — ejecuta `IRequestExceptionHandler<,,>`; si uno marca la excepción como gestionada, se devuelve esa respuesta.

Para streaming, existe una estructura paralela: `IStreamPipelineBehavior<TRequest, TResponse>`. Los procesadores pre/post/excepciones **no** están disponibles para streams.

---

## Resumen de cardinalidad de handlers

| Tipo de mensaje | Handlers requeridos | ¿Múltiples? | ¿Pipeline? | Retorna |
|-----------------|--------------------|-------------|------------|---------|
| `IRequest<TResponse>` | 1 | ❌ (lanza si hay varios) | `IPipelineBehavior<,>` | `Task<TResponse>` |
| `IRequest` | 1 | ❌ | `IPipelineBehavior<TRequest, Unit>` | `Task` |
| `INotification` | 0+ | ✅ | ❌ (sin pipeline) | `Task` |
| `IStreamRequest<TResponse>` | 1 | ❌ | `IStreamPipelineBehavior<,>` | `IAsyncEnumerable<TResponse>` |

> Nota: las notificaciones **no tienen** pipeline. Si necesitas comportamientos transversales alrededor de eventos, impleméntalos en un `INotificationPublisher` (estrategia custom) o en un servicio envoltorio.

---

## Modos de dispatch: tipado vs. dinámico

Cada método de envío viene en dos versiones:

```csharp
// Tipado (compile-time): el compilador elige la sobrecarga correcta
Pong pong = await mediator.Send(new Ping { Message = "hi" });

// Dinámico (runtime): el tipo solo se conoce en runtime, p.ej. vía reflexión
object response = await mediator.Send((object)pingInstance);
```

El dispatch dinámico es ligeramente más lento (usa `Type.GetInterfaces()` para descubrir `IRequest<T>`) pero es útil para código genérico de host, API gateways, tests y herramientas de introspección.

Mismo patrón para notificaciones (`Publish(object)`) y streams (`CreateStream(object)`).

---

## ¿Por qué `Unit` en lugar de `void`?

El `void` de C# no es un tipo de primera clase: `Task<void>` no es válido, y no puedes expresar "un método genérico que devuelve void" de forma uniforme con uno que devuelve un tipo concreto. AN.MediatR define el tipo de valor `Unit` como sustituto:

```csharp
public readonly struct Unit : IEquatable<Unit>, IComparable<Unit>, IComparable
{
    public static ref readonly Unit Value => ref _value;
    public static Task<Unit> Task { get; } = System.Threading.Tasks.Task.FromResult(_value);
    // Todas las instancias son iguales; GetHashCode() == 0; ToString() == "()"
}
```

Dondequiera que aparezca internamente un "request void", el tipo de respuesta es `Unit`. Esto mantiene el pipeline uniforme: un `IPipelineBehavior<TRequest, TResponse>` con `TResponse = Unit` maneja requests void exactamente igual que los demás.

---

## Modelo mental de resumen

- **Enviar un mensaje, recibir una respuesta** → `IRequest<TResponse>`.
- **Enviar un mensaje, sin respuesta** → `IRequest`.
- **Difundir un evento, cero o varios handlers** → `INotification`.
- **Enviar items a medida que están disponibles** → `IStreamRequest<TResponse>`.
- **Envolver comportamiento transversal alrededor de un handler** → `IPipelineBehavior<TRequest, TResponse>`.
- **Ejecutar código antes/después de un handler, o en excepción** → `IRequestPreProcessor`, `IRequestPostProcessor`, `IRequestExceptionHandler`, `IRequestExceptionAction`.
- **Elegir cómo se despachan las notificaciones** → `INotificationPublisher` (secuencial `ForeachAwaitPublisher` por defecto, paralelo `TaskWhenAllPublisher` opcional, o custom).
