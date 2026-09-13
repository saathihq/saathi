//
//  VoiceLaneReport.cs
//  Saathi.Core
//
//  "If I talk to Saathi, where does my voice go?"
//
//  The C# half of a report that must come out byte-identical to the Swift one — see
//  macos/Saathi/Sources/SaathiKit/VoiceLaneReport.swift, and scripts/check-parity.sh, which diffs
//  the two clients running side by side. Two clients that disagree about where a learner's voice
//  goes would be worse than either of them being wrong on its own.
//
//  The interesting line is `your voice`. In the chain lane speech-to-text and text-to-speech both
//  run on-device, so even with a cloud provider doing the thinking the learner's AUDIO never leaves
//  the machine — only the transcript does. That is a materially different promise from the realtime
//  lane, and it is the reason this report exists separately from ProviderReport.
//
//  Windows has no voice implementation yet: this reports the lane the contract assigns, which is
//  real and checkable, and the WPF shell will implement it behind the same contract. Reporting a
//  lane the platform cannot yet run is deliberate — it is what makes the gap visible rather than
//  silently absent.
//

using Saathi.Contract;

namespace Saathi.Core;

public static class VoiceLaneReport
{
    /// <summary>Deterministic. Same configuration in, same bytes out, on either platform.</summary>
    public static string Describe(SaathiConfiguration configuration)
    {
        var row = configuration.ProviderRow;
        var chosenExplicitly = configuration.Provider is not null;
        var model = configuration.ResolvedModel.Length == 0 ? "chosen by the backend" : configuration.ResolvedModel;

        var lines = new List<string>
        {
            $"provider: {row.Kind.ToString().ToLowerInvariant()}{(chosenExplicitly ? "" : "  (default — nothing configured)")}",
            $"  {LaneSummary(row.Voice)}",
            "",
            $"  lane       {row.Voice.ToString().ToLowerInvariant()}",
            $"  speech in  {SpeechEnd(row)}",
            $"  thinking   {model} @ {configuration.ResolvedProviderBaseUrl}",
            $"  speech out {SpeechEnd(row)}",
            $"  your voice {VoicePrivacy(row)}",
            $"  turn       {TurnShape(row.Voice)}",
        };
        return string.Join("\n", lines);
    }

    private static string LaneSummary(VoiceLane lane) => lane switch
    {
        VoiceLane.Realtime =>
            "One open connection carries speech in and speech out — the companion can be interrupted mid-sentence.",
        _ => "Speech in, think, speech out as three separate steps. Slower, and it works with any model.",
    };

    /// <summary>In the chain lane both ends are on-device, whoever the provider is. That is not a
    /// fallback — it is the reason the chain lane is worth having at all.</summary>
    private static string SpeechEnd(SaathiProvider row) =>
        row.Voice == VoiceLane.Realtime
            ? $"{row.Kind.ToString().ToLowerInvariant()}, over the open connection"
            : "on this machine";

    private static string VoicePrivacy(SaathiProvider row)
    {
        if (row.Voice == VoiceLane.Realtime) return "leaves this machine as audio";
        if (row.SendsDataOffMachine) return "stays on this machine — only the transcript is sent";
        return "stays on this machine";
    }

    private static string TurnShape(VoiceLane lane) => lane switch
    {
        VoiceLane.Realtime => "one connection, no round trip per step",
        _ => "three steps per turn, so expect a pause before Saathi answers",
    };
}
