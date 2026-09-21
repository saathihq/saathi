// Generated from contract/schema/saathi.json by contract/generate.mjs. Do not edit.
// Run `npm run generate -w contract` after changing the schema.
// Contract version 0.8.0.

#nullable enable
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Saathi.Contract;

/// <summary>Where the backend lives, and the contract this client was built against.</summary>
public static class SaathiBackend
{
    public const string DefaultBaseUrl = "https://api.saathi.dev";
    public const string ContractVersion = "0.8.0";
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
    string KeyHeader,
    string KeyPrefix,
    VoiceLane Voice,
    string DefaultVoiceModel,
    string DefaultVoice,
    string Summary)
{
    public static readonly IReadOnlyList<SaathiProvider> All =
    [
        new(global::Saathi.Contract.ProviderKind.Local, "http://localhost:11434", "llama3.2", false, false, false, "", "", global::Saathi.Contract.VoiceLane.Chain, "", "", "An OpenAI-compatible server on this machine — Ollama, LM Studio, llama.cpp. No key, no account, nothing leaves the device."),
        new(global::Saathi.Contract.ProviderKind.Openai, "https://api.openai.com/v1", "gpt-4o-mini", true, false, true, "Authorization", "Bearer ", global::Saathi.Contract.VoiceLane.Realtime, "gpt-realtime", "cedar", "Your own OpenAI key, held on your machine and sent straight to OpenAI. Saathi's servers are not involved."),
        new(global::Saathi.Contract.ProviderKind.Anthropic, "https://api.anthropic.com", "claude-sonnet-5", true, false, true, "x-api-key", "", global::Saathi.Contract.VoiceLane.Chain, "", "", "Your own Anthropic key, held on your machine and sent straight to Anthropic. Saathi's servers are not involved."),
        new(global::Saathi.Contract.ProviderKind.Sarvam, "https://api.sarvam.ai/v1", "sarvam-105b", true, false, true, "Authorization", "Bearer ", global::Saathi.Contract.VoiceLane.Chain, "", "", "Your own Sarvam AI key, sent straight to Sarvam. Indian-built models with real Indic-language coverage — the reason this option exists, given where Saathi starts."),
        new(global::Saathi.Contract.ProviderKind.Hosted, "https://api.saathi.dev", "", false, true, true, "Authorization", "Bearer ", global::Saathi.Contract.VoiceLane.Realtime, "gpt-realtime", "cedar", "Saathi's hosted backend holds the provider keys; you hold an account token. For people who would rather not run or configure anything."),
    ];

    /// <summary>The one header this provider needs, ready to set — or null when it needs none.
    /// Built here so no client hard-codes Bearer for one provider and x-api-key for another.</summary>
    public (string Name, string Value)? AuthorizationHeader(string credential)
    {
        var trimmed = credential?.Trim() ?? string.Empty;
        if (KeyHeader.Length == 0 || trimmed.Length == 0) return null;
        return (KeyHeader, KeyPrefix + trimmed);
    }

    /// <summary>`All` covers every case of a closed enum, so this cannot miss in practice;
    /// throwing is better than inventing a fallback that would silently pick a mode.</summary>
    public static SaathiProvider Of(ProviderKind kind) =>
        All.FirstOrDefault(p => p.Kind == kind)
        ?? throw new InvalidOperationException($"no provider row for {kind} — the contract is out of sync");
}

