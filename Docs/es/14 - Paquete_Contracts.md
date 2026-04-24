# Paquete Contracts

`MediatR.Contracts` es un paquete NuGet separado, sin dependencias, que contiene solo las interfaces marcador que necesita cada tipo request / notification / stream-request. Este capítulo explica qué contiene, por qué está separado y cómo `TypeForwardings.cs` lo mantiene compatible binariamente.

---

## Qué hay dentro

Fuente: [src/MediatR.Contracts/](../../src/MediatR.Contracts/).

```
src/MediatR.Contracts/
├── INotification.cs      # public interface INotification { }
├── IRequest.cs           # IBaseRequest, IRequest, IRequest<TResponse>
├── IStreamRequest.cs     # public interface IStreamRequest<out TResponse> { }
├── Unit.cs               # tipo valor sustituto de void
└── MediatR.Contracts.csproj
```

Y eso es **todo el paquete**. Cinco archivos. Sin lógica — solo marcadores y un tipo de valor.

### Resumen del csproj

```xml
<PropertyGroup>
  <TargetFramework>netstandard2.0</TargetFramework>
  <Version>2.0.1</Version>
  <PackageLicenseExpression>Apache-2.0</PackageLicenseExpression>
  <RootNamespace>MediatR</RootNamespace>
  <!-- SignAssembly, strong-named con MediatR.snk -->
</PropertyGroup>
```

- **Solo netstandard2.0**. Al no tener lógica, un único target es suficiente y lo hace accesible desde cualquier runtime moderno o legacy.
- **Licencia Apache-2.0**. Deliberadamente permisiva — porque el paquete principal `MediatR` es RPL-1.5 o comercial, y necesitas los tipos de request/notification usables en cualquier proyecto sin restricciones de licenciamiento.
- **Versión fija `2.0.1`** — no guiada por el versionado `MinVer` del paquete principal. Se espera que los contratos sean estables.
- **Namespace `MediatR`** — mismo namespace que la librería principal, así que los consumidores solo escriben `using MediatR;` sin importar qué paquete define un tipo.

---

## Por qué un paquete separado

### 1. Licenciamiento independiente

La librería principal `MediatR` se distribuye bajo RPL 1.5 (o licencia comercial — ver [Licenciamiento](13%20-%20Licenciamiento.md) y `LICENSE.md`). El paquete de contratos es Apache-2.0, mucho más permisiva.

Esta dicotomía te permite definir tus tipos de request y notification en **cualquier** librería downstream — incluso librerías que no pueden aceptar dependencia RPL — sin arrastrar el binario principal.

### 2. Proyectos de contratos de API

Es habitual tener un proyecto dedicado a contratos API (p. ej. `MyApp.Contracts`) referenciado por el servidor y varios clientes (Blazor, gRPC, workers, etc.). Esos clientes no necesitan el mediator — solo los tipos para serializar/deserializar.

```
MyApp.Api       → referencia MediatR + MyApp.Contracts (tiene handlers, usa el mediator)
MyApp.Contracts → referencia MediatR.Contracts          (solo define tipos IRequest)
MyApp.Client    → referencia MyApp.Contracts             (envía requests vía HTTP/gRPC)
```

### 3. Blazor WebAssembly / escenarios solo-cliente

Del README:

> This package is useful in scenarios where your MediatR contracts are in a separate assembly/project from handlers. Example scenarios include:
> - API contracts
> - gRPC contracts
> - Blazor

Una app Blazor WASM suele querer compartir DTOs con el servidor pero no hostea un mediator. Llevarse solo `MediatR.Contracts` mantiene el payload WASM mínimo.

### 4. Separación limpia de responsabilidades

Marcadores + modelo de datos en `MediatR.Contracts`. Mecánica de dispatch + pipeline + DI + licenciamiento en `MediatR`. La división sigue la costura natural.

---

## Cómo coexisten ambos paquetes: `TypeForwardings`

Fuente: [src/MediatR/TypeForwardings.cs](../../src/MediatR/TypeForwardings.cs).

```csharp
using System.Runtime.CompilerServices;
using MediatR;

[assembly: TypeForwardedTo(typeof(IBaseRequest))]
[assembly: TypeForwardedTo(typeof(IRequest<>))]
[assembly: TypeForwardedTo(typeof(IRequest))]
[assembly: TypeForwardedTo(typeof(INotification))]
[assembly: TypeForwardedTo(typeof(Unit))]
```

`TypeForwardedTo` le dice al resolver de tipos CLR: *"si alguien busca `MediatR.IRequest` en el ensamblado `MediatR`, redirígelo a la definición real en `MediatR.Contracts`."*

### Por qué importa

Sin type forwarding tendrías dos problemas:

1. **Definiciones duplicadas**. Si `MediatR.IRequest` existiera tanto en `MediatR.Contracts.dll` como en `MediatR.dll`, cualquier código que referencie ambos obtendría errores de ambigüedad. Peor: el CLR los trataría como dos tipos distintos aunque tengan el mismo namespace y nombre.
2. **Ruptura de compatibilidad binaria**. Consumidores compilados contra una versión antigua de `MediatR` que definía `IRequest` localmente romperían al actualizar a una versión que lo movió a un ensamblado separado.

Type forwarding soluciona ambos: las definiciones viven físicamente en un solo sitio (`MediatR.Contracts`) y el ensamblado `MediatR` anuncia "yo sigo proveyendo esos tipos — solo tienes que pedírmelos y te redirijo".

Esto significa:

