#!/usr/bin/env node
//
// Generates the Swift, C# and TypeScript views of schema/saathi.json.
//
//   node generate.mjs           rewrite contract/generated/
//   node generate.mjs --check   exit 1 if the checked-in output is stale (this is what CI runs)
//
// Why generate rather than hand-write three copies: Swift and C# cannot share code, so the contract
// is the only thing binding a macOS client to a Windows one, and nothing about it is checked by a
// compiler. OpenClicky proved how that ends — two copies of one TypeScript file, in adjacent
// directories in the same repo, had already drifted. A comment saying "keep in sync" is not a
// mechanism. `--check` in CI is.
//
// Deliberately dependency-free: it runs on any Node 22 with no install step, which is what lets the
// Windows CI job verify the contract without a full npm workspace.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const schema = JSON.parse(readFileSync(join(here, "schema", "saathi.json"), "utf8"));
const checkOnly = process.argv.includes("--check");

const BANNER = (comment) =>
  `${comment} Generated from contract/schema/saathi.json by contract/generate.mjs. Do not edit.\n` +
  `${comment} Run \`npm run generate -w contract\` after changing the schema.\n` +
  `${comment} Contract version ${schema.version}.\n`;

const enumNames = new Set(schema.enums.map((e) => e.name));

// The C# side maps enum members to wire strings with JsonNamingPolicy.SnakeCaseLower, which only
// reproduces a case name that is already lower snake case. Fail loudly here rather than emit a
// client that cannot read the other client's files.
for (const e of schema.enums) {
  for (const c of e.cases) {
    if (!/^[a-z][a-z0-9]*(_[a-z0-9]+)*$/.test(c)) {
      throw new Error(`enum ${e.name} case "${c}" must be lower snake case — the C# converter cannot round-trip it`);
    }
  }
}
const providerRows = schema.providers.rows;
const providerDefault = schema.providers.default;
const pascal = (s) => s.charAt(0).toUpperCase() + s.slice(1);
const wireOf = (action) => action.wireName ?? action.name;

/** Parameters sort required-first so generated initialisers have no un-defaultable holes. */
const orderedParameters = (action) =>
  [...action.parameters].sort((a, b) => Number(isOptional(a)) - Number(isOptional(b)));
const isOptional = (p) => Boolean(p.optional) || p.default !== undefined;

// ---------------------------------------------------------------------------- tool schema

/**
 * The action list as JSON-Schema function tools — what a model is actually shown.
 *
 * Emitted as one JSON string constant rather than as native literals in each language, so all three
 * clients hand a model byte-identical bytes. That matters more than it looks: a tool list that
 * drifts between platforms means the same sentence produces different behaviour on Windows and on
 * macOS, and nothing would catch it — the types would still compile on both sides.
 *
 * Every enum parameter becomes a JSON-Schema `enum`. That is the whole reason the contract's enums
 * are closed: a speech pipeline mishears, and a misheard word that can only land inside a known set
 * produces a wrong VALUE, never a wrong COMMAND.
 */
function toolSchema() {
  return schema.actions.map((a) => {
    const properties = {};
    const required = [];
    for (const p of a.parameters) {
      const property = {};
      if (enumNames.has(p.type)) {
        property.type = "string";
        property.enum = schema.enums.find((e) => e.name === p.type).cases;
      } else {
        property.type = p.type === "int" ? "integer" : "string";
      }
      property.description = p.doc;
      if (p.default !== undefined) property.description += ` Defaults to "${p.default}".`;
      properties[p.name] = property;
      if (!isOptional(p)) required.push(p.name);
    }
    return {
      type: "function",
      name: wireOf(a),
      description: a.doc,
      parameters: { type: "object", properties, required },
    };
  });
}

/** Pretty-printed so a human can read a diff of it; every language embeds these exact bytes. */
const TOOL_SCHEMA_JSON = JSON.stringify(toolSchema(), null, 2);

