//
//  Speakers.cs
//  Saathi.Core
//
//  Two ways to say something, and one way to open a link.
//  Mirrors macos/Saathi/Sources/SaathiKit/Speakers.swift.
//
//  Note what is NOT here: a SAPI / System.Speech speaker. That assembly is Windows-only, and this
//  project targets net8.0 so the contract and its rules stay compilable on the Linux CI runner and
//  on a maintainer's Mac. The speaking implementation belongs to the WPF shell (net8.0-windows),
//  behind this same ISpeaker.
//

using System.Diagnostics;
using Saathi.Contract;

namespace Saathi.Core;

/// <summary>
/// Prints the line instead of speaking it — for CI, for --quiet, and for anyone who would rather
/// read than listen. The companion says what it is doing either way.
/// </summary>
public sealed class PrintingSpeaker(string prefix = "saathi:", TextWriter? output = null) : ISpeaker
{
    private readonly TextWriter _output = output ?? Console.Out;

    public Task SpeakAsync(string text, Tone tone, CancellationToken cancellationToken = default)
    {
        _output.WriteLine($"{prefix} [{ToneWire(tone)}] {text}");
        return Task.CompletedTask;
    }

    /// <summary>The wire spelling, so CLI output matches the schema and the macOS client.</summary>
    private static string ToneWire(Tone tone) => tone.ToString().ToLowerInvariant();
}

/// <summary>Records what it was asked to say. Tests assert on this; nothing is spoken.</summary>
public sealed class RecordingSpeaker : ISpeaker
{
    public readonly record struct Line(string Text, Tone Tone);

    private readonly List<Line> _recorded = [];
    private readonly object _gate = new();

    public Task SpeakAsync(string text, Tone tone, CancellationToken cancellationToken = default)
    {
        lock (_gate) { _recorded.Add(new Line(text, tone)); }
        return Task.CompletedTask;
    }

    public IReadOnlyList<Line> Lines
    {
        get { lock (_gate) { return _recorded.ToArray(); } }
    }
}

/// <summary>
/// Hands the URL to the OS. Reached only through <see cref="ActionPerformer.Validated"/>, which has
/// already refused everything that is not http(s).
/// </summary>
public sealed class SystemUrlOpener : IUrlOpener
{
    public Task OpenAsync(Uri url, CancellationToken cancellationToken = default)
    {
        // UseShellExecute is what makes this open the default browser rather than trying to execute
        // the string. It is also why the scheme check upstream is not optional.
        Process.Start(new ProcessStartInfo(url.ToString()) { UseShellExecute = true })?.Dispose();
        return Task.CompletedTask;
    }
}

/// <summary>Records what it was asked to open, and opens nothing.</summary>
public sealed class RecordingUrlOpener : IUrlOpener
{
    private readonly List<Uri> _recorded = [];
    private readonly object _gate = new();

    public Task OpenAsync(Uri url, CancellationToken cancellationToken = default)
    {
        lock (_gate) { _recorded.Add(url); }
        return Task.CompletedTask;
    }

    public IReadOnlyList<Uri> Opened
    {
        get { lock (_gate) { return _recorded.ToArray(); } }
    }
}
