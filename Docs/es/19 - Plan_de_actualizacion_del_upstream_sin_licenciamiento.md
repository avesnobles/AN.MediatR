# Plan de actualización desde el upstream sin licenciamiento en ejecución

## 1. Propósito y resultado esperado

Este documento convierte la actualización del repositorio en tareas pequeñas y verificables. El resultado esperado es:

- conservar el fork, los ensamblados, los paquetes y los espacios de nombres `AN.MediatR`;
- incorporar el comportamiento funcional y las pruebas no relacionadas con licencias del upstream;
- **no** incorporar activación, validación, claves, telemetría ni avisos de licencia en tiempo de ejecución;
- conservar una trazabilidad clara de toda diferencia intencionada respecto al upstream.

No es un plan para publicar ni para modificar el código durante esta primera tanda. Las siguientes sesiones deben ejecutar las fases en orden y cerrar cada una con una prueba concreta.

## 2. Línea base analizada

| Elemento | Valor |
|---|---|
| Repositorio de referencia local | `C:\devtest\MediatR` |
| Commit de referencia | `916ef1b` — *Merge pull request #1175 from LuckyPennySoftware/feature/license-key-env-var* |
| Fecha del commit de referencia | 2 de julio de 2026 |
| Base upstream ya presente en el historial del fork | `f72aef8` |
| Estado del fork durante el análisis | árbol de trabajo con el renombrado `MediatR` → `AN.MediatR` aún sin consolidar en Git |

La comparación se ha realizado sobre los archivos reales, excluyendo `.git`, `.vs`, `bin`, `obj`, `artifacts`, `.claude` y la documentación existente. Al normalizar rutas y texto por el cambio de nombre, el núcleo de producción del fork coincide con la base upstream `f72aef8`, salvo la retirada deliberada de licenciamiento.

Entre `f72aef8` y `916ef1b`, el upstream cambia nueve archivos (382 líneas añadidas y 20 eliminadas). Los cambios de código de ese intervalo son exclusivamente del subsistema de licencia: validación en segundo plano, tratamiento de claves vacías y claves de entorno. Por tanto, no hay una interfaz funcional nueva de MediatR que deba añadirse al fork para alcanzar esta referencia sin licenciamiento.

## 3. Alcance exacto de «sin licencia»

En este plan, *sin licencia* significa **sin mecanismo comercial/de activación en el binario ni en el registro de DI**. No significa borrar los avisos legales, atribuciones o metadatos de distribución que correspondan legalmente.

### Elementos que deben permanecer excluidos

No portar ninguno de los siguientes elementos desde el upstream:

| Área | Elementos excluidos | Motivo |
|---|---|---|
| Código | `src/MediatR/Licensing/BuildInfo.cs`, `Edition.cs`, `License.cs`, `LicenseAccessor.cs`, `LicenseValidator.cs`, `ProductType.cs` | Modelo, lectura y validación JWT de licencia. |
| Recursos | `src/MediatR/license.txt` | Texto de licencia del producto upstream. |
| API pública | `Mediator.LicenseKey` y `MediatRServiceConfiguration.LicenseKey` | Configuración de clave que no tiene función en el fork. |
| DI | `CheckLicense`, `LicenseChecked`, `LicenseAccessor`, `LicenseValidator` y el registro de `ILoggerFactory` destinado a ellos | Validación asíncrona y registro de servicios de licencia. |
| Dependencias | `Microsoft.IdentityModel.JsonWebTokens` y `Microsoft.Extensions.Logging.Abstractions` cuando se usen exclusivamente para licencia | Dependencias introducidas por el validador. |
| Compilación | target `EmbedBuildDate` si sólo alimenta `Licensing/BuildInfo` | Metadato de fecha usado por la licencia perpetua. |
| Pruebas | `test/MediatR.Tests/Licensing/**` | Cubren un comportamiento que el fork no ofrece. |
| Documentación | configuración de claves, variables `MEDIATR_LICENSE_KEY` / `LUCKYPENNY_LICENSE_KEY`, filtros del logger de Lucky Penny y enlaces de compra | No deben aparecer como funcionalidad de `AN.MediatR`. |

