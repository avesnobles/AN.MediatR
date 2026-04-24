# Gestión de Excepciones

AN.MediatR provee **dos** mecanismos paralelos para reaccionar ante excepciones lanzadas por handlers:

1. **Exception actions** (`IRequestExceptionAction<TRequest, TException>`) — observan y reaccionan (logging, métricas). Siempre relanzan.
2. **Exception handlers** (`IRequestExceptionHandler<TRequest, TResponse, TException>`) — recuperan y devuelven una respuesta alternativa.

Ambos se implementan como decoradores `IPipelineBehavior` conectados automáticamente por `ServiceRegistrar`. Ambos viven en el namespace `MediatR.Pipeline`.

---

## **Actions** de excepción — disparar y relanzar

### Contrato

```csharp
public interface IRequestExceptionAction<in TRequest, in TException>
    where TRequest : notnull
    where TException : Exception
{
    Task Execute(TRequest request, TException exception, CancellationToken cancellationToken);
}
```

Fuente: [src/MediatR/Pipeline/IRequestExceptionAction.cs](../../src/MediatR/Pipeline/IRequestExceptionAction.cs).

### Semántica

- Se ejecuta cuando el handler lanza `TException` **o cualquier subclase**.
- Pensada para logging, tracing, métricas, notificaciones y otros efectos laterales que no deben cambiar el flujo.
- **La excepción siempre se relanza** tras ejecutarse todas las actions que casan.
- Se permiten varias actions por excepción; se ejecutan en orden de prioridad (ver `HandlersOrderer` más abajo).

### Implementación

```csharp
public class LogException<TRequest> : IRequestExceptionAction<TRequest, Exception>
    where TRequest : notnull
{
    private readonly ILogger<LogException<TRequest>> _logger;
    public LogException(ILogger<LogException<TRequest>> logger) => _logger = logger;

    public Task Execute(TRequest request, Exception exception, CancellationToken cancellationToken)
    {
        _logger.LogError(exception, "Error handling {Request}", typeof(TRequest).Name);
        return Task.CompletedTask;
    }
}
```

El parámetro genérico `Exception` significa "ejecuta para cualquier excepción". Para reducir el alcance, usa una subclase como `TimeoutException` o `ValidationException`.

---

## **Handlers** de excepción — recuperar con una respuesta

### Contrato

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

Fuente: [src/MediatR/Pipeline/IRequestExceptionHandler.cs](../../src/MediatR/Pipeline/IRequestExceptionHandler.cs).

### `RequestExceptionHandlerState<TResponse>`

```csharp
public class RequestExceptionHandlerState<TResponse>
{
    public bool Handled { get; private set; }
    public TResponse? Response { get; private set; }

    public void SetHandled(TResponse response)
    {
        Handled = true;
        Response = response;
    }
}
```

Objeto de estado mutable pasado por referencia a cada handler. Llama a `state.SetHandled(response)` para suprimir la excepción y devolver `response`.

### Semántica

- Se ejecuta cuando el handler lanza `TException` **o cualquier subclase**.
- Si algún handler llama a `state.SetHandled(response)`, la excepción se traga y se devuelve `response` al llamador.
- Si **ningún** handler pone `Handled`, la excepción original se relanza.
- Una vez `Handled` está a `true`, los handlers restantes **no** se invocan.
- Si un handler pone `Handled` pero `response` es `null`, el behavior relanza igualmente (null se trata como "sin respuesta").

### Implementación

```csharp
public class TranslateNotFound<TRequest, TResponse> : IRequestExceptionHandler<TRequest, TResponse, EntityNotFoundException>
    where TRequest : notnull
    where TResponse : new()
{
    public Task Handle(
        TRequest request,
        EntityNotFoundException exception,
        RequestExceptionHandlerState<TResponse> state,
        CancellationToken cancellationToken)
    {
        state.SetHandled(new TResponse());   // devuelve una respuesta por defecto
        return Task.CompletedTask;
    }
}
```

---

## Dentro de los pipeline behaviors

### `RequestExceptionProcessorBehavior<TRequest, TResponse>`

Fuente: [src/MediatR/Pipeline/RequestExceptionProcessorBehavior.cs](../../src/MediatR/Pipeline/RequestExceptionProcessorBehavior.cs).

