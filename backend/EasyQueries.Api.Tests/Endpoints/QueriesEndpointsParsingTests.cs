using EasyQueries.Api.Endpoints;

namespace EasyQueries.Api.Tests.Endpoints;

public class QueriesEndpointsParsingTests : IDisposable
{
    private readonly string _tempFile = Path.Combine(Path.GetTempPath(), $"{Guid.NewGuid()}.sql");

    public void Dispose()
    {
        if (File.Exists(_tempFile))
        {
            File.Delete(_tempFile);
        }
    }

    private QueriesEndpoints.QueryDefinition ParseContent(string content)
    {
        File.WriteAllText(_tempFile, content);
        return QueriesEndpoints.ParseQueryFile(_tempFile);
    }

    [Fact]
    public void ParsesNameAndDbMetadata()
    {
        var query = ParseContent(
            """
            --#name: Translation Text
            --#db: Translations*
            SELECT tra.Value
            FROM [Translations].[globalization].[Translation] tra
            """);

        Assert.Equal("Translation Text", query.Name);
        Assert.Equal(["Translations*"], query.DbPatterns);
    }

    [Fact]
    public void MultipleDbMetadataLines_AreAllCollected()
    {
        var query = ParseContent(
            """
            -- #db: VXStart
            -- #db: VXTest
            SELECT 1
            """);

        Assert.Equal(["VXStart", "VXTest"], query.DbPatterns);
    }

    [Fact]
    public void DefaultsNameToFileName_WhenNoNameMetadata()
    {
        var query = ParseContent("SELECT 1");

        Assert.Equal(Path.GetFileNameWithoutExtension(_tempFile), query.Name);
    }

    [Fact]
    public void MetadataAndFilterLines_AreExcludedFromSqlBody()
    {
        var query = ParseContent(
            """
            --#name: Translation Text
            --#db: Translations*
            SELECT tra.Value
            FROM [Translations].[globalization].[Translation] tra
            -- # [bundle] | bun.Name like '[bundle]'
            ORDER BY tra.Value
            """);

        Assert.Equal(
            "SELECT tra.Value\nFROM [Translations].[globalization].[Translation] tra\nORDER BY tra.Value",
            query.Sql);
    }

    [Fact]
    public void ParsesPlainFilter_WithNoOptions()
    {
        var query = ParseContent(
            """
            SELECT 1
            -- # [bundle] | bun.Name like '[bundle]'
            """);

        var filter = Assert.Single(query.Filters);
        Assert.Equal("bundle", filter.Name);
        Assert.Equal("bun.Name like '[bundle]'", filter.ClauseTemplate);
        Assert.Empty(filter.Options);
        Assert.Null(filter.OptionsQuery);
    }

    [Fact]
    public void ParsesFilter_WithStaticOptionsList()
    {
        var query = ParseContent(
            """
            SELECT 1
            -- # [status] | gbBlocked = [status] | [Open, Closed, Pending]
            """);

        var filter = Assert.Single(query.Filters);
        Assert.Equal(["Open", "Closed", "Pending"], filter.Options);
        Assert.Null(filter.OptionsQuery);
    }

    [Fact]
    public void ParsesFilter_WithOptionsQuery()
    {
        var query = ParseContent(
            """
            SELECT 1
            -- # [uitnodiging-status] | gbUitnodigingMailStatus = [uitnodiging-status] | select ms.umId, ms.umNaam from [VXStart].[dbo].[tblLibUitnodigingMailStatus] ms order by ms.umNaam
            """);

        var filter = Assert.Single(query.Filters);
        Assert.Equal(
            "select ms.umId, ms.umNaam from [VXStart].[dbo].[tblLibUitnodigingMailStatus] ms order by ms.umNaam",
            filter.OptionsQuery);
        Assert.Empty(filter.Options);
    }
}
