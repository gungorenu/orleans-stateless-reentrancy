using Orleans.Configuration;
using System.Net;
using System.Net.Sockets;
using MyService;
using Microsoft.EntityFrameworkCore;
using Serilog;
using MyService.Migrations;

internal class Program
{
    private const string InvariantName = "Microsoft.Data.SqlClient";

    private static void Main(string[] args)
    {
        SetupSerilog();
        var host = Host.CreateDefaultBuilder(args)
            .UseOrleans(silo => ConfigureTalepreterOrleans(silo))
            .ConfigureServices(services =>
            {
                services.AddLogging();
                services.AddSerilog();
                services.AddDbContext<MyDbContext>(options => options.UseSqlServer(MyDbContext.ConnectionString));
                services.AddHostedService<PlaygroundService>();
                services.AddSingleton<SampleDB>();
            })
            .Build();

        host.Run();
    }

    public static void ConfigureTalepreterOrleans(ISiloBuilder silo)
    {
        var clusteringConnString = MyDbContext.ConnectionString;
        var storageConnString = MyDbContext.ConnectionString;
        var ipAddress = "192.168.0.4";
        var clusterId = "MyCluster";
        var serviceId = "MyService";

        silo.Configure<SiloOptions>(options => options.SiloName = "MySilo");

        silo.UseAdoNetClustering(options => { options.Invariant = InvariantName; options.ConnectionString = clusteringConnString; })
            .Configure<ClusterOptions>(options => { options.ClusterId = clusterId; options.ServiceId = serviceId; });

        silo.Configure<EndpointOptions>(options =>
        {
            options.AdvertisedIPAddress = GetAdvertisedIpAddress(ipAddress);
            options.GatewayPort = 30000;
            options.SiloPort = 11111;
            options.GatewayListeningEndpoint = new IPEndPoint(IPAddress.Any, 30000);
            options.SiloListeningEndpoint = new IPEndPoint(IPAddress.Any, 11111);
        });

        silo.AddAdoNetGrainStorage("MyGrainStorage", options => { options.Invariant = InvariantName; options.ConnectionString = storageConnString; });
    }

    private static IPAddress GetAdvertisedIpAddress(string ipAddress)
    {
        if (!string.IsNullOrEmpty(ipAddress))
        {
            return IPAddress.Parse(ipAddress);
        }

        var host = Dns.GetHostEntry(Dns.GetHostName());
        foreach (var ip in host.AddressList)
        {
            if (ip.AddressFamily == AddressFamily.InterNetwork)
            {
                return ip;
            }
        }
        throw new Exception("No network adapters with an IPv4 address in the system!");
    }

    public static void SetupSerilog()
    {
        Log.Logger = new LoggerConfiguration()
            .MinimumLevel.Debug()
            .MinimumLevel.Override("Microsoft", Serilog.Events.LogEventLevel.Warning)
            .MinimumLevel.Override("Orleans", Serilog.Events.LogEventLevel.Warning)
            .WriteTo.Console()
            .CreateLogger();

        Log.Information(new string('-', 144));
        Log.Information(new string('-', 12) + $" STARTING UP " + new string('-', 119));
        Log.Information(new string('-', 144));
    }
}