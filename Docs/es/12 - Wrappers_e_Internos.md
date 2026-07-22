# Wrappers e Internos

Este capítulo levanta el telón sobre el *cómo* de AN.MediatR. Léelo si quieres depurar problemas raros de DI, contribuir a la librería o entender sus características de rendimiento.

La mayoría de tipos aquí son `internal`, así que no forman parte de la API pública.

---

## Por qué existen los wrappers

La API de `IMediator` es intencionadamente pequeña:

```csharp
Task<TResponse> Send<TResponse>(IRequest<TResponse> request, CancellationToken ct = default);
```

Pero el tipo real del request solo se conoce en runtime — `IRequest<TResponse>` es el contrato de compilación, el `GetOrderById : IRequest<Order>` concreto es el tipo runtime. Para despachar correctamente, `Mediator` debe:

1. Averiguar el `TRequest` concreto (tipo runtime de `request`).
2. Resolver el `IRequestHandler<TRequest, TResponse>` correcto del contenedor.
3. Resolver todos los `IPipelineBehavior<TRequest, TResponse>` y montarlos en un pipeline.
4. Llamar al resultado.

Hacerlo vía reflexión en cada envío sería extremadamente lento. En su lugar, AN.MediatR usa un truco de **type erasure**: para cada pareja `(TRequest, TResponse)`, construye una clase **wrapper** genérica una sola vez, la cachea en un `static ConcurrentDictionary<Type, ...>` y la reutiliza para siempre. El wrapper cacheado lleva la información genérica en su definición de clase, así los despachos siguientes solo cuestan una consulta a diccionario + una llamada virtual.

---

## Wrappers de request

Fuente: [src/AN.MediatR/Wrappers/RequestHandlerWrapper.cs](../../src/AN.MediatR/Wrappers/RequestHandlerWrapper.cs).

```csharp
public abstract class RequestHandlerBase
{
    public abstract Task<object?> Handle(object request, IServiceProvider serviceProvider, CancellationToken ct);
}

public abstract class RequestHandlerWrapper<TResponse> : RequestHandlerBase
{
    public abstract Task<TResponse> Handle(IRequest<TResponse> request, IServiceProvider sp, CancellationToken ct);
}

public abstract class RequestHandlerWrapper : RequestHandlerBase
{
    public abstract Task<Unit> Handle(IRequest request, IServiceProvider sp, CancellationToken ct);
}
```

Tres niveles abstractos:

- `RequestHandlerBase` — la base completamente borrada usada como valor de la caché.
- `RequestHandlerWrapper<TResponse>` — conserva `TResponse` para `Send<TResponse>` tipado.
- `RequestHandlerWrapper` — para requests void (`IRequest`), devuelve `Unit` uniformemente.

### `RequestHandlerWrapperImpl<TRequest, TResponse>`

```csharp
public class RequestHandlerWrapperImpl<TRequest, TResponse> : RequestHandlerWrapper<TResponse>
    where TRequest : IRequest<TResponse>
{
    public override async Task<object?> Handle(object request, IServiceProvider sp, CancellationToken ct)
        => await Handle((IRequest<TResponse>)request, sp, ct).ConfigureAwait(false);

    public override Task<TResponse> Handle(IRequest<TResponse> request, IServiceProvider sp, CancellationToken ct)
    {
        Task<TResponse> Handler(CancellationToken t = default) =>
            sp.GetRequiredService<IRequestHandler<TRequest, TResponse>>()
              .Handle((TRequest)request, t == default ? ct : t);

        return sp.GetServices<IPipelineBehavior<TRequest, TResponse>>()
            .Reverse()
            .Aggregate(
                (RequestHandlerDelegate<TResponse>)Handler,
                (next, pipeline) => (t) => pipeline.Handle((TRequest)request, next, t == default ? ct : t))();
    }
}
```

Qué ocurre en cada llamada:

1. **Función local `Handler`** resuelve el `IRequestHandler<TRequest, TResponse>` concreto y lo invoca. Es el paso más interno del pipeline.
2. **`sp.GetServices<IPipelineBehavior<TRequest, TResponse>>()`** enumera cada behavior registrado. Si llamaste a `AddMediatR(cfg => cfg.AddOpenBehavior(typeof(LoggingBehavior<,>)))`, ese behavior — cerrado sobre `<TRequest, TResponse>` — se incluye junto con los registros cerrados y los decoradores pre/post/excepciones.
3. **`.Reverse()`** asegura que el **primer** behavior registrado acabe como la capa **más externa**.
4. **`.Aggregate(seed, (next, pipeline) => (t) => pipeline.Handle(request, next, t))`** pliega el enumerable en un único `RequestHandlerDelegate<TResponse>`. Cada `Handle(request, next, ct)` del behavior pasa a ser el `next` del behavior exterior.
5. **`()`** invoca la cadena montada.

