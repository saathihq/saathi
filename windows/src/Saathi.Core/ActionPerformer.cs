//
//  ActionPerformer.cs
//  Saathi.Core
//
//  Performing a contract action. The interesting part is what it refuses to do.
//  Mirrors macos/Saathi/Sources/SaathiKit/ActionPerformer.swift — same rules, same messages, same
//  tests on both sides.
//

using Saathi.Contract;

namespace Saathi.Core;

/// <summary>
/// Saying things out loud is the companion's primary output, so it is an interface from the start:
/// the CLI prints, the shell speaks, and the tests assert without either.
/// </summary>
public interface ISpeaker
{
    Task SpeakAsync(string text, Tone tone, CancellationToken cancellationToken = default);
}

/// <summary>Opening things in the world is the other side. Same reason.</summary>
public interface IUrlOpener
{
    Task OpenAsync(Uri url, CancellationToken cancellationToken = default);
}

public sealed class ActionException : Exception
{
    public ActionException(string message) : base(message) { }
}

public sealed class ActionPerformer(ISpeaker speaker, IUrlOpener urlOpener)
{
    public async Task PerformAsync(ISaathiAction action, CancellationToken cancellationToken = default)
    {
        switch (action)
        {
            case SayAction say:
                await speaker.SpeakAsync(say.Text, say.Tone, cancellationToken).ConfigureAwait(false);
                break;

            case ShowStepAction step:
                await speaker.SpeakAsync(Narration(step), Tone.Encouraging, cancellationToken).ConfigureAwait(false);
                break;

            case OpenUrlAction open:
                await urlOpener.OpenAsync(Validated(open.Url), cancellationToken).ConfigureAwait(false);
                break;

            default:
                // Unreachable while every action in the contract is handled above. If the schema
                // gains one and this switch is not updated, failing loudly here is the point.
                throw new ActionException($"no handler for action \"{action.WireName}\"");
        }
    }

    /// <summary>
    /// A step is announced with its place in the whole. Someone who cannot see a progress bar still
    /// needs to know how much is left, and someone who can see one is not harmed by hearing it.
    /// </summary>
    public static string Narration(ShowStepAction step)
    {
        if (step.Total < 1 || step.Index < 1 || step.Index > step.Total)
        {
            throw new ActionException($"step {step.Index} of {step.Total} is not a step that exists");
        }

        var sentence = $"Step {step.Index} of {step.Total}. {step.Title}";
        if (!sentence.EndsWith('.')) sentence += ".";

        if (!string.IsNullOrWhiteSpace(step.Detail))
        {
            sentence += $" {step.Detail}";
            if (!sentence.EndsWith('.')) sentence += ".";
        }

        return sentence;
    }

    /// <summary>
    /// http(s) only, checked here rather than at the call site.
    ///
    /// The contract says a client MUST reject every other scheme. This is where that happens, and
    /// it is deliberately not a nicety: the URL in an open_url action came from a model, which got
    /// it from speech. file:, ssh:, or a custom scheme registered by some other app all hand that
    /// chain the ability to make the OS do something no one asked for.
    /// </summary>
    public static Uri Validated(string raw)
    {
        var trimmed = raw?.Trim() ?? string.Empty;

        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var url))
        {
            throw new ActionException($"not a URL Saathi can open: {raw}");
        }

        var scheme = url.Scheme.ToLowerInvariant();
        if (scheme is not ("http" or "https"))
        {
            throw new ActionException($"refusing to open a \"{scheme}\" URL — Saathi opens http and https only");
        }

        if (string.IsNullOrEmpty(url.Host))
        {
            throw new ActionException($"not a URL Saathi can open: {raw}");
        }

        return url;
    }
}
