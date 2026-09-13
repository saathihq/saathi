//
//  realtime.ts
//  @saathi/backend
//
//  Minting a short-lived credential for a realtime voice session, instead of proxying one.
//
//  ── The decision, and why ────────────────────────────────────────────────────
//  A hosted realtime voice turn can be carried two ways. This backend could hold both sockets and
//  relay frames, which would give it full visibility — real token metering, the ability to cut a
//  session off mid-turn. Or it can mint a short-lived client secret and let the client talk to the
//  provider directly.
//
//  This is the second, for two reasons:
//
//  1. It is the same shape as the rest of the project. The provider-key boundary says the real key
//     lives here and never reaches a client; minting honours that exactly — the client gets a
//     credential that expires in about a minute and can only open one session. Proxying would make
//     Saathi's servers a permanent participant in every conversation a learner has, which is
//     precisely what `local` mode exists to avoid.
//  2. PCM16 mono at 24 kHz is 48 kB/s in each direction, so a proxied session pushes about
//     346 MB per session-hour through this process and needs a stateful always-on server. The edge
//     runtime this deploys to cannot hold a websocket at all.
//
//  The cost of that choice is real and is not hidden: **this backend never sees the tokens a
//  session spends**, so usage-based metering is impossible here. What is enforceable is enforced
//  at the moment the credential is handed out — see SessionLedger below.
//

/** What the provider needs to mint a credential, and how to ask for it. */
export type RealtimeProvider = {
  /** The provider's own base URL — NOT this backend's. */
  baseUrl: string;
  /** The real key. Never serialised into a response. */
  apiKey: string;
  model: string;
  voice?: string;
};

export type RealtimeGrant = {
  /** The short-lived secret the client opens its socket with. */
  value: string;
  /** Unix seconds. */
  expiresAt: number;
  model: string;
  /** Where the client should connect. It goes to the PROVIDER, not back here. */
  url: string;
};

/**
 * Grant-time metering.
 *
 * Because the audio never crosses this backend, a session cannot be metered by what it spends. It
 * can only be metered by what it is allowed to start: how many per window, and how long each may
 * run. That is weaker than token accounting and saying so plainly is better than implying a
 * control that does not exist.
 *
 * `check` MUST be atomic. The predecessor's credit checks were read-then-spend with no
 * reservation, so two requests in flight both saw the same balance and both proceeded — a bug that
 * is rail-independent and would bite under any payment provider. An implementation backed by
 * Postgres should do this as a single conditional UPDATE, not a SELECT followed by an UPDATE.
 */
export interface SessionLedger {
  /** Named so `/health` can say what is actually enforcing limits. */
  readonly description: string;
  /** Returns null to allow, or a reason to refuse. Must be atomic against concurrent callers. */
  check(token: string): Promise<string | null>;
}

/** No limits at all. The honest default for a self-hosted backend serving its owner. */
export const unlimitedLedger: SessionLedger = {
  description: "none — every authorised caller may start a session",
  check: async () => null,
};

/**
 * A per-process counter.
 *
 * Correct for a self-hosted backend, which is one process. **Not a real limit on a serverless
 * deployment**, where each isolate gets its own empty map and a caller can exceed the quota by the
 * number of isolates that happen to be warm. `/health` reports this verbatim so an operator can see
 * which of the two situations they are in rather than assuming they are protected.
 */
export function inMemoryLedger(perDay: number): SessionLedger {
  const seen = new Map<string, { day: number; count: number }>();
  return {
    description: `${perDay}/day, counted in this process only (not a shared limit across instances)`,
    check: async (token) => {
      const day = Math.floor(Date.now() / 86_400_000);
      const entry = seen.get(token);
      if (!entry || entry.day !== day) {
        seen.set(token, { day, count: 1 });
        return null;
      }
      if (entry.count >= perDay) {
        return `that is ${perDay} voice sessions today, which is this backend's limit`;
      }
      entry.count += 1;
      return null;
    },
  };
}

/**
 * Asks the provider for an ephemeral client secret.
 *
 * The response deliberately carries no part of the real key, and the caller's own account token is
 * never forwarded to the provider either — the two credentials are kept entirely separate, so a
 * provider-side log can never contain a Saathi account token and vice versa.
 */
export async function mintRealtimeGrant(
  provider: RealtimeProvider,
  fetchImpl: typeof fetch = fetch,
): Promise<RealtimeGrant> {
  const base = provider.baseUrl.endsWith("/") ? provider.baseUrl.slice(0, -1) : provider.baseUrl;

  const response = await fetchImpl(`${base}/realtime/client_secrets`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${provider.apiKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      session: {
        type: "realtime",
        model: provider.model,
        ...(provider.voice ? { audio: { output: { voice: provider.voice } } } : {}),
      },
    }),
  });

  if (!response.ok) {
    // The provider's body can quote the request, so it must not be passed through verbatim — that
    // is how a key prefix ends up in a client's logs. Say what failed, not what was sent.
    throw new RealtimeMintError(`the provider refused to open a realtime session (${response.status})`);
  }

  const body = (await response.json()) as {
    value?: string;
    expires_at?: number;
    session?: { model?: string };
  };

  if (typeof body.value !== "string" || body.value.length === 0) {
    throw new RealtimeMintError("the provider returned no client secret");
  }

  return {
    value: body.value,
    // A missing expiry must not read as "never expires". One minute matches the provider's own
    // default and is the safe direction to be wrong in.
    expiresAt: typeof body.expires_at === "number" ? body.expires_at : Math.floor(Date.now() / 1000) + 60,
    model: body.session?.model ?? provider.model,
    url: `${base.replace(/^http/, "ws")}/realtime?model=${encodeURIComponent(body.session?.model ?? provider.model)}`,
  };
}

export class RealtimeMintError extends Error {}
