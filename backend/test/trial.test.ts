import { describe, expect, it, vi } from "vitest";
import { createApp } from "../src/app.js";
import { LedgerUnavailableError, supabaseLedger, type SessionLedger, type TrialResult } from "../src/realtime.js";

const DEVICE = "3f2b8c1e-5a44-4c1b-9d0e-7a6b5c4d3e2f";

/** A ledger that records what it was asked, and answers with `result`. */
function trialLedger(result: TrialResult | Error) {
  const calls: { device: string; tokenSha256: string; sourceSha256: string }[] = [];
  const ledger: SessionLedger = {
    description: "test",
    authorize: async () => null,
    check: async () => null,
    issueTrial: async (device, tokenSha256, sourceSha256) => {
      calls.push({ device, tokenSha256, sourceSha256 });
      if (result instanceof Error) throw result;
      return result;
    },
  };
  return { ledger, calls };
}

const post = (app: ReturnType<typeof createApp>, body: unknown, headers: Record<string, string> = {}) =>
  app.request("/trial", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

describe("POST /trial", () => {
  const granted: TrialResult = { ok: true, expiresAt: "2026-09-28T10:00:00+00:00", dailyVoiceSessions: 3 };

  it("mints a token without asking for one, and never stores or echoes it in the clear to the ledger", async () => {
    const { ledger, calls } = trialLedger(granted);
    const response = await post(createApp({}, { ledger }), { device: DEVICE }, { "x-forwarded-for": "203.0.113.7, 10.0.0.1" });

    expect(response.status).toBe(200);
    const body = (await response.json()) as { token: string; expiresAt: string; dailyVoiceSessions: number };
    expect(body.token).toMatch(/^saathi_trial_[A-Za-z0-9_-]{43}$/);
    expect(body.expiresAt).toBe("2026-09-28T10:00:00+00:00");
    expect(body.dailyVoiceSessions).toBe(3);

    expect(calls).toHaveLength(1);
    expect(calls[0]!.device).toBe(DEVICE);
    expect(calls[0]!.tokenSha256).toMatch(/^[0-9a-f]{64}$/);
    expect(calls[0]!.tokenSha256).not.toContain(body.token);
    expect(calls[0]!.sourceSha256).toMatch(/^[0-9a-f]{64}$/);
    expect(calls[0]!.sourceSha256).not.toContain("203.0.113.7");
  });

  it("gives two requests two different tokens", async () => {
    const { ledger } = trialLedger(granted);
    const app = createApp({}, { ledger });
    const first = (await (await post(app, { device: DEVICE })).json()) as { token: string };
    const second = (await (await post(app, { device: DEVICE })).json()) as { token: string };
    expect(first.token).not.toBe(second.token);
  });

  it("hashes the first forwarded address, so one network is one bucket whatever proxies follow", async () => {
    const { ledger, calls } = trialLedger(granted);
    const app = createApp({}, { ledger });
    await post(app, { device: DEVICE }, { "x-forwarded-for": "203.0.113.7, 10.0.0.1" });
    await post(app, { device: DEVICE }, { "x-forwarded-for": "203.0.113.7" });
    await post(app, { device: DEVICE }, { "x-forwarded-for": "198.51.100.2" });
    expect(calls[0]!.sourceSha256).toBe(calls[1]!.sourceSha256);
    expect(calls[0]!.sourceSha256).not.toBe(calls[2]!.sourceSha256);
  });

  it.each([
    ["no body", ""],
    ["not JSON", "{"],
    ["no device", {}],
    ["a device that is not a UUID", { device: "my-mac" }],
    ["a UUID that is not v4", { device: "3f2b8c1e-5a44-1c1b-9d0e-7a6b5c4d3e2f" }],
    ["a device that is not a string", { device: 7 }],
  ])("answers 400 for %s and asks the ledger nothing", async (_name, body) => {
    const { ledger, calls } = trialLedger(granted);
    const response = await post(createApp({}, { ledger }), body);
    expect(response.status).toBe(400);
    expect(calls).toHaveLength(0);
  });

  it("accepts an upper-case UUID and sends the ledger the lower-case one", async () => {
    const { ledger, calls } = trialLedger(granted);
    const response = await post(createApp({}, { ledger }), { device: DEVICE.toUpperCase() });
    expect(response.status).toBe(200);
    expect(calls[0]!.device).toBe(DEVICE);
  });

  it("answers 429 in words when the network has asked five times today", async () => {
    const { ledger } = trialLedger({ ok: false, reason: "rate_limited" });
    const response = await post(createApp({}, { ledger }), { device: DEVICE });
    expect(response.status).toBe(429);
    expect(((await response.json()) as { error: string }).error).toContain("five trial requests");
  });

  it("answers 403 in words when this device's trial has ended", async () => {
    const { ledger } = trialLedger({ ok: false, reason: "expired" });
    const response = await post(createApp({}, { ledger }), { device: DEVICE });
    expect(response.status).toBe(403);
    expect(((await response.json()) as { error: string }).error).toContain("trial has ended");
  });

  it("answers 503, not a token, when the database does not answer", async () => {
    const { ledger } = trialLedger(new LedgerUnavailableError("the accounts database did not answer (500)"));
    const response = await post(createApp({}, { ledger }), { device: DEVICE });
    expect(response.status).toBe(503);
  });

  it("answers 501 on a backend with no accounts ledger, whatever its auth posture", async () => {
    for (const env of [{ SAATHI_TOKENS: "good" }, { SAATHI_ALLOW_ANONYMOUS: "1" }, {}]) {
      const response = await post(createApp(env), { device: DEVICE });
      expect(response.status).toBe(501);
    }
  });
});

describe("/health and trials", () => {
  it("says on with a ledger that can issue them, off otherwise", async () => {
    const { ledger } = trialLedger({ ok: false, reason: "expired" });
    const on = (await (await createApp({}, { ledger }).request("/health")).json()) as { trial: string };
    const off = (await (await createApp({ SAATHI_TOKENS: "good" }).request("/health")).json()) as { trial: string };
    expect(on.trial).toBe("on");
    expect(off.trial).toBe("off");
  });
});

describe("the Supabase ledger and trials", () => {
  const supabase = { url: "https://project.supabase.co", secretKey: "sb_secret_test" };

  it("calls saathi_issue_trial with exactly the three parameters and maps the answer", async () => {
    const fetchImpl = vi.fn(async (_url: string | URL | Request, _init?: RequestInit) =>
      new Response(JSON.stringify({ ok: true, expires_at: "2026-09-28T10:00:00+00:00", daily_voice_sessions: 3 })),
    ) as unknown as typeof fetch;
    const result = await supabaseLedger(supabase, fetchImpl).issueTrial!(DEVICE, "a".repeat(64), "b".repeat(64));

    expect(result).toEqual({ ok: true, expiresAt: "2026-09-28T10:00:00+00:00", dailyVoiceSessions: 3 });
    const [url, init] = (fetchImpl as unknown as ReturnType<typeof vi.fn>).mock.calls[0]!;
    expect(String(url)).toBe("https://project.supabase.co/rest/v1/rpc/saathi_issue_trial");
    expect(JSON.parse((init as RequestInit).body as string)).toEqual({
      p_device_id: DEVICE, p_token_sha256: "a".repeat(64), p_source_sha256: "b".repeat(64),
    });
  });

  it("maps a refusal, and treats an unknown reason as expired rather than as a grant", async () => {
    const answering = (body: unknown) =>
      (async () => new Response(JSON.stringify(body))) as unknown as typeof fetch;
    expect(await supabaseLedger(supabase, answering({ ok: false, reason: "rate_limited" })).issueTrial!(DEVICE, "a", "b"))
      .toEqual({ ok: false, reason: "rate_limited" });
    expect(await supabaseLedger(supabase, answering({ ok: false, reason: "something new" })).issueTrial!(DEVICE, "a", "b"))
      .toEqual({ ok: false, reason: "expired" });
    expect(await supabaseLedger(supabase, answering({ ok: true })).issueTrial!(DEVICE, "a", "b"))
      .toEqual({ ok: false, reason: "expired" });
  });

  it("throws LedgerUnavailableError when the database does not answer", async () => {
    const down = (async () => new Response("nope", { status: 500 })) as unknown as typeof fetch;
    await expect(supabaseLedger(supabase, down).issueTrial!(DEVICE, "a", "b")).rejects.toBeInstanceOf(LedgerUnavailableError);
  });

  it("passes the reason an expired trial is refused through to the caller", async () => {
    const fetchImpl = (async () =>
      new Response(JSON.stringify({ ok: false, reason: "your Saathi trial has ended" }))) as unknown as typeof fetch;
    const response = await createApp({}, { ledger: supabaseLedger(supabase, fetchImpl) }).request("/session", {
      method: "POST",
      headers: { authorization: "Bearer was-real" },
    });
    expect(response.status).toBe(401);
    expect(((await response.json()) as { error: string }).error).toBe("your Saathi trial has ended");
  });
});
