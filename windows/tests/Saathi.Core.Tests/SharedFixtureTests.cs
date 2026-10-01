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
        Assert.Equal("not-a-real-openai-key", configuration.OpenaiKey);
        Assert.Equal("not-a-real-anthropic-key", configuration.AnthropicKey);
        Assert.Equal("not-a-real-sarvam-key", configuration.SarvamKey);
        Assert.Equal("not-a-real-voice-model", configuration.VoiceModel);
        Assert.Equal("not-a-real-voice", configuration.Voice);
        Assert.Equal(SpeechEngine.Sarvam, configuration.Speech);
        Assert.Equal("ta", configuration.Language);
        Assert.Equal("https://backend.example.test", configuration.BackendUrl);
        Assert.Equal("not-a-real-token", configuration.Token);
        Assert.Equal("Asha", configuration.Name);
        Assert.Equal("teal", configuration.Colour);
        Assert.Equal(Tone.Calm, configuration.Tone);
        Assert.Equal(Pace.Slow, configuration.Pace);
        Assert.Equal("play the tabla", configuration.FirstGoal);
        Assert.True(configuration.Onboarded);
        Assert.Equal("3f2b8c1e-5a44-4c1b-9d0e-7a6b5c4d3e2f", configuration.DeviceId);
        Assert.False(configuration.StartAtLogin);
    }

    /// <summary>Precedence, not just parsing: both clients must resolve the fixture the same way.</summary>
    [Fact]
    public void ResolutionThroughTheFixtureMatches()
    {
        var configuration = ConfigurationStore.Load(FixturePath());

        Assert.Equal(ProviderKind.Sarvam, configuration.ResolvedProvider);
        Assert.Equal("http://192.168.1.9:11434", configuration.ResolvedProviderBaseUrl);
        Assert.Equal("sarvam-105b-conversations", configuration.ResolvedModel);
        Assert.Equal("not-a-real-sarvam-key", configuration.Credential(ProviderKind.Sarvam));
        Assert.Equal(SpeechEngine.Sarvam, configuration.ResolvedSpeech);
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

    /// <summary>Unset must mean this machine's: a config written before the field existed promised
    /// the voice stays here, and an update must not change that.</summary>
    [Fact]
    public void SpeechIsThisMachinesUntilItIsAskedFor()
    {
        Assert.Equal(
            SpeechEngine.Device,
            new SaathiConfiguration { Provider = ProviderKind.Sarvam, ApiKey = "k" }.ResolvedSpeech);
        Assert.Equal(SpeechEngine.Sarvam, new SaathiConfiguration { Speech = SpeechEngine.Sarvam }.ResolvedSpeech);
    }

    /// <summary>Sarvam has a field of its own, like the other two, and the legacy shared key still
    /// stands in for it on a config written before there was one.</summary>
    [Fact]
    public void SarvamHasItsOwnFieldAndStillReadsTheLegacyOne()
    {
        var own = new SaathiConfiguration { ApiKey = "legacy", OpenaiKey = "sk-openai", SarvamKey = " sk-sarvam " };
        Assert.Equal("sk-sarvam", own.Credential(ProviderKind.Sarvam));
        Assert.Equal(
            "legacy",
            new SaathiConfiguration { Provider = ProviderKind.Sarvam, ApiKey = "legacy" }.Credential(ProviderKind.Sarvam));
        Assert.Null(new SaathiConfiguration { OpenaiKey = "sk-openai" }.Credential(ProviderKind.Sarvam));
    }

    /// <summary>The shared key is one key, and it is the named provider's. Handed to every vendor
    /// that asked, a config naming Sarvam gave its Sarvam key to whoever was asked next.</summary>
    [Fact]
    public void TheLegacySharedKeyBelongsToNoOtherProvider()
    {
        var sarvam = new SaathiConfiguration { Provider = ProviderKind.Sarvam, ApiKey = "sk-legacy" };
        Assert.Equal("sk-legacy", sarvam.Credential(ProviderKind.Sarvam));
        Assert.Null(sarvam.Credential(ProviderKind.Anthropic));
        Assert.Null(sarvam.Credential(ProviderKind.Openai));

        var unnamed = new SaathiConfiguration { ApiKey = "sk-legacy" };
        foreach (var kind in Enum.GetValues<ProviderKind>())
            Assert.Null(unnamed.Credential(kind));
    }
}