/** Embeds TOOL_SCHEMA_JSON as a source literal, per language. */
function toolSchemaLiteral(lang) {
  if (lang === "swift") {
    // A Swift multi-line string literal with `#` delimiters needs no escaping of quotes or
    // backslashes, and JSON contains both.
    return '#"""\n' + TOOL_SCHEMA_JSON + '\n"""#';
  }
  if (lang === "csharp") {
    // C# raw string literal. JSON never contains three consecutive double quotes.
    return '"""\n' + TOOL_SCHEMA_JSON + '\n"""';
  }
  return JSON.stringify(TOOL_SCHEMA_JSON); // TypeScript: an ordinary escaped string.
}

// ---------------------------------------------------------------------------- Swift

/** Config fields are always optional; only their base type varies. */
function swiftConfigType(f) {
  return (f.type === "string" ? "String" : f.type) + "?";
}

function swift() {
  const type = (p) => {
    const base = p.type === "string" ? "String" : p.type === "int" ? "Int" : p.type;
    return p.optional ? `${base}?` : base;
  };
  const out = [];
  out.push(BANNER("//"));
  out.push("import Foundation\n");

  out.push("/// Where the backend lives, and how this client is configured to reach it.");
  out.push("public enum SaathiBackend {");
  out.push(`    public static let defaultBaseURL = "${schema.backend.defaultBaseUrl}"`);
  out.push(`    public static let contractVersion = "${schema.version}"`);
  out.push("}\n");

  // Provider table, emitted before the config that resolves against it.
  out.push("/// One row per provider mode: where it runs, what it needs, and whether using it means");
  out.push("/// anything the learner says leaves their machine.");
  out.push("public struct SaathiProvider: Sendable, Equatable {");
  out.push("    public let kind: ProviderKind");
  out.push("    public let defaultBaseURL: String");
  out.push("    public let defaultModel: String");
  out.push("    /// Needs the user's own provider key, held on their machine.");
  out.push("    public let requiresKey: Bool");
  out.push("    /// Needs a Saathi account token.");
  out.push("    public let requiresToken: Bool");
  out.push("    /// False only for `local`. Worth surfacing to the user rather than burying.");
  out.push("    public let sendsDataOffMachine: Bool");
  out.push("    /// The header the credential goes in, empty when none is needed.");
  out.push("    public let keyHeader: String");
  out.push("    /// What precedes the credential in that header (\"Bearer \", or empty).");
  out.push("    public let keyPrefix: String");
  out.push("    /// How this provider carries a spoken turn. A capability, not a preference — see the");
  out.push("    /// schema's providers comment for why only some providers have a realtime socket.");
  out.push("    public let voice: VoiceLane");
  out.push("    public let summary: String\n");
  out.push("    public static let all: [SaathiProvider] = [");
  for (const r of providerRows) {
    out.push(`        SaathiProvider(kind: .${r.kind}, defaultBaseURL: "${r.defaultBaseUrl}", defaultModel: "${r.defaultModel}", requiresKey: ${r.requiresKey}, requiresToken: ${r.requiresToken}, sendsDataOffMachine: ${r.sendsDataOffMachine}, keyHeader: "${r.keyHeader}", keyPrefix: "${r.keyPrefix}", voice: .${r.voice}, summary: ${JSON.stringify(r.doc)}),`);
  }
  out.push("    ]\n");
  out.push("    /// The one header this provider needs, ready to set — or nil when it needs none.");
  out.push("    /// Built here so no client hard-codes `Bearer` for one provider and `x-api-key` for another.");
  out.push("    public func authorizationHeader(credential: String) -> (name: String, value: String)? {");
  out.push("        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)");
  out.push("        guard !keyHeader.isEmpty, !trimmed.isEmpty else { return nil }");
  out.push("        return (keyHeader, keyPrefix + trimmed)");
  out.push("    }\n");
  out.push("    public static func of(_ kind: ProviderKind) -> SaathiProvider {");
  out.push("        // `all` covers every case of a closed enum, so this cannot be nil in practice;");
  out.push("        // trapping is better than inventing a fallback that would silently pick a mode.");
  out.push("        guard let row = all.first(where: { $0.kind == kind }) else {");
  out.push("            preconditionFailure(\"no provider row for \\(kind) — the contract is out of sync\")");
  out.push("        }");
  out.push("        return row");
  out.push("    }");
  out.push("}\n");

  out.push("/// The action list as JSON-Schema function tools \u2014 the exact bytes a model is shown.");
  out.push("/// Identical on macOS, Windows and the backend; see contract/generate.mjs for why that matters.");
  out.push("public enum SaathiTools {");
  out.push("    public static let json = " + toolSchemaLiteral("swift"));
  out.push("}\n");

  out.push(`/// \`~/${schema.config.directoryName}/${schema.config.fileName}\`.`);
  out.push("public struct SaathiConfiguration: Codable, Sendable {");
  for (const f of schema.config.fields) {
    out.push(`    /// ${f.doc}`);
    out.push(`    public var ${f.name}: ${swiftConfigType(f)}`);
  }
  out.push("");
  out.push(`    public init(${schema.config.fields.map((f) => `${f.name}: ${swiftConfigType(f)} = nil`).join(", ")}) {`);
  for (const f of schema.config.fields) out.push(`        self.${f.name} = ${f.name}`);
  out.push("    }\n");
  out.push(`    /// The mode in effect. Unset means \`.${providerDefault}\` — running against a model on this`);
  out.push("    /// machine, with no key and no account, is the default rather than a special case.");
  out.push(`    public var resolvedProvider: ProviderKind { provider ?? .${providerDefault} }\n`);
  out.push("    public var providerRow: SaathiProvider { SaathiProvider.of(resolvedProvider) }\n");
  out.push("    /// The provider's base URL, or the override if one is configured.");
  out.push("    public var resolvedProviderBaseURL: String {");
  out.push("        let trimmed = providerBaseUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? \"\"");
  out.push("        return trimmed.isEmpty ? providerRow.defaultBaseURL : trimmed");
  out.push("    }\n");
  out.push("    public var resolvedModel: String {");
  out.push("        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? \"\"");
  out.push("        return trimmed.isEmpty ? providerRow.defaultModel : trimmed");
  out.push("    }\n");
  out.push("    /// The hosted backend unless the config names another one. Only meaningful in hosted mode.");
  out.push("    public var resolvedBaseURL: String {");
  out.push("        let trimmed = backendUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? \"\"");
  out.push("        return trimmed.isEmpty ? SaathiBackend.defaultBaseURL : trimmed");
  out.push("    }");
  out.push("}\n");

  for (const e of schema.enums) {
    out.push(`/// ${e.doc}`);
    out.push(`public enum ${e.name}: String, Codable, CaseIterable, Sendable {`);
    for (const c of e.cases) out.push(`    case ${c}`);
    out.push("}\n");
  }

  for (const a of schema.actions) {
    const name = `${pascal(a.name)}Action`;
    out.push(`/// ${a.doc}`);
    out.push(`public struct ${name}: Codable, Sendable, Equatable {`);
    out.push(`    public static let wireName = "${wireOf(a)}"\n`);
    for (const p of a.parameters) {
      out.push(`    /// ${p.doc}`);
      out.push(`    public var ${p.name}: ${type(p)}`);
    }
    out.push("");
    const args = orderedParameters(a)
      .map((p) => {
        if (p.default !== undefined) return `${p.name}: ${p.type} = .${p.default}`;
        if (p.optional) return `${p.name}: ${type(p)} = nil`;
        return `${p.name}: ${type(p)}`;
      })
      .join(", ");
    out.push(`    public init(${args}) {`);
    for (const p of a.parameters) out.push(`        self.${p.name} = ${p.name}`);
    out.push("    }");
    out.push("}\n");
  }

  out.push("/// Every action a Saathi client can be asked to perform. Closed on purpose: a mishearing");
  out.push("/// can produce a wrong value inside one of these, never a command outside the set.");
  out.push("public enum SaathiAction: Sendable, Equatable {");
  for (const a of schema.actions) out.push(`    case ${a.name}(${pascal(a.name)}Action)`);
  out.push("");
  out.push("    public var wireName: String {");
  out.push("        switch self {");
  for (const a of schema.actions) out.push(`        case .${a.name}: return ${pascal(a.name)}Action.wireName`);
  out.push("        }");
  out.push("    }\n");
  out.push("    /// The wire names, in schema order — for building a tool list or a smoke test.");
  out.push(`    public static let allWireNames: [String] = [${schema.actions.map((a) => `"${wireOf(a)}"`).join(", ")}]`);
  out.push("}");
  return out.join("\n") + "\n";
}

