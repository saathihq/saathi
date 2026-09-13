//
//  SharedFixtureTests.cs
//
//  Reads the SAME file as the macOS suite: contract/fixtures/config.json.
//
//  Two clients that cannot parse each other's config are two clients whose users cannot move
//  between them, and nothing in either single-language suite would notice — each would be
//  self-consistently wrong. This fixture is what caught System.Text.Json silently ignoring
//  [JsonPropertyName] on enum members, which left the C# client able to read only "Sarvam" while
//  Swift wrote "sarvam".
//

using System.Text.Json;
using Saathi.Contract;
using Saathi.Core;
using Xunit;

namespace Saathi.Core.Tests;

public class SharedFixtureTests
{
    private static string FixturePath([System.Runtime.CompilerServices.CallerFilePath] string thisFile = "")
    {
        // <repo>/windows/tests/Saathi.Core.Tests/SharedFixtureTests.cs
        var repo = Path.GetFullPath(Path.Combine(Path.GetDirectoryName(thisFile)!, "..", "..", ".."));
        return Path.Combine(repo, "contract", "fixtures", "config.json");
    }

    [Fact]
    public void TheSharedConfigFixtureParses()
    {
        var configuration = ConfigurationStore.Load(FixturePath());

        Assert.Equal(ProviderKind.Sarvam, configuration.Provider);
        Assert.Equal("http://192.168.1.9:11434", configuration.ProviderBaseUrl);
        Assert.Equal("sarvam-105b-conversations", configuration.Model);
        Assert.Equal("not-a-real-key", configuration.ApiKey);
        Assert.Equal("https://backend.example.test", configuration.BackendUrl);
        Assert.Equal("not-a-real-token", configuration.Token);
    }

    /// <summary>Precedence, not just parsing: both clients must resolve the fixture the same way.</summary>
    [Fact]
    public void ResolutionThroughTheFixtureMatches()
    {
        var configuration = ConfigurationStore.Load(FixturePath());

        Assert.Equal(ProviderKind.Sarvam, configuration.ResolvedProvider);
        Assert.Equal("http://192.168.1.9:11434", configuration.ResolvedProviderBaseUrl);
        Assert.Equal("sarvam-105b-conversations", configuration.ResolvedModel);
    }

    /// <summary>
    /// Every enum value must survive a round trip through its wire spelling, since the other client
    /// reads what this one writes.
    /// </summary>
    [Fact]
    public void EveryEnumValueRoundTripsThroughItsWireSpelling()
    {
        foreach (var kind in Enum.GetValues<ProviderKind>())
        {
            var json = JsonSerializer.Serialize(new SaathiConfiguration { Provider = kind });
            var wire = kind.ToString().ToLowerInvariant();
            Assert.Contains($"\"{wire}\"", json, StringComparison.Ordinal);

            var decoded = JsonSerializer.Deserialize<SaathiConfiguration>(json);
            Assert.Equal(kind, decoded!.Provider);
        }
    }

    /// <summary>A PascalCase spelling is not the wire format and must not quietly be accepted.</summary>
    [Fact]
    public void TheCSharpMemberNameIsNotAcceptedAsAWireValue()
    {
        Assert.ThrowsAny<JsonException>(
            () => JsonSerializer.Deserialize<SaathiConfiguration>("""{"provider":"Sarvam"}"""));
    }
}