La implementación ya ha eliminado el grueso de estos elementos. La regla para sesiones futuras es que una actualización no puede reintroducirlos de forma indirecta al copiar un `.csproj`, un helper de pruebas o un archivo de documentación.

### Decisión legal pendiente antes de publicar

El `LICENSE.md` del upstream analizado declara RPL-1.5/una licencia comercial. El fork actual declara Apache-2.0 y explica que partía de MediatR v12.5 bajo Apache-2.0. Copiar código posterior desde el upstream no demuestra por sí solo que pueda redistribuirse bajo Apache-2.0.

Antes de generar o publicar un paquete debe documentarse la procedencia de cada cambio incorporado y obtenerse la confirmación legal correspondiente. Hasta entonces, se puede preparar y probar el port local, pero no debe afirmarse que la actualización completa es redistribuible bajo Apache-2.0 ni copiar `LICENSE.md` del upstream. Esta es una condición de publicación, no una razón para reactivar el licenciamiento en ejecución.

## 4. Inventario de diferencias y tratamiento

### 4.1. Producción

| Origen upstream | Destino previsto en el fork | Acción |
|---|---|---|
| `src/MediatR.Contracts/**` | `src/AN.MediatR.Contracts/**` | Mantener el contenido funcional equivalente, sustituyendo únicamente namespaces, rutas, ensamblados y referencias del fork. |
| `src/MediatR/**`, salvo `Licensing/**` y `license.txt` | `src/AN.MediatR/**` | Portar sólo diferencias funcionales futuras mediante merge de tres vías; hoy no hay diferencias no relacionadas con licencia que requieran código nuevo. |
| `MediatRServiceCollectionExtensions.cs` | actualmente `MicrosoftExtensionsDI/ServiceCollectionExtensions.cs` | Renombrar archivo y tipo público a `MediatRServiceCollectionExtensions` para recuperar la superficie pública del upstream; conservar `AddMediatR` y omitir todos los miembros de licencia. |
| `MediatR.csproj` | `AN.MediatR.csproj` | Mantener identidad, claves y referencias `AN.*`; adoptar las mejoras de empaquetado sólo si no incluyen licencia, branding o infraestructura de Lucky Penny. |
| `MediatR.Contracts.csproj` | `AN.MediatR.Contracts.csproj` | Mantener el paquete/ensamblado del fork. No sustituirlo por una dependencia de `MediatR.Contracts`. |

Las únicas diferencias de código de producción observadas frente al upstream son las exclusiones de licencia en `Mediator`, `ServiceRegistrar`, extensiones de `IServiceCollection`, archivos de proyecto y la carpeta `Licensing`. Son intencionadas.

### 4.2. Solución, muestras y pruebas

| Elemento upstream ausente o distinto | Acción prevista |
|---|---|
| `MediatR.slnx` | Crear `AN.MediatR.slnx` adaptando todas las rutas y añadiendo los tres grupos: `src`, `test`, `samples`. Mantener temporalmente `AN.MediatR.sln` hasta que la nueva solución compile y esté validada. |
| `test/MediatR.DependencyInjectionTests` (33 archivos) | Crear `test/AN.MediatR.DependencyInjectionTests` y portar pruebas/fixtures de Microsoft DI, Autofac, DryIoc, Lamar, LightInject y Stashbox. |
| `test/MediatR.Tests/GlobalUsings.cs` | Añadirlo con namespaces `AN.MediatR` cuando simplifique los tests; verificar que no crea conflictos con el framework objetivo. |
| `test/MediatR.Tests/TestContainer.cs` | Añadir una variante libre de licencia: registrar sólo servicios del mediador necesarios y no `ILoggerFactory`, `LicenseAccessor` ni `LicenseValidator`. |
| Pruebas unitarias existentes | Hacer merge por archivo, no sobrescribir a ciegas. Las pruebas actuales usan Lamar directamente en varios casos; el upstream usa `TestContainer` y separa las comprobaciones multi-contenedor en otro proyecto. |
| `samples/**` | Conservar todas las muestras renombradas. Después de la migración de proyectos, compilar cada una contra `AN.MediatR`; no volver a introducir dependencias de paquetes upstream. |
| `test/MediatR.Tests/Licensing/**` | No crear equivalente. Sustituirlas por un test negativo de guardia descrito en la fase 7. |