### `RequestHandlerWrapperImpl<TRequest>` (void)

```csharp
public class RequestHandlerWrapperImpl<TRequest> : RequestHandlerWrapper
    where TRequest : IRequest
{
    public override Task<Unit> Handle(IRequest request, IServiceProvider sp, CancellationToken ct)
    {
        async Task<Unit> Handler(CancellationToken t = default)
        {
            await sp.GetRequiredService<IRequestHandler<TRequest>>()
                    .Handle((TRequest)request, t == default ? ct : t);
            return Unit.Value;
        }

        return sp.GetServices<IPipelineBehavior<TRequest, Unit>>()
            .Reverse()
            .Aggregate(
                (RequestHandlerDelegate<Unit>)Handler,
                (next, pipeline) => (t) => pipeline.Handle((TRequest)request, next, t == default ? ct : t))();
    }
}
```

Diferencias con la versión tipada:

- `IRequestHandler<TRequest>` no tiene respuesta, así `Handler` devuelve `Unit.Value` tras completar.
- Los behaviors son `IPipelineBehavior<TRequest, Unit>` — los requests void se unifican con el pipeline tipado fingiendo que `Unit` es el tipo de respuesta.

---

## Wrappers de notificación

Fuente: [src/AN.MediatR/Wrappers/NotificationHandlerWrapper.cs](../../src/AN.MediatR/Wrappers/NotificationHandlerWrapper.cs).

```csharp
public abstract class NotificationHandlerWrapper
{
    public abstract Task Handle(INotification notification, IServiceProvider sp,
        Func<IEnumerable<NotificationHandlerExecutor>, INotification, CancellationToken, Task> publish,
        CancellationToken ct);
}

public class NotificationHandlerWrapperImpl<TNotification> : NotificationHandlerWrapper
    where TNotification : INotification
{
    public override Task Handle(INotification notification, IServiceProvider sp,
        Func<IEnumerable<NotificationHandlerExecutor>, INotification, CancellationToken, Task> publish,
        CancellationToken ct)
    {
        var handlers = sp
            .GetServices<INotificationHandler<TNotification>>()
            .GroupBy(static x => x.GetType())
            .Select(static g => g.First())
            .Select(static x => new NotificationHandlerExecutor(x,
                (theNotification, theToken) => x.Handle((TNotification)theNotification, theToken)));

        return publish(handlers, notification, ct);
    }
}
```

Responsabilidades:

- Resolver todos los handlers de notificación para `TNotification`.
- Deduplicar por tipo concreto (`GroupBy(x => x.GetType()).Select(g => g.First())`).
- Envolver cada handler en un `NotificationHandlerExecutor` que hace cast `INotification` → `TNotification` dentro de su callback.
- Entregar el enumerable al delegate `publish` provisto por el mediator — ese delegate es `Mediator.PublishCore`, que a su vez llama a `INotificationPublisher.Publish(...)`.

---

## Wrappers de stream

Fuente: [src/AN.MediatR/Wrappers/StreamRequestHandlerWrapper.cs](../../src/AN.MediatR/Wrappers/StreamRequestHandlerWrapper.cs).

```csharp
internal abstract class StreamRequestHandlerBase
{
    public abstract IAsyncEnumerable<object?> Handle(object request, IServiceProvider sp, CancellationToken ct);
}

internal abstract class StreamRequestHandlerWrapper<TResponse> : StreamRequestHandlerBase
{
    public abstract IAsyncEnumerable<TResponse> Handle(IStreamRequest<TResponse> request, IServiceProvider sp, CancellationToken ct);
}

internal class StreamRequestHandlerWrapperImpl<TRequest, TResponse> : StreamRequestHandlerWrapper<TResponse>
    where TRequest : IStreamRequest<TResponse>
{
    public override async IAsyncEnumerable<object?> Handle(object request, IServiceProvider sp, [EnumeratorCancellation] CancellationToken ct)
    {
        await foreach (var item in Handle((IStreamRequest<TResponse>)request, sp, ct))
            yield return item;
    }

    public override async IAsyncEnumerable<TResponse> Handle(IStreamRequest<TResponse> request, IServiceProvider sp, [EnumeratorCancellation] CancellationToken ct)
    {
        IAsyncEnumerable<TResponse> Handler() =>
            sp.GetRequiredService<IStreamRequestHandler<TRequest, TResponse>>()
              .Handle((TRequest)request, ct);

        var items = sp
            .GetServices<IStreamPipelineBehavior<TRequest, TResponse>>()
            .Reverse()
            .Aggregate(
                (StreamHandlerDelegate<TResponse>)Handler,
                (next, pipeline) => () => pipeline.Handle((TRequest)request, () => NextWrapper(next(), ct), ct))();

        await foreach (var item in items.WithCancellation(ct))
            yield return item;
    }

    private static async IAsyncEnumerable<T> NextWrapper<T>(IAsyncEnumerable<T> items, [EnumeratorCancellation] CancellationToken ct)
    {
        await foreach (var item in items.WithCancellation(ct).ConfigureAwait(false))
            yield return item;
    }
}
```

