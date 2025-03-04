using Microsoft.Identity.Client;

namespace MyService;

public class SampleData
{
    public string Name { get; init; } = default!;
    public int PropX { get; set; }
    public int PropY { get; set; }
}


public class SampleDB
{
    private readonly Dictionary<string, SampleData> _db = [];
    private readonly Random _random = new();

    public async Task Overwrite(SampleData data)
    {
        await Wait();
        _db[data.Name] = new SampleData
        {
            Name = data.Name,
            PropX = data.PropX,
            PropY = data.PropY,
        };
        await Wait();
    }

    public SampleData Fetch => new() { Name = _db.First().Value.Name, PropX = _db.First().Value.PropX, PropY = _db.First().Value.PropY };

    private async Task Wait()
    {
        var r = (_random.Next(10) + 1) * 5;
        await Task.Delay(r);
    }
}