### 4.3. Automatización y documentación

| Archivo upstream | Tratamiento en `AN.MediatR` |
|---|---|
| `.github/workflows/ci.yml` | Adoptar la estructura actual: .NET 8/9/10, `actions/checkout@v4`, artefactos `.trx`, permisos mínimos y rama principal real del fork. Sustituir nombres de paquete, feeds y secretos. |
| `.github/workflows/test-report.yml` | Añadirlo si el repositorio usa GitHub Actions: permite publicar resultados de PRs, incluidos forks, con el token adecuado en un flujo separado. |
| `.github/workflows/release.yml` | Portar sólo build, test, empaquetado, SBOM y adjuntos que sean útiles. No copiar OIDC de Azure, Key Vault, certificado, feeds Feedz.io/MyGet ni secretos de Lucky Penny. Configurarlos sólo con credenciales y URLs propias. |
| `Build.ps1`, `BuildContracts.ps1`, `Push.ps1` | Actualizar rutas para ambos proyectos `AN.*`; conservar el empaquetado de ambos paquetes del fork. Mantener `--skip-duplicate` si la política de publicación lo requiere. |
| `README.md` | Actualizar tras el código: instalación de `AN.MediatR`/`AN.MediatR.Contracts`, referencia de versión upstream y lista de diferencias; omitir cualquier apartado de claves. |
| `.gitattributes`, `.gitignore` | Adoptar las mejoras que eviten artefactos generados y normalicen el repositorio, sin borrar reglas de seguridad ya existentes como `devskim.yml` salvo decisión explícita. |

## 5. Interfaces y API que se deben conservar

No hay una interfaz nueva que implementar en el upstream `916ef1b`. La tarea es preservar, con namespaces `AN.MediatR`, las interfaces existentes y sus firmas, porque constituyen la compatibilidad funcional del fork.

| Grupo | Interfaces/superficie que deben seguir presentes |
|---|---|
| Contratos | `IRequest`, `IRequest<TResponse>`, `INotification`, `IStreamRequest<TResponse>`, `Unit` |
| Envío/publicación | `ISender`, `IPublisher`, `IMediator`, `INotificationPublisher` |
| Handlers | `IRequestHandler<TRequest,TResponse>`, `IRequestHandler<TRequest>`, `INotificationHandler<TNotification>`, `IStreamRequestHandler<TRequest,TResponse>` |
| Pipeline | `IPipelineBehavior<TRequest,TResponse>`, `IStreamPipelineBehavior<TRequest,TResponse>`, `IRequestPreProcessor<TRequest>`, `IRequestPostProcessor<TRequest,TResponse>`, `IRequestExceptionHandler<TRequest,TResponse,TException>`, `IRequestExceptionAction<TRequest,TException>` |
| DI | extensiones `AddMediatR(...)` y la configuración `MediatRServiceConfiguration`, sin miembros `LicenseKey` |

Los fixtures del nuevo proyecto `AN.MediatR.DependencyInjectionTests` deberán implementar los contratos de prueba del upstream (`IRequest<T>`, `IRequestHandler<,>`, `IRequestHandler<>`, `INotification`, `INotificationHandler<>`, `IStreamRequest<T>` e `IStreamRequestHandler<,>`). Son implementaciones de prueba, no API nueva de producción.