/// <summary>The action list as JSON-Schema function tools — the exact bytes a model is shown.
/// Identical on macOS, Windows and the backend; see contract/generate.mjs for why that matters.</summary>
public static class SaathiTools
{
    public const string Json = """
[
  {
    "type": "function",
    "name": "say",
    "description": "Speak a line to the learner. The companion narrates; this is the primary action.",
    "parameters": {
      "type": "object",
      "properties": {
        "text": {
          "type": "string",
          "description": "What to say. One or two sentences."
        },
        "tone": {
          "type": "string",
          "enum": [
            "calm",
            "encouraging",
            "neutral"
          ],
          "description": "How it should sound. Defaults to \"neutral\"."
        }
      },
      "required": [
        "text"
      ]
    }
  },
  {
    "type": "function",
    "name": "show_step",
    "description": "Put one step of something being learned in front of the learner, with its place in the whole.",
    "parameters": {
      "type": "object",
      "properties": {
        "title": {
          "type": "string",
          "description": "The step itself, in a few words."
        },
        "detail": {
          "type": "string",
          "description": "One sentence of elaboration, if it helps."
        },
        "index": {
          "type": "integer",
          "description": "1-based position of this step."
        },
        "total": {
          "type": "integer",
          "description": "How many steps there are, so progress is always audible."
        },
        "pace": {
          "type": "string",
          "enum": [
            "slow",
            "normal"
          ],
          "description": "How fast to move on. Defaults to \"normal\"."
        }
      },
      "required": [
        "title",
        "index",
        "total"
      ]
    }
  },
  {
    "type": "function",
    "name": "open_url",
    "description": "Open a resource in the learner's browser. http(s) only — clients MUST reject every other scheme rather than pass it to the OS.",
    "parameters": {
      "type": "object",
      "properties": {
        "url": {
          "type": "string",
          "description": "An absolute http or https URL."
        }
      },
      "required": [
        "url"
      ]
    }
  },
  {
    "type": "function",
    "name": "look_at_screen",
    "description": "Look at what is on the learner's screen and answer a question about it. Call this whenever they ask about something they can see — a window, a folder, an error, a button — instead of guessing or saying you cannot see. One frame of the main display is sent to a vision model; nothing is captured at any other time.",
    "parameters": {
      "type": "object",
      "properties": {
        "question": {
          "type": "string",
          "description": "What to find out about the screen, in the learner's own words where possible."
        }
      },
      "required": [
        "question"
      ]
    }
  }
]
""";
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

    /// <summary>Deprecated: use openaiKey or anthropicKey. Still read when no vendor-specific key is set, so existing configs keep working.</summary>
    [JsonPropertyName("apiKey")]
    public string? ApiKey { get; set; }

    /// <summary>Your own OpenAI key. Used for the realtime voice lane and for thinking. Never sent to Saathi's servers.</summary>
    [JsonPropertyName("openaiKey")]
    public string? OpenaiKey { get; set; }

    /// <summary>Your own Anthropic key. Stored for a lane that does not exist yet; nothing calls it today.</summary>
    [JsonPropertyName("anthropicKey")]
    public string? AnthropicKey { get; set; }

    /// <summary>Overrides the realtime voice model. Distinct from model, which is what does the thinking.</summary>
    [JsonPropertyName("voiceModel")]
    public string? VoiceModel { get; set; }

    /// <summary>The realtime voice's name. Defaults to the provider row's.</summary>
    [JsonPropertyName("voice")]
    public string? Voice { get; set; }

    /// <summary>The language Saathi speaks, as a BCP-47 tag ("en", "hi", "ta", "ko"). Unset means follow this machine's language rather than let the model guess.</summary>
    [JsonPropertyName("language")]
    public string? Language { get; set; }

    /// <summary>Overrides the hosted backend URL. Only used in hosted mode.</summary>
    [JsonPropertyName("backendUrl")]
    public string? BackendUrl { get; set; }

    /// <summary>Account token for the hosted backend. Only used in hosted mode.</summary>
    [JsonPropertyName("token")]
    public string? Token { get; set; }

    /// <summary>What the learner asked to be called. Asked once, in onboarding.</summary>
    [JsonPropertyName("name")]
    public string? Name { get; set; }

    /// <summary>The mascot's colour, as a palette name from mascot.json.</summary>
    [JsonPropertyName("colour")]
    public string? Colour { get; set; }

    /// <summary>How the learner asked Saathi to sound.</summary>
    [JsonPropertyName("tone")]
    public Tone? Tone { get; set; }

    /// <summary>How fast the learner asked Saathi to go.</summary>
    [JsonPropertyName("pace")]
    public Pace? Pace { get; set; }

    /// <summary>What the learner said they want to learn or play with first.</summary>
    [JsonPropertyName("firstGoal")]
    public string? FirstGoal { get; set; }

