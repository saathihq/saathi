import { describe, expect, it } from "vitest";
import { ACTION_WIRE_NAMES, BACKEND_ROUTES, CONTRACT_VERSION } from "../src/contract.js";
import { createApp } from "../src/app.js";

describe("health", () => {
  it("is reachable without a token and reports the contract version", async () => {
    const response = await createApp().request("/health");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, version: CONTRACT_VERSION });
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
  it("refuses everything when no tokens are configured, rather than allowing everything", async () => {
    for (const authorization of ["Bearer anything", "Bearer ", ""]) {
      const response = await createApp({}).request("/session", {
        method: "POST",
        headers: authorization ? { authorization } : {},
      });
      expect(response.status, `authorization: ${JSON.stringify(authorization)}`).toBe(401);
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