```csharp
public async Task<TResponse> Handle(TRequest request, RequestHandlerDelegate<TResponse> next, CancellationToken cancellationToken)
{
    try
    {
        return await next(cancellationToken).ConfigureAwait(false);
    }
    catch (Exception exception)
    {
        var state = new RequestExceptionHandlerState<TResponse>();
        var exceptionTypes = GetExceptionTypes(exception.GetType());   // sube por Exception.BaseType

        var handlersForException = exceptionTypes
            .SelectMany(t => GetHandlersForException(t, request))   // el contenedor resuelve handlers por tipo
            .GroupBy(x => x.Handler.GetType())
            .Select(g => g.First())                                 // dedupe por tipo de handler
            .Select(x => (MethodInfo: GetMethodInfoForHandler(x.ExceptionType), x.Handler))
            .ToList();

        foreach (var (methodInfo, handler) in handlersForException)
        {
            try { await ((Task)methodInfo.Invoke(handler, new object[] { request, exception, state, cancellationToken })!).ConfigureAwait(false); }
            catch (TargetInvocationException tie) when (tie.InnerException != null) { ExceptionDispatchInfo.Capture(tie.InnerException).Throw(); }

            if (state.Handled) break;
        }

        if (!state.Handled) throw;                 // ningún handler recuperó
        if (state.Response is null) throw;         // handler olvidó poner respuesta
        return state.Response;
    }
}
```

Puntos clave:

- **Recorrido por tipo de excepción**: empieza por el tipo concreto y sigue `BaseType` hasta `Exception`, juntando todos los handlers registrados para cada nivel.
- **Prioridad**: dentro de cada nivel, `HandlersOrderer.Prioritize(handlers, request)` los reordena (ver más abajo).
- **Salida temprana**: en cuanto `state.Handled` se pone a `true`, los handlers restantes se omiten.
- **Semántica de relanzado**: un `throw;` pelado preserva la stack trace original; el desempaquetado de `TargetInvocationException` usa `ExceptionDispatchInfo` para conservar la stack trace interna.

### `RequestExceptionActionProcessorBehavior<TRequest, TResponse>`

Fuente: [src/MediatR/Pipeline/RequestExceptionActionProcessorBehavior.cs](../../src/MediatR/Pipeline/RequestExceptionActionProcessorBehavior.cs).

Mismo patrón de recorrido de tipo + priorización + dedupe, pero:

- Sin objeto de estado; las actions solo "disparan y vuelven".
- Tras ejecutarse todas, la excepción se **relanza siempre** (`throw;`).

---

## Prioridad vía `HandlersOrderer`

Ambos behaviors usan `MediatR.Internal.HandlersOrderer.Prioritize(handlers, request)` para ordenar handlers antes de ejecutarlos.

Fuente: [src/MediatR/Internal/HandlersOrderer.cs](../../src/MediatR/Internal/HandlersOrderer.cs), [src/MediatR/Internal/ObjectDetails.cs](../../src/MediatR/Internal/ObjectDetails.cs).

### Reglas, por orden de prioridad

1. **Eliminar sobrescritos**: si el tipo A es asignable desde B (B es más derivado), A se marca como sobrescrito y se elimina. Permite que una subclase concreta "gane" sobre un handler genérico base.
2. **Preferir mismo ensamblado que el request**: los handlers del mismo ensamblado que el tipo de request corren antes que los de otros ensamblados.
3. **Preferir mismo namespace o descendiente**: dentro del mismo ensamblado, los handlers cuyo namespace empieza por el prefijo del request corren primero.
4. **Preferir namespace más cercano / más específico**: entre handlers que coinciden con el prefijo, el de menor distancia (más corta) gana; empates se resuelven por longitud de location (más largo gana — más específico).

Efecto práctico: a los handlers locales y específicos se les da la oportunidad de manejar la excepción antes que a handlers genéricos de infraestructura. Si tienes `MyApp.Orders.CreateOrderException` y un `CreateOrderExceptionHandler` en `MyApp.Orders` y un `GenericExceptionLogger` en `MyApp.Infra`, el handler de orders corre primero.

---

## Registro

### Las implementaciones se descubren automáticamente

`ServiceRegistrar.AddMediatRClasses` escanea cada ensamblado registrado buscando:

- Implementaciones de `IRequestExceptionHandler<,,>` (cerradas y de genéricos abiertos).
- Implementaciones de `IRequestExceptionAction<,>`.

Ambas se registran como `Transient` con la interfaz concreta que cierran. Se permiten varios registros (usa la ruta de "multi-instancia").

### Los behaviors se añaden bajo demanda

`ServiceRegistrar.AddRequiredServices` comprueba si hay alguna implementación de `IRequestExceptionHandler<,,>` o `IRequestExceptionAction<,>` en la service collection:

```csharp
private static void RegisterBehaviorIfImplementationsExist(
    IServiceCollection services, Type behaviorType, Type subBehaviorType)
{
    var hasAny = services
        .Where(s => !s.IsKeyedService)
        .Select(s => s.ImplementationType)
        .OfType<Type>()
        .SelectMany(t => t.GetInterfaces())
        .Where(t => t.IsGenericType)
        .Select(t => t.GetGenericTypeDefinition())
        .Any(t => t == subBehaviorType);

    if (hasAny)
    {
        services.TryAddEnumerable(new ServiceDescriptor(
            typeof(IPipelineBehavior<,>), behaviorType, ServiceLifetime.Transient));
    }
}
```

Por lo tanto:

- Sin handlers/actions registrados → no hay behaviors de excepciones en el pipeline. Coste runtime cero.
- Al menos uno registrado → el behavior correspondiente se inyecta en el pipeline de cada request.