    /// <summary>True once first run has finished. Unset or false means show it.</summary>
    [JsonPropertyName("onboarded")]
    public bool? Onboarded { get; set; }

    /// <summary>A UUID v4 generated once on this machine. Sent to the hosted backend only to ask for a trial, so a reinstall does not mint a second allowance.</summary>
    [JsonPropertyName("deviceId")]
    public string? DeviceId { get; set; }

    /// <summary>Whether Saathi registered itself as a login item.</summary>
    [JsonPropertyName("startAtLogin")]
    public bool? StartAtLogin { get; set; }

    /// <summary>The mode in effect. Unset means <c>local</c> — running against a model
    /// on this machine, with no key and no account, is the default rather than a special case.</summary>
    public ProviderKind ResolvedProvider => Provider ?? global::Saathi.Contract.ProviderKind.Local;

    public SaathiProvider ProviderRow => SaathiProvider.Of(ResolvedProvider);

    /// <summary>The provider's base URL, or the override if one is configured.</summary>
    public string ResolvedProviderBaseUrl =>
        string.IsNullOrWhiteSpace(ProviderBaseUrl) ? ProviderRow.DefaultBaseUrl : ProviderBaseUrl!.Trim();

    public string ResolvedModel =>
        string.IsNullOrWhiteSpace(Model) ? ProviderRow.DefaultModel : Model!.Trim();

    /// <summary>The realtime voice model. Separate from ResolvedModel on purpose: the socket is
    /// opened with this one, and opening it with the thinking model is rejected by the provider.</summary>
    public string ResolvedVoiceModel =>
        string.IsNullOrWhiteSpace(VoiceModel) ? ProviderRow.DefaultVoiceModel : VoiceModel!.Trim();

    public string ResolvedVoice =>
        string.IsNullOrWhiteSpace(Voice) ? ProviderRow.DefaultVoice : Voice!.Trim();

    /// <summary>The language Saathi speaks. Unset follows this machine's own language.</summary>
    public string ResolvedLanguage =>
        string.IsNullOrWhiteSpace(Language)
            ? (System.Globalization.CultureInfo.CurrentUICulture.TwoLetterISOLanguageName ?? "en")
            : Language!.Trim();

    /// <summary>The credential for a provider: its own vendor field first, then the legacy
    /// shared ApiKey. Providers needing no key of their own get null.</summary>
    public string? Credential(ProviderKind kind)
    {
        if (!SaathiProvider.Of(kind).RequiresKey) return null;
        var candidates = kind switch
        {
            global::Saathi.Contract.ProviderKind.Openai => new[] { OpenaiKey, ApiKey },
            global::Saathi.Contract.ProviderKind.Anthropic => new[] { AnthropicKey, ApiKey },
            _ => new[] { ApiKey },
        };
        foreach (var candidate in candidates)
            if (!string.IsNullOrWhiteSpace(candidate)) return candidate!.Trim();
        return null;
    }

    /// <summary>The hosted backend unless the config names another one. Only meaningful in hosted mode.</summary>
    public string ResolvedBaseUrl =>
        string.IsNullOrWhiteSpace(BackendUrl) ? SaathiBackend.DefaultBaseUrl : BackendUrl!.Trim();
}

/// <summary>ProviderKind on the wire. Accepts the contract's spelling only — the C# member
/// name is not an alias, because the Swift client would not accept it either.</summary>
public sealed class ProviderKindWireConverter : JsonConverter<ProviderKind>
{
    public override ProviderKind Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.GetString() switch
        {
            "local" => ProviderKind.Local,
            "openai" => ProviderKind.Openai,
            "anthropic" => ProviderKind.Anthropic,
            "sarvam" => ProviderKind.Sarvam,
            "hosted" => ProviderKind.Hosted,
            var other => throw new JsonException($"{other} is not a valid ProviderKind — expected one of: local, openai, anthropic, sarvam, hosted"),
        };