Misma estructura que `RequestHandlerWrapperImpl`, pero:

- Tipo de retorno `IAsyncEnumerable<TResponse>`.
- `StreamHandlerDelegate<TResponse>` **sin argumentos** (el token se captura en el closure).
- `NextWrapper` es un método helper para que cada paso del pipeline re-envuelva el enumerable aguas abajo con `WithCancellation(...)` — crítico para la cancelación cooperativa entre behaviors.

Nota que `StreamRequestHandlerBase`, `StreamRequestHandlerWrapper<TResponse>` y `StreamRequestHandlerWrapperImpl<TRequest, TResponse>` son `internal`. Es una asimetría deliberada con los wrappers de request (que son públicos por razones históricas).

---

## `HandlersOrderer` y `ObjectDetails`

Usados exclusivamente por los behaviors de excepciones (`RequestExceptionProcessorBehavior<,>` y `RequestExceptionActionProcessorBehavior<,>`) para ordenar handlers por relevancia antes de ejecutarlos.

### `HandlersOrderer`

Fuente: [src/AN.MediatR/Internal/HandlersOrderer.cs](../../src/AN.MediatR/Internal/HandlersOrderer.cs).

```csharp
internal static class HandlersOrderer
{
    public static IList<object> Prioritize<TRequest>(IList<object> handlers, TRequest request) where TRequest : notnull
    {
        if (handlers.Count < 2) return handlers;

        var requestObjectDetails = new ObjectDetails(request);
        var handlerObjectsDetails = handlers.Select(static s => new ObjectDetails(s)).ToList();

        var uniqueHandlers = RemoveOverridden(handlerObjectsDetails).ToArray();
        Array.Sort(uniqueHandlers, requestObjectDetails);      // el request actúa como comparer

        return uniqueHandlers.Select(static s => s.Value).ToList();
    }

    private static IEnumerable<ObjectDetails> RemoveOverridden(IList<ObjectDetails> handlersData)
    {
        for (var i = 0; i < handlersData.Count - 1; i++)
            for (var j = i + 1; j < handlersData.Count; j++)
            {
                if (handlersData[i].IsOverridden || handlersData[j].IsOverridden) continue;

                if (handlersData[i].Type.IsAssignableFrom(handlersData[j].Type))
                    handlersData[i].IsOverridden = true;
                else if (handlersData[j].Type.IsAssignableFrom(handlersData[i].Type))
                    handlersData[j].IsOverridden = true;
            }

        return handlersData.Where(static w => !w.IsOverridden);
    }
}
```

- **`RemoveOverridden`**: si el tipo de un handler es asignable desde el de otro, el menos derivado se descarta. Permite a una subclase sobrescribir un handler base.
- **`Array.Sort(..., requestObjectDetails)`**: la instancia `ObjectDetails` construida desde el request se usa como `IComparer<ObjectDetails>`. Sus reglas de comparación (ver abajo) ordenan las ubicaciones de handlers por proximidad al request.

### `ObjectDetails`

Fuente: [src/AN.MediatR/Internal/ObjectDetails.cs](../../src/AN.MediatR/Internal/ObjectDetails.cs).

```csharp
internal class ObjectDetails : IComparer<ObjectDetails>
{
    public string Name { get; }
    public string? AssemblyName { get; }
    public string? Location { get; }   // namespace sin el prefijo AssemblyName
    public object Value { get; }
    public Type Type { get; }
    public bool IsOverridden { get; set; }

    public ObjectDetails(object value)
    {
        Value = value;
        Type = value.GetType();
        Name = Type.Name;
        AssemblyName = Type.Assembly.GetName().Name;
        Location = Type.Namespace?.Replace($"{AssemblyName}.", string.Empty);
    }

    public int Compare(ObjectDetails? x, ObjectDetails? y)
    {
        if (x == null) return 1;
        if (y == null) return -1;
        return CompareByAssembly(x, y) ?? CompareByNamespace(x, y) ?? CompareByLocation(x, y);
    }

    // CompareByAssembly — gana el del mismo ensamblado del request
    // CompareByNamespace — gana el con prefijo de namespace coincidente
    // CompareByLocation — gana el de mayor longitud de location (más específico)
}
```

