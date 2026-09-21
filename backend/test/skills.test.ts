import { describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import { parseSkillMarkdown, slugify } from "../src/skillMarkdown.js";

const VALID = `---
name: Write Like Me
description: Answer in the user's own voice.
surfaces: [talk]
---

## Use When
The user asks for something written.
`;

/** A backend that can draft, with a fetch that returns whatever the model is pretending to say. */
const draftingApp = (content: string, status = 200) =>
  createApp(
    { SAATHI_TOKENS: "good", SAATHI_SKILL_KEY: "sk-test", SAATHI_SKILL_MODEL: "gpt-4o-mini" },
    {
      fetchImpl: async () =>
        new Response(JSON.stringify({ choices: [{ message: { content } }] }), {
          status,
          headers: { "content-type": "application/json" },
        }),
    },
  );

const post = (app: ReturnType<typeof createApp>, body: unknown, token = "good") =>
  app.request("/skills/create", {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });

describe("skill markdown", () => {
  it("reads the frontmatter the macOS client writes and reads", () => {
    const parsed = parseSkillMarkdown(VALID);
    expect(parsed?.name).toBe("Write Like Me");
    expect(parsed?.surfaces).toEqual(["talk"]);
    expect(parsed?.body.startsWith("## Use When")).toBe(true);
  });

  it("refuses a file with no frontmatter, rather than inventing a name", () => {
    expect(parseSkillMarkdown("# Just a heading")).toBeNull();
    expect(parseSkillMarkdown("---\nname: No Description\n---\nbody")).toBeNull();
  });

  // The Swift side slugifies the same way; a skill whose id differs between the two is a skill
  // that lands in one folder and is looked for in another.
  it("slugifies the way SkillLibraryStore does", () => {
    expect(slugify("Write Like Me")).toBe("write-like-me");
    expect(slugify("  Émile's 2nd skill!  ")).toBe("mile-s-2nd-skill");
    expect(slugify("!!!")).toBe("skill");
  });
});

describe("POST /skills/create", () => {
  it("drafts a skill and hands back the markdown", async () => {
    const response = await post(draftingApp(VALID), { request: "reply in my voice" });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      id: "write-like-me",
      name: "Write Like Me",
      description: "Answer in the user's own voice.",
      markdown: VALID,
    });
  });

  it("strips the code fence a model puts round the file even when told not to", async () => {
    const response = await post(draftingApp("```markdown\n" + VALID + "```"), { request: "x" });
    expect(response.status).toBe(200);
    expect(((await response.json()) as { markdown: string }).markdown).toBe(VALID);
  });

  it("is authorised like every other route", async () => {
    const app = draftingApp(VALID);
    expect((await app.request("/skills/create", { method: "POST" })).status).toBe(401);
    expect((await post(app, { request: "x" }, "bad")).status).toBe(401);
  });

  it("refuses a request that is missing, empty or oversized", async () => {
    const app = draftingApp(VALID);
    expect((await post(app, {})).status).toBe(400);
    expect((await post(app, { request: "   " })).status).toBe(400);
    expect((await post(app, { request: "x".repeat(2001) })).status).toBe(400);
  });

  // Both fields go into a prompt paid for by this backend's key, so both are bounded.
  it("refuses capabilities that are too many, too long, or not strings", async () => {
    const app = draftingApp(VALID);
    expect((await post(app, { request: "ok", capabilities: Array(21).fill("gmail") })).status).toBe(400);
    expect((await post(app, { request: "ok", capabilities: ["y".repeat(65)] })).status).toBe(400);
    expect((await post(app, { request: "ok", capabilities: [42] })).status).toBe(400);
  });

  it("says it does not draft skills when it holds no key, rather than failing obscurely", async () => {
    const app = createApp({ SAATHI_TOKENS: "good" });
    const response = await post(app, { request: "x" });
    expect(response.status).toBe(503);
    expect(((await response.json()) as { error: string }).error).toBe("this backend does not draft skills");
  });

  it("refuses what the model returned when it is not a SKILL.md", async () => {
    const response = await post(draftingApp("Sure! Here is a skill for you."), { request: "x" });
    expect(response.status).toBe(502);
  });

  it("reports an upstream failure as 502 rather than passing its status through", async () => {
    const app = createApp(
      { SAATHI_TOKENS: "good", SAATHI_SKILL_KEY: "sk-test", SAATHI_SKILL_MODEL: "m" },
      { fetchImpl: async () => new Response("nope", { status: 429 }) },
    );
    expect((await post(app, { request: "x" })).status).toBe(502);
  });
});
