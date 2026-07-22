# Implementación del Mediator

Este documento recorre la clase `Mediator` — implementación por defecto de `IMediator` — de arriba abajo. Léelo si quieres entender **cómo** AN.MediatR despacha mensajes (no solo **qué** hace la API).

Archivo fuente: [src/AN.MediatR/Mediator.cs](../../src/AN.MediatR/Mediator.cs).

---

## Firma de la clase

```csharp
namespace AN.MediatR;

public class Mediator : IMediator
{
    private readonly IServiceProvider _serviceProvider;
    private readonly INotificationPublisher _publisher;

    private static readonly ConcurrentDictionary<Type, RequestHandlerBase> _requestHandlers = new();
    private static readonly ConcurrentDictionary<Type, NotificationHandlerWrapper> _notificationHandlers = new();
    private static readonly ConcurrentDictionary<Type, StreamRequestHandlerBase> _streamRequestHandlers = new();

    public Mediator(IServiceProvider serviceProvider)
        : this(serviceProvider, new ForeachAwaitPublisher()) { }

    public Mediator(IServiceProvider serviceProvider, INotificationPublisher publisher)
    {
        _serviceProvider = serviceProvider;
        _publisher = publisher;
    }
}
```

Dos cosas a destacar:

1. **Dos campos privados**: un `IServiceProvider` (para resolver handlers y comportamientos en cada llamada) y un `INotificationPublisher` (la estrategia para dispatch multi-handler).
2. **Tres diccionarios estáticos**: son las **cachés globales de wrappers**, compartidas entre todas las instancias de `Mediator` del proceso. La clave es el tipo **en runtime** de un mensaje; el valor es un wrapper cacheado que sabe cómo invocar handlers para ese tipo.

Los dos constructores forman una pequeña **cadena**: si no pasas `INotificationPublisher`, obtienes `ForeachAwaitPublisher` (ejecución secuencial de handlers). El constructor no realiza ningún otro trabajo — sin check de licencia, sin llamadas de red, sin logging.

---

## Las tres cachés estáticas

```csharp
private static readonly ConcurrentDictionary<Type, RequestHandlerBase> _requestHandlers = new();
private static readonly ConcurrentDictionary<Type, NotificationHandlerWrapper> _notificationHandlers = new();
private static readonly ConcurrentDictionary<Type, StreamRequestHandlerBase> _streamRequestHandlers = new();
```

Las cachés almacenan **wrappers**, no handlers. Ver [Wrappers e Internos](12%20-%20Wrappers_e_Internos.md) para la jerarquía completa. Por ahora basta saber:

- Los wrappers son **sin estado** — solo llevan información de tipos genéricos.
- Los wrappers se comparten entre todas las instancias de `Mediator` y todos los scopes.
- En el primer uso, el wrapper para un `(tipo de request)` dado se crea con `Activator.CreateInstance` (una llamada reflexiva) y queda cacheado para siempre.

Este diseño es un compromiso deliberado: una pequeña cantidad de estado estático a nivel de proceso a cambio de cero reflexión en el camino caliente.

> Las cachés viven en `Mediator`, no en un helper estático — eso significa que una subclase que sobrescriba `PublishCore` comparte las mismas cachés. Es aceptable porque las cachés solo dependen de tipos de mensaje, no del comportamiento de la instancia.

---

## `Send<TResponse>(IRequest<TResponse>)`

```csharp
public Task<TResponse> Send<TResponse>(IRequest<TResponse> request, CancellationToken cancellationToken = default)
{
    if (request == null) throw new ArgumentNullException(nameof(request));

    var handler = (RequestHandlerWrapper<TResponse>)_requestHandlers.GetOrAdd(request.GetType(), static requestType =>
    {
        var wrapperType = typeof(RequestHandlerWrapperImpl<,>).MakeGenericType(requestType, typeof(TResponse));
        var wrapper = Activator.CreateInstance(wrapperType)
                      ?? throw new InvalidOperationException($"Could not create wrapper type for {requestType}");
        return (RequestHandlerBase)wrapper;
    });

    return handler.Handle(request, _serviceProvider, cancellationToken);
}
```

Paso a paso:

1. **Null check**. Camino muy rápido.
2. **Consulta a la caché** por el tipo **runtime** del request (no el de compilación). Así un request `GetOrderById` que implementa `IRequest<Order>` se indexa con la clave `typeof(GetOrderById)`.
3. **Factory en miss de caché** (lambda `static` — sin estado capturado): cierra `RequestHandlerWrapperImpl<TRequest, TResponse>` sobre `(requestType, typeof(TResponse))`, lo instancia con `Activator.CreateInstance`. Es el único coste de reflexión, pagado una vez por tipo de request.
4. **Cast** a `RequestHandlerWrapper<TResponse>` (seguro — lo acabamos de construir) e **invoca** `Handle(request, _serviceProvider, cancellationToken)`.