### Orden: `RequestExceptionActionProcessorStrategy`

El orden relativo de ambos behaviors lo controla un enum de configuración:

```csharp
public enum RequestExceptionActionProcessorStrategy
{
    ApplyForUnhandledExceptions,   // por defecto
    ApplyForAllExceptions
}
```

Fuente: [src/MediatR/MicrosoftExtensionsDI/RequestExceptionActionProcessorStrategy.cs](../../src/MediatR/MicrosoftExtensionsDI/RequestExceptionActionProcessorStrategy.cs).

De `ServiceRegistrar.AddRequiredServices`:

```csharp
if (serviceConfiguration.RequestExceptionActionProcessorStrategy == RequestExceptionActionProcessorStrategy.ApplyForUnhandledExceptions)
{
    RegisterBehaviorIfImplementationsExist(services, typeof(RequestExceptionActionProcessorBehavior<,>), typeof(IRequestExceptionAction<,>));
    RegisterBehaviorIfImplementationsExist(services, typeof(RequestExceptionProcessorBehavior<,>), typeof(IRequestExceptionHandler<,,>));
}
else
{
    RegisterBehaviorIfImplementationsExist(services, typeof(RequestExceptionProcessorBehavior<,>), typeof(IRequestExceptionHandler<,,>));
    RegisterBehaviorIfImplementationsExist(services, typeof(RequestExceptionActionProcessorBehavior<,>), typeof(IRequestExceptionAction<,>));
}
```

#### `ApplyForUnhandledExceptions` (por defecto)

Actions registradas **antes** que handlers ⇒ en el pipeline las actions quedan **fuera** de los handlers ⇒ las actions corren **solo** si los handlers no recuperan.

Línea temporal:

```
try next() lanza Ex
  → ExceptionProcessor prueba sus handlers; supón que uno recupera
  → Se devuelve respuesta ✓
  → El decorador ExceptionAction no ve excepción → no hace nada
```

Si nada recupera:

```
try next() lanza Ex
  → Los handlers de ExceptionProcessor no hacen nada
  → relanza
  → ExceptionAction captura, ejecuta actions, relanza
```

#### `ApplyForAllExceptions`

Handlers registrados antes que actions ⇒ handlers quedan fuera de actions ⇒ **las actions siempre corren**, aunque luego un handler hubiera recuperado.

Línea temporal:

```
try next() lanza Ex
  → ExceptionAction captura, ejecuta actions, relanza
  → ExceptionProcessor captura ese relanzamiento, ejecuta handlers
  → si un handler recupera, se devuelve respuesta
  → si no, relanza
```

Elige `ApplyForAllExceptions` cuando quieras que las actions (p. ej. logging) se disparen incluso para excepciones recuperadas — útil para pistas de auditoría.

---

## Casos extremos y trampas

- **No hagas `throw` desde dentro de un handler** — usa `state.SetHandled(...)` para controlar el flujo. Un relanzado cambia la excepción original por otra en medio del bucle de handlers y puede romper las invariantes del recorrido por prioridad.
- **`TException` casa subclases** — registrar `IRequestExceptionHandler<MyReq, MyResp, Exception>` coincide con cualquier excepción, pudiendo tragar cosas inesperadas. Sé explícito.
- **Deduplicación por tipo** — registrar el mismo tipo de handler dos veces (p. ej. explícitamente y vía escaneo) todavía lo ejecuta una sola vez por nivel de excepción.
- **Stream requests (`IStreamRequest<T>`) no participan** — los behaviors de excepción solo aplican a `IPipelineBehavior<TRequest, TResponse>`, no a `IStreamPipelineBehavior<,>`. Usa try/catch en `await foreach` o implementa un stream pipeline behavior.
- **Las notificaciones no tienen pipeline de excepciones** — las excepciones en handlers de notificaciones se propagan a través de `INotificationPublisher`. Ver [Publicadores de Notificaciones](09%20-%20Publicadores_Notificaciones.md) para estrategias de agregación.

---

## Resumen

| Característica | Action | Handler |
|----------------|--------|---------|
| Interfaz | `IRequestExceptionAction<TRequest, TException>` | `IRequestExceptionHandler<TRequest, TResponse, TException>` |
| ¿Puede recuperar? | ❌ | ✅ vía `state.SetHandled(...)` |
| ¿Relanza? | Siempre | Solo si nada pone `Handled` |
| Uso típico | Logging, métricas, notificaciones | Traducir excepción de dominio → respuesta amigable |
| ¿Corre para subclases de `TException`? | Sí | Sí |
| ¿Cómo se ordenan? | `HandlersOrderer` (ensamblado → namespace → profundidad) | Igual |
| ¿Behavior automático? | `RequestExceptionActionProcessorBehavior<,>` | `RequestExceptionProcessorBehavior<,>` |
| ¿Orden controlado entre ambos? | `RequestExceptionActionProcessorStrategy` |
