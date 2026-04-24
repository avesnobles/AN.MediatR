# Publicadores de Notificaciones

Las notificaciones son el mecanismo de fan-out de AN.MediatR: una única `INotification` se entrega a cero, uno o varios `INotificationHandler<TNotification>`. La **estrategia** que decide *cómo* se invocan esos handlers — ¿secuencialmente? ¿en paralelo? ¿con agregación de errores? — se encapsula en `INotificationPublisher`.

---

## El contrato

```csharp
public interface INotificationPublisher
{
    Task Publish(
        IEnumerable<NotificationHandlerExecutor> handlerExecutors,
        INotification notification,
        CancellationToken cancellationToken);
}
```

Fuente: [src/MediatR/INotificationPublisher.cs](../../src/MediatR/INotificationPublisher.cs).

El publisher recibe:

- Una secuencia ya construida de `NotificationHandlerExecutor` — cada uno es un record `(HandlerInstance, HandlerCallback)`.
- La notificación original (con tipo borrado a `INotification`).
- Un token de cancelación.

Su trabajo: manejar los callbacks como quiera y devolver un único `Task` que complete cuando "todos los handlers estén considerados listos".

```csharp
public record NotificationHandlerExecutor(
    object HandlerInstance,
    Func<INotification, CancellationToken, Task> HandlerCallback);
```

Fuente: [src/MediatR/NotificationHandlerExecutor.cs](../../src/MediatR/NotificationHandlerExecutor.cs).

---

## Cómo se construyen los executors

En `NotificationHandlerWrapperImpl<TNotification>.Handle(...)`:

```csharp
var handlers = serviceFactory
    .GetServices<INotificationHandler<TNotification>>()
    .GroupBy(static x => x.GetType())           // dedupe por tipo concreto de handler
    .Select(static g => g.First())              // elige la primera instancia de cada tipo
    .Select(static x => new NotificationHandlerExecutor(x,
        (theNotification, theToken) => x.Handle((TNotification)theNotification, theToken)));

return publish(handlers, notification, cancellationToken);
```

Fuente: [src/MediatR/Wrappers/NotificationHandlerWrapper.cs](../../src/MediatR/Wrappers/NotificationHandlerWrapper.cs).

Comportamientos importantes:

- **Deduplicación por tipo concreto**. Si el mismo tipo de handler se registró dos veces (p. ej. explícitamente **y** vía escaneo), solo se ejecuta una instancia por notificación.
- **Handlers capturados en closures** — el closure hace cast de `INotification` a `TNotification` antes de llamar a `Handle`. Añade un poco de seguridad de tipos a cambio de una asignación por publish.
- **El enumerable es perezoso** — el publisher decide cuándo (o si) lo enumera. Si un publisher hace `ToArray()` primero, las instancias de handler se materializan de una vez.

---

## Publishers built-in

### `ForeachAwaitPublisher` (por defecto)

Fuente: [src/MediatR/NotificationPublishers/ForeachAwaitPublisher.cs](../../src/MediatR/NotificationPublishers/ForeachAwaitPublisher.cs).

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

**Comportamiento**: secuencial, await-cada-uno, fail-fast.

- Los handlers corren **uno a la vez**, en orden de resolución DI.
- Si un handler lanza, los siguientes **no** se invocan y la excepción sube al llamador de `mediator.Publish(...)`.
- Garantiza orden y consistencia transaccional.
- Valor por defecto seguro para handlers que tocan estado compartido (BBDD, cachés, etc.).

### `TaskWhenAllPublisher`

Fuente: [src/MediatR/NotificationPublishers/TaskWhenAllPublisher.cs](../../src/MediatR/NotificationPublishers/TaskWhenAllPublisher.cs).

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

**Comportamiento**: arranque en paralelo, único await con `WhenAll`.

- Cada handler se invoca síncronamente en un bucle; si la porción síncrona inicial lanza, los demás handlers igualmente arrancan.
- Esperado con `Task.WhenAll`. Si **cualquiera** falla, el `Task` devuelto pasa a faulted con la **primera** excepción; las demás están en `Task.Exception.InnerExceptions`.
- Los handlers deben ser independientes y no sensibles al orden.
- Adecuado para eventos de integración fire-and-forget-ish donde el throughput importa más que el orden.

