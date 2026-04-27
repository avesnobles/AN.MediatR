# Integración de Contenedores DI

AN.MediatR depende de `Microsoft.Extensions.DependencyInjection.Abstractions` — cualquier contenedor que exponga sus servicios como `IServiceProvider` se puede usar. El repositorio incluye samples listos para ejecutar con las alternativas más populares.

Cada sample resuelve `IMediator` desde el contenedor y llama al `Runner.Run(mediator, writer, projectName, testStreams: true)` compartido en `samples/MediatR.Examples/Runner.cs`. El runner envía `Ping`, publica `Pinged`, dispara `Ponged` (diseñado para fallar), envía `Jing` (también para fallar), opcionalmente hace streaming de `Sing`, y luego ejercita handlers / actions de excepciones.

---

## Nativo: `Microsoft.Extensions.DependencyInjection`

Sample: `samples/MediatR.Examples.AspNetCore/Program.cs`.

```csharp
var services = new ServiceCollection();
services.AddSingleton<TextWriter>(writer);

services.AddMediatR(cfg =>
{
    cfg.RegisterServicesFromAssemblies(typeof(Ping).Assembly, typeof(Sing).Assembly);
});

// Stream handler registrado manualmente para ilustrar
services.AddScoped(typeof(IStreamRequestHandler<Sing, Song>), typeof(SingHandler));

// Behaviors de pipeline de genéricos abiertos
services.AddScoped(typeof(IPipelineBehavior<,>), typeof(GenericPipelineBehavior<,>));
services.AddScoped(typeof(IRequestPreProcessor<>), typeof(GenericRequestPreProcessor<>));
services.AddScoped(typeof(IRequestPostProcessor<,>), typeof(GenericRequestPostProcessor<,>));
services.AddScoped(typeof(IStreamPipelineBehavior<,>), typeof(GenericStreamPipelineBehavior<,>));

var provider = services.BuildServiceProvider();
var mediator = provider.GetRequiredService<IMediator>();
```

Notas:

- `services.AddLogging()` es opcional — AN.MediatR no hace logging por sí misma, pero la mayoría de apps lo querrán igualmente.
- `AddMediatR` puede registrar behaviors abiertos directamente con `cfg.AddOpenBehavior(typeof(GenericPipelineBehavior<,>))`, pero usar `services.AddScoped(typeof(IPipelineBehavior<,>), typeof(GenericPipelineBehavior<,>))` tras `AddMediatR` también funciona.

---

## Autofac

Sample: `samples/MediatR.Examples.Autofac/`.

Autofac soporta genéricos abiertos nativamente. Patrón típico:

```csharp
var builder = new ContainerBuilder();

builder.RegisterType<Mediator>().As<IMediator>().InstancePerLifetimeScope();

// Escaneo para handlers
var assembly = typeof(Ping).Assembly;
builder.RegisterAssemblyTypes(assembly)
    .AsClosedTypesOf(typeof(IRequestHandler<,>))
    .AsImplementedInterfaces();
builder.RegisterAssemblyTypes(assembly)
    .AsClosedTypesOf(typeof(INotificationHandler<>))
    .AsImplementedInterfaces();

// Behavior de genérico abierto
builder.RegisterGeneric(typeof(GenericPipelineBehavior<,>))
    .As(typeof(IPipelineBehavior<,>))
    .InstancePerLifetimeScope();

var container = builder.Build();
var mediator = container.Resolve<IMediator>();
```

Particularidades Autofac:

- Los genéricos abiertos se registran con `RegisterGeneric(...).As(typeof(Interface<,>))`.
- `AsClosedTypesOf(...)` encuentra cada cierre concreto de una interfaz abierta — exactamente lo que hace `ServiceRegistrar`, con semántica Autofac.

---

## DryIoc

Sample: `samples/MediatR.Examples.DryIoc/`.

