# Buenas Prácticas y FAQ

Guía pragmática para usar AN.MediatR bien — basada en cómo está diseñada la librería, los patrones adoptados por la comunidad durante años y observaciones del código.

---

## Convenciones de diseño

### 1. Un handler por request, muchos por notificación

- `IRequest<TResponse>` e `IRequest` son **1-a-1**. Si casan dos handlers, DI lanzará (`GetRequiredService`) o elegirá uno silenciosamente — ninguna es lo que quieres.
- `INotification` es **1-a-muchos**. Se esperan varios handlers; si te ves escribiendo lógica que necesita "el resultado" de una notificación, conviértela en un request.

### 2. Nombra tipos por intención

- Requests: imperativo (`CreateOrder`, `DeleteCustomer`) o interrogativo (`GetOrderById`, `FindCustomersByName`).
- Notificaciones: pasado (`OrderCreated`, `CustomerDeleted`).
- Handlers: `<RequestName>Handler` / `<NotificationName>Handler` — conciso y predecible.
- Pipeline behaviors: `<Responsabilidad>Behavior` (p. ej. `ValidationBehavior`, `LoggingBehavior`).
- Procesadores pre/post: `<Responsabilidad>PreProcessor` / `<Responsabilidad>PostProcessor`.

### 3. Pon los handlers junto a sus requests

Co-localiza `CreateOrder.cs` y `CreateOrderHandler.cs` en la misma carpeta. Cuando se añade una feature nueva, todo el slice vive en un sitio — funciona bien con "vertical slice architecture".

### 4. Mantén los requests como datos inmutables

Los requests son DTOs. Prefiere `record` / `record struct` con propiedades `init`. No mutes un request dentro de su handler — muta entidades de dominio, no el mensaje.

### 5. Inyecta `ISender` / `IPublisher` en lugar de `IMediator` cuando puedas

`ISender` dice "esta clase envía comandos/queries". `IPublisher` dice "esta clase levanta eventos". `IMediator` dice "ambos". Dependencias más estrechas = intención más clara + tests más baratos.

### 6. Prefiere pipeline behaviors sobre lógica duplicada en handlers

Si el mismo try/catch o el mismo logging aparece en más de dos handlers, extráelo a un pipeline behavior. Si la misma validación aparece por todas partes, usa `ValidationBehavior<,>` con FluentValidation (o similar).

### 7. Mantén los behaviors finos y enfocados

Un behavior debería hacer **una** cosa. "Log + abrir transacción + captura excepciones + validar" son cuatro behaviors, no uno.

---

## Integración con CQRS

AN.MediatR encaja de forma natural en CQRS (*Command Query Responsibility Segregation*):

- **Queries** → `IRequest<TResponse>`.
- **Commands** → `IRequest` o `IRequest<TResponse>` (cuando necesitas devolver el nuevo id).
- **Eventos de dominio** → `INotification`.
- **Eventos de integración** → `INotification` que dispara un handler que publica a un bus.

Estructura típica de carpetas:

```
Application/
├── Orders/
│   ├── Commands/
│   │   ├── CreateOrder.cs
│   │   └── CreateOrderHandler.cs
│   ├── Queries/
│   │   ├── GetOrderById.cs
│   │   └── GetOrderByIdHandler.cs
│   └── Events/
│       ├── OrderCreated.cs
│       └── NotifyShippingOnOrderCreated.cs
```

Consejo: aunque no hagas CQRS estricto, el split directorio-por-feature acelera el descubrimiento.

---

## Recetas de composición del pipeline

### Stack típico de behaviors (comandos)

Registrados en este orden (primero = exterior):

1. **LoggingBehavior** — el más externo, siempre.
2. **RequestExceptionActionProcessorBehavior** (auto-inyectado) — observacional.
3. **RequestExceptionProcessorBehavior** (auto-inyectado) — recuperación.
4. **RequestPreProcessorBehavior** (auto-inyectado) — los procesadores pre corren dentro.
5. **ValidationBehavior** — lanza en inputs inválidos antes de tocar nada caro.
6. **AuthorizationBehavior** — comprueba autorización tras validación.
7. **TransactionBehavior** — frontera externa del scope transaccional.
8. **CachingBehavior** — el último antes del handler, así el caching ve la respuesta autoritativa.
9. **RequestPostProcessorBehavior** (auto-inyectado) — procesadores post corren aquí.

Regla general: **el trabajo caro debería estar lo más cerca posible del handler**. Los rechazos rápidos (auth, validación) en el exterior.

### Queries

Las queries normalmente necesitan un subconjunto más pequeño: logging, caching y quizá validación. Sáltate las transacciones.

### Notificaciones

Sin pipeline. Cualquier lógica transversal debe vivir en un `INotificationPublisher` o aplicarse en un envoltorio que llame a `mediator.Publish(...)`.

---

## Anti-patrones comunes

### ❌ Llamar `IMediator` desde dentro de un handler ("recursión de mediator")

