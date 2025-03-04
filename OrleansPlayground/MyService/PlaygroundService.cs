using MyService.Grains;

namespace MyService;

public class PlaygroundService : IHostedService
{
    private readonly ILogger<PlaygroundService> _logger;
    private readonly SampleDB _db;
    private readonly IGrainFactory _grainFactory;

    public PlaygroundService(ILogger<PlaygroundService> logger, SampleDB db, IGrainFactory grainFactory)
    {
        _logger = logger;
        _db = db;
        _grainFactory = grainFactory;
    }

    public async Task StartAsync(CancellationToken CT)
    {
        _logger.LogInformation($"Starting in 5 seconds...");
        await Task.Delay(5000, CT);

        int iteration = 1;
        do
        {
            if (CT.IsCancellationRequested)
                break;
            await _db.Overwrite(new SampleData { Name = "Blob", PropX = 0, PropY = 0 });
            if (iteration > 1000000)
            {
                _logger.LogInformation($"We tried million times and failed to break, we stop. Run svc again");
                break;
            }
            if ((iteration % 10) == 0) _logger.LogInformation($"{iteration}th iteration ran, all good for now");

#if STATEFUL
            async Task first()
            {
                var grain = _grainFactory.GetGrain<IStatefulGrain>("ROOT");
                await grain.Operate1(iteration);
            }

            async Task second()
            {
                var grain = _grainFactory.GetGrain<IStatefulGrain>("ROOT");
                await grain.Operate2(iteration);
            }
#else
            async Task first()
            {
                var grain = _grainFactory.GetGrain<IStatelessGrain>("ROOT");
                await grain.Operate1(iteration);
            }

            async Task second()
            {
                var grain = _grainFactory.GetGrain<IStatelessGrain>("ROOT");
                await grain.Operate2(iteration);
            }
#endif
            await Task.WhenAll(first(), second());

            var data = _db.Fetch;
            if (data.PropX != iteration || data.PropY != iteration)
            {
                _logger.LogWarning($"Breaking loop at {iteration}th iteration, the check failed");
                break;
            }

            ++iteration;
        } while (true);
    }

    public Task StopAsync(CancellationToken cancellationToken)
    {
        return Task.CompletedTask;
    }
}