// ---------------------------------------------------------------------------- C#

function csharp() {
  const type = (p) => {
    const base = p.type === "string" ? "string" : p.type === "int" ? "int" : p.type;
    return p.optional ? `${base}?` : base;
  };
  const out = [];
  out.push(BANNER("//"));
  out.push("#nullable enable");
  out.push("using System.Linq;");
  out.push("using System.Text.Json;");
  out.push("using System.Text.Json.Serialization;\n");
  out.push("namespace Saathi.Contract;\n");

  out.push("/// <summary>Where the backend lives, and the contract this client was built against.</summary>");
  out.push("public static class SaathiBackend");
  out.push("{");
  out.push(`    public const string DefaultBaseUrl = "${schema.backend.defaultBaseUrl}";`);
  out.push(`    public const string ContractVersion = "${schema.version}";`);
  out.push("}\n");

  out.push("/// <summary>One row per provider mode: where it runs, what it needs, and whether using it");
  out.push("/// means anything the learner says leaves their machine.</summary>");
  out.push("public sealed record SaathiProvider(");
  out.push("    ProviderKind Kind,");
  out.push("    string DefaultBaseUrl,");
  out.push("    string DefaultModel,");
  out.push("    bool RequiresKey,");
  out.push("    bool RequiresToken,");
  out.push("    bool SendsDataOffMachine,");
  out.push("    string KeyHeader,");
  out.push("    string KeyPrefix,");
  out.push("    VoiceLane Voice,");
  out.push("    string Summary)");
  out.push("{");
  out.push("    public static readonly IReadOnlyList<SaathiProvider> All =");
  out.push("    [");
  for (const r of providerRows) {
    out.push(`        new(global::Saathi.Contract.ProviderKind.${pascal(r.kind)}, "${r.defaultBaseUrl}", "${r.defaultModel}", ${r.requiresKey}, ${r.requiresToken}, ${r.sendsDataOffMachine}, "${r.keyHeader}", "${r.keyPrefix}", global::Saathi.Contract.VoiceLane.${pascal(r.voice)}, ${JSON.stringify(r.doc)}),`);
  }
  out.push("    ];\n");
  out.push("    /// <summary>The one header this provider needs, ready to set — or null when it needs none.");
  out.push("    /// Built here so no client hard-codes Bearer for one provider and x-api-key for another.</summary>");
  out.push("    public (string Name, string Value)? AuthorizationHeader(string credential)");
  out.push("    {");
  out.push("        var trimmed = credential?.Trim() ?? string.Empty;");
  out.push("        if (KeyHeader.Length == 0 || trimmed.Length == 0) return null;");
  out.push("        return (KeyHeader, KeyPrefix + trimmed);");
  out.push("    }\n");
  out.push("    /// <summary>`All` covers every case of a closed enum, so this cannot miss in practice;");
  out.push("    /// throwing is better than inventing a fallback that would silently pick a mode.</summary>");
  out.push("    public static SaathiProvider Of(ProviderKind kind) =>");
  out.push("        All.FirstOrDefault(p => p.Kind == kind)");
  out.push("        ?? throw new InvalidOperationException($\"no provider row for {kind} — the contract is out of sync\");");
  out.push("}\n");

  out.push("/// <summary>The action list as JSON-Schema function tools \u2014 the exact bytes a model is shown.");
  out.push("/// Identical on macOS, Windows and the backend; see contract/generate.mjs for why that matters.</summary>");
  out.push("public static class SaathiTools");
  out.push("{");
  out.push("    public const string Json = " + toolSchemaLiteral("csharp") + ";");
  out.push("}\n");

  out.push(`/// <summary><c>~/${schema.config.directoryName}/${schema.config.fileName}</c>.</summary>`);
  out.push("public sealed class SaathiConfiguration");
  out.push("{");
  for (const f of schema.config.fields) {
    out.push(`    /// <summary>${f.doc}</summary>`);
    out.push(`    [JsonPropertyName("${f.name}")]`);
    out.push(`    public ${f.type === "string" ? "string" : f.type}? ${pascal(f.name)} { get; set; }\n`);
  }
  const baseUrlField = pascal(
    (schema.config.fields.find((f) => f.name === "backendUrl") ?? schema.config.fields[0]).name,
  );
  out.push(`    /// <summary>The mode in effect. Unset means <c>${providerDefault}</c> — running against a model`);
  out.push("    /// on this machine, with no key and no account, is the default rather than a special case.</summary>");
  out.push(`    public ProviderKind ResolvedProvider => Provider ?? global::Saathi.Contract.ProviderKind.${pascal(providerDefault)};\n`);
  out.push("    public SaathiProvider ProviderRow => SaathiProvider.Of(ResolvedProvider);\n");
  out.push("    /// <summary>The provider's base URL, or the override if one is configured.</summary>");
  out.push("    public string ResolvedProviderBaseUrl =>");
  out.push("        string.IsNullOrWhiteSpace(ProviderBaseUrl) ? ProviderRow.DefaultBaseUrl : ProviderBaseUrl!.Trim();\n");
  out.push("    public string ResolvedModel =>");
  out.push("        string.IsNullOrWhiteSpace(Model) ? ProviderRow.DefaultModel : Model!.Trim();\n");
  out.push("    /// <summary>The hosted backend unless the config names another one. Only meaningful in hosted mode.</summary>");
  out.push("    public string ResolvedBaseUrl =>");
  out.push(`        string.IsNullOrWhiteSpace(${baseUrlField}) ? SaathiBackend.DefaultBaseUrl : ${baseUrlField}!.Trim();`);
  out.push("}\n");

  // Two things make this converter hand-written rather than JsonStringEnumConverter.
  //
  // First, `[JsonPropertyName]` is silently ignored on enum members by System.Text.Json — it
  // compiles, reads as intentional, and does nothing, which left the C# client able to read only
  // "Sarvam" while Swift wrote "sarvam".
  //
  // Second, JsonStringEnumConverter with a naming policy still ACCEPTS the raw member name as a
  // fallback. That leniency is worse than it sounds here: a config written by hand as "Sarvam"
  // would work on Windows and fail on macOS, which is exactly the divergence the whole contract
  // exists to prevent. These converters accept the wire spelling and nothing else.
  for (const e of schema.enums) {
    out.push(`/// <summary>${e.name} on the wire. Accepts the contract's spelling only — the C# member`);
    out.push("/// name is not an alias, because the Swift client would not accept it either.</summary>");
    out.push(`public sealed class ${e.name}WireConverter : JsonConverter<${e.name}>`);
    out.push("{");
    out.push(`    public override ${e.name} Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>`);
    out.push("        reader.GetString() switch");
    out.push("        {");
    for (const c of e.cases) out.push(`            "${c}" => ${e.name}.${pascal(c)},`);
    out.push(`            var other => throw new JsonException($"{other} is not a valid ${e.name} — expected one of: ${e.cases.join(", ")}"),`);
    out.push("        };\n");
    out.push(`    public override void Write(Utf8JsonWriter writer, ${e.name} value, JsonSerializerOptions options) =>`);
    out.push("        writer.WriteStringValue(value switch");
    out.push("        {");
    for (const c of e.cases) out.push(`            ${e.name}.${pascal(c)} => "${c}",`);
    out.push(`            _ => throw new JsonException($"no wire spelling for {value} — the contract is out of sync"),`);
    out.push("        });");
    out.push("}\n");
  }

  for (const e of schema.enums) {
    out.push(`/// <summary>${e.doc}</summary>`);
    out.push(`[JsonConverter(typeof(${e.name}WireConverter))]`);
    out.push(`public enum ${e.name}`);
    out.push("{");
    for (const c of e.cases) out.push(`    ${pascal(c)},`);
    out.push("}\n");
  }

  for (const a of schema.actions) {
    const name = `${pascal(a.name)}Action`;
    const args = orderedParameters(a)
      .map((p) => {
        const t = type(p);
        // Fully qualified: a parameter named `Pace` of type `Pace` would otherwise make the
        // default expression `Pace.Normal` resolve to the parameter, not the enum.
        if (p.default !== undefined) {
          return `${p.type} ${pascal(p.name)} = global::Saathi.Contract.${p.type}.${pascal(p.default)}`;
        }
        if (p.optional) return `${t} ${pascal(p.name)} = null`;
        return `${t} ${pascal(p.name)}`;
      })
      .join(", ");
    out.push(`/// <summary>${a.doc}</summary>`);
    out.push(`public sealed record ${name}(${args}) : ISaathiAction`);
    out.push("{");
    out.push(`    public const string Wire = "${wireOf(a)}";`);
    out.push("    public string WireName => Wire;");
    out.push("}\n");
  }

  out.push("/// <summary>Every action a Saathi client can be asked to perform. Closed on purpose: a");
  out.push("/// mishearing can produce a wrong value inside one of these, never a command outside the set.</summary>");
  out.push("public interface ISaathiAction");
  out.push("{");
  out.push("    string WireName { get; }");
  out.push("}\n");

  out.push("public static class SaathiActions");
  out.push("{");
  out.push("    /// <summary>The wire names, in schema order — for building a tool list or a smoke test.</summary>");
  out.push("    public static readonly string[] AllWireNames =");
  out.push(`    [${schema.actions.map((a) => `"${wireOf(a)}"`).join(", ")}];`);
  out.push("}");
  return out.join("\n") + "\n";
}

