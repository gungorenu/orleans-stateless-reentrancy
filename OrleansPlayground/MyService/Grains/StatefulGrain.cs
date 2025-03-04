using Orleans.Runtime;
using System;

namespace MyService.Grains;

public interface IStatefulGrain : IGrainWithStringKey
{
    Task Operate1(int arg);
    Task Operate2(int arg);
}

[GenerateSerializer]
public class MyGrainState
{
    [Id(0)] public int LastIteration { get; set; }
}

[GenerateSerializer]
public class StatefulGrain : IStatefulGrain
{
    private readonly IPersistentState<MyGrainState> _state;
    private readonly ILogger _logger;
    private readonly Random _random = new();
    private readonly SampleDB _db;

    public StatefulGrain([PersistentState("persistentState", "MyGrainStorage")] IPersistentState<MyGrainState> persistentState, ILogger<StatefulGrain> logger, SampleDB db)
    {
        _state = persistentState;
        _logger = logger;
        _db = db;
    }

    protected async Task SaveStateAsync(Func<MyGrainState, Task> action)
    {
        await action(_state.State);
        await _state.WriteStateAsync();
    }

    private async Task Wait()
    {
        var r = (_random.Next(10) + 1) * 5;
        await Task.Delay(r);
    }

    public async Task Operate1(int arg)
    {
        await SaveStateAsync(async (state) =>
        {
            await Wait();
            var data = _db.Fetch;
            data.PropX += arg;
            await _db.Overwrite(data);
            await Wait();

            state.LastIteration = arg;
        });
    }
    public async Task Operate2(int arg)
    {
        await SaveStateAsync(async (state) =>
        {
            await Wait();
            var data = _db.Fetch;
            data.PropY += arg;
            await _db.Overwrite(data);
            await Wait();

            state.LastIteration = arg;
        });
    }
}
