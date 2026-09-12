// Generated from contract/schema/saathi.json by contract/generate.mjs. Do not edit.
// Run `npm run generate -w contract` after changing the schema.
// Contract version 0.1.0.

#nullable enable
using System.Text.Json.Serialization;

namespace Saathi.Contract;

/// <summary>Where the backend lives, and the contract this client was built against.</summary>
public static class SaathiBackend
{
    public const string DefaultBaseUrl = "https://api.saathi.dev";
    public const string ContractVersion = "0.1.0";
}

/// <summary><c>~/.saathi/shell.json</c>.</summary>
public sealed class SaathiConfiguration
{
    /// <summary>Overrides the hosted default.</summary>
    [JsonPropertyName("backendUrl")]
    public string? BackendUrl { get; set; }

    /// <summary>Bearer token for the backend.</summary>
    [JsonPropertyName("token")]
    public string? Token { get; set; }

    /// <summary>The hosted backend unless the config names another one.</summary>
    public string ResolvedBaseUrl =>
        string.IsNullOrWhiteSpace(BackendUrl) ? SaathiBackend.DefaultBaseUrl : BackendUrl!.Trim();
}

/// <summary>How a spoken line should sound. Accessibility-first: the companion says what is happening, and how it says it is part of the message.</summary>
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum Tone
{
    [JsonPropertyName("calm")]
    Calm,
    [JsonPropertyName("encouraging")]
    Encouraging,
    [JsonPropertyName("neutral")]
    Neutral,
}

/// <summary>How fast to move through a sequence of steps. The learner sets this, not the model.</summary>
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum Pace
{
    [JsonPropertyName("slow")]
    Slow,
    [JsonPropertyName("normal")]
    Normal,
}

/// <summary>Speak a line to the learner. The companion narrates; this is the primary action.</summary>
public sealed record SayAction(string Text, Tone Tone = global::Saathi.Contract.Tone.Neutral) : ISaathiAction
{
    public const string Wire = "say";
    public string WireName => Wire;
}

/// <summary>Put one step of something being learned in front of the learner, with its place in the whole.</summary>
public sealed record ShowStepAction(string Title, int Index, int Total, string? Detail = null, Pace Pace = global::Saathi.Contract.Pace.Normal) : ISaathiAction
{
    public const string Wire = "show_step";
    public string WireName => Wire;
}

/// <summary>Open a resource in the learner's browser. http(s) only — clients MUST reject every other scheme rather than pass it to the OS.</summary>
public sealed record OpenUrlAction(string Url) : ISaathiAction
{
    public const string Wire = "open_url";
    public string WireName => Wire;
}

/// <summary>Every action a Saathi client can be asked to perform. Closed on purpose: a
/// mishearing can produce a wrong value inside one of these, never a command outside the set.</summary>
public interface ISaathiAction
{
    string WireName { get; }
}

public static class SaathiActions
{
    /// <summary>The wire names, in schema order — for building a tool list or a smoke test.</summary>
    public static readonly string[] AllWireNames =
    ["say", "show_step", "open_url"];
}
