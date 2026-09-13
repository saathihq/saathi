// Generated from contract/schema/saathi.json by contract/generate.mjs. Do not edit.
// Run `npm run generate -w contract` after changing the schema.
// Contract version 0.2.0.

#nullable enable
using System.Linq;
using System.Text.Json.Serialization;

namespace Saathi.Contract;

/// <summary>Where the backend lives, and the contract this client was built against.</summary>
public static class SaathiBackend
{
    public const string DefaultBaseUrl = "https://api.saathi.dev";
    public const string ContractVersion = "0.2.0";
}

/// <summary>One row per provider mode: where it runs, what it needs, and whether using it
/// means anything the learner says leaves their machine.</summary>
public sealed record SaathiProvider(
    ProviderKind Kind,
    string DefaultBaseUrl,
    string DefaultModel,
    bool RequiresKey,
    bool RequiresToken,
    bool SendsDataOffMachine,
    string Summary)
{
    public static readonly IReadOnlyList<SaathiProvider> All =
    [
        new(global::Saathi.Contract.ProviderKind.Local, "http://localhost:11434", "llama3.2", false, false, false, "An OpenAI-compatible server on this machine — Ollama, LM Studio, llama.cpp. No key, no account, nothing leaves the device."),
        new(global::Saathi.Contract.ProviderKind.Openai, "https://api.openai.com/v1", "gpt-4o-mini", true, false, true, "Your own OpenAI key, held on your machine and sent straight to OpenAI. Saathi's servers are not involved."),
        new(global::Saathi.Contract.ProviderKind.Anthropic, "https://api.anthropic.com", "claude-sonnet-5", true, false, true, "Your own Anthropic key, held on your machine and sent straight to Anthropic. Saathi's servers are not involved."),
        new(global::Saathi.Contract.ProviderKind.Hosted, "https://api.saathi.dev", "", false, true, true, "Saathi's hosted backend holds the provider keys; you hold an account token. For people who would rather not run or configure anything."),
    ];

    /// <summary>`All` covers every case of a closed enum, so this cannot miss in practice;
    /// throwing is better than inventing a fallback that would silently pick a mode.</summary>
    public static SaathiProvider Of(ProviderKind kind) =>
        All.FirstOrDefault(p => p.Kind == kind)
        ?? throw new InvalidOperationException($"no provider row for {kind} — the contract is out of sync");
}

/// <summary><c>~/.saathi/shell.json</c>.</summary>
public sealed class SaathiConfiguration
{
    /// <summary>Which mode to run in. Unset means local — see providers.default.</summary>
    [JsonPropertyName("provider")]
    public ProviderKind? Provider { get; set; }

    /// <summary>Overrides the provider's default base URL (another Ollama host, a proxy, a compatible server).</summary>
    [JsonPropertyName("providerBaseUrl")]
    public string? ProviderBaseUrl { get; set; }

    /// <summary>Overrides the provider's default model.</summary>
    [JsonPropertyName("model")]
    public string? Model { get; set; }

    /// <summary>Your own provider key, for the openai and anthropic modes. Never sent to Saathi's servers.</summary>
    [JsonPropertyName("apiKey")]
    public string? ApiKey { get; set; }

    /// <summary>Overrides the hosted backend URL. Only used in hosted mode.</summary>
    [JsonPropertyName("backendUrl")]
    public string? BackendUrl { get; set; }

    /// <summary>Account token for the hosted backend. Only used in hosted mode.</summary>
    [JsonPropertyName("token")]
    public string? Token { get; set; }

    /// <summary>The mode in effect. Unset means <c>local</c> — running against a model
    /// on this machine, with no key and no account, is the default rather than a special case.</summary>
    public ProviderKind ResolvedProvider => Provider ?? global::Saathi.Contract.ProviderKind.Local;

    public SaathiProvider ProviderRow => SaathiProvider.Of(ResolvedProvider);

    /// <summary>The provider's base URL, or the override if one is configured.</summary>
    public string ResolvedProviderBaseUrl =>
        string.IsNullOrWhiteSpace(ProviderBaseUrl) ? ProviderRow.DefaultBaseUrl : ProviderBaseUrl!.Trim();

    public string ResolvedModel =>
        string.IsNullOrWhiteSpace(Model) ? ProviderRow.DefaultModel : Model!.Trim();

    /// <summary>The hosted backend unless the config names another one. Only meaningful in hosted mode.</summary>
    public string ResolvedBaseUrl =>
        string.IsNullOrWhiteSpace(BackendUrl) ? SaathiBackend.DefaultBaseUrl : BackendUrl!.Trim();
}

/// <summary>Where the model actually runs. This is the choice that decides whether anything the learner says leaves their machine.</summary>
[JsonConverter(typeof(JsonStringEnumConverter))]
public enum ProviderKind
{
    [JsonPropertyName("local")]
    Local,
    [JsonPropertyName("openai")]
    Openai,
    [JsonPropertyName("anthropic")]
    Anthropic,
    [JsonPropertyName("hosted")]
    Hosted,
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