La única diferencia pública deliberada es la ausencia de `Mediator.LicenseKey` y `MediatRServiceConfiguration.LicenseKey`. No se debe introducir un stub que ignore esas claves: ocultaría una incompatibilidad y perpetuaría una API que el fork no soporta.

## 6. Orden de implementación por sesiones

### Fase 0 — Preparar una base reproducible

1. No ejecutar `git reset`, `git checkout --` ni limpiezas sobre el árbol actual: contiene el renombrado del fork aún no consolidado.
2. Registrar en una rama de trabajo o commit independiente el estado de `AN.MediatR` antes de traer cambios adicionales.
3. Fijar `916ef1b` como referencia de esta actualización y dejar registrada cualquier actualización posterior como una nueva tarea, no como una referencia móvil.
4. Generar una tabla de correspondencias de ruta `MediatR` → `AN.MediatR` para usarla en los merges y evitar referencias residuales al paquete upstream.

**Criterio de salida:** el equipo puede repetir la comparación contra el mismo commit sin depender de un clon remoto.

### Fase 1 — Estructura de solución y proyectos

1. Crear `AN.MediatR.slnx` a partir de la solución upstream, sustituyendo rutas y nombres de proyectos.
2. Añadir el proyecto `test/AN.MediatR.DependencyInjectionTests/AN.MediatR.DependencyInjectionTests.csproj` con las referencias de proyecto a `AN.MediatR` y las dependencias de contenedor usadas por los tests.
3. Añadir todos los fixtures, contratos y pruebas de ese proyecto bajo el namespace `AN.MediatR.DependencyInjectionTests`.
4. Revisar rutas de muestras y proyectos de benchmark; todos deben referenciar proyectos/paquetes `AN.*`, nunca `MediatR` o `MediatR.Contracts` del upstream.
5. Una vez que `AN.MediatR.slnx` compile, decidir si se conserva `AN.MediatR.sln` por compatibilidad de Visual Studio o se retira en una modificación separada y revisable.

**Criterio de salida:** `dotnet build AN.MediatR.slnx -c Release` resuelve la solución sin usar paquetes locales accidentales del upstream.

### Fase 2 — Alinear la API de producción no relacionada con licencia

1. Aplicar un merge de tres vías por archivo entre la base común, `916ef1b` y el fork. No sustituir directorios enteros: el fork contiene los cambios de identidad `AN.*` y las exclusiones requeridas.
2. Renombrar `ServiceCollectionExtensions` a `MediatRServiceCollectionExtensions` y validar que sus dos sobrecargas `AddMediatR` permanecen idénticas en comportamiento al upstream.
3. Verificar que `Mediator`, `ServiceRegistrar`, wrappers, publicadores, procesadores, streaming y contratos preservan las firmas de la sección 5.
4. Mantener fuera cualquier importación `MediatR.Licensing`, `Microsoft.IdentityModel.*` o `Microsoft.Extensions.Logging` que exista sólo para la licencia.
5. Confirmar que `MediatRServiceConfiguration` no expone `LicenseKey` y que no queda ningún punto de llamada a `CheckLicense`.

**Criterio de salida:** compilación de `src` y comparación de API pública que sólo muestre los cambios de nombre `AN.*` y las dos exclusiones de `LicenseKey`.

### Fase 3 — Migrar y reorganizar las pruebas

