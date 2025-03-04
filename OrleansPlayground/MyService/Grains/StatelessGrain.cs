using Orleans.Concurrency;

namespace MyService.Grains;

public interface IStatelessGrain : IGrainWithStringKey
{
    Task Operate1(int arg);
    Task Operate2(int arg);
}

[GenerateSerializer]
[StatelessWorker]
// NOTE: making StatelessWorker(1) also solves it
public class StatelessGrain : IStatelessGrain
{
    protected readonly ILogger _logger;
    private readonly Random _random = new();
    private readonly SampleDB _db;

    public StatelessGrain(ILogger<StatelessGrain> logger, SampleDB db)
    {
        _logger = logger;
        _db = db;
    }

    private async Task Wait()
    {
        var r = (_random.Next(10) + 1) * 5;
        await Task.Delay(r);
    }

    public async Task Operate1(int arg)
    {
        await Wait();
        var data = _db.Fetch;
        data.PropX += arg;
        await _db.Overwrite(data);
        await Wait();
    }
    public async Task Operate2(int arg)
    {
        await Wait();
        var data = _db.Fetch;
        data.PropY += arg;
        await _db.Overwrite(data);
        await Wait();
    }
}
