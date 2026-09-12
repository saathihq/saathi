//
//  app.ts
//  @saathi/backend
//
//  The key-holding side. Clients hold a token for this backend and nothing else — no provider key
//  ever reaches a client or a subprocess. That boundary is the one thing from OpenClicky that came
//  through an external review unscathed, and it is cheaper to keep than to retrofit.
//
//  Routes are declared in contract/schema/saathi.json; `routesMatchContract` in the tests is what
//  stops this file and that schema drifting apart.
//

import { Hono } from "hono";
import { ACTION_WIRE_NAMES, CONTRACT_VERSION } from "./contract.js";

export type AppEnv = {
  /** Bearer tokens accepted by authenticated routes. Empty means "no accounts yet", not "allow all". */
  SAATHI_TOKENS?: string;
};

export function createApp(env: AppEnv = {}) {
  const app = new Hono();

  app.get("/health", (c) => c.json({ ok: true, version: CONTRACT_VERSION }));

  app.post("/session", async (c) => {
    const authorization = c.req.header("authorization") ?? "";
    const presented = authorization.toLowerCase().startsWith("bearer ")
      ? authorization.slice("bearer ".length).trim()
      : "";

    // An unset token list denies rather than allows. A backend with no accounts configured is a
    // backend nobody has an account on — reading it as "let everyone in" is how an unconfigured
    // deploy becomes an open one.
    const accepted = (env.SAATHI_TOKENS ?? "")
      .split(",")
      .map((t) => t.trim())
      .filter((t) => t.length > 0);

    if (presented.length === 0 || !accepted.includes(presented)) {
      return c.json({ error: "not authorised" }, 401);
    }

    return c.json({
      contractVersion: CONTRACT_VERSION,
      // What this client may be asked to do. The client validates each action again on its own
      // side — this list is the offer, not the enforcement.
      actions: ACTION_WIRE_NAMES,
    });
  });

  app.notFound((c) => c.json({ error: "no such route" }, 404));

  return app;
}
