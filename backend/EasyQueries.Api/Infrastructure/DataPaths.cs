namespace EasyQueries.Api.Infrastructure;

public static class DataPaths
{
    public static string GetDataDirectory(IWebHostEnvironment env, IConfiguration config)
    {
        var configuredPath = config["DataDirectory"] ?? "../../data";
        return Path.IsPathRooted(configuredPath)
            ? configuredPath
            : Path.GetFullPath(Path.Combine(env.ContentRootPath, configuredPath));
    }
}
