/**
 * skillMarkdown.ts
 * @saathi/backend
 *
 * Hermes-style SKILL.md: `---` YAML frontmatter (flat keys, inline `[a, b]` lists) + a Markdown
 * body. Ported from OpenClicky unchanged, because the macOS client's `SkillFile.swift` is the other
 * half of this format — a divergence here is a skill this backend writes and the app then refuses
 * to read.
 */

export interface ParsedSkill {
  name: string;
  description: string;
  apps: string[];
  sites: string[];
  surfaces: string[];
  body: string;
}

/** Drop a trailing `# comment` from a scalar value (quoted strings are left alone). */
function stripComment(v: string): string {
  const t = v.trim();
  if (/^["']/.test(t)) return t;
  return t.replace(/\s+#.*$/, "").trim();
}

/** Inline list `[a, "b"]` — anything after the closing bracket (e.g. a `# comment`) is ignored. */
function parseList(v: string): string[] {
  const m = /^\[([^\]]*)\]/.exec(v.trim());
  const inner = m?.[1] ?? stripComment(v);
  return inner
    .split(",")
    .map((s) => s.trim().replace(/^["']|["']$/g, ""))
    .filter(Boolean);
}

export function parseSkillMarkdown(md: string): ParsedSkill | null {
  const m = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/.exec(md.replace(/^﻿/, ""));
  if (!m) return null;
  const fm: Record<string, string> = {};
  const [, front = "", rest = ""] = m;
  for (const line of front.split(/\r?\n/)) {
    const [, key, value] = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(line) ?? [];
    if (key !== undefined) fm[key] = stripComment(value ?? "").replace(/^(["'])(.*)\1$/, "$2");
  }
  if (!fm.name || !fm.description) return null;
  const surfaces = fm.surfaces ? parseList(fm.surfaces) : ["talk", "agent"];
  return {
    name: fm.name,
    description: fm.description,
    apps: fm.apps ? parseList(fm.apps) : [],
    sites: fm.sites ? parseList(fm.sites) : [],
    surfaces,
    body: rest.trim(),
  };
}

/** kebab-case id from a skill name ("Write Like Me" → "write-like-me"). */
export const slugify = (s: string) =>
  s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "") || "skill";