1. Añadir `GlobalUsings.cs` y la versión libre de licencia de `TestContainer`.
2. Portar las pruebas funcionales del upstream una a una, resolviendo diferencias frente a las pruebas existentes en favor de cobertura, no de una sustitución mecánica.
3. Restituir expresamente regresiones no relacionadas con licencia, por ejemplo carga parcial de assemblies (`ReflectionTypeLoadException`), handlers genéricos, pipelines, stream pipelines, publicadores y excepciones.
4. Trasladar las pruebas dependientes de contenedor al nuevo proyecto de integración. El proyecto principal no debe depender de Lamar para ejercitar casos que el upstream ya prueba en el proyecto multi-contenedor.
5. Eliminar de los tests las llamadas a `AddFakeLogging` que sólo atendían al validador. Mantenerlas únicamente si una prueba concreta valida logging propio de la aplicación.
6. No portar los cuatro archivos de `test/MediatR.Tests/Licensing`; añadir en su lugar una comprobación de ausencia de licenciamiento (fase 7).

**Criterio de salida:** todas las pruebas unitarias y de integración pasan en `net10.0`; si Windows está disponible, también las variantes que el proyecto habilita para `net462`.

### Fase 4 — Empaquetado, dependencias y metadatos

1. Revisar `AN.MediatR.csproj` y `AN.MediatR.Contracts.csproj` después de cada merge. Mantener `ProjectReference`/dependencia del paquete `AN.MediatR.Contracts`, nunca la dependencia hacia `MediatR.Contracts`.
2. No añadir `Microsoft.IdentityModel.JsonWebTokens` ni las referencias de logging motivadas exclusivamente por licencia.
3. Empaquetar ambos proyectos y abrir los `.nuspec` generados para comprobar: identidad `AN.*`, dependencia de contratos correcta, README incluido y ausencia de dependencias de licencia.
4. Resolver formalmente la decisión de licencia legal de la sección 3 antes de conservar o publicar `PackageLicenseExpression` como Apache-2.0.
5. Alinear `Build.ps1`, `BuildContracts.ps1` y `Push.ps1` con las dos salidas de paquete, rutas `AN.*` y la política de versión del fork.

**Criterio de salida:** `dotnet pack` genera paquetes autoconsistentes y la inspección de dependencias no muestra paquetes upstream ni de validación JWT.

### Fase 5 — CI/CD y supply chain

1. Actualizar CI a SDKs 8, 9 y 10, acciones v4, checkout completo para MinVer y generación de artefactos `.trx`.
2. Configurar CI para la rama principal real del fork (`main` en el remoto actual, salvo cambio explícito) y permisos de sólo lectura.
3. Añadir el flujo de informe de pruebas separado, si se acepta el uso de `dorny/test-reporter`; validar específicamente una PR procedente de un fork.
4. Adaptar release a la identidad de `AN.MediatR`: repositorio, autor, namespace SBOM, feed, firma y secretos propios. Las secciones de OIDC/Key Vault sólo se habilitan con infraestructura propia.
5. Conservar `devskim.yml` u otras medidas adicionales ya presentes, a menos que haya una razón documentada para retirarlas.

**Criterio de salida:** CI construye, prueba, adjunta artefactos y no necesita secretos o URLs de Lucky Penny.

### Fase 6 — README y documentación de usuario

1. Actualizar el README después de que la API, paquetes y versión final estén fijados.
2. Incluir instalación, referencia de contratos, DI, pipelines, streams y ejemplos usando `AN.MediatR`.
3. Añadir una sección breve de compatibilidad/procedencia: commit upstream, renombrado de namespaces y exclusión del subsistema de licencia en tiempo de ejecución.
4. Eliminar toda instrucción de `LicenseKey`, variables de entorno de licencia, filtro de logger o enlaces de compra.
5. Mantener este documento como registro de diferencias intencionadas y actualizar el commit de referencia cuando se haga una nueva actualización.

**Criterio de salida:** un usuario nuevo puede instalar y registrar el paquete sin encontrar ninguna configuración de licencia.

## 7. Matriz de verificación final

Ejecutar, como mínimo, las comprobaciones siguientes en una copia limpia del árbol de trabajo una vez completadas las fases:

