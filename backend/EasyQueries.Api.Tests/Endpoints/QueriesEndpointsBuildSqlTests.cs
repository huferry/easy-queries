using EasyQueries.Api.Endpoints;
using Microsoft.Extensions.Configuration;

namespace EasyQueries.Api.Tests.Endpoints;

public class QueriesEndpointsBuildSqlTests
{
    private static readonly IConfiguration EmptyConfig = new ConfigurationBuilder().Build();

    private static Task<string> BuildSqlAsync(
        string sql,
        List<QueriesEndpoints.QueryFilter> filters,
        Dictionary<string, string>? requestedFilters,
        int? maxResults = null) =>
        QueriesEndpoints.BuildSqlAsync(
            new QueriesEndpoints.QueryDefinition("Test", sql, ["*"], filters),
            requestedFilters,
            maxResults,
            "AnyDatabase",
            EmptyConfig);

    [Fact]
    public async Task NoRequestedFilters_ReturnsSqlUnchanged()
    {
        var sql = await BuildSqlAsync("SELECT 1 FROM Foo", filters: [], requestedFilters: null);

        Assert.Equal("SELECT 1 FROM Foo", sql);
    }

    [Fact]
    public async Task BlankFilterValue_IsIgnored()
    {
        var filters = new List<QueriesEndpoints.QueryFilter>
        {
            new("bundle", "bun.Name like '[bundle]'", [], null)
        };

        var sql = await BuildSqlAsync(
            "SELECT 1 FROM Foo",
            filters,
            new Dictionary<string, string> { ["bundle"] = "   " });

        Assert.Equal("SELECT 1 FROM Foo", sql);
    }

    [Fact]
    public async Task AppendsWhereClause_WhenNoExistingWhere()
    {
        var filters = new List<QueriesEndpoints.QueryFilter>
        {
            new("bundle", "bun.Name like '[bundle]'", [], null)
        };

        var sql = await BuildSqlAsync(
            "SELECT 1 FROM Foo",
            filters,
            new Dictionary<string, string> { ["bundle"] = "shared" });

        Assert.Equal("SELECT 1 FROM Foo\nWHERE bun.Name like 'shared'", sql);
    }

    [Fact]
    public async Task AppendsAndClause_WhenWhereAlreadyPresent()
    {
        var filters = new List<QueriesEndpoints.QueryFilter>
        {
            new("bundle", "bun.Name like '[bundle]'", [], null)
        };

        var sql = await BuildSqlAsync(
            "SELECT 1 FROM Foo WHERE 1 = 1",
            filters,
            new Dictionary<string, string> { ["bundle"] = "shared" });

        Assert.Equal("SELECT 1 FROM Foo WHERE 1 = 1\nAND bun.Name like 'shared'", sql);
    }

    [Fact]
    public async Task CombinesMultipleFilters_WithAnd()
    {
        var filters = new List<QueriesEndpoints.QueryFilter>
        {
            new("bundle", "bun.Name like '[bundle]'", [], null),
            new("code", "cod.Name like '%[code]%'", [], null)
        };

        var sql = await BuildSqlAsync(
            "SELECT 1 FROM Foo",
            filters,
            new Dictionary<string, string> { ["bundle"] = "shared", ["code"] = "greeting" });

        Assert.Equal(
            "SELECT 1 FROM Foo\nWHERE bun.Name like 'shared' AND cod.Name like '%greeting%'",
            sql);
    }

    [Fact]
    public async Task InsertsClauseBeforeOrderBy_InsteadOfAfterIt()
    {
        // Regression test: translations.sql ends with ORDER BY. Appending the
        // filter clause after it used to produce invalid SQL like
        // "ORDER BY ... WHERE ...".
        var filters = new List<QueriesEndpoints.QueryFilter>
        {
            new("bundle", "bun.Name like '[bundle]'", [], null)
        };

        var sql = await BuildSqlAsync(
            "SELECT bun.Name\nFROM Foo bun\nORDER BY bun.Name",
            filters,
            new Dictionary<string, string> { ["bundle"] = "shared" });

        Assert.Equal(
            "SELECT bun.Name\nFROM Foo bun\nWHERE bun.Name like 'shared'\nORDER BY bun.Name",
            sql);
    }

    [Fact]
    public async Task SingleQuotesInFilterValue_AreEscaped()
    {
        var filters = new List<QueriesEndpoints.QueryFilter>
        {
            new("code", "cod.Name like '%[code]%'", [], null)
        };

        var sql = await BuildSqlAsync(
            "SELECT 1 FROM Foo",
            filters,
            new Dictionary<string, string> { ["code"] = "O'Brien" });

        Assert.Equal("SELECT 1 FROM Foo\nWHERE cod.Name like '%O''Brien%'", sql);
    }

    [Fact]
    public async Task MaxResults_InsertsTopKeywordAfterSelect()
    {
        var sql = await BuildSqlAsync(
            "SELECT bun.Name FROM Foo bun",
            filters: [],
            requestedFilters: null,
            maxResults: 50);

        Assert.Equal("SELECT TOP (50) bun.Name FROM Foo bun", sql);
    }

    [Fact]
    public async Task StripsThreePartDatabaseQualifier_BeforeApplyingFilters()
    {
        var sql = await BuildSqlAsync(
            "SELECT tra.Value FROM [Translations].[globalization].[Translation] tra",
            filters: [],
            requestedFilters: null);

        Assert.Equal("SELECT tra.Value FROM [globalization].[Translation] tra", sql);
    }
}
