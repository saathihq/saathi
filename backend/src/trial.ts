//
//  trial.ts
//  @saathi/backend
//
//  A first-run Mac asks for a trial and is handed a token, with no account and no sign-in.
//
//  This is the one route that gives something away to a caller who has proved nothing, so what it
//  can give is small and the limits are not here: three sessions a day for seven days, one account
//  per device, five asks per network per day — all of it enforced in one Postgres function (see
//  migrations/0002_trials.sql), because a counter in this process is one quota per warm isolate.
//
//  What this file does is refuse malformed requests before they reach the database, mint the
//  token, and make sure neither the token nor the caller's address travels any further than it
//  has to: the ledger is handed hashes.
//

import type { Context } from "hono";
import { LedgerUnavailableError, sha256Hex, type SessionLedger } from "./realtime.js";

/** UUID version 4, variant 1 — what `UUID()` on macOS and `Guid.NewGuid()` on Windows produce. */
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

/** The device id as the database will key it, or null when it is not a v4 UUID. */
export function normalisedDevice(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const lower = raw.trim().toLowerCase();
  return UUID_V4.test(lower) ? lower : null;
}

/** 32 random bytes, base64url: 43 characters, prefixed so a leaked one is recognisable in a log. */
export function mintTrialToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  const encoded = btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  return `saathi_trial_${encoded}`;
}

/**
 * Who is asking, for the rate limit. The first entry of `x-forwarded-for` is the client as the
 * platform's edge saw it; later entries are proxies. With no header at all — a self-hosted backend
 * with nothing in front of it — every caller shares one bucket, which is the conservative side.
 */
export function sourceAddress(forwardedFor: string | undefined): string {
  const first = (forwardedFor ?? "").split(",")[0]?.trim() ?? "";
  return first.length > 0 ? first : "unknown";
}

export async function issueTrial(c: Context, ledger: SessionLedger): Promise<Response> {
  if (typeof ledger.issueTrial !== "function") {
    // A backend without an accounts database is a normal, supported posture — same answer, and
    // the same reasoning, as hosted voice without a provider key.
    return c.json(
      {
        error: "this backend does not offer trials",
        hint: "trials need the accounts database (SAATHI_SUPABASE_URL and SAATHI_SUPABASE_SECRET_KEY).",
      },
      501,
    );
  }

  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "the body must be JSON: {\"device\": \"<uuid v4>\"}" }, 400);
  }
  const device = normalisedDevice((body as { device?: unknown } | null)?.device);
  if (!device) return c.json({ error: "device must be a version 4 UUID" }, 400);

  const token = mintTrialToken();
  try {
    const result = await ledger.issueTrial(
      device,
      await sha256Hex(token),
      await sha256Hex(sourceAddress(c.req.header("x-forwarded-for"))),
    );
    if (result.ok) {
      return c.json({ token, expiresAt: result.expiresAt, dailyVoiceSessions: result.dailyVoiceSessions });
    }
    if (result.reason === "rate_limited") {
      return c.json({ error: "that is five trial requests from this network today; try again tomorrow" }, 429);
    }
    return c.json({ error: "this Mac's Saathi trial has ended" }, 403);
  } catch (error) {
    const message = error instanceof LedgerUnavailableError ? error.message : "could not set up a trial";
    return c.json({ error: message }, 503);
  }
}