```csharp
var container = new Container();

container.Register<TextWriter>(reuse: Reuse.Singleton, made: Made.Of(() => writer));

container.Register<IMediator, Mediator>(Reuse.Scoped);

// Escaneo para handlers
container.RegisterMany(new[] { typeof(Ping).Assembly, typeof(Sing).Assembly },
    serviceTypeCondition: t => t.IsGenericType && (
        t.GetGenericTypeDefinition() == typeof(IRequestHandler<,>) ||
        t.GetGenericTypeDefinition() == typeof(INotificationHandler<>) ||
        t.GetGenericTypeDefinition() == typeof(IStreamRequestHandler<,>)));

// Behavior de genérico abierto
container.Register(typeof(IPipelineBehavior<,>), typeof(GenericPipelineBehavior<,>));

var mediator = container.Resolve<IMediator>();
```

DryIoc destaca por su velocidad y soporta `RegisterMany(...)` con predicados custom.

---

## Lamar

Sample: `samples/MediatR.Examples.Lamar/`.

Lamar es un reemplazo drop-in de `ServiceCollection` con mejor soporte de genéricos abiertos. Escaneo idiomático:

```csharp
var container = new Container(cfg =>
{
    cfg.Scan(scanner =>
    {
        scanner.AssemblyContainingType<Ping>();
        scanner.ConnectImplementationsToTypesClosing(typeof(IRequestHandler<,>));
        scanner.ConnectImplementationsToTypesClosing(typeof(INotificationHandler<>));
        scanner.AddAllTypesOf(typeof(IPipelineBehavior<,>));
    });

    cfg.For<IMediator>().Use<Mediator>();
    cfg.For(typeof(IPipelineBehavior<,>)).Add(typeof(GenericPipelineBehavior<,>));
});

var mediator = container.GetInstance<IMediator>();
```

`Scan.ConnectImplementationsToTypesClosing(...)` es conceptualmente idéntico al `ServiceRegistrar.ConnectImplementationsToTypesClosing(...)` de AN.MediatR.

---

## LightInject

Sample: `samples/MediatR.Examples.LightInject/`.

```csharp
var container = new ServiceContainer();

container.Register<IMediator, Mediator>();
container.Register(typeof(IPipelineBehavior<,>), typeof(GenericPipelineBehavior<,>));

container.RegisterAssembly(typeof(Ping).Assembly, (type, implementation) =>
    type.IsGenericType
    && (type.GetGenericTypeDefinition() == typeof(IRequestHandler<,>)
        || type.GetGenericTypeDefinition() == typeof(INotificationHandler<>)));

var mediator = container.GetInstance<IMediator>();
```

---

## SimpleInjector

Sample: `samples/MediatR.Examples.SimpleInjector/`.

SimpleInjector es notoriamente estricto con el orden de decoradores y desajustes de lifetime — un buen banco de pruebas para verificar que los registros de AN.MediatR son correctos.

Patrón clave:

```csharp
var container = new Container();

container.Register<IMediator, Mediator>(Lifestyle.Singleton);

var assembly = typeof(Ping).Assembly;

container.Register(typeof(IRequestHandler<,>), new[] { assembly });
container.Collection.Register(typeof(INotificationHandler<>), new[] { assembly });

// Register open-generic behaviors as decorators
container.RegisterDecorator(typeof(IPipelineBehavior<,>), typeof(GenericPipelineBehavior<,>));

var mediator = container.GetInstance<IMediator>();
```

Notas:

- Los handlers de notificaciones deben usar `container.Collection.Register` porque pueden ser múltiples.
- `RegisterDecorator(...)` asegura que el decorador se aplica alrededor del handler más interno.
- SimpleInjector fuerza verificación con `container.Verify()` — llámalo en startup en desarrollo.

---

## Stashbox

Sample: `samples/MediatR.Examples.Stashbox/`.

```csharp
var container = new StashboxContainer();

container.Register<IMediator, Mediator>();
container.Register(typeof(IPipelineBehavior<,>), typeof(GenericPipelineBehavior<,>));

container.RegisterAssemblyContaining<Ping>(typeSelector: t =>
    t.GetInterfaces().Any(i => i.IsGenericType && (
        i.GetGenericTypeDefinition() == typeof(IRequestHandler<,>) ||
        i.GetGenericTypeDefinition() == typeof(INotificationHandler<>))));

var mediator = container.Resolve<IMediator>();
```

---

## Castle Windsor

Sample: `samples/MediatR.Examples.Windsor/`.

