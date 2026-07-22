# Glosario

Terminología usada en toda la documentación, en orden alfabético.

---

**Action (exception action)**  
Implementación de `IRequestExceptionAction<TRequest, TException>`. Se dispara cuando un handler lanza, ejecuta sus efectos laterales (logging, métricas) y **siempre** relanza. No puede recuperar.

**Assembly scanning (escaneo de ensamblados)**  
Descubrimiento por reflexión de tipos que implementan interfaces de handler / behavior / procesador. Realizado por `ServiceRegistrar.AddMediatRClasses` durante `AddMediatR(...)`. Controlado por `RegisterServicesFromAssembly(...)` y amigos.

**Behavior (pipeline behavior)**  
Implementación de `IPipelineBehavior<TRequest, TResponse>`. Envuelve cada handler con lógica transversal (logging, validación, caching, transacciones, …). Recibe un delegate `next` y puede invocarlo, cortocircuitar, envolver la respuesta o capturar excepciones.

**Behavior (stream pipeline behavior)**  
Implementación de `IStreamPipelineBehavior<TRequest, TResponse>`. Misma idea que un behavior normal, pero para mensajes `IStreamRequest` — cede items según pasan por él.

**Caché (caché de wrappers)**  
Los tres campos estáticos `ConcurrentDictionary<Type, ...>` en la clase `Mediator` (`_requestHandlers`, `_notificationHandlers`, `_streamRequestHandlers`) que cachean instancias de wrappers genéricos por tipo runtime del mensaje. Compartidas a nivel de proceso.

**Command (comando)**  
En CQRS, un request que muta estado. Se expresa en AN.MediatR como `IRequest` (void) o `IRequest<TResponse>` (cuando se devuelve un resultado como un identificador).

**Contracts (`AN.MediatR.Contracts`)**  
Paquete NuGet separado que contiene las interfaces marcador mínimas (`IBaseRequest`, `IRequest`, `IRequest<T>`, `IStreamRequest<T>`, `INotification`) y el tipo valor `Unit`. Licenciado Apache-2.0 para uso en ensamblados de solo contratos.

**CQRS**  
*Command Query Responsibility Segregation*. Patrón arquitectónico que separa la ruta de escritura (comandos) de la de lectura (queries). Mapea naturalmente a la tríada `IRequest` / `IRequest<T>` / `INotification`.

**Dispatch**  
Acto de enviar un mensaje a través del mediator — `Send`, `Publish`, `CreateStream`.

**Dispatch dinámico**  
Sobrecargas con tipo `object`: `Send(object)`, `Publish(object)`, `CreateStream(object)`. Se introspecta el tipo runtime para encontrar la interfaz marcador. Útil para hosts genéricos, API gateways, arneses de test.

**ForeachAwaitPublisher**  
`INotificationPublisher` por defecto. Corre handlers secuencialmente, espera cada uno. Semántica fail-fast.

**Handler (request handler)**  
Implementación de `IRequestHandler<TRequest, TResponse>` o `IRequestHandler<TRequest>`. Recibe un request y devuelve una respuesta. Exactamente uno por tipo de request.

**Handler (notification handler)**  
Implementación de `INotificationHandler<TNotification>`. Se permiten varios por notificación; todos corren (orden según el publisher).

**Handler (stream request handler)**  
Implementación de `IStreamRequestHandler<TRequest, TResponse>`. Devuelve `IAsyncEnumerable<TResponse>` en vez de `Task<TResponse>`.

**Handler (exception handler)**  
Implementación de `IRequestExceptionHandler<TRequest, TResponse, TException>`. Se ejecuta cuando el handler lanza; puede recuperar llamando a `state.SetHandled(response)`.

**HandlersOrderer**  
Helper estático interno (`AN.MediatR.Internal.HandlersOrderer`) que prioriza handlers de excepciones por proximidad de ensamblado y namespace al request.

**IMediator**  
Interfaz combinada del mediator. Hereda `ISender` e `IPublisher`.

**INotificationPublisher**  
Interfaz de estrategia que decide **cómo** se invocan los handlers de notificaciones (secuencial, paralelo, con agregación de errores, …). Ver [Publicadores de Notificaciones](09%20-%20Publicadores_Notificaciones.md).

**IPublisher**  
Interfaz para la parte publish-subscribe del mediator (`Publish` / `Publish<T>`). Subconjunto de `IMediator`.

**IRequest**  
Marcador para un request void.

**IRequest&lt;TResponse&gt;**  
Marcador para un request que devuelve `TResponse`.

**ISender**  
Interfaz para el lado request/stream del mediator (`Send`, `Send<TResponse>`, `Send(object)`, `CreateStream`, `CreateStream(object)`). Subconjunto de `IMediator`.

**IStreamRequest&lt;TResponse&gt;**  
Marcador para un stream request que devuelve `IAsyncEnumerable<TResponse>`.

**Marker interface (interfaz marcador)**  
Interfaz sin miembros usada solo para restricciones de tipo y dispatch polimórfico (p. ej. `IRequest`, `INotification`).

**Mediator**  
Clase concreta que implementa `IMediator`. Ver [Implementación del Mediator](05%20-%20Implementacion_Mediator.md).

**MediatR.Contracts**  
Ver **Contracts**.

**MediatRServiceConfiguration**  
Objeto de configuración fluida pasado al delegate `AddMediatR(cfg => ...)`. Recoge ensamblados, behaviors, procesadores, etc.

