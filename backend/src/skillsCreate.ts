/**
 * skillsCreate.ts
 * @saathi/backend
 *
 * "Create a skill": someone types what a skill should do into the island's Home tab, and the model
 * drafts one SKILL.md. The client saves it into `~/.saathi/skills/library` and activates it.
 *
 * This is a backend route rather than a call the app makes for one reason: it has to work in
 * `hosted` mode, where the client holds no provider key at all. The key stays here, as it does for
 * every other provider call — the boundary this whole backend exists to keep.
 *
 * Ported from OpenClicky's `skillsCreate.ts`, minus its billing and skills-manifest dependencies.
 */

import type { Context } from "hono";
import { parseSkillMarkdown, slugify } from "./skillMarkdown.js";

const SYSTEM = `You write skills for Saathi, a Mac voice companion that helps people learn and play. A skill is ONE Markdown file in this exact format:
---
name: <Short Title Case name>
description: <one sentence: what it does and when to use it>
surfaces: [talk, agent]
---
<body: ≤ 600 words. Headings: Use When, Steps/Rules, Voice or Style (if relevant), Do Not.>

surfaces: "talk" applies when the user is talking to Saathi or asking about something; "agent" applies when Saathi does work. Use [talk] for styles and knowledge, [agent] for operational workflows, [talk, agent] when unsure. Do not add comments after the value.
Only rely on capabilities from this list: {{CAPS}}. Never invent tools or integrations. Output the file only, no commentary.`;

// Both fields are interpolated into a model call billed to the backend's key: keep them bounded.
const MAX_REQUEST_CHARS = 2000;
const MAX_CAPABILITIES = 20;
const MAX_CAPABILITY_CHARS = 64;

export type SkillCreateEnv = {
  /** The key this route drafts with. Falls back to the realtime key: same vendor, same account. */
  SAATHI_SKILL_KEY?: string;
  SAATHI_REALTIME_KEY?: string;
  SAATHI_SKILL_BASE_URL?: string;
  SAATHI_REALTIME_BASE_URL?: string;
  SAATHI_SKILL_MODEL?: string;
};

export async function createSkill(
  c: Context,
  env: SkillCreateEnv,
  fetchImpl: typeof fetch = fetch,
): Promise<Response> {
  const body = (await c.req.json().catch(() => ({}))) as { request?: unknown; capabilities?: unknown };

  if (typeof body.request !== "string" || !body.request.trim()) {
    return c.json({ error: "request (string) is required" }, 400);
  }
  if (body.request.length > MAX_REQUEST_CHARS) {
    return c.json({ error: `request is longer than ${MAX_REQUEST_CHARS} characters` }, 400);
  }
  if (body.capabilities !== undefined) {
    const ok =
      Array.isArray(body.capabilities) &&
      body.capabilities.length <= MAX_CAPABILITIES &&
      body.capabilities.every((x) => typeof x === "string" && x.length <= MAX_CAPABILITY_CHARS);
    if (!ok) {
      return c.json(
        { error: `capabilities must be at most ${MAX_CAPABILITIES} strings of ${MAX_CAPABILITY_CHARS} characters` },
        400,
      );
    }
  }

  // `||`, not `??`: an env file that declares `SAATHI_SKILL_KEY=` hands over "", which is "not set"
  // and must fall back the same way an absent variable does.
  const key = (env.SAATHI_SKILL_KEY?.trim() || env.SAATHI_REALTIME_KEY?.trim() || "");
  const model = (env.SAATHI_SKILL_MODEL ?? "").trim();
  if (!key || !model) {
    // A backend that cannot draft skills is a normal posture, not a broken one — the same shape of
    // answer /realtime/session gives when it holds no key. It says which, so nobody debugs a
    // deliberate choice.
    return c.json(
      { error: "this backend does not draft skills", hint: "set SAATHI_SKILL_KEY (or SAATHI_REALTIME_KEY) and SAATHI_SKILL_MODEL" },
      503,
    );
  }

  const caps = Array.isArray(body.capabilities)
    ? body.capabilities.filter((x): x is string => typeof x === "string")
    : [];
  const capList = caps.join(", ") || "none";
  const baseUrl = (
    env.SAATHI_SKILL_BASE_URL?.trim() || env.SAATHI_REALTIME_BASE_URL?.trim() || "https://api.openai.com/v1"
  ).replace(/\/$/, "");

  let upstream: Response;
  try {
    upstream = await fetchImpl(`${baseUrl}/chat/completions`, {
      method: "POST",
      headers: { authorization: `Bearer ${key}`, "content-type": "application/json" },
      body: JSON.stringify({
        model,
        stream: false,
        messages: [
          { role: "system", content: SYSTEM.replace("{{CAPS}}", () => capList) },
          { role: "user", content: `Skill request: ${body.request.trim()}` },
        ],
      }),
    });
  } catch {
    return c.json({ error: "could not reach the model" }, 502);
  }

  if (!upstream.ok) return c.json({ error: `upstream ${upstream.status}` }, 502);

  const parsedResponse = (await upstream.json().catch(() => ({}))) as {
    choices?: { message?: { content?: string } }[];
  };
  const raw = (parsedResponse.choices?.[0]?.message?.content ?? "").trim();
  // Models fence the file even when told not to; the fence is stripped rather than rejected.
  const markdown = raw.replace(/^```[a-z]*\n?/i, "").replace(/\n?```\s*$/, "").trim() + "\n";
  const parsed = parseSkillMarkdown(markdown);
  if (!parsed) return c.json({ error: "the model did not return a valid SKILL.md" }, 502);

  return c.json({ id: slugify(parsed.name), name: parsed.name, description: parsed.description, markdown });
}
