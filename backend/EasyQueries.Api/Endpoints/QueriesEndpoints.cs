using EasyQueries.Api.Infrastructure;
using Microsoft.Data.SqlClient;
using System.Text.RegularExpressions;

namespace EasyQueries.Api.Endpoints;

public static class QueriesEndpoints
{
    private static readonly Regex MetadataPattern = new(
        @"^\s*--\s*#(?<key>\w+)\s*:\s*(?<value>.*)$",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private static readonly Regex FilterPrefixPattern = new(
        @"^\s*--\s*#\s*\[(?<name>[^\]]+)\]\s*\|(?<rest>.*)$",
        RegexOptions.Compiled);

    private static readonly Regex BracketedListPattern = new(
        @"^\[(?<items>.*)\]$",
        RegexOptions.Compiled);

    private static readonly Regex NumericLiteralPattern = new(
        @"^-?\d+(\.\d+)?$",
        RegexOptions.Compiled);

    private static readonly Regex WherePattern = new(
        @"\bWHERE\b",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private static readonly Regex SelectTopPattern = new(
        @"\A(\s*SELECT\s+)(TOP\s*\(\s*\d+\s*\)\s*)?",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public static void MapQueriesEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/queries", GetQueriesAsync)
            .WithName("GetQueries");

        app.MapPost("/api/queries/execute", ExecuteQueryAsync)
            .WithName("ExecuteQuery");
    }

    private static async Task<IResult> GetQueriesAsync(IConfiguration config, IWebHostEnvironment env, string? database)
    {
        var queriesDir = Path.Combine(DataPaths.GetDataDirectory(env, config), "queries");
        var queries = LoadQueries(queriesDir);

        if (!string.IsNullOrWhiteSpace(database))
        {
            queries = queries
                .Where(q => q.DbPatterns.Any(pattern => MatchesDatabase(pattern, database)))
                .ToList();
        }

        var result = new List<object>();
        foreach (var q in queries)
        {
            var filters = new List<object>();
            foreach (var f in q.Filters)
            {
                var options = f.OptionsQuery is not null && !string.IsNullOrWhiteSpace(database)
                    ? (await RunOptionsQueryAsync(f.OptionsQuery, database, config)).Select(o => o.Label).ToArray()
                    : f.Options;

                filters.Add(new { name = f.Name, options });
            }

            result.Add(new { name = q.Name, sql = q.Sql, filters });
        }

        return Results.Ok(result);
    }

    private static async Task<IResult> ExecuteQueryAsync(
        ExecuteQueryRequest request,
        IConfiguration config,
        IWebHostEnvironment env)
    {
        var queriesDir = Path.Combine(DataPaths.GetDataDirectory(env, config), "queries");
        var query = LoadQueries(queriesDir)
            .FirstOrDefault(q => string.Equals(q.Name, request.Name, StringComparison.OrdinalIgnoreCase));

        if (query is null)
        {
            return Results.NotFound(new { message = $"Query '{request.Name}' not found." });
        }

        if (!query.DbPatterns.Any(pattern => MatchesDatabase(pattern, request.Database)))
        {
            return Results.BadRequest(new { message = $"Query '{request.Name}' does not apply to database '{request.Database}'." });
        }

        var connectionStringBuilder = new SqlConnectionStringBuilder(config.GetConnectionString("database"))
        {
            InitialCatalog = request.Database
        };

        try
        {
            var sql = await BuildSqlAsync(query, request.Filters, request.MaxResults, request.Database, config);

            await using var connection = new SqlConnection(connectionStringBuilder.ConnectionString);
            await connection.OpenAsync();

            await using var command = connection.CreateCommand();
            command.CommandText = sql;

            await using var reader = await command.ExecuteReaderAsync();

            var columns = Enumerable.Range(0, reader.FieldCount)
                .Select(i => new { name = reader.GetName(i), type = reader.GetDataTypeName(i) })
                .ToList();

            var rows = new List<object?[]>();
            while (await reader.ReadAsync())
            {
                var row = new object?[reader.FieldCount];
                for (var i = 0; i < reader.FieldCount; i++)
                {
                    row[i] = reader.IsDBNull(i) ? null : reader.GetValue(i);
                }

                rows.Add(row);
            }

            return Results.Ok(new { columns, rows, sql });
        }
        catch (SqlException ex)
        {
            return Results.BadRequest(new { message = ex.Message });
        }
    }

    private static async Task<string> BuildSqlAsync(
        QueryDefinition query,
        Dictionary<string, string>? requestedFilters,
        int? maxResults,
        string database,
        IConfiguration config)
    {
        var sql = StripDatabaseQualifier(query.Sql);

        if (maxResults is > 0)
        {
            sql = SelectTopPattern.Replace(sql, $"$1TOP ({maxResults}) ", 1);
        }

        if (requestedFilters is null || query.Filters.Count == 0)
        {
            return sql;
        }

        var filterValues = new Dictionary<string, string>(requestedFilters, StringComparer.OrdinalIgnoreCase);

        var clauses = new List<string>();
        foreach (var f in query.Filters)
        {
            if (!filterValues.TryGetValue(f.Name, out var value) || string.IsNullOrWhiteSpace(value))
            {
                continue;
            }

            var resolvedValue = value;
            if (f.OptionsQuery is not null)
            {
                var options = await RunOptionsQueryAsync(f.OptionsQuery, database, config);
                var match = options.FirstOrDefault(o => string.Equals(o.Label, value, StringComparison.OrdinalIgnoreCase));
                if (match.Label is not null)
                {
                    resolvedValue = match.Value;
                }
            }

            clauses.Add(SubstitutePlaceholder(f.ClauseTemplate, f.Name, resolvedValue));
        }

        if (clauses.Count == 0)
        {
            return sql;
        }

        var keyword = WherePattern.IsMatch(sql) ? "AND" : "WHERE";
        return $"{sql}\n{keyword} {string.Join(" AND ", clauses)}";
    }

    private static async Task<List<(string Value, string Label)>> RunOptionsQueryAsync(
        string optionsQuery, string database, IConfiguration config)
    {
        // A broken options query (bad SQL, missing alias, wrong table for a given database, etc.)
        // shouldn't take down the whole query list or block execution - the filter still works as
        // a plain free-text field either way, it just won't offer suggestions.
        try
        {
            var connectionStringBuilder = new SqlConnectionStringBuilder(config.GetConnectionString("database"))
            {
                InitialCatalog = database
            };

            await using var connection = new SqlConnection(connectionStringBuilder.ConnectionString);
            await connection.OpenAsync();

            await using var command = connection.CreateCommand();
            command.CommandText = StripDatabaseQualifier(optionsQuery);

            await using var reader = await command.ExecuteReaderAsync();

            var results = new List<(string, string)>();
            while (await reader.ReadAsync())
            {
                var value = reader.IsDBNull(0) ? "" : Convert.ToString(reader.GetValue(0)) ?? "";
                var label = reader.IsDBNull(1) ? "" : Convert.ToString(reader.GetValue(1)) ?? "";
                results.Add((value, label));
            }

            return results;
        }
        catch (SqlException)
        {
            return [];
        }
    }

    private static string SubstitutePlaceholder(string template, string paramName, string rawValue)
    {
        var token = $"[{paramName}]";
        var index = template.IndexOf(token, StringComparison.OrdinalIgnoreCase);
        if (index < 0)
        {
            return template;
        }

        var insideQuotes = false;
        for (var i = 0; i < index; i++)
        {
            if (template[i] == '\'')
            {
                insideQuotes = !insideQuotes;
            }
        }

        var escapedValue = rawValue.Replace("'", "''");
        var isNumeric = NumericLiteralPattern.IsMatch(rawValue);
        var replacement = insideQuotes || isNumeric ? escapedValue : $"'{escapedValue}'";

        return template[..index] + replacement + template[(index + token.Length)..];
    }

    private static string StripDatabaseQualifier(string sql) =>
        Regex.Replace(sql, @"\[[A-Za-z0-9_]+\]\.(?=\[[A-Za-z0-9_]+\]\.\[[A-Za-z0-9_]+\])", string.Empty);

    private static List<QueryDefinition> LoadQueries(string queriesDir) =>
        Directory.GetFiles(queriesDir, "*.sql")
            .Select(ParseQueryFile)
            .ToList();

    private static QueryDefinition ParseQueryFile(string file)
    {
        var name = Path.GetFileNameWithoutExtension(file);
        var dbPatterns = new List<string>();
        var filters = new List<QueryFilter>();
        var bodyLines = new List<string>();

        foreach (var line in File.ReadAllLines(file))
        {
            var filterMatch = FilterPrefixPattern.Match(line);
            if (filterMatch.Success)
            {
                var rest = filterMatch.Groups["rest"].Value;
                var parts = rest.Split('|', 2);
                var clause = parts[0].Trim();

                string[] staticOptions = [];
                string? optionsQuery = null;

                if (parts.Length > 1)
                {
                    var optionsSpec = parts[1].Trim();
                    var bracketMatch = BracketedListPattern.Match(optionsSpec);
                    if (bracketMatch.Success)
                    {
                        staticOptions = bracketMatch.Groups["items"].Value
                            .Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
                    }
                    else
                    {
                        optionsQuery = optionsSpec;
                    }
                }

                filters.Add(new QueryFilter(
                    filterMatch.Groups["name"].Value.Trim(),
                    clause,
                    staticOptions,
                    optionsQuery));
                continue;
            }

            var metadataMatch = MetadataPattern.Match(line);
            if (!metadataMatch.Success)
            {
                bodyLines.Add(line);
                continue;
            }

            var value = metadataMatch.Groups["value"].Value.Trim();
            switch (metadataMatch.Groups["key"].Value.ToLowerInvariant())
            {
                case "name":
                    name = value;
                    break;
                case "db":
                    dbPatterns.Add(value);
                    break;
            }
        }

        return new QueryDefinition(name, string.Join("\n", bodyLines).Trim(), dbPatterns, filters);
    }

    private static bool MatchesDatabase(string pattern, string database)
    {
        var regexPattern = "^" + Regex.Escape(pattern).Replace("\\*", ".*") + "$";
        return Regex.IsMatch(database, regexPattern, RegexOptions.IgnoreCase);
    }

    private sealed record QueryDefinition(string Name, string Sql, List<string> DbPatterns, List<QueryFilter> Filters);

    private sealed record QueryFilter(string Name, string ClauseTemplate, string[] Options, string? OptionsQuery);

    public sealed record ExecuteQueryRequest(string Name, string Database, Dictionary<string, string>? Filters, int? MaxResults);
}