| Objetivo | Comprobación |
|---|---|
| Restauración | `dotnet restore AN.MediatR.slnx` |
| Compilación | `dotnet build AN.MediatR.slnx -c Release --no-restore` |
| Tests unitarios | `dotnet test test/AN.MediatR.Tests/AN.MediatR.Tests.csproj -c Release --no-build` |
| Tests multi-contenedor | `dotnet test test/AN.MediatR.DependencyInjectionTests/AN.MediatR.DependencyInjectionTests.csproj -c Release --no-build` |
| Muestras | Compilar todos los `samples/AN.MediatR.*/*.csproj` en Release. |
| Paquetes | Ejecutar `Build.ps1` o `dotnet pack` de ambos proyectos e inspeccionar el `.nuspec`. |
| Ausencia de runtime licensing | Buscar en `src`, `samples` y `test`, excluyendo resultados generados, `MediatR.Licensing`, `LicenseKey`, `CheckLicense`, `LicenseAccessor`, `LicenseValidator`, `Microsoft.IdentityModel` y `LUCKYPENNY_LICENSE_KEY`; el resultado debe ser vacío. |
| Paridad | Repetir la comparación normalizada de rutas/contenido contra `916ef1b` y justificar por escrito cada diferencia: prefijo `AN.*`, metadatos propios, exclusiones de licencia y configuración de publicación propia. |
| CI | Ejecutar el flujo en una rama y revisar que no usa secretos, feeds, URL de SBOM, certificado ni identidad de Lucky Penny. |

El guardia de ausencia de licenciamiento debe implementarse como prueba automatizada o validación de CI, no sólo como una revisión manual. Puede ser un test que inspeccione los ensamblados/referencias o un script de CI que falle ante símbolos y paquetes prohibidos.

## 8. Riesgos y decisiones que no se deben ocultar

1. **Licencia de redistribución:** es el bloqueo principal para publicar código copiado de commits posteriores al cambio de licencia del upstream. Requiere una decisión del titular del fork o asesoramiento legal.
2. **Compatibilidad de paquetes:** el cambio de namespace y de IDs de NuGet es intencionadamente incompatible con consumidores que referencian `MediatR`. Debe documentarse una guía de migración `using MediatR` → `using AN.MediatR`.
3. **Solución `.slnx`:** requiere tooling compatible. Si los usuarios principales aún necesitan `.sln`, mantener ambos archivos mientras se decide la transición.
4. **Tests de DI:** su nueva batería incrementa dependencias y tiempo de CI, pero es la cobertura que evita regresiones al registrar handlers en contenedores distintos.
5. **Infraestructura de release:** el workflow upstream contiene recursos que pertenecen a Lucky Penny. Sólo la estructura técnica es reutilizable; los secretos y endpoints no lo son.
6. **Árbol de trabajo actual:** contiene muchas modificaciones no confirmadas, incluidas eliminaciones/altas derivadas del renombrado. Las sesiones de implementación deben preservar esos cambios y trabajar en commits temáticos pequeños.

## 9. Desglose recomendado para próximas sesiones

1. **Sesión A:** consolidar estado y crear `AN.MediatR.slnx` sin tocar código de producción.
2. **Sesión B:** añadir `AN.MediatR.DependencyInjectionTests`, `GlobalUsings` y `TestContainer` libre de licencia; hacer pasar los tests.
3. **Sesión C:** normalizar el nombre de `MediatRServiceCollectionExtensions`, contrastar API y añadir el guardia anti-licencia.
4. **Sesión D:** revisar `.csproj`, scripts, `.gitignore`/`.gitattributes` y empaquetado de ambos paquetes.
5. **Sesión E:** actualizar CI, informes de pruebas, SBOM y release con identidad propia.
6. **Sesión F:** actualizar README/documentación de usuario y resolver explícitamente la política legal de publicación.

Cada sesión debe limitarse al bloque indicado, ejecutar sus criterios de salida y registrar en este documento cualquier desviación aceptada respecto a `916ef1b`.