```csharp
public class CreateOrderHandler : IRequestHandler<CreateOrder, int>
{
    private readonly IMediator _mediator;
    public CreateOrderHandler(IMediator mediator) => _mediator = mediator;

    public async Task<int> Handle(CreateOrder cmd, CancellationToken ct)
    {
        var customer = await _mediator.Send(new GetCustomerById(cmd.CustomerId), ct);   // ← acoplamiento
        // ...
    }
}
```

Funciona pero enreda los handlers. Prefiere dependencias directas (`ICustomerRepository`) salvo que necesites explícitamente el pipeline alrededor de la llamada interna.

### ❌ Handlers de notificación que devuelven datos

```csharp
public class BadHandler : INotificationHandler<OrderCreated>
{
    public Task Handle(OrderCreated n, CancellationToken ct)
    {
        // Intenta "devolver" algo vía estado compartido
        SharedBag.LastOrderId = n.Id;
        return Task.CompletedTask;
    }
}
```

Las notificaciones son fire-and-forget. Si necesitas respuesta, hazlo un request.

### ❌ `INotificationHandler` con side effects y publisher paralelo

Mezclar `TaskWhenAllPublisher` con handlers que escriben a la misma fila / clave de caché / archivo crea condiciones de carrera. Elige secuencial (`ForeachAwaitPublisher`) o diseña handlers realmente independientes.

### ❌ Pipeline behaviors que lanzan en lugar de usar exception handlers

```csharp
public async Task<TResponse> Handle(TRequest r, ..., CancellationToken ct)
{
    try { return await next(ct); }
    catch (Exception ex) { throw new MyWrappedException(ex); }   // ← se salta IRequestExceptionHandler
}
```

Si necesitas traducción de excepciones, prefiere `IRequestExceptionHandler<TRequest, TResponse, TException>` — está ordenado, deduplicado y componible. Solo usa try/catch en behaviors que sean realmente sobre gestión de excepciones.

### ❌ Confiar en el orden de registro de handlers

El orden de registro de handlers no es un contrato. No escribas código que dependa de qué handler "gana" cuando varios casan — diseña el sistema para que solo uno case por request.

### ❌ Reusar un `IMediator` scoped entre hilos

Si `IMediator` es scoped (común en ASP.NET Core), no lo pases a `Task.Run(...)`. Esa task puede sobrevivir al scope, momento en el que el service provider está disposed. Resuelve un `IMediator` fresco dentro de la task vía `IServiceScopeFactory`.

---

## Consejos de rendimiento

1. **Reusa instancias de behavior**. Regístralas como transient salvo que necesiten estado; transient es el default más seguro.
2. **Prefiere registros explícitos en rutas calientes**. `services.AddTransient<IRequestHandler<Hot, HotResponse>, HotHandler>()` evita coste de escaneo si arrancas muchos procesos (tests).
3. **Evita reflexión dentro de behaviors**. Todo lo necesario para llamar al siguiente paso está en tu closure.
4. **Benchmarkea antes de optimizar**. `test/AN.MediatR.Benchmarks` te da el coste base; AN.MediatR ya es muy rápido para la mayoría de cargas.
5. **Cachea pipelines compuestos si llamas a `Send` en un bucle caliente**. No puedes cachear la cadena resuelta completa porque los servicios DI pueden ser scoped, pero sí puedes cachear **estado inmutable** que los behaviors necesiten.

---

## Consejos de testing

- **Testea los handlers directamente**. Son clases normales con dependencias inyectadas — no hace falta mediator.
- **Testea pipeline behaviors con un `next` falso** — un lambda que devuelve una respuesta fija o lanza.
- **Testea `IMediator` solo cuando verificas el pipeline compuesto**. Es testing de integración; usa el contenedor real.
- **Evita mockear `IMediator`** en controladores/servicios salvo si no queda otra. Prefiere DI real y asserts a nivel de handler.

---

## FAQ

### ¿Qué diferencia hay entre AN.MediatR y jbogard/MediatR?

AN.MediatR es un **fork libre y de código abierto** basado en **MediatR v12.5**, la última versión Apache-2.0 antes de que el proyecto upstream (v13+, ahora de Lucky Penny Software) pasara a un modelo dual de licenciamiento comercial/RPL-1.5 con comprobación JWT en runtime.

En el punto de fork (v12.5) ambas bases de código son idénticas. De ahí en adelante:

- AN.MediatR se mantiene Apache-2.0. Sin validación de licencia en runtime. Sin JWT. Sin categoría de log `LuckyPennySoftware.MediatR.License`.
- AN.MediatR no tiene carpeta `Licensing/`, ni propiedad `Mediator.LicenseKey`, ni setting `cfg.LicenseKey`, ni tipos `LicenseAccessor` / `LicenseValidator` / `BuildInfo`.
- El equipo AN evolucionará la librería de forma independiente — correcciones, mejoras de rendimiento, nuevas features — sin seguir cada cambio del upstream.
- El upstream (jbogard/MediatR v13+) ha ganado un subsistema de licenciamiento JWT y es un producto comercial. Las features añadidas ahí tras v12.5 no se portan automáticamente aquí.

### ¿Necesito licencia para usar AN.MediatR?