**Middleware (pipeline)**  
Sinónimo libre de **pipeline behavior**. Refleja la similitud con el middleware de ASP.NET Core.

**MinVer**  
Herramienta MSBuild de versionado usada por `AN.MediatR.csproj`. Deriva versiones de tags git (prefijo `v*`).

**Notification (notificación)**  
Evento de fan-out despachado vía `IPublisher.Publish(...)`. Cero a muchos handlers por notificación, sin respuesta.

**NotificationHandlerExecutor**  
Record (`object HandlerInstance, Func<INotification, CancellationToken, Task> HandlerCallback`) que empareja un handler resuelto con un closure que sabe invocarlo. Materializado por `NotificationHandlerWrapperImpl<T>`. Pasado a `INotificationPublisher.Publish`.

**ObjectDetails**  
Implementación interna de `IComparer<ObjectDetails>` usada por `HandlersOrderer` para ordenar handlers por ensamblado / namespace / location.

**OpenBehavior**  
Objeto de valor (`AN.MediatR.Entities.OpenBehavior`) usado por `cfg.AddOpenBehaviors(IEnumerable<OpenBehavior>)` para registrar un behavior de genérico abierto con `ServiceLifetime` explícito.

**Open generic (genérico abierto)**  
Definición de tipo genérico (`LoggingBehavior<,>`) frente a genérico cerrado (`LoggingBehavior<CreateOrder, int>`).

**Pipeline**  
Cadena compuesta de wrappers `IPipelineBehavior<TRequest, TResponse>` + el handler final. Construida por `RequestHandlerWrapperImpl` con `Reverse().Aggregate(...)`.

**Post-processor (procesador post)**  
Implementación de `IRequestPostProcessor<TRequest, TResponse>`. Corre **después** del handler, recibe request y respuesta, devuelve `Task`. No puede reemplazar la respuesta.

**Pre-processor (procesador pre)**  
Implementación de `IRequestPreProcessor<TRequest>`. Corre **antes** del handler, recibe request, devuelve `Task`. No puede cortocircuitar.

**Publisher**  
Ver **INotificationPublisher**.

**Query**  
En CQRS, un request que devuelve datos sin mutar estado. `IRequest<TResponse>` en AN.MediatR.

**Request**  
Mensaje single-handler despachado vía `ISender.Send(...)`. Puede ser `IRequest` (void) o `IRequest<TResponse>`.

**RequestExceptionActionProcessorBehavior**  
Behavior interno que invoca `IRequestExceptionAction<TRequest, TException>` en excepción y relanza.

**RequestExceptionProcessorBehavior**  
Behavior interno que invoca `IRequestExceptionHandler<TRequest, TResponse, TException>` en excepción, permitiendo recuperación.

**RequestExceptionHandlerState&lt;TResponse&gt;**  
Objeto de estado mutable pasado a los handlers de excepción. `SetHandled(response)` recupera el request.

**RequestExceptionActionProcessorStrategy**  
Enum que controla si las actions corren **solo para excepciones no gestionadas** (por defecto) o **para todas** (incluyendo recuperadas).

**RequestHandlerDelegate&lt;TResponse&gt;**  
`delegate Task<TResponse> RequestHandlerDelegate<TResponse>(CancellationToken t = default)`. Callback "siguiente paso del pipeline".

**RequestHandlerWrapper**  
Wrapper abstracto de type-erasure sobre `IRequestHandler<,>`. Ver [Wrappers e Internos](12%20-%20Wrappers_e_Internos.md).

**ServiceRegistrar**  
Clase estática (`AN.MediatR.Registration.ServiceRegistrar`) que realiza el escaneo de ensamblados y registra servicios en `IServiceCollection`. Corazón de `AddMediatR`.

**Short-circuit (cortocircuito)**  
Un pipeline behavior eligiendo **no** llamar a `next`, devolviendo una respuesta directamente. Usado para caching, autorización, feature flags, idempotencia.

**Stream**  
Patrón request/response en el que la respuesta es `IAsyncEnumerable<TResponse>`. Manejado por `IStreamRequestHandler`, compuesto por `IStreamPipelineBehavior`.

**StreamHandlerDelegate&lt;TResponse&gt;**  
`delegate IAsyncEnumerable<TResponse> StreamHandlerDelegate<out TResponse>()`. Equivalente streaming de `RequestHandlerDelegate`.

**TaskWhenAllPublisher**  
`INotificationPublisher` built-in que arranca cada handler concurrentemente y espera `Task.WhenAll`.

**Type erasure (borrado de tipo)**  
Técnica de convertir una interfaz genérica (`IRequestHandler<TRequest, TResponse>`) en una clase base no genérica para que las instancias compartan caché. Implementada por la jerarquía de wrappers en `AN.MediatR.Wrappers`.

**TypeForwardings**  
Mecanismo CLR que permite a un ensamblado "redirigir" la búsqueda de un tipo a otro. Usado por `MediatR.dll` para redirigir `IRequest`, `INotification`, `Unit`, etc. a `MediatR.Contracts.dll`.

**Unit**  
Tipo de valor singleton (`MediatR.Unit`) usado como sustituto de `void` en contextos genéricos. `Unit.Value` es el singleton; `Unit.Task` es un `Task<Unit>` preasignado.

**Wrapper**  
Cualquiera de las clases internas en `AN.MediatR.Wrappers` que traducen una llamada a handler genérico en una llamada virtual con tipo borrado. Ver **Type erasure**.
