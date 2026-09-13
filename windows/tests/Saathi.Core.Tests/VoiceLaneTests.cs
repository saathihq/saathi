//
//  VoiceLaneTests.cs
//  Saathi.Core.Tests
//
//  The C# half of macos/Saathi/Tests/SaathiKitTests/VoiceTests.swift. Same assertions, written
//  twice on purpose: the two clients share no code, so a rule only holds on both platforms if it is
//  checked on both. check-parity.sh then proves the OUTPUT matches; these prove the RULES do.
//

using System.Text.Json;
using Saathi.Contract;
using Saathi.Core;
using Xunit;

namespace Saathi.Core.Tests;

public class VoiceLaneTests
{
    /// <summary>The lane is a capability of the provider, not a setting. If this table changes it is
    /// because a provider gained or lost an API — exactly when someone should be made to look.</summary>
    [Fact]
    public void EveryProviderDeclaresALaneAndOnlyRealProviderSocketsAreRealtime()
    {
        var lanes = SaathiProvider.All.ToDictionary(p => p.Kind, p => p.Voice);
        Assert.Equal(VoiceLane.Chain, lanes[ProviderKind.Local]);
        Assert.Equal(VoiceLane.Chain, lanes[ProviderKind.Anthropic]);
        Assert.Equal(VoiceLane.Chain, lanes[ProviderKind.Sarvam]);
        Assert.Equal(VoiceLane.Realtime, lanes[ProviderKind.Openai]);
        Assert.Equal(VoiceLane.Realtime, lanes[ProviderKind.Hosted]);
        Assert.Equal(Enum.GetValues<ProviderKind>().Length, lanes.Count);
    }

    /// <summary>The default mode must be speakable, with no key and no account.</summary>
    [Fact]
    public void TheDefaultProviderCanBeSpokenTo()
    {
        var unconfigured = new SaathiConfiguration();
        Assert.Equal(ProviderKind.Local, unconfigured.ResolvedProvider);
        Assert.Equal(VoiceLane.Chain, unconfigured.ProviderRow.Voice);
        Assert.False(unconfigured.ProviderRow.RequiresKey);
    }

    /// <summary>The distinction the chain lane exists to make: with a cloud provider thinking, the
    /// transcript leaves but the audio does not.</summary>
    [Fact]
    public void ChainLaneKeepsAudioOnTheMachineEvenForCloudProviders()
    {
        var report = VoiceLaneReport.Describe(
            new SaathiConfiguration { Provider = ProviderKind.Sarvam, ApiKey = "x" });
        Assert.Contains("lane       chain", report);
        Assert.Contains("speech in  on this machine", report);
        Assert.Contains("speech out on this machine", report);
        Assert.Contains("your voice stays on this machine — only the transcript is sent", report);
    }

    [Fact]
    public void RealtimeLaneSaysPlainlyThatAudioLeaves()
    {
        var report = VoiceLaneReport.Describe(
            new SaathiConfiguration { Provider = ProviderKind.Openai, ApiKey = "x" });
        Assert.Contains("lane       realtime", report);
        Assert.Contains("your voice leaves this machine as audio", report);
    }

    [Fact]
    public void LocalReportSaysNothingLeaves()
    {
        var report = VoiceLaneReport.Describe(new SaathiConfiguration());
        Assert.Contains("provider: local  (default — nothing configured)", report);
        Assert.Contains("your voice stays on this machine", report);
        Assert.DoesNotContain("only the transcript is sent", report);
    }

    /// <summary>Same input, same bytes — what check-parity.sh diffs against the macOS client.</summary>
    [Fact]
    public void TheReportIsDeterministic()
    {
        var configuration = new SaathiConfiguration { Provider = ProviderKind.Anthropic, ApiKey = "x" };
        Assert.Equal(VoiceLaneReport.Describe(configuration), VoiceLaneReport.Describe(configuration));
    }
}

public class VoiceToolSchemaTests
{
    /// <summary>The tool list handed to a model is the generated contract bytes. If it cannot be
    /// parsed, every lane silently runs with no tools — a failure that looks like a stupid model.</summary>
    [Fact]
    public void TheGeneratedToolSchemaIsValidAndCoversEveryAction()
    {
        using var document = JsonDocument.Parse(SaathiTools.Json);
        var names = document.RootElement.EnumerateArray()
            .Select(tool => tool.GetProperty("name").GetString()!)
            .ToHashSet();
        Assert.Equal(SaathiActions.AllWireNames.ToHashSet(), names);
    }

    /// <summary>Why the contract's enums are closed, as a test: a mishearing can produce a wrong
    /// value inside a known set, never a command outside it.</summary>
    [Fact]
    public void EnumParametersReachTheModelAsClosedSets()
    {
        using var document = JsonDocument.Parse(SaathiTools.Json);
        var say = document.RootElement.EnumerateArray()
            .Single(tool => tool.GetProperty("name").GetString() == "say");
        var tone = say.GetProperty("parameters").GetProperty("properties").GetProperty("tone");
        var cases = tone.GetProperty("enum").EnumerateArray().Select(v => v.GetString()).ToArray();
        Assert.Equal(Enum.GetNames<Tone>().Select(n => n.ToLowerInvariant()).ToArray(), cases);
    }

    /// <summary>The point of emitting the schema as one JSON string rather than native literals per
    /// language: a model sees the same bytes on Windows and on macOS. Anything else drifts.</summary>
    [Fact]
    public void TheSchemaIsTheSameBytesTheOtherClientEmbeds()
    {
        var swiftSource = File.ReadAllText(Path.Combine(
            RepositoryRoot(), "macos", "Saathi", "Sources", "SaathiContract", "SaathiContract.swift"));
        Assert.Contains(SaathiTools.Json.Replace("\r\n", "\n"), swiftSource.Replace("\r\n", "\n"));
    }

    private static string RepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "contract")))
        {
            directory = directory.Parent;
        }
        return directory?.FullName ?? throw new InvalidOperationException("could not find the repository root");
    }
}
