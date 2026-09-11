using EasyQueries.Api.Infrastructure;
using Microsoft.Data.SqlClient;
using System.Text.Json;

namespace EasyQueries.Api.Endpoints;

public static class DatabasesEndpoints
{
    public static void MapDatabasesEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/databases", GetDatabasesAsync)
            .WithName("GetDatabases");
    }

    private static async Task<string[]> GetDatabasesAsync(
        IConfiguration config,
        IWebHostEnvironment env,
        bool isFavorite = true)
    {
        if (isFavorite)
        {
            return await ReadFavoritesAsync(env, config);
        }

        return await ReadLiveDatabasesAsync(config);
    }

    private static async Task<string[]> ReadFavoritesAsync(IWebHostEnvironment env, IConfiguration config)
    {
        var favoritesPath = Path.Combine(DataPaths.GetDataDirectory(env, config), "favorites.json");
        var json = await File.ReadAllTextAsync(favoritesPath);
        return JsonSerializer.Deserialize<string[]>(json) ?? [];
    }

    private static async Task<string[]> ReadLiveDatabasesAsync(IConfiguration config)
    {
        var connectionString = config.GetConnectionString("database");
        var databases = new List<string>();

        await using var connection = new SqlConnection(connectionString);
        await connection.OpenAsync();

        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT name FROM sys.databases WHERE database_id > 4 ORDER BY name";

        await using var reader = await command.ExecuteReaderAsync();
        while (await reader.ReadAsync())
        {
            databases.Add(reader.GetString(0));
        }

        return databases.ToArray();
    }
}