Esa llamada es donde realmente se construye y ejecuta el pipeline — ver [Wrappers e Internos](12%20-%20Wrappers_e_Internos.md) y [Comportamientos del Pipeline](06%20-%20Comportamientos_del_Pipeline.md).

---

## `Send<TRequest>(TRequest)` (void)

```csharp
public Task Send<TRequest>(TRequest request, CancellationToken cancellationToken = default)
    where TRequest : IRequest
{
    if (request == null) throw new ArgumentNullException(nameof(request));

    var handler = (RequestHandlerWrapper)_requestHandlers.GetOrAdd(request.GetType(), static requestType =>
    {
        var wrapperType = typeof(RequestHandlerWrapperImpl<>).MakeGenericType(requestType);
        var wrapper = Activator.CreateInstance(wrapperType)
                      ?? throw new InvalidOperationException($"Could not create wrapper type for {requestType}");
        return (RequestHandlerBase)wrapper;
    });

    return handler.Handle(request, _serviceProvider, cancellationToken);
}
```

Misma forma que la versión tipada, pero el wrapper es `RequestHandlerWrapperImpl<TRequest>` (un solo parámetro genérico). Internamente este wrapper produce un `Task<Unit>` y lo expone como `Task` al llamador.

---

## `Send(object)` (dinámico)

```csharp
public Task<object?> Send(object request, CancellationToken cancellationToken = default)
{
    if (request == null) throw new ArgumentNullException(nameof(request));

    var handler = _requestHandlers.GetOrAdd(request.GetType(), static requestType =>
    {
        Type wrapperType;

        var requestInterfaceType = requestType.GetInterfaces()
            .FirstOrDefault(static i => i.IsGenericType && i.GetGenericTypeDefinition() == typeof(IRequest<>));

        if (requestInterfaceType is null)
        {
            requestInterfaceType = requestType.GetInterfaces().FirstOrDefault(static i => i == typeof(IRequest));
            if (requestInterfaceType is null)
            {
                throw new ArgumentException($"{requestType.Name} does not implement {nameof(IRequest)}", nameof(request));
            }

            wrapperType = typeof(RequestHandlerWrapperImpl<>).MakeGenericType(requestType);
        }
        else
        {
            var responseType = requestInterfaceType.GetGenericArguments()[0];
            wrapperType = typeof(RequestHandlerWrapperImpl<,>).MakeGenericType(requestType, responseType);
        }

        var wrapper = Activator.CreateInstance(wrapperType)
                      ?? throw new InvalidOperationException($"Could not create wrapper for type {requestType}");
        return (RequestHandlerBase)wrapper;
    });

    return handler.Handle(request, _serviceProvider, cancellationToken);
}
```

La sobrecarga dinámica añade una pieza extra de reflexión: descubrir si el tipo runtime implementa `IRequest<T>` o `IRequest`, luego cerrar el wrapper según corresponda. Tras el primer uso, la caché elimina ese coste.

Cualquier otro tipo de objeto lanza `ArgumentException`.

---

## `Publish<TNotification>(TNotification)`

```csharp
public Task Publish<TNotification>(TNotification notification, CancellationToken cancellationToken = default)
    where TNotification : INotification
{
    if (notification == null) throw new ArgumentNullException(nameof(notification));
    return PublishNotification(notification, cancellationToken);
}

public Task Publish(object notification, CancellationToken cancellationToken = default) =>
    notification switch
    {
        null => throw new ArgumentNullException(nameof(notification)),
        INotification instance => PublishNotification(instance, cancellationToken),
        _ => throw new ArgumentException($"{nameof(notification)} does not implement ${nameof(INotification)}")
    };
```

Ambas sobrecargas desembocan en:

```csharp
private Task PublishNotification(INotification notification, CancellationToken cancellationToken = default)
{
    var handler = _notificationHandlers.GetOrAdd(notification.GetType(), static notificationType =>
    {
        var wrapperType = typeof(NotificationHandlerWrapperImpl<>).MakeGenericType(notificationType);
        var wrapper = Activator.CreateInstance(wrapperType)
                      ?? throw new InvalidOperationException($"Could not create wrapper for type {notificationType}");
        return (NotificationHandlerWrapper)wrapper;
    });

    return handler.Handle(notification, _serviceProvider, PublishCore, cancellationToken);
}
```

Nota que `PublishCore` se pasa como `Func` — la estrategia publisher se invoca desde dentro del wrapper.

### `PublishCore` — el punto de extensión

```csharp
protected virtual Task PublishCore(
    IEnumerable<NotificationHandlerExecutor> handlerExecutors,
    INotification notification,
    CancellationToken cancellationToken)
    => _publisher.Publish(handlerExecutors, notification, cancellationToken);
```

