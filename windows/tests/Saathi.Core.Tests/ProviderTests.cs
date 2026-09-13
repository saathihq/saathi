//
//  ProviderTests.cs
//
//  Mirrors ProviderTests in the macOS package. Running against your own model, on your own machine,
//  with no key and no account is the primary objective — these pin the behaviour that makes that
//  true by default rather than by instruction.
//

using Saathi.Contract;
using Saathi.Core;
using Xunit;

namespace Saathi.Core.Tests;

public class ProviderTests
{
    [Fact]
    public void NothingConfiguredMeansLocal()
    {
        var configuration = new SaathiConfiguration();
        Assert.Equal(ProviderKind.Local, configuration.ResolvedProvider);
        Assert.Equal("http://localhost:11434", configuration.ResolvedProviderBaseUrl);
        Assert.False(configuration.ProviderRow.RequiresKey);
        Assert.False(configuration.ProviderRow.RequiresToken);
    }

    /// <summary>The one that matters most: the default mode must not send anything anywhere.</summary>
    [Fact]
    public void TheDefaultModeKeepsEverythingOnTheMachine()
    {
        Assert.False(new SaathiConfiguration().ProviderRow.SendsDataOffMachine);
    }

    /// <summary>
    /// There is no silent fallback from local to a network provider. An unreachable local model is
    /// an error the user sees, never a quiet upgrade to sending their words to someone else.
    /// </summary>
    [Fact]
    public void EveryNetworkModeIsMarkedAsLeavingTheMachine()
    {
        foreach (var kind in Enum.GetValues<ProviderKind>())
        {
            if (kind == ProviderKind.Local) continue;
            Assert.True(SaathiProvider.Of(kind).SendsDataOffMachine, $"{kind} should be marked as leaving the machine");
        }
        Assert.Equal(ProviderKind.Hosted, new SaathiConfiguration { Provider = ProviderKind.Hosted }.ResolvedProvider);
    }

    [Fact]
    public void EveryProviderKindHasARow()
    {
        foreach (var kind in Enum.GetValues<ProviderKind>())
        {
            Assert.Equal(kind, SaathiProvider.Of(kind).Kind);
        }
        Assert.Equal(Enum.GetValues<ProviderKind>().Length, SaathiProvider.All.Count);
    }

    [Fact]
    public void OverridesWinOverTheProviderDefaults()
    {
        var configuration = new SaathiConfiguration
        {
            Provider = ProviderKind.Local,
            ProviderBaseUrl = "http://192.168.1.9:11434",
            Model = "qwen2.5",
        };
        Assert.Equal("http://192.168.1.9:11434", configuration.ResolvedProviderBaseUrl);
        Assert.Equal("qwen2.5", configuration.ResolvedModel);
    }

    [Fact]
    public void BlankOverridesFallBackToTheDefaults()
    {
        var configuration = new SaathiConfiguration
        {
            Provider = ProviderKind.Local,
            ProviderBaseUrl = "  ",
            Model = "",
        };
        Assert.Equal("http://localhost:11434", configuration.ResolvedProviderBaseUrl);
        Assert.Equal("llama3.2", configuration.ResolvedModel);
    }

    [Fact]
    public void TheKeyRequiringModesSaySoRatherThanFailingLater()
    {
        Assert.True(SaathiProvider.Of(ProviderKind.Openai).RequiresKey);
        Assert.True(SaathiProvider.Of(ProviderKind.Anthropic).RequiresKey);
        Assert.True(SaathiProvider.Of(ProviderKind.Hosted).RequiresToken);
    }

    [Fact]
    public void TheReportNamesTheDefaultAsADefault()
    {
        var report = ProviderReport.Describe(new SaathiConfiguration());
        Assert.Contains("provider: local", report, StringComparison.Ordinal);
        Assert.Contains("(default — nothing configured)", report, StringComparison.Ordinal);
        Assert.Contains("stays on this machine", report, StringComparison.Ordinal);
    }

    [Fact]
    public void TheReportFlagsAMissingKeyLoudly()
    {
        var report = ProviderReport.Describe(new SaathiConfiguration { Provider = ProviderKind.Openai });
        Assert.Contains("MISSING", report, StringComparison.Ordinal);
        Assert.Contains("leaves this machine", report, StringComparison.Ordinal);
    }

    /// <summary>The key must never appear in the report — not in full, and not as a prefix.</summary>
    [Fact]
    public void TheReportNeverPrintsTheKey()
    {
        const string secret = "sk-live-abcdef0123456789";
        var report = ProviderReport.Describe(new SaathiConfiguration
        {
            Provider = ProviderKind.Openai,
            ApiKey = secret,
        });
        Assert.DoesNotContain(secret, report, StringComparison.Ordinal);
        Assert.DoesNotContain("sk-", report, StringComparison.Ordinal);
        Assert.Contains("set", report, StringComparison.Ordinal);
    }
}

/// <summary>
/// Adding a provider should be a row in the schema, not a branch in Swift and another in C#.
/// Mirrors ProviderCredentialTests in the macOS package.
/// </summary>
public class ProviderCredentialTests
{
    [Fact]
    public void SarvamIsPresentAndShapedLikeOpenAI()
    {
        var row = SaathiProvider.Of(ProviderKind.Sarvam);
        Assert.Equal("https://api.sarvam.ai/v1", row.DefaultBaseUrl);
        Assert.True(row.RequiresKey);
        Assert.False(row.RequiresToken);
        Assert.True(row.SendsDataOffMachine);
    }

    [Theory]
    [InlineData(ProviderKind.Openai, "Authorization", "Bearer k")]
    [InlineData(ProviderKind.Sarvam, "Authorization", "Bearer k")]
    [InlineData(ProviderKind.Anthropic, "x-api-key", "k")]
    [InlineData(ProviderKind.Hosted, "Authorization", "Bearer k")]
    public void EachProviderPresentsItsCredentialItsOwnWay(ProviderKind kind, string name, string value)
    {
        var header = SaathiProvider.Of(kind).AuthorizationHeader("k");
        Assert.NotNull(header);
        Assert.Equal(name, header!.Value.Name);
        Assert.Equal(value, header.Value.Value);
    }

    [Fact]
    public void TheLocalModeAsksForNoHeaderAtAll()
    {
        Assert.Null(SaathiProvider.Of(ProviderKind.Local).AuthorizationHeader("anything"));
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public void AnEmptyCredentialProducesNoHeaderRatherThanABareBearer(string blank)
    {
        Assert.Null(SaathiProvider.Of(ProviderKind.Openai).AuthorizationHeader(blank));
    }

    [Fact]
    public void TheCredentialIsTrimmedBeforeItIsSent()
    {
        var header = SaathiProvider.Of(ProviderKind.Openai).AuthorizationHeader("  k  ");
        Assert.Equal("Bearer k", header!.Value.Value);
    }
}
