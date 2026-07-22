using Autofac;

namespace AN.MediatR.Extensions.Autofac.DependencyInjection;

internal class ServiceProviderWrapper : IServiceProvider
{
    private readonly ILifetimeScope lifeTimeScope;

    public ServiceProviderWrapper(ILifetimeScope lifeTimeScope)
    {
        this.lifeTimeScope = lifeTimeScope;
    }

    public object? GetService(Type serviceType) => lifeTimeScope.ResolveOptional(serviceType);
}