- Puedes referenciar cualquiera de los dos paquetes y `MediatR.IRequest` siempre refiere al mismo tipo CLR.
- Ensamblados compilados contra versiones antiguas de `MediatR` siguen cargando.

---

## `Unit` en detalle

El tipo de valor `Unit` es el miembro más sustancial del paquete de contratos.

Fuente: [src/MediatR.Contracts/Unit.cs](../../src/MediatR.Contracts/Unit.cs).

```csharp
public readonly struct Unit : IEquatable<Unit>, IComparable<Unit>, IComparable
{
    private static readonly Unit _value = new();

    public static ref readonly Unit Value => ref _value;
    public static Task<Unit> Task { get; } = System.Threading.Tasks.Task.FromResult(_value);

    public int CompareTo(Unit other) => 0;
    int IComparable.CompareTo(object? obj) => 0;

    public override int GetHashCode() => 0;
    public bool Equals(Unit other) => true;
    public override bool Equals(object? obj) => obj is Unit;

    public static bool operator ==(Unit first, Unit second) => true;
    public static bool operator !=(Unit first, Unit second) => false;

    public override string ToString() => "()";
}
```

### Propiedades clave

- **`readonly struct`** — tipo de valor de tamaño cero, sin coste de asignación.
- **`static ref readonly Unit Value`** — expone una referencia a un singleton, para que los llamadores puedan pasarlo sin copia implícita.
- **`static Task<Unit> Task`** — `Task.FromResult(Unit.Value)` preasignado, útil como "completado" barato.
- **Semántica de igualdad** — todo `Unit` es igual a todo `Unit`. `GetHashCode()` siempre es `0`. `CompareTo` siempre `0`.
- **`ToString() => "()"`** — para que los logs/debugger muestren `()` para respuestas void.

### Cómo lo usa la librería

- Los requests void (`IRequest`) se unifican internamente con los tipados usando `Unit` como su respuesta:
    - `RequestHandlerWrapperImpl<TRequest>.Handle(...)` devuelve `Task<Unit>`.
    - Los behaviors registrados para requests void tienen tipo de servicio `IPipelineBehavior<TRequest, Unit>`.
- En código de aplicación rara vez tipearás `Unit` — la sobrecarga `Mediator.Send<TRequest>(TRequest)` ya devuelve `Task`, no `Task<Unit>`, ocultando `Unit` al llamador.

### `Unit.Task` como bonus

Cuando implementas un handler síncrono que debe conformar a `Task<Unit>`, puedes devolver `Unit.Task` directamente:

```csharp
public class LogPingHandler : IRequestHandler<Ping, Unit>   // Unit explícito para ilustrar
{
    public Task<Unit> Handle(Ping request, CancellationToken ct)
    {
        Console.WriteLine(request.Message);
        return Unit.Task;
    }
}
```

— ahorra una asignación frente a `Task.FromResult(Unit.Value)`.

---

## Contrato de estabilidad

Como `MediatR.Contracts` es una API pública expuesta a muchas librerías downstream, su versión se fija deliberadamente en `MediatR.csproj`:

```xml
<PackageReference Include="MediatR.Contracts" Version="[2.0.1, 3.0.0)" />
```

- Límite inferior exacto `2.0.1`.
- Límite superior exclusivo `3.0.0`.

Garantiza que cualquier versión de `MediatR` que referencia estos contratos es compatible con cualquier `2.x`.

---

## Cuándo depender de cada paquete

| Escenario | Depende de |
|-----------|------------|
| Alojas el mediator (servidor, worker, app de escritorio) | `MediatR` |
| Defines tipos de request/notification en una librería de solo contratos | `MediatR.Contracts` |
| Escribes un cliente Blazor WASM que solo hace llamadas HTTP con requests tipados | `MediatR.Contracts` |
| Escribes un proyecto de contratos gRPC | `MediatR.Contracts` |
| Escribes pipeline behaviors o handlers | `MediatR` |
| Construyes un cliente que *resolverá* `IMediator` (aunque proxye a HTTP) | `MediatR` |

Regla general: *si llamas a `.Send(...)` o `.Publish(...)` necesitas `MediatR`; si solo declaras tipos, `MediatR.Contracts` basta.*

---

## Lista completa de tipos públicos (ambos paquetes combinados)

Namespace `MediatR`:

- De `MediatR.Contracts`: `IBaseRequest`, `IRequest`, `IRequest<TResponse>`, `IStreamRequest<TResponse>`, `INotification`, `Unit`.
- De `MediatR`: `IMediator`, `ISender`, `IPublisher`, `IRequestHandler<TRequest, TResponse>`, `IRequestHandler<TRequest>`, `NotificationHandler<TNotification>`, `INotificationHandler<TNotification>`, `IStreamRequestHandler<TRequest, TResponse>`, `IPipelineBehavior<TRequest, TResponse>`, `IStreamPipelineBehavior<TRequest, TResponse>`, `RequestHandlerDelegate<TResponse>`, `StreamHandlerDelegate<TResponse>`, `INotificationPublisher`, `NotificationHandlerExecutor`, `Mediator`.

Namespace `MediatR.Pipeline`: procesadores y handlers de excepciones.

Namespace `MediatR.NotificationPublishers`: los dos publishers built-in.

Namespace `MediatR.Entities`: `OpenBehavior`.

Namespace `Microsoft.Extensions.DependencyInjection`: `AddMediatR`, `MediatRServiceConfiguration`, `RequestExceptionActionProcessorStrategy`.
