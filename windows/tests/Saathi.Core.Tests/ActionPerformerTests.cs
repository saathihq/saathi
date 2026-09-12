//
//  ActionPerformerTests.cs
//
//  The same assertions as macos/Saathi/Tests/SaathiKitTests/SaathiKitTests.swift. Kept
//  deliberately parallel: if one client's rules drift from the other's, the divergence should show
//  up as a test that exists on one side and not the other, which is visible in review.
//

using Saathi.Contract;
using Saathi.Core;
using Xunit;

namespace Saathi.Core.Tests;

public class UrlSafetyTests
{
    [Theory]
    [InlineData("https://saathi.dev", "saathi.dev")]
    [InlineData("http://example.org/a/b", "example.org")]
    [InlineData("  https://saathi.dev  ", "saathi.dev")]
    public void HttpAndHttpsUrlsAreAccepted(string raw, string expectedHost)
    {
        Assert.Equal(expectedHost, ActionPerformer.Validated(raw).Host);
    }

    /// <summary>
    /// The URL in an open_url action came from a model, which got it from speech. Every one of
    /// these would otherwise hand that chain the ability to make the OS do something unasked.
    /// </summary>
    [Theory]
    [InlineData("file:///etc/passwd")]
    [InlineData("ssh://root@example.com")]
    [InlineData("ftp://example.com")]
    [InlineData("javascript:alert(1)")]
    [InlineData("data:text/html,<script>alert(1)</script>")]
    [InlineData("vscode://file/etc/passwd")]
    [InlineData("smb://example.com/share")]
    public void EveryOtherSchemeIsRefused(string raw)
    {
        var error = Assert.Throws<ActionException>(() => ActionPerformer.Validated(raw));
        Assert.Contains("http and https only", error.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("saathi.dev")]
    [InlineData("")]
    [InlineData("   ")]
    public void SchemelessAndJunkUrlsAreRefused(string raw)
    {
        Assert.Throws<ActionException>(() => ActionPerformer.Validated(raw));
    }
}

public class StepNarrationTests
{
    [Fact]
    public void AStepAlwaysAnnouncesItsPlaceInTheWhole()
    {
        var step = new ShowStepAction("Open the lid", 2, 5);
        Assert.Equal("Step 2 of 5. Open the lid.", ActionPerformer.Narration(step));
    }

    [Fact]
    public void DetailIsAppendedAndPunctuated()
    {
        var step = new ShowStepAction("Open the lid", 1, 2, "It is stiff the first time");
        Assert.Equal("Step 1 of 2. Open the lid. It is stiff the first time.", ActionPerformer.Narration(step));
    }

    [Fact]
    public void BlankDetailIsNotAppended()
    {
        var step = new ShowStepAction("Open the lid", 1, 2, "   ");
        Assert.Equal("Step 1 of 2. Open the lid.", ActionPerformer.Narration(step));
    }

    [Theory]
    [InlineData(0, 3)]
    [InlineData(4, 3)]
    [InlineData(1, 0)]
    [InlineData(-1, 5)]
    public void ImpossibleStepNumbersAreRefused(int index, int total)
    {
        Assert.Throws<ActionException>(() => ActionPerformer.Narration(new ShowStepAction("x", index, total)));
    }
}

public class PerformingTests
{
    [Fact]
    public async Task PerformingSayPassesTheToneThrough()
    {
        var speaker = new RecordingSpeaker();
        var performer = new ActionPerformer(speaker, new RecordingUrlOpener());

        await performer.PerformAsync(new SayAction("hello", Tone.Calm));

        var line = Assert.Single(speaker.Lines);
        Assert.Equal("hello", line.Text);
        Assert.Equal(Tone.Calm, line.Tone);
    }

    [Fact]
    public async Task PerformingAStepNarratesItEncouragingly()
    {
        var speaker = new RecordingSpeaker();
        var performer = new ActionPerformer(speaker, new RecordingUrlOpener());

        await performer.PerformAsync(new ShowStepAction("Try it", 1, 1));

        var line = Assert.Single(speaker.Lines);
        Assert.Equal("Step 1 of 1. Try it.", line.Text);
        Assert.Equal(Tone.Encouraging, line.Tone);
    }

    [Fact]
    public async Task ARefusedUrlIsNeverHandedToTheOpener()
    {
        var opener = new RecordingUrlOpener();
        var performer = new ActionPerformer(new RecordingSpeaker(), opener);

        await Assert.ThrowsAsync<ActionException>(
            () => performer.PerformAsync(new OpenUrlAction("file:///etc/passwd")));

        Assert.Empty(opener.Opened);
    }
}

public class ContractTests
{
    /// <summary>
    /// The generated contract is the only thing binding this client to the macOS one. If a wire
    /// name changes here without changing there, nothing else in either build would notice.
    /// </summary>
    [Fact]
    public void WireNamesAreWhatTheSchemaSays()
    {
        Assert.Equal(["say", "show_step", "open_url"], SaathiActions.AllWireNames);
        Assert.Equal("say", SayAction.Wire);
        Assert.Equal("show_step", ShowStepAction.Wire);
        Assert.Equal("open_url", OpenUrlAction.Wire);
    }

    [Fact]
    public void AnActionReportsItsOwnWireName()
    {
        Assert.Equal("say", new SayAction("x").WireName);
        Assert.Equal("show_step", new ShowStepAction("x", 1, 1).WireName);
    }

    [Fact]
    public void DefaultsMatchTheSchema()
    {
        Assert.Equal(Tone.Neutral, new SayAction("x").Tone);
        Assert.Equal(Pace.Normal, new ShowStepAction("x", 1, 1).Pace);
    }
}
