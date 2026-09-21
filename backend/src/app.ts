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
import { createSkill, type SkillCreateEnv } from "./skillsCreate.js";
import { issueTrial } from "./trial.js";
import {
  LedgerUnavailableError,
  mintRealtimeGrant,
  RealtimeMintError,
  unlimitedLedger,
  type SessionLedger,
} from "./realtime.js";

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
  /**
   * The provider key for hosted realtime voice. This is the one real secret this process holds:
   * it is used to mint short-lived client secrets and is never serialised into any response.
   * Unset simply means this deployment does not offer hosted voice, which is a normal posture for
   * a self-hosted backend whose users bring their own keys.
   */
  SAATHI_REALTIME_KEY?: string;
  SAATHI_REALTIME_BASE_URL?: string;
  SAATHI_REALTIME_MODEL?: string;
  SAATHI_REALTIME_VOICE?: string;
  /**
   * What `/skills/create` drafts with. Separate names from the realtime ones so a deploy can draft
   * skills without offering hosted voice, or the other way round; the key falls back to the
   * realtime one because in practice it is the same vendor account.
   */
  SAATHI_SKILL_KEY?: string;
  SAATHI_SKILL_BASE_URL?: string;
  SAATHI_SKILL_MODEL?: string;
};

/** Injectable so the tests never open a socket or need a key. */
export type AppDependencies = {
  ledger?: SessionLedger;
  fetchImpl?: typeof fetch;
};

/** What the backend will accept, decided once so both the route and /health can report it. */
export type AuthPosture =
  | { mode: "tokens"; accepted: string[] }
  /** Accounts live in a database; the ledger decides. */
  | { mode: "accounts" }
  | { mode: "anonymous" }
  | { mode: "closed" };

/**
 * `hasAccountStore` is passed rather than read from the environment because it is a property of
 * what was actually wired in, not of what was configured. A deploy with database credentials set
 * but no store constructed must not claim to be checking accounts.
 */
export function authPosture(env: AppEnv, hasAccountStore = false): AuthPosture {
  const accepted = (env.SAATHI_TOKENS ?? "")
    .split(",")
    .map((t) => t.trim())
    .filter((t) => t.length > 0);

  // A static list wins when present: it needs no network, and a self-hoster who set it meant it.
  if (accepted.length > 0) return { mode: "tokens", accepted };

  // Accounts in a database are the hosted posture. Checked before ANONYMOUS on purpose — a deploy
  // that has an accounts database is never meant to be open.
  if (hasAccountStore) return { mode: "accounts" };

  const anonymous = (env.SAATHI_ALLOW_ANONYMOUS ?? "").trim().toLowerCase();
  if (anonymous === "1" || anonymous === "true" || anonymous === "yes") return { mode: "anonymous" };

  return { mode: "closed" };
}