No. AN.MediatR es Apache-2.0. Puedes usarla en cualquier proyecto, comercial o no, sujeto a los términos Apache-2.0 (que son mínimos).

### ¿Puedo usar `IRequest<TResponse>` con `TResponse` tipo valor / record struct?

Sí. Los tipos de valor funcionan igual que los de referencia.

### ¿Por qué `Send<TResponse>` no tiene `where TResponse : notnull`?

Porque `TResponse` puede ser un nullable de referencia (`Customer?`) o de valor (`int?`). La librería no le importa.

### ¿Se propaga la cancelación por el pipeline?

Sí. El `CancellationToken` se:

- Pasa a cada `Handle` de behavior.
- Pasa al handler final.
- Respetado por `Task.WhenAll` e `IAsyncEnumerable.WithCancellation` dentro de streams.

Cada behavior puede pasar un token distinto aguas abajo usando el parámetro opcional de `RequestHandlerDelegate<TResponse>`.

### ¿`Mediator` es thread-safe?

Sí. El único estado mutable son las tres cachés estáticas de wrappers, que usan `ConcurrentDictionary`. La resolución de handlers pasa por una llamada `IServiceProvider.GetServices` fresca en cada dispatch, así que aplican las reglas habituales de scope / thread-safety de tu contenedor DI.

### ¿Puedo registrar handlers como singletons?

Técnicamente sí, pero: los singleton handlers deben ser thread-safe, no deben depender de servicios scoped (DbContext, IHttpContextAccessor, etc.) y no deben mantener estado específico del request. Por defecto transient salvo que el perfil lo justifique.

### ¿Cómo obtengo un `IServiceScope` dentro de un handler?

Inyecta `IServiceScopeFactory` y crea un scope explícitamente:

```csharp
public class MyHandler(IServiceScopeFactory scopeFactory) : IRequestHandler<MyReq>
{
    public async Task Handle(MyReq r, CancellationToken ct)
    {
        using var scope = scopeFactory.CreateScope();
        var db = scope.ServiceProvider.GetRequiredService<DbContext>();
        // ...
    }
}
```

Es poco común — normalmente tu handler ya es scoped.

### ¿Qué pasa si ningún handler casa con un request?

`IServiceProvider.GetRequiredService<IRequestHandler<TRequest, TResponse>>()` lanza `InvalidOperationException`:

```
No service for type 'MediatR.IRequestHandler`2[MyRequest, MyResponse]' has been registered.
```

### ¿Qué pasa si varios handlers casan con un request?

DI devuelve el **primero** registrado (vía `TryAddTransient` en `ServiceRegistrar`). El wrapper llama a `GetRequiredService` (no `GetServices`), así que solo se invoca uno. Dos handlers para el mismo request es casi siempre un bug.

### ¿Qué pasa si no hay handler para una notificación?

Nada — `GetServices<INotificationHandler<TNotification>>()` devuelve secuencia vacía, y el publisher corre sobre cero executors. `Publish` devuelve una task completada.

### ¿Por qué las cachés de wrappers son estáticas?

Porque su identidad depende solo de tipos de mensaje, inmutables por-proceso. Las cachés sobreviven reconstrucciones del service-provider (p. ej. en fixtures de test), lo cual es deseable — no pagas el coste reflexivo en cada test.

### ¿Puedo personalizar `Mediator`?

Sí. Subclasa y pon `cfg.MediatorImplementationType = typeof(MyMediator)`. Sobrescribe `PublishCore` para tocar el dispatch de notificaciones.

### ¿Puedo usar AN.MediatR con AOT / trimming?

Trimming es posible con cuidado: cada handler debe ser **alcanzable por root** para el linker IL. El registro explícito (en lugar de escaneo) ayuda. El soporte AOT no se anuncia oficialmente — la librería usa reflexión en `ServiceRegistrar` y `Mediator`, así que verifica con tu escenario.

### ¿Para qué sirve `Unit`?

Sustituto de `void` en contextos genéricos. `Task<Unit>` es un tipo válido; `Task<void>` no. Ver [Paquete Contracts](13%20-%20Paquete_Contracts.md).

---

## Cuándo *no* usar AN.MediatR

- **Tienes < 10 handlers**. El coste de la abstracción supera el beneficio.
- **Tus commands/queries se encadenan estrechamente**. Si cada handler llama a tres otros, el bajo acoplamiento se vuelve falso acoplamiento vía recursión de `IMediator`. Prefiere llamadas directas.
- **Necesitas mensajería distribuida**. AN.MediatR es **solo en proceso**. Usa MassTransit, NServiceBus o similares para mensajería entre procesos / entre máquinas.
- **Quieres dispatch completamente estático**. AN.MediatR resuelve handlers vía DI en runtime — así "handler ausente" es error runtime, no de compilación.

---

## Lectura adicional

- [Wiki original de MediatR](https://github.com/jbogard/MediatR/wiki) — más ejemplos y patrones (la mayoría siguen aplicando).
- [Posts de Jimmy Bogard](https://www.jimmybogard.com/) — escritos del autor original sobre CQRS y mediator.
- `samples/AN.MediatR.Examples.*` — demos ejecutables en el repo.
