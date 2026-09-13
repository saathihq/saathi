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
  /** Comma-separated bearer tokens accepted by authenticated routes. */
  SAATHI_TOKENS?: string;
  /**
   * Runs the backend with no accounts at all — every request is allowed.
   *
   * This is the self-hosting mode, and it is opt-in for a reason. An unset token list must never
   * be read as "let everyone in", because that turns a half-finished deploy into an open one; but
   * someone running Saathi on their own machine should not have to invent an account system first.
   * So the permissive behaviour exists and has to be asked for by name.
   */
  SAATHI_ALLOW_ANONYMOUS?: string;
};

/** What the backend will accept, decided once so both the route and /health can report it. */
export type AuthPosture =
  | { mode: "tokens"; accepted: string[] }
  | { mode: "anonymous" }
  | { mode: "closed" };

export function authPosture(env: AppEnv): AuthPosture {
  const accepted = (env.SAATHI_TOKENS ?? "")
    .split(",")
    .map((t) => t.trim())
    .filter((t) => t.length > 0);

  if (accepted.length > 0) return { mode: "tokens", accepted };

  const anonymous = (env.SAATHI_ALLOW_ANONYMOUS ?? "").trim().toLowerCase();
  if (anonymous === "1" || anonymous === "true" || anonymous === "yes") return { mode: "anonymous" };

  return { mode: "closed" };
}

export function createApp(env: AppEnv = {}) {
  const app = new Hono();

  const posture = authPosture(env);

  app.get("/health", (c) =>
    c.json({
      ok: true,
      version: CONTRACT_VERSION,
      // Said out loud so an operator can see, without reading the config, whether the thing they
      // just deployed is open to the world.
      auth: posture.mode,
    }),
  );

  app.post("/session", (c) => {
    if (posture.mode === "closed") {
      return c.json(
        {
          error: "this backend has no accounts configured",
          hint: "set SAATHI_TOKENS, or SAATHI_ALLOW_ANONYMOUS=1 to run it open for self-hosting",
        },
        401,
      );
    }

    if (posture.mode === "tokens") {
      const authorization = c.req.header("authorization") ?? "";
      const presented = authorization.toLowerCase().startsWith("bearer ")
        ? authorization.slice("bearer ".length).trim()
        : "";

      if (presented.length === 0 || !posture.accepted.includes(presented)) {
        return c.json({ error: "not authorised" }, 401);
      }
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