    public override void Write(Utf8JsonWriter writer, ProviderKind value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value switch
        {
            ProviderKind.Local => "local",
            ProviderKind.Openai => "openai",
            ProviderKind.Anthropic => "anthropic",
            ProviderKind.Sarvam => "sarvam",
            ProviderKind.Hosted => "hosted",
            _ => throw new JsonException($"no wire spelling for {value} — the contract is out of sync"),
        });
}

/// <summary>Tone on the wire. Accepts the contract's spelling only — the C# member
/// name is not an alias, because the Swift client would not accept it either.</summary>
public sealed class ToneWireConverter : JsonConverter<Tone>
{
    public override Tone Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.GetString() switch
        {
            "calm" => Tone.Calm,
            "encouraging" => Tone.Encouraging,
            "neutral" => Tone.Neutral,
            var other => throw new JsonException($"{other} is not a valid Tone — expected one of: calm, encouraging, neutral"),
        };

    public override void Write(Utf8JsonWriter writer, Tone value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value switch
        {
            Tone.Calm => "calm",
            Tone.Encouraging => "encouraging",
            Tone.Neutral => "neutral",
            _ => throw new JsonException($"no wire spelling for {value} — the contract is out of sync"),
        });
}

/// <summary>Pace on the wire. Accepts the contract's spelling only — the C# member
/// name is not an alias, because the Swift client would not accept it either.</summary>
public sealed class PaceWireConverter : JsonConverter<Pace>
{
    public override Pace Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.GetString() switch
        {
            "slow" => Pace.Slow,
            "normal" => Pace.Normal,
            var other => throw new JsonException($"{other} is not a valid Pace — expected one of: slow, normal"),
        };

    public override void Write(Utf8JsonWriter writer, Pace value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value switch
        {
            Pace.Slow => "slow",
            Pace.Normal => "normal",
            _ => throw new JsonException($"no wire spelling for {value} — the contract is out of sync"),
        });
}

/// <summary>VoiceLane on the wire. Accepts the contract's spelling only — the C# member
/// name is not an alias, because the Swift client would not accept it either.</summary>
public sealed class VoiceLaneWireConverter : JsonConverter<VoiceLane>
{
    public override VoiceLane Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        reader.GetString() switch
        {
            "realtime" => VoiceLane.Realtime,
            "chain" => VoiceLane.Chain,
            var other => throw new JsonException($"{other} is not a valid VoiceLane — expected one of: realtime, chain"),
        };

    public override void Write(Utf8JsonWriter writer, VoiceLane value, JsonSerializerOptions options) =>
        writer.WriteStringValue(value switch
        {
            VoiceLane.Realtime => "realtime",
            VoiceLane.Chain => "chain",
            _ => throw new JsonException($"no wire spelling for {value} — the contract is out of sync"),
        });
}

/// <summary>Where the model actually runs. This is the choice that decides whether anything the learner says leaves their machine.</summary>
[JsonConverter(typeof(ProviderKindWireConverter))]
public enum ProviderKind
{
    Local,
    Openai,
    Anthropic,
    Sarvam,
    Hosted,
}

/// <summary>How a spoken line should sound. Accessibility-first: the companion says what is happening, and how it says it is part of the message.</summary>
[JsonConverter(typeof(ToneWireConverter))]
public enum Tone
{
    Calm,
    Encouraging,
    Neutral,
}

/// <summary>How fast to move through a sequence of steps. The learner sets this, not the model.</summary>
[JsonConverter(typeof(PaceWireConverter))]
public enum Pace
{
    Slow,
    Normal,
}

/// <summary>How a provider carries a spoken turn. Not a quality setting — a statement of what the provider can actually do, which is why it is a column in the provider table rather than a preference.</summary>
[JsonConverter(typeof(VoiceLaneWireConverter))]
public enum VoiceLane
{
    Realtime,
    Chain,
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

/// <summary>Look at what is on the learner's screen and answer a question about it. Call this whenever they ask about something they can see — a window, a folder, an error, a button — instead of guessing or saying you cannot see. One frame of the main display is sent to a vision model; nothing is captured at any other time.</summary>
public sealed record LookAtScreenAction(string Question) : ISaathiAction
{
    public const string Wire = "look_at_screen";
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
    ["say", "show_step", "open_url", "look_at_screen"];
}
