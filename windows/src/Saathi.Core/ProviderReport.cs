//
//  ProviderReport.cs
//  Saathi.Core
//
//  "Which mode am I actually in, and does anything I say leave this machine?"
//
//  Mirrors macos/Saathi/Sources/SaathiKit/ProviderReport.swift line for line — the two must render
//  byte-identical text, and scripts/check-parity.sh diffs them to make sure they still do.
//
//  Describe() is pure so that comparison is possible at all. Reachability touches the network and
//  its answer depends on the machine, so it is a separate, opt-in step.
//

using Saathi.Contract;

namespace Saathi.Core;

public static class ProviderReport
{
    /// <summary>Deterministic. Same configuration in, same bytes out, on either platform.</summary>
    public static string Describe(SaathiConfiguration configuration)
    {
        var row = configuration.ProviderRow;
        var chosenExplicitly = configuration.Provider is not null;

        var lines = new List<string>
        {
            $"provider: {Wire(row.Kind)}{(chosenExplicitly ? "" : "  (default — nothing configured)")}",
            $"  {row.Summary}",
            "",
            $"  base url   {configuration.ResolvedProviderBaseUrl}",
            $"  model      {(string.IsNullOrEmpty(configuration.ResolvedModel) ? "chosen by the backend" : configuration.ResolvedModel)}",
            $"  your key   {KeyLine(row, configuration)}",
            $"  account    {TokenLine(row, configuration)}",
            $"  privacy    {(row.SendsDataOffMachine ? "leaves this machine" : "stays on this machine")}",
        };

        return string.Join("\n", lines);
    }

    /// <summary>The wire spelling, so the two clients agree on how a mode is named.</summary>
    private static string Wire(ProviderKind kind) => kind.ToString().ToLowerInvariant();

    private static string KeyLine(SaathiProvider row, SaathiConfiguration configuration)
    {
        if (!row.RequiresKey) return "not needed";
        var present = !string.IsNullOrWhiteSpace(configuration.ApiKey);
        // Never the key itself, and never a prefix of it: a logged prefix is still a logged secret.
        return present ? "set" : "MISSING — this mode cannot run without it";
    }

    private static string TokenLine(SaathiProvider row, SaathiConfiguration configuration)
    {
        if (!row.RequiresToken) return "not needed";
        var present = !string.IsNullOrWhiteSpace(configuration.Token);
        return present ? "signed in" : "MISSING — sign in, or switch to a mode that needs no account";
    }

    /// <summary>
    /// Is the configured provider actually there? Opt-in, because it touches the network.
    /// Any HTTP answer counts as reachable — the question is whether something is listening, not
    /// whether this particular path exists.
    /// </summary>
    public static async Task<string> ReachabilityAsync(
        SaathiConfiguration configuration,
        HttpClient? httpClient = null,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        if (!Uri.TryCreate(configuration.ResolvedProviderBaseUrl, UriKind.Absolute, out var url))
        {
            return $"cannot check — {configuration.ResolvedProviderBaseUrl} is not a usable URL";
        }

        var ownsClient = httpClient is null;
        var client = httpClient ?? new HttpClient { Timeout = timeout ?? TimeSpan.FromSeconds(3) };
        try
        {
            using var response = await client.GetAsync(url, cancellationToken).ConfigureAwait(false);
            return "reachable";
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            if (configuration.ResolvedProvider == ProviderKind.Local)
            {
                return "not reachable — start Ollama or LM Studio, or point providerBaseUrl elsewhere";
            }
            return $"not reachable — {e.Message}";
        }
        finally
        {
            if (ownsClient) client.Dispose();
        }
    }
}
