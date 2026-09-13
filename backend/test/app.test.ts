import { describe, expect, it } from "vitest";
import { ACTION_WIRE_NAMES, BACKEND_ROUTES, CONTRACT_VERSION } from "../src/contract.js";
import { createApp } from "../src/app.js";

describe("health", () => {
  it("is reachable without a token and reports the contract version", async () => {
    const response = await createApp().request("/health");
    expect(response.status).toBe(200);
    // Exact rather than partial on purpose: /health is what an operator reads to see what they
    // just deployed, so a field appearing or vanishing should fail here and be looked at.
    expect(await response.json()).toEqual({
      ok: true,
      version: CONTRACT_VERSION,
      auth: "closed",
      voice: "off",
      limits: "none — every authorised caller may start a session",
    });
  });
});

describe("session", () => {
  it("refuses a request with no token", async () => {
    const response = await createApp({ SAATHI_TOKENS: "good" }).request("/session", { method: "POST" });
    expect(response.status).toBe(401);
  });

  it("refuses a token that is not on the list", async () => {
    const response = await createApp({ SAATHI_TOKENS: "good" }).request("/session", {
      method: "POST",
      headers: { authorization: "Bearer bad" },
    });
    expect(response.status).toBe(401);
  });

  // A backend with no accounts configured is a backend nobody has an account on. Reading an unset
  // token list as "allow everyone" is how an unconfigured deploy quietly becomes an open one.
  it("refuses everything when nothing is configured, rather than allowing everything", async () => {
    for (const authorization of ["Bearer anything", "Bearer ", ""]) {
      const response = await createApp({}).request("/session", {
        method: "POST",
        headers: authorization ? { authorization } : {},
      });
      expect(response.status, `authorization: ${JSON.stringify(authorization)}`).toBe(401);
    }
  });

  it("says why it refused, so an operator is not left guessing", async () => {
    const response = await createApp({}).request("/session", { method: "POST" });
    const body = (await response.json()) as { error: string; hint: string };
    expect(body.error).toContain("no accounts configured");
    expect(body.hint).toContain("SAATHI_ALLOW_ANONYMOUS");
  });
});

// Running Saathi against your own model, on your own machine, is the primary objective — so the
// backend has to be usable without inventing an account system first. The permissive mode exists
// and must be asked for by name; that is what keeps it from being the accident above.
describe("self-hosting (SAATHI_ALLOW_ANONYMOUS)", () => {
  it("serves a session with no token at all when anonymous access is asked for", async () => {
    const response = await createApp({ SAATHI_ALLOW_ANONYMOUS: "1" }).request("/session", {
      method: "POST",
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      contractVersion: CONTRACT_VERSION,
      actions: [...ACTION_WIRE_NAMES],
    });
  });

  it("accepts the spellings a person would actually write", async () => {
    for (const value of ["1", "true", "TRUE", "yes", " yes "]) {
      const response = await createApp({ SAATHI_ALLOW_ANONYMOUS: value }).request("/session", {
        method: "POST",
      });
      expect(response.status, `SAATHI_ALLOW_ANONYMOUS=${JSON.stringify(value)}`).toBe(200);
    }
  });

  it("is not switched on by a value that does not mean yes", async () => {
    for (const value of ["0", "false", "no", "", "   ", "maybe"]) {
      const response = await createApp({ SAATHI_ALLOW_ANONYMOUS: value }).request("/session", {
        method: "POST",
      });
      expect(response.status, `SAATHI_ALLOW_ANONYMOUS=${JSON.stringify(value)}`).toBe(401);
    }
  });

  // Configured tokens win: someone who set both did not mean "and also let everyone in".
  it("still enforces tokens when both are configured", async () => {
    const app = createApp({ SAATHI_TOKENS: "good", SAATHI_ALLOW_ANONYMOUS: "1" });
    expect((await app.request("/session", { method: "POST" })).status).toBe(401);
    const ok = await app.request("/session", {
      method: "POST",
      headers: { authorization: "Bearer good" },
    });
    expect(ok.status).toBe(200);
  });

  it("reports its posture on /health so an operator can see it without reading the config", async () => {
    const cases: [Record<string, string>, string][] = [
      [{}, "closed"],
      [{ SAATHI_ALLOW_ANONYMOUS: "1" }, "anonymous"],
      [{ SAATHI_TOKENS: "good" }, "tokens"],
    ];
    for (const [env, expected] of cases) {
      const response = await createApp(env).request("/health");
      const body = (await response.json()) as { auth: string };
      expect(body.auth, JSON.stringify(env)).toBe(expected);
    }
  });

  it("offers exactly the actions the contract declares", async () => {
    const response = await createApp({ SAATHI_TOKENS: "good" }).request("/session", {
      method: "POST",
      headers: { authorization: "Bearer good" },
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      contractVersion: CONTRACT_VERSION,
      actions: [...ACTION_WIRE_NAMES],
    });
  });
});

// The clients are generated from the schema; this file is hand-written, so it is the one that can
// drift from it. This test is the thing that notices.
describe("routes match the contract", () => {
  it("serves every route the schema declares", async () => {
    const app = createApp({ SAATHI_TOKENS: "good" });
    for (const route of BACKEND_ROUTES) {
      const response = await app.request(route.path, {
        method: route.method,
        headers: route.auth ? { authorization: "Bearer good" } : {},
      });
      expect(response.status, `${route.method} ${route.path}`).not.toBe(404);
    }
  });
});
