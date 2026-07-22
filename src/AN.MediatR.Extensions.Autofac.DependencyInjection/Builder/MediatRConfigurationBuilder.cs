using System.Reflection;
using AN.MediatR.NotificationPublishers;

namespace AN.MediatR.Extensions.Autofac.DependencyInjection.Builder;

public class MediatRConfigurationBuilder
{
    private readonly Assembly[] handlersFromAssembly;

    private Type mediatorType = typeof(Mediator);
    private Type notificationPublisherType = typeof(ForeachAwaitPublisher);

    private readonly HashSet<Type> internalCustomPipelineBehaviorTypes = new();
    private readonly HashSet<Type> internalCustomStreamPipelineBehaviorTypes = new();
    private readonly HashSet<Type> internalOpenGenericHandlerTypesToRegister = new();

    private RegistrationScope registrationScope = RegistrationScope.Transient;

    private MediatRConfigurationBuilder(Assembly[] handlersFromAssembly)
    {
        if (handlersFromAssembly == null || !handlersFromAssembly.Any() || handlersFromAssembly.All(x => x == null))
        {
            throw new ArgumentNullException(nameof(handlersFromAssembly),
                $"Must provide assemblies in order to request {nameof(Mediator)}");
        }

        this.handlersFromAssembly = handlersFromAssembly;
    }

    public static MediatRConfigurationBuilder Create(params Assembly[] handlersFromAssembly)
        => new(handlersFromAssembly);

    public MediatRConfigurationBuilder UseMediatorType(Type customMediatorType)
    {
        if (!typeof(IMediator).IsAssignableFrom(customMediatorType)
            || !typeof(ISender).IsAssignableFrom(customMediatorType)
            || !typeof(IPublisher).IsAssignableFrom(customMediatorType))
        {
            throw new ArgumentException(
                $"{customMediatorType.Name} needs to be assignable to the following interfaces {nameof(IMediator)}, {nameof(ISender)}, {nameof(IPublisher)}!",
                nameof(customMediatorType));
        }

        mediatorType = customMediatorType;
        return this;
    }

    public MediatRConfigurationBuilder UseNotificationPublisher(Type customNotificationPublisherType)
    {
        if (!typeof(INotificationPublisher).IsAssignableFrom(customNotificationPublisherType))
        {
            throw new ArgumentException(
                $"{customNotificationPublisherType.Name} is not assignable to type {nameof(INotificationPublisher)}!",
                nameof(customNotificationPublisherType));
        }

        notificationPublisherType = customNotificationPublisherType;
        return this;
    }

    public MediatRConfigurationBuilder WithCustomPipelineBehavior(Type customPipelineBehaviorType)
    {
        if (customPipelineBehaviorType is null)
        {
            throw new ArgumentNullException(nameof(customPipelineBehaviorType));
        }

        internalCustomPipelineBehaviorTypes.Add(customPipelineBehaviorType);
        return this;
    }

    public MediatRConfigurationBuilder WithCustomPipelineBehaviors(IEnumerable<Type> customPipelineBehaviorTypes)
    {
        if (customPipelineBehaviorTypes is null)
        {
            throw new ArgumentNullException(nameof(customPipelineBehaviorTypes));
        }

        foreach (var customPipelineBehaviorType in customPipelineBehaviorTypes)
        {
            WithCustomPipelineBehavior(customPipelineBehaviorType);
        }

        return this;
    }

    public MediatRConfigurationBuilder WithCustomStreamPipelineBehavior(Type customStreamPipelineBehaviorType)
    {
        if (customStreamPipelineBehaviorType is null)
        {
            throw new ArgumentNullException(nameof(customStreamPipelineBehaviorType));
        }

        internalCustomStreamPipelineBehaviorTypes.Add(customStreamPipelineBehaviorType);
        return this;
    }

    public MediatRConfigurationBuilder WithAllOpenGenericHandlerTypesRegistered()
    {
        foreach (var openGenericHandlerType in KnownHandlerTypes.AllTypes)
        {
            AddOpenGenericHandlerToRegister(openGenericHandlerType);
        }

        return this;
    }

    public MediatRConfigurationBuilder WithRegistrationScope(RegistrationScope registrationScope)
    {
        this.registrationScope = registrationScope;
        return this;
    }

    public MediatRConfigurationBuilder WithOpenGenericHandlerTypeToRegister(Type openGenericHandlerType)
    {
        if (!KnownHandlerTypes.AllTypes.Contains(openGenericHandlerType))
        {
            throw new ArgumentException(
                $"Invalid open-generic handler-type {openGenericHandlerType.Name}",
                nameof(openGenericHandlerType));
        }

        AddOpenGenericHandlerToRegister(openGenericHandlerType);
        return this;
    }

    public MediatRConfigurationBuilder WithRequestHandlersManuallyRegistered()
    {
        foreach (var openGenericHandlerType in KnownHandlerTypes.AllTypes.Where(type => type != typeof(IRequestHandler<,>)))
        {
            AddOpenGenericHandlerToRegister(openGenericHandlerType);
        }

        return this;
    }

    public MediatRConfigurationBuilder WithCustomStreamPipelineBehaviors(IEnumerable<Type> customStreamPipelineBehaviorTypes)
    {
        if (customStreamPipelineBehaviorTypes is null)
        {
            throw new ArgumentNullException(nameof(customStreamPipelineBehaviorTypes));
        }

        foreach (var customStreamPipelineBehaviorType in customStreamPipelineBehaviorTypes)
        {
            WithCustomStreamPipelineBehavior(customStreamPipelineBehaviorType);
        }

        return this;
    }

    public MediatRConfiguration Build() => new(
        handlersFromAssembly,
        mediatorType,
        notificationPublisherType,
        internalOpenGenericHandlerTypesToRegister.ToArray(),
        internalCustomPipelineBehaviorTypes.ToArray(),
        internalCustomStreamPipelineBehaviorTypes.ToArray(),
        registrationScope);

    private void AddOpenGenericHandlerToRegister(Type openHandlerType)
    {
        internalOpenGenericHandlerTypesToRegister.Add(openHandlerType);
    }
}
