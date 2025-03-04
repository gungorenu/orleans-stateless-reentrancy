using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using MyService.Migrations;

internal class Program
{
    private static void Main(string[] args)
    {
        var host = Host.CreateDefaultBuilder()
            .ConfigureServices(services =>
            {
                services.AddLogging();
                services.AddDbContextFactory<MyDbContext>();
                services.AddHostedService<Migrator>();
            })
            .Build();

        host.Run();
    }
}