// ---------------------------------------------------------------------------- TypeScript

function typescript() {
  const type = (p) => {
    const base = p.type === "string" ? "string" : p.type === "int" ? "number" : p.type;
    return p.optional ? `${base} | undefined` : base;
  };
  const out = [];
  out.push(BANNER("//"));
  out.push(`export const CONTRACT_VERSION = "${schema.version}";`);
  out.push(`export const DEFAULT_BASE_URL = "${schema.backend.defaultBaseUrl}";\n`);

  out.push(`/** \`~/${schema.config.directoryName}/${schema.config.fileName}\`. */`);
  out.push("export type SaathiConfiguration = {");
  for (const f of schema.config.fields) {
    out.push(`  /** ${f.doc} */\n  ${f.name}?: ${f.type === "string" ? "string" : f.type};`);
  }
  out.push("};\n");

  out.push("/** One row per provider mode: where it runs, what it needs, and whether using it means");
  out.push(" *  anything the learner says leaves their machine. */");
  out.push("export type SaathiProvider = {");
  out.push("  kind: ProviderKind;");
  out.push("  defaultBaseUrl: string;");
  out.push("  defaultModel: string;");
  out.push("  requiresKey: boolean;");
  out.push("  requiresToken: boolean;");
  out.push("  sendsDataOffMachine: boolean;");
  out.push("  keyHeader: string;");
  out.push("  keyPrefix: string;");
  out.push("  voice: VoiceLane;");
  out.push("  summary: string;");
  out.push("};\n");
  out.push(`export const DEFAULT_PROVIDER: ProviderKind = "${providerDefault}";`);
  out.push("export const PROVIDERS: readonly SaathiProvider[] = [");
  for (const r of providerRows) {
    out.push(`  { kind: "${r.kind}", defaultBaseUrl: "${r.defaultBaseUrl}", defaultModel: "${r.defaultModel}", requiresKey: ${r.requiresKey}, requiresToken: ${r.requiresToken}, sendsDataOffMachine: ${r.sendsDataOffMachine}, keyHeader: "${r.keyHeader}", keyPrefix: "${r.keyPrefix}", voice: "${r.voice}", summary: ${JSON.stringify(r.doc)} },`);
  }
  out.push("] as const;\n");

  for (const e of schema.enums) {
    out.push(`/** ${e.doc} */`);
    out.push(`export type ${e.name} = ${e.cases.map((c) => `"${c}"`).join(" | ")};`);
    out.push(`export const ${e.name.toUpperCase()}_CASES: readonly ${e.name}[] = [${e.cases.map((c) => `"${c}"`).join(", ")}] as const;\n`);
  }

  for (const a of schema.actions) {
    out.push(`/** ${a.doc} */`);
    out.push(`export type ${pascal(a.name)}Action = {`);
    out.push(`  action: "${wireOf(a)}";`);
    for (const p of a.parameters) {
      out.push(`  /** ${p.doc} */`);
      out.push(`  ${p.name}${isOptional(p) ? "?" : ""}: ${type(p)};`);
    }
    out.push("};\n");
  }

  out.push("/** Every action a Saathi client can be asked to perform. Closed on purpose. */");
  out.push(`export type SaathiAction =\n${schema.actions.map((a) => `  | ${pascal(a.name)}Action`).join("\n")};\n`);
  out.push("/** The wire names, in schema order — for building a tool list or a smoke test. */");
  out.push(`export const ACTION_WIRE_NAMES = [${schema.actions.map((a) => `"${wireOf(a)}"`).join(", ")}] as const;\n`);
  out.push("/** The action list as JSON-Schema function tools — the exact bytes a model is shown.");
  out.push(" *  Identical on macOS, Windows and the backend; see contract/generate.mjs for why that matters. */");
  out.push("export const SAATHI_TOOLS_JSON = " + toolSchemaLiteral("typescript") + ";\n");

  out.push("export const BACKEND_ROUTES = [");
  for (const r of schema.backend.routes) {
    out.push(`  { method: "${r.method}", path: "${r.path}", auth: ${r.auth} },`);
  }
  out.push("] as const;");
  return out.join("\n") + "\n";
}

