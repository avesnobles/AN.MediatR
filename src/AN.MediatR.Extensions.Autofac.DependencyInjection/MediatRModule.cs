using Autofac;
using AN.MediatR.Extensions.Autofac.DependencyInjection.Extensions;
using AN.MediatR.Pipeline;
using Module = Autofac.Module;

namespace AN.MediatR.Extensions.Autofac.DependencyInjection;

internal class MediatRModule : Module
{
    private readonly MediatRConfiguration mediatRConfiguration;

    private readonly Type[] builtInPipelineBehaviorTypes =
    {
        typeof(RequestPostProcessorBehavior<,>),
        typeof(RequestPreProcessorBehavior<,>),
        typeof(RequestExceptionActionProcessorBehavior<,>),
        typeof(RequestExceptionProcessorBehavior<,>),
    };

    public MediatRModule(MediatRConfiguration mediatRConfiguration)
    {
        this.mediatRConfiguration = mediatRConfiguration;
    }

    protected override void Load(ContainerBuilder builder)
    {
        builder.RegisterType<ServiceProviderWrapper>()
            .As<IServiceProvider>()
            .InstancePerDependency()
            .IfNotRegistered(typeof(IServiceProvider));

        builder
            .RegisterType(mediatRConfiguration.MediatorType)
            .As<IMediator>()
            .As<IPublisher>()
            .As<ISender>()
            .ApplyTargetScope(mediatRConfiguration.RegistrationScope);

        builder
            .RegisterType(mediatRConfiguration.NotificationPublisherType)
            .As<INotificationPublisher>()
            .ApplyTargetScope(mediatRConfiguration.RegistrationScope);

        foreach (var openHandlerType in mediatRConfiguration.OpenGenericTypesToRegister)
        {
            builder.RegisterAssemblyTypes(mediatRConfiguration.HandlersFromAssemblies)
                .AsClosedTypesOf(openHandlerType)
                .ApplyTargetScope(mediatRConfiguration.RegistrationScope);
        }

        foreach (var builtInPipelineBehaviorType in builtInPipelineBehaviorTypes)
        {
            RegisterGeneric(builder, builtInPipelineBehaviorType, typeof(IPipelineBehavior<,>));
        }

        foreach (var customBehaviorType in mediatRConfiguration.CustomPipelineBehaviors)
        {
            RegisterGeneric(builder, customBehaviorType, typeof(IPipelineBehavior<,>));
        }

        foreach (var customBehaviorType in mediatRConfiguration.CustomStreamPipelineBehaviors)
        {
            RegisterGeneric(builder, customBehaviorType, typeof(IStreamPipelineBehavior<,>));
        }
    }

    private void RegisterGeneric(ContainerBuilder builder, Type implementationType, Type asType)
    {
        builder.RegisterGeneric(implementationType)
            .As(asType)
            .ApplyTargetScope(mediatRConfiguration.RegistrationScope);
    }
}
