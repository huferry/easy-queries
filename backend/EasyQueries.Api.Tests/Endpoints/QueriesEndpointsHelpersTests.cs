using EasyQueries.Api.Endpoints;

namespace EasyQueries.Api.Tests.Endpoints;

public class QueriesEndpointsHelpersTests
{
    [Theory]
    [InlineData("VXStart", "VXStart", true)]
    [InlineData("vxstart", "VXStart", true)]
    [InlineData("VX_SalesDemo*", "VX_SalesDemo_Ferry_Utomo", true)]
    [InlineData("Translations*", "TranslationsProd", true)]
    [InlineData("VXStart", "VXTest", false)]
    [InlineData("Translations*", "OtherDb", false)]
    public void MatchesDatabase_HandlesExactAndWildcardPatterns(string pattern, string database, bool expected)
    {
        Assert.Equal(expected, QueriesEndpoints.MatchesDatabase(pattern, database));
    }

    [Fact]
    public void SubstitutePlaceholder_MissingToken_ReturnsTemplateUnchanged()
    {
        var result = QueriesEndpoints.SubstitutePlaceholder("cod.Name = [other]", "code", "value");

        Assert.Equal("cod.Name = [other]", result);
    }

    [Fact]
    public void SubstitutePlaceholder_OutsideQuotes_WrapsNonNumericValueInQuotes()
    {
        var result = QueriesEndpoints.SubstitutePlaceholder("cod.Name = [code]", "code", "greeting");

        Assert.Equal("cod.Name = 'greeting'", result);
    }

    [Fact]
    public void SubstitutePlaceholder_OutsideQuotes_LeavesNumericValueUnquoted()
    {
        var result = QueriesEndpoints.SubstitutePlaceholder("gbKlantID = [id]", "id", "42");

        Assert.Equal("gbKlantID = 42", result);
    }

    [Fact]
    public void SubstitutePlaceholder_InsideQuotes_DoesNotAddExtraQuotes()
    {
        var result = QueriesEndpoints.SubstitutePlaceholder("cod.Name like '%[code]%'", "code", "greeting");

        Assert.Equal("cod.Name like '%greeting%'", result);
    }

    [Fact]
    public void SubstitutePlaceholder_EscapesEmbeddedSingleQuotes()
    {
        var result = QueriesEndpoints.SubstitutePlaceholder("cod.Name = [code]", "code", "O'Brien");

        Assert.Equal("cod.Name = 'O''Brien'", result);
    }

    [Fact]
    public void StripDatabaseQualifier_RemovesLeadingDatabaseName_FromThreePartName()
    {
        var result = QueriesEndpoints.StripDatabaseQualifier(
            "FROM [Translations].[globalization].[Translation] tra");

        Assert.Equal("FROM [globalization].[Translation] tra", result);
    }

    [Fact]
    public void StripDatabaseQualifier_LeavesTwoPartName_Untouched()
    {
        var result = QueriesEndpoints.StripDatabaseQualifier("FROM [dbo].[Translation] tra");

        Assert.Equal("FROM [dbo].[Translation] tra", result);
    }
}