> Estrictamente los handlers no tienen por qué ejecutarse en paralelo — todos arrancan síncronamente y solo ceden en `await`. Pero una vez ceden, el resto corre en paralelo.

---

## Configurando el publisher

### Por instancia

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
    cfg.NotificationPublisher = new TaskWhenAllPublisher();
});
```

La instancia se registra como el singleton `INotificationPublisher`.

### Por tipo (resuelto por DI)

```csharp
services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssembly(typeof(Program).Assembly);
    cfg.NotificationPublisherType = typeof(MyCustomPublisher);
});
```

Cuando `NotificationPublisherType` está definido, prevalece sobre `NotificationPublisher`. AN.MediatR lo registra con el `Lifetime` de la configuración, dando acceso a servicios DI a tu publisher. Esta es la opción correcta cuando el publisher necesita `ILogger`, `IMetrics`, `IOptions<...>`, etc.

Dentro de `ServiceRegistrar.AddRequiredServices`:

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

## Publisher personalizado

Puede ser tan simple o complejo como necesites. Aquí varias recetas.

### 1. Continuar en excepciones (secuencial)

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

### 2. Completamente paralelo con `Task.Run`

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

> Advertencia: fire-and-forget descarta excepciones y puede correr contra el shutdown del host. Úsalo solo si tienes un mecanismo externo para observar fallos (p. ej. un pipeline de telemetría).

### 4. Con telemetría

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

## Varias estrategias a la vez

Si necesitas estrategias distintas por notificación:

1. **Subclasea `Mediator`** y sobrescribe `PublishCore`:

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

2. **Construye una fachada** como la de `samples/MediatR.Examples.PublishStrategies/Publisher.cs`. Crea un `CustomMediator` por estrategia y expone `Publish(notification, strategy)`. Ver el sample para seis estrategias (`Async`, `ParallelNoWait`, `ParallelWhenAll`, `ParallelWhenAny`, `SyncContinueOnException`, `SyncStopOnException`).

---

## ¡Las notificaciones no tienen pipeline!

A diferencia de los requests, las notificaciones **no** pasan por `IPipelineBehavior` ni procesadores pre/post/excepciones. Cualquier lógica transversal (logging, reintentos, telemetría) debe vivir en:

- Los propios handlers (acoplado), o
- Un `INotificationPublisher` personalizado (reusable), o
- Un decorador de `IPublisher` en tu aplicación (flexible).

Decisión deliberada: las notificaciones son eventos unidireccionales y best-effort. Si te ves queriendo un pipeline completo alrededor de notificaciones, probablemente quieras un comando.

---

## Elegir entre `ForeachAwait` y `TaskWhenAll`

| Pregunta | `ForeachAwait` | `TaskWhenAll` |
|----------|----------------|---------------|
| ¿Los handlers comparten estado / escriben en la misma fila? | ✅ Preferible (secuencial, predecible) | ❌ Problemas de concurrencia |
| ¿Cada handler llama a un servicio externo distinto? | Funciona | ✅ Preferible (paralelo = menor latencia) |
| ¿Necesitas side effects ordenados? | ✅ | ❌ |
| ¿Quieres ejecutar todo lo posible aunque uno falle? | ❌ (para) | Parcial (todos arrancan, falla al await) |
| Opción por defecto para un proyecto nuevo | ✅ Seguro | — |

En la duda, empieza con `ForeachAwaitPublisher` (el valor por defecto). Cambia solo si el perfil de rendimiento lo exige.

---

## Observando errores

Como `Publish` devuelve un único `Task`, cada publisher decide qué significa "completado":

- `ForeachAwaitPublisher` falla con la **primera** excepción y para.
- `TaskWhenAllPublisher` falla con `AggregateException` si alguno falló (pero `await` desempaqueta a la primera `InnerException`).
- Los publishers personalizados pueden recoger, agregar o tragar excepciones.

Documenta siempre la semántica de tus publishers — distintas políticas son válidas, pero sorpresivas.
