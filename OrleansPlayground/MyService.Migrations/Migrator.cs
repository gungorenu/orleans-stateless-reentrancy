using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace MyService.Migrations;

public class Migrator : BackgroundService
{
    private readonly IDbContextFactory<MyDbContext> _dbContextFactory;
    private readonly IHostApplicationLifetime _hostApplicationLifetime;
    private readonly ILogger<Migrator> _logger;

    public Migrator(IHostApplicationLifetime hostApplicationLifetime, ILogger<Migrator> logger, IDbContextFactory<MyDbContext> factory)
    {
        _hostApplicationLifetime = hostApplicationLifetime;
        _dbContextFactory = factory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken cancellationToken)
    {
        try
        {
            using var dbContext = await _dbContextFactory.CreateDbContextAsync(cancellationToken);
            await dbContext.Database.MigrateAsync(cancellationToken);

            _logger.LogInformation("Done migration runner!");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, $"Migration runner error:{ex.Message} | {ex.StackTrace} | {ex}");
        }
        finally
        {
            _hostApplicationLifetime.StopApplication();
        }
    }

    public override async Task StartAsync(CancellationToken cancellationToken)
    {
        _logger.LogInformation($"Starting migration runner!");
        await base.StartAsync(cancellationToken);
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        _logger.LogInformation($"Stoping migration runner!");
        await base.StopAsync(cancellationToken);
    }
}