// ---------------------------------------------------------------------------- drive

// Written straight into each platform's source tree rather than into one `generated/` directory
// that the platforms symlink. Symlinks in a git checkout need developer mode or elevation on
// Windows, and Windows is a first-class target here — a contract that only resolves on macOS would
// defeat the point of having one.
const outputs = [
  ["../macos/Saathi/Sources/SaathiContract/SaathiContract.swift", swift()],
  ["../windows/src/Saathi.Contract/SaathiContract.cs", csharp()],
  ["../backend/src/contract.ts", typescript()],
];

/** Paths are written relative to the generator; report them relative to the repo root instead. */
const fromRepoRoot = (relativePath) => relative(join(here, ".."), join(here, relativePath));

let stale = [];
for (const [relativePath, content] of outputs) {
  const absolute = join(here, relativePath);
  if (checkOnly) {
    let existing = null;
    try {
      existing = readFileSync(absolute, "utf8");
    } catch {
      existing = null;
    }
    if (existing !== content) stale.push(fromRepoRoot(relativePath));
  } else {
    mkdirSync(dirname(absolute), { recursive: true });
    writeFileSync(absolute, content);
    console.log(`wrote ${fromRepoRoot(relativePath)}`);
  }
}

if (checkOnly) {
  if (stale.length) {
    console.error("Generated contract files are stale:");
    for (const p of stale) console.error(`  ${p}`);
    console.error("\nRun `npm run generate -w contract` and commit the result.");
    process.exit(1);
  }
  console.log(`contract ${schema.version}: generated files are up to date`);
}