La comparación es de tres niveles:

1. **Ensamblado**: `x.AssemblyName == requestAssembly && y.AssemblyName != requestAssembly` ⇒ `x` gana.
2. **Prefijo de namespace**: `x.Location.StartsWith(requestLocation)` && `!y.Location.StartsWith(requestLocation)` ⇒ `x` gana.
3. **Profundidad/longitud de location**: dentro de igualdad, el `Location` más largo (más específico) gana; finalmente cae a igualdad.

Consecuencia práctica: un `MyApp.Orders.InvalidOrderExceptionHandler` correrá antes que un `MyApp.Infra.GenericExceptionLogger` cuando el request es `MyApp.Orders.CreateOrder`.

---

## Entidad `OpenBehavior`

Fuente: [src/AN.MediatR/Entities/OpenBehavior.cs](../../src/AN.MediatR/Entities/OpenBehavior.cs).

Objeto de valor público para registrar múltiples behaviors de genéricos abiertos con lifetimes explícitos:

```csharp
public class OpenBehavior
{
    public OpenBehavior(Type openBehaviorType, ServiceLifetime serviceLifetime = ServiceLifetime.Transient)
    {
        ValidatePipelineBehaviorType(openBehaviorType);
        OpenBehaviorType = openBehaviorType;
        ServiceLifetime = serviceLifetime;
    }

    public Type OpenBehaviorType { get; }
    public ServiceLifetime ServiceLifetime { get; }

    private static void ValidatePipelineBehaviorType(Type openBehaviorType)
    {
        if (openBehaviorType == null) throw new ArgumentNullException("Open behavior type can not be null.");

        var isPipelineBehavior = openBehaviorType.GetInterfaces()
            .Any(i => i.IsGenericType && i.GetGenericTypeDefinition() == typeof(IPipelineBehavior<,>));

        if (!isPipelineBehavior)
            throw new InvalidOperationException($"The type \"{openBehaviorType.Name}\" must implement IPipelineBehavior<,> interface.");
    }
}
```

Usado por `cfg.AddOpenBehaviors(IEnumerable<OpenBehavior>)` — azúcar ergonómica menor sobre pasar tuplas `Type` + `ServiceLifetime`.

---

## Type forwardings

Fuente: [src/AN.MediatR/TypeForwardings.cs](../../src/AN.MediatR/TypeForwardings.cs).

```csharp
[assembly: TypeForwardedTo(typeof(IBaseRequest))]
[assembly: TypeForwardedTo(typeof(IRequest<>))]
[assembly: TypeForwardedTo(typeof(IRequest))]
[assembly: TypeForwardedTo(typeof(INotification))]
[assembly: TypeForwardedTo(typeof(Unit))]
```

Físicamente esos tipos viven en `AN.MediatR.Contracts`. El ensamblado `MediatR` redirige sus definiciones para que el código existente que referencia `MediatR.IRequest`, `MediatR.INotification`, etc. siga funcionando sin una referencia explícita a `AN.MediatR.Contracts` — y sin duplicar definiciones en ambos ensamblados (lo que sería un desastre de identidad CLR).

Ver [Paquete Contracts](13%20-%20Paquete_Contracts.md) para la justificación.

---

## Recapitulación — contrato de rendimiento

| Operación | Coste |
|-----------|-------|
| Primer Send de un tipo de request dado | Un `Type.MakeGenericType` + `Activator.CreateInstance` para el wrapper. Un `IServiceProvider.GetServices(...)` + `Reverse().Aggregate(...)` para montar el pipeline (materializa la lista de behaviors). |
| Send siguientes | Un `ConcurrentDictionary.TryGetValue`. Una llamada virtual (`RequestHandlerBase.Handle`). Un `GetServices` + `Aggregate` (todavía — la composición del pipeline necesita la lista fresca de servicios). |
| Primer Publish de un tipo de notificación | Construcción del wrapper + `GetServices<INotificationHandler<TNotification>>()`. |
| Publish siguientes | Consulta a diccionario + llamada virtual + `GetServices` + estrategia publisher. |
| CreateStream | Igual que request; el enumerable es perezoso. |

La lista de behaviors del pipeline se **re-materializa en cada llamada** — necesario porque DI puede devolver instancias distintas para servicios scoped/transient. Mantén la instanciación de behaviors barata.
