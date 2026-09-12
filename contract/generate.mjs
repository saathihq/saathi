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
const pascal = (s) => s.charAt(0).toUpperCase() + s.slice(1);
const wireOf = (action) => action.wireName ?? action.name;

/** Parameters sort required-first so generated initialisers have no un-defaultable holes. */
const orderedParameters = (action) =>
  [...action.parameters].sort((a, b) => Number(isOptional(a)) - Number(isOptional(b)));
const isOptional = (p) => Boolean(p.optional) || p.default !== undefined;

// ---------------------------------------------------------------------------- Swift

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

  out.push(`/// \`~/${schema.config.directoryName}/${schema.config.fileName}\`.`);
  out.push("public struct SaathiConfiguration: Codable, Sendable {");
  for (const f of schema.config.fields) {
    out.push(`    /// ${f.doc}`);
    out.push(`    public var ${f.name}: String?`);
  }
  out.push("");
  out.push(`    public init(${schema.config.fields.map((f) => `${f.name}: String? = nil`).join(", ")}) {`);
  for (const f of schema.config.fields) out.push(`        self.${f.name} = ${f.name}`);
  out.push("    }\n");
  out.push("    /// The hosted backend unless the config names another one.");
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
  out.push("using System.Text.Json.Serialization;\n");
  out.push("namespace Saathi.Contract;\n");

  out.push("/// <summary>Where the backend lives, and the contract this client was built against.</summary>");
  out.push("public static class SaathiBackend");
  out.push("{");
  out.push(`    public const string DefaultBaseUrl = "${schema.backend.defaultBaseUrl}";`);
  out.push(`    public const string ContractVersion = "${schema.version}";`);
  out.push("}\n");

  out.push(`/// <summary><c>~/${schema.config.directoryName}/${schema.config.fileName}</c>.</summary>`);
  out.push("public sealed class SaathiConfiguration");
  out.push("{");
  for (const f of schema.config.fields) {
    out.push(`    /// <summary>${f.doc}</summary>`);
    out.push(`    [JsonPropertyName("${f.name}")]`);
    out.push(`    public string? ${pascal(f.name)} { get; set; }\n`);
  }
  const baseUrlField = pascal(
    (schema.config.fields.find((f) => f.name === "backendUrl") ?? schema.config.fields[0]).name,
  );
  out.push("    /// <summary>The hosted backend unless the config names another one.</summary>");
  out.push("    public string ResolvedBaseUrl =>");
  out.push(`        string.IsNullOrWhiteSpace(${baseUrlField}) ? SaathiBackend.DefaultBaseUrl : ${baseUrlField}!.Trim();`);
  out.push("}\n");

  for (const e of schema.enums) {
    out.push(`/// <summary>${e.doc}</summary>`);
    out.push("[JsonConverter(typeof(JsonStringEnumConverter))]");
    out.push(`public enum ${e.name}`);
    out.push("{");
    for (const c of e.cases) {
      out.push(`    [JsonPropertyName("${c}")]`);
      out.push(`    ${pascal(c)},`);
    }
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
  for (const f of schema.config.fields) out.push(`  /** ${f.doc} */\n  ${f.name}?: string;`);
  out.push("};\n");

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