export function createApp(env: AppEnv = {}, dependencies: AppDependencies = {}) {
  const app = new Hono();

  const ledger = dependencies.ledger ?? unlimitedLedger;
  const fetchImpl = dependencies.fetchImpl ?? fetch;
  const posture = authPosture(env, typeof ledger.authorize === "function");

  /** Pulls the bearer token out, or "" when there is not one. */
  const bearer = (authorization: string): string =>
    authorization.toLowerCase().startsWith("bearer ") ? authorization.slice("bearer ".length).trim() : "";

  /**
   * The one authorisation rule, written once.
   *
   * It was inline in `/session` when there was one authenticated route. Copying it to a second
   * route is how two routes end up disagreeing about what counts as authorised, and the one that
   * drifts is never the one anybody tests — so it moved here the moment there was a second caller.
   *
   * Returns a Response to send, or null when the caller may proceed.
   */
  const rejectIfUnauthorised = async (authorization: string): Promise<Response | null> => {
    if (posture.mode === "closed") {
      return Response.json(
        {
          error: "this backend has no accounts configured",
          hint: "set SAATHI_TOKENS, an accounts database, or SAATHI_ALLOW_ANONYMOUS=1 for self-hosting",
        },
        { status: 401 },
      );
    }

    const presented = bearer(authorization);

    if (posture.mode === "tokens") {
      // Compared against the configured list rather than a prefix or a pattern; an empty presented
      // token must never match an empty configured one, which `authPosture` already filters out.
      if (presented.length === 0 || !posture.accepted.includes(presented)) {
        return Response.json({ error: "not authorised" }, { status: 401 });
      }
    }

    if (posture.mode === "accounts") {
      if (presented.length === 0) return Response.json({ error: "not authorised" }, { status: 401 });
      try {
        const refusal = await ledger.authorize!(presented);
        if (refusal) return Response.json({ error: refusal }, { status: 401 });
      } catch (error) {
        // A database that cannot be reached must refuse, not allow. 503 rather than 401, because
        // the caller's credentials were never the problem and retrying is the right response.
        if (error instanceof LedgerUnavailableError) {
          return Response.json({ error: error.message }, { status: 503 });
        }
        return Response.json({ error: "could not check that account" }, { status: 503 });
      }
    }

    return null;
  };

  app.get("/health", (c) =>
    c.json({
      ok: true,
      version: CONTRACT_VERSION,
      // Said out loud so an operator can see, without reading the config, whether the thing they
      // just deployed is open to the world.
      auth: posture.mode,
      // Whether hosted voice is on, and what is limiting it. An in-memory ledger on a serverless
      // deployment is per-isolate and therefore not a real limit; it says so itself rather than
      // letting an operator assume a quota they do not have.
      voice: (env.SAATHI_REALTIME_KEY ?? "").trim().length > 0 ? "hosted" : "off",
      limits: ledger.description,
      // Whether a first-run client can be given a trial here. Only a ledger that can make accounts
      // can, so this is a property of what was wired in, like `auth`.
      trial: typeof ledger.issueTrial === "function" ? "on" : "off",
    }),
  );

  app.post("/session", async (c) => {
    const rejection = await rejectIfUnauthorised(c.req.header("authorization") ?? "");
    if (rejection) return rejection;

    return c.json({
      contractVersion: CONTRACT_VERSION,
      // What this client may be asked to do. The client validates each action again on its own
      // side — this list is the offer, not the enforcement.
      actions: ACTION_WIRE_NAMES,
    });
  });

  /**
   * Mints a short-lived client secret for a realtime voice session.
   *
   * No audio passes through here — see realtime.ts for why that was chosen over proxying, and what
   * it costs. The client takes the returned `url` and `value` and connects to the PROVIDER; this
   * backend is out of the conversation from that point on.
   */
  app.post("/realtime/session", async (c) => {
    const authorization = c.req.header("authorization") ?? "";
    const rejection = await rejectIfUnauthorised(authorization);
    if (rejection) return rejection;

    const key = (env.SAATHI_REALTIME_KEY ?? "").trim();
    if (key.length === 0) {
      // A deployment without a provider key is a normal, supported posture, not a broken one. Say
      // which it is so nobody debugs a misconfiguration that is actually a deliberate choice.
      return c.json(
        {
          error: "this backend does not offer hosted voice",
          hint: "it holds no provider key. Use your own key with provider \"openai\", or run a backend with SAATHI_REALTIME_KEY set.",
        },
        501,
      );
    }

    // The caller's own token, used only as a ledger key. It is never forwarded to the provider.
    const presented = bearer(authorization) || "anonymous";

    let refusal: string | null;
    try {
      refusal = await ledger.check(presented);
    } catch (error) {
      const message = error instanceof LedgerUnavailableError ? error.message : "could not check the allowance";
      return c.json({ error: message }, 503);
    }
    // 429 is the honest code: the caller is fine, they have simply used what they had today.
    if (refusal) return c.json({ error: refusal }, 429);

    try {
      const grant = await mintRealtimeGrant(
        {
          baseUrl: env.SAATHI_REALTIME_BASE_URL ?? "https://api.openai.com/v1",
          apiKey: key,
          model: env.SAATHI_REALTIME_MODEL ?? "gpt-realtime",
          voice: env.SAATHI_REALTIME_VOICE,
        },
        fetchImpl,
      );
      return c.json(grant);
    } catch (error) {
      if (error instanceof RealtimeMintError) return c.json({ error: error.message }, 502);
      return c.json({ error: "could not open a realtime session" }, 502);
    }
  });

  /**
   * Drafts one SKILL.md from a sentence, on this backend's key.
   *
   * Authorised like every other route, and no further: what it spends is one non-streaming model
   * call with both interpolated fields length-capped, which is the whole of the abuse surface.
   */
  app.post("/skills/create", async (c) => {
    const rejection = await rejectIfUnauthorised(c.req.header("authorization") ?? "");
    if (rejection) return rejection;

    return createSkill(c, env as SkillCreateEnv, fetchImpl);
  });

  /**
   * Hands a first-run client a trial token. The one unauthenticated route that gives anything
   * away — see trial.ts for what bounds it.
   */
  app.post("/trial", (c) => issueTrial(c, ledger));

  app.notFound((c) => c.json({ error: "no such route" }, 404));

  return app;
}
