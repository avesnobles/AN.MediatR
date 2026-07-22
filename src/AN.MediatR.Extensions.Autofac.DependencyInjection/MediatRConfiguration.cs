using System.Reflection;

namespace AN.MediatR.Extensions.Autofac.DependencyInjection;

public class MediatRConfiguration
{
    internal Assembly[] HandlersFromAssemblies { get; }

    internal Type MediatorType { get; }

    internal Type NotificationPublisherType { get; }

    internal Type[] CustomPipelineBehaviors { get; }

    internal Type[] CustomStreamPipelineBehaviors { get; }

    internal Type[] OpenGenericTypesToRegister { get; }

    internal RegistrationScope RegistrationScope { get; }

    internal MediatRConfiguration(
        Assembly[] fromAssemblies,
        Type mediatorType,
        Type notificationPublisherType,
        Type[] openGenericTypesToRegister,
        Type[]? customPipelineBehaviors = null,
        Type[]? customStreamPipelineBehaviors = null,
        RegistrationScope registrationScope = RegistrationScope.Transient)
    {
        HandlersFromAssemblies = fromAssemblies ?? throw new ArgumentNullException(nameof(fromAssemblies));
        MediatorType = mediatorType ?? throw new ArgumentNullException(nameof(mediatorType));
        NotificationPublisherType = notificationPublisherType ?? throw new ArgumentNullException(nameof(notificationPublisherType));
        OpenGenericTypesToRegister = openGenericTypesToRegister ?? throw new ArgumentNullException(nameof(openGenericTypesToRegister));
        CustomPipelineBehaviors = customPipelineBehaviors ?? [];
        CustomStreamPipelineBehaviors = customStreamPipelineBehaviors ?? [];
        RegistrationScope = registrationScope;
    }
}