Delega al `INotificationPublisher` configurado. Puedes sobrescribir `PublishCore` en una subclase de `Mediator` para inyectar telemetría, agregación de errores, ajustes de orden, etc., sin reemplazar la estrategia publisher entera.

---

## `CreateStream<TResponse>(IStreamRequest<TResponse>)`

```csharp
public IAsyncEnumerable<TResponse> CreateStream<TResponse>(
    IStreamRequest<TResponse> request, CancellationToken cancellationToken = default)
{
    if (request == null) throw new ArgumentNullException(nameof(request));

    var streamHandler = (StreamRequestHandlerWrapper<TResponse>)_streamRequestHandlers.GetOrAdd(request.GetType(), static requestType =>
    {
        var wrapperType = typeof(StreamRequestHandlerWrapperImpl<,>).MakeGenericType(requestType, typeof(TResponse));
        var wrapper = Activator.CreateInstance(wrapperType)
                      ?? throw new InvalidOperationException($"Could not create wrapper for type {requestType}");
        return (StreamRequestHandlerBase)wrapper;
    });

    return streamHandler.Handle(request, _serviceProvider, cancellationToken);
}
```

Estructura idéntica a `Send<TResponse>`, pero el wrapper devuelve `IAsyncEnumerable<TResponse>`. Aquí no se espera (`await`) nada — el llamador controla la enumeración con `await foreach`.

---

## `CreateStream(object)`

```csharp
public IAsyncEnumerable<object?> CreateStream(object request, CancellationToken cancellationToken = default)
{
    if (request == null) throw new ArgumentNullException(nameof(request));

    var handler = _streamRequestHandlers.GetOrAdd(request.GetType(), static requestType =>
    {
        var requestInterfaceType = requestType.GetInterfaces()
            .FirstOrDefault(static i => i.IsGenericType && i.GetGenericTypeDefinition() == typeof(IStreamRequest<>));

        if (requestInterfaceType is null)
            throw new ArgumentException($"{requestType.Name} does not implement IStreamRequest<TResponse>", nameof(request));

        var responseType = requestInterfaceType.GetGenericArguments()[0];
        var wrapperType = typeof(StreamRequestHandlerWrapperImpl<,>).MakeGenericType(requestType, responseType);
        var wrapper = Activator.CreateInstance(wrapperType)
                      ?? throw new InvalidOperationException($"Could not create wrapper for type {requestType}");
        return (StreamRequestHandlerBase)wrapper;
    });

    return handler.Handle(request, _serviceProvider, cancellationToken);
}
```

Espejo de `Send(object)` pero para streams. Solo `IStreamRequest<T>` es válido — no hay equivalente void, y tiene sentido: un stream sin items es simplemente un `IAsyncEnumerable<T>` vacío.

---

## Por qué `Mediator` no es `sealed`

`Mediator` es una `public class` regular (no sealed). Puedes heredar de ella para:

- Sobrescribir `PublishCore` para dispatch de notificaciones personalizado.
- Añadir telemetría / spans de tracing alrededor de `Send` / `Publish` / `CreateStream`.
- Registrar una subclase con `cfg.MediatorImplementationType = typeof(MyMediator)`.

El proyecto `samples/AN.MediatR.Examples.PublishStrategies` hace exactamente eso: su subclase `CustomMediator` acepta un delegate y lo llama desde `PublishCore` para implementar seis estrategias (Async, ParallelNoWait, ParallelWhenAll, ParallelWhenAny, SyncContinueOnException, SyncStopOnException).

---

## Resumen de manejo de null

| Método | Con request/notification `null` |
|--------|---------------------------------|
| `Send<TResponse>(IRequest<TResponse>)` | `ArgumentNullException` |
| `Send<TRequest>(TRequest)` | `ArgumentNullException` |
| `Send(object)` | `ArgumentNullException` |
| `Publish<TNotification>` | `ArgumentNullException` |
| `Publish(object)` | `ArgumentNullException` (vía switch) |
| `CreateStream<TResponse>` | `ArgumentNullException` |
| `CreateStream(object)` | `ArgumentNullException` |

Además, `Send(object)` / `CreateStream(object)` / `Publish(object)` lanzan `ArgumentException` si el objeto no implementa la interfaz marcador correcta.

---

## Características de rendimiento

- **Dispatch en estado estable**: una consulta a diccionario, una llamada virtual, una enumeración de `IServiceProvider.GetServices(...)` por comportamiento del pipeline. Sin reflexión.
- **Primer dispatch**: además, un `Activator.CreateInstance` + `MakeGenericType` por wrapper. Amortizado sobre la vida de la aplicación.
- **Memoria**: tres entradas estáticas de `ConcurrentDictionary` por tipo distinto de request / notification / stream-request. Los wrappers son minúsculos (solo tablas de métodos virtuales).

Para la suite de benchmarks, ver `test/AN.MediatR.Benchmarks`.