```csharp
var container = new WindsorContainer();

container.Register(Component.For<IMediator>().ImplementedBy<Mediator>());

container.Register(Classes.FromAssemblyContaining<Ping>()
    .BasedOn(typeof(IRequestHandler<,>))
    .WithServiceAllInterfaces());

container.Register(Classes.FromAssemblyContaining<Ping>()
    .BasedOn(typeof(INotificationHandler<>))
    .WithServiceAllInterfaces()
    .AllowMultipleMatches());

container.Register(Component.For(typeof(IPipelineBehavior<,>))
    .ImplementedBy(typeof(GenericPipelineBehavior<,>)));

var mediator = container.Resolve<IMediator>();
```

`AllowMultipleMatches()` es importante para los handlers de notificaciones — sin él, Windsor solo registra el primer match.

---

## Trampas comunes entre contenedores

### 1. Registro single-instance de handlers de notificaciones

Muchos contenedores registran solo la primera implementación para una interfaz dada. Para `INotificationHandler<>` necesitas explícitamente registro por colección (`AllowMultipleMatches`, `Collection.Register`, `RegisterMany`, etc.). Si no, `mediator.Publish(...)` invocará silenciosamente solo un handler.

### 2. Scoping de `IMediator` vs. `IServiceProvider`

Si registras `IMediator` como scoped, debes **resolverlo dentro de un scope**. La mayoría de contenedores expone una API de child-scope — prefiere scoped para ASP.NET Core, transient para consola/host. Para ASP.NET clásico (pre-Core) usa `PerRequest` o equivalente.

### 3. Registro de behaviors de genérico abierto

Si tu behavior tiene un tipo de respuesta genérico anidado (p. ej. `IPipelineBehavior<TRequest, Result<T>>`), la mayoría de contenedores no pueden auto-cerrarlo. El registrar nativo de AN.MediatR lo gestiona vía `RegisterClosedBehaviorsFromAssemblies` — basta con registrar el behavior abierto con `cfg.AddOpenBehavior(...)` y las variantes cerradas se generan automáticamente. Para contenedores de terceros que no pasen por `AddMediatR(...)`, quizá necesites registrar cada variante cerrada manualmente o usar funcionalidades específicas del contenedor.

### 4. Caché de wrappers

La clase `Mediator` mantiene cachés `static ConcurrentDictionary` **a nivel de proceso**. El contenedor DI elegido no afecta eso — pero si lanzas varios contenedores en el mismo proceso (¡tests de integración!) las cachés se comparten. Normalmente no es problema porque los wrappers son sin estado.

---

## Checklist entre contenedores

Sin importar el contenedor, asegúrate de:

- [ ] `IMediator` resuelve a `Mediator` (o tu subclase).
- [ ] `ISender` e `IPublisher` resuelven a la misma instancia de `IMediator` por scope.
- [ ] `IServiceProvider` está disponible (propio del contenedor o adaptador — el soporte de `Microsoft.Extensions.DependencyInjection.Abstractions` es obligatorio).
- [ ] `INotificationHandler<T>` está registrado como **colección** / `AllowMultipleMatches`.
- [ ] `IPipelineBehavior<,>` e `IStreamPipelineBehavior<,>` están registrados como colecciones, con orden preservado.

Si cumples todo, `Mediator.Send(...)` / `Publish(...)` / `CreateStream(...)` se comportan idénticamente al camino DI nativo.

---

## Profundizando: por qué el escaneo de ensamblados es opcional

Puedes saltarte `RegisterServicesFromAssembly(...)` y registrar handlers a mano:

```csharp
services.AddMediatR(cfg => cfg.RegisterServicesFromAssemblyContaining<Ping>());   // sigue siendo obligatorio pasar al menos un ensamblado
services.AddTransient<IRequestHandler<Ping, Pong>, PingHandler>();
services.AddTransient<INotificationHandler<Pinged>, PingedHandler>();
```

Pros del registro explícito:

- Arranque más rápido para ensamblados grandes.
- Intención más clara — sin magia de reflexión.
- Mejor para escenarios AOT / trimming donde la reflexión está restringida.

Contras:

- Cada handler nuevo requiere editar el composition root.
- Los behaviors de genéricos abiertos son más difíciles de registrar sin escaneo.

Elige lo que mejor se adapte a tu codebase; ambos enfoques están totalmente soportados.
