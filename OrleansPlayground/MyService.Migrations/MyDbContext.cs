using Microsoft.EntityFrameworkCore;

namespace MyService.Migrations;

public class MyDbContext : DbContext
{
    public const string ConnectionString = "Server=localhost,17433;Database=my_orleansdata;User Id=sa;Password='sup3rs3cre!pwd;';TrustServerCertificate=true";
    public MyDbContext() { }
    public MyDbContext(DbContextOptions contextOptions) : base(contextOptions) { }

    protected override void OnConfiguring(DbContextOptionsBuilder optionsBuilder)
    {
        optionsBuilder.UseSqlServer(ConnectionString, b =>
        {
            b.MigrationsAssembly("MyService.Migrations");
            b.EnableRetryOnFailure(5, TimeSpan.FromSeconds(10), null);
        });
        base.OnConfiguring(optionsBuilder);
    }
}
