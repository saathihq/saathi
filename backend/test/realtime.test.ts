import { describe, expect, it, vi } from "vitest";
import { createApp } from "../src/app.js";
import { inMemoryLedger, mintRealtimeGrant, RealtimeMintError } from "../src/realtime.js";

/** A provider that answers the way OpenAI does, without a network or a key. */
const providerRespondingWith = (body: unknown, status = 200) =>
  vi.fn(async () => new Response(JSON.stringify(body), { status })) as unknown as typeof fetch;

const happyProvider = () =>
  providerRespondingWith({
    value: "ek_test_abc123",
    expires_at: 1_800_000_060,
    session: { model: "gpt-realtime" },
  });

const withKey = {
  SAATHI_TOKENS: "good",
  SAATHI_REALTIME_KEY: "sk-real-provider-key-do-not-leak",
};

describe("realtime session minting", () => {
  it("hands back a client secret and a URL pointing at the provider, not at this backend", async () => {
    const app = createApp(withKey, { fetchImpl: happyProvider() });
    const response = await app.request("/realtime/session", {
      method: "POST",
      headers: { authorization: "Bearer good" },
    });

    expect(response.status).toBe(200);
    const grant = (await response.json()) as { value: string; url: string; expiresAt: number };
    expect(grant.value).toBe("ek_test_abc123");
    expect(grant.expiresAt).toBe(1_800_000_060);
    // The whole point of minting rather than proxying: the client is sent somewhere else.
    expect(grant.url).toBe("wss://api.openai.com/v1/realtime?model=gpt-realtime");
    expect(grant.url).not.toContain("saathi.dev");
  });

  /**
   * The provider-key boundary, as a test. This is the one secret the process holds, and the
   * response is the one place it could escape to a client.
   */
  it("never lets the real provider key reach the client, in any field", async () => {
    const app = createApp(withKey, { fetchImpl: happyProvider() });
    const response = await app.request("/realtime/session", {
      method: "POST",
      headers: { authorization: "Bearer good" },
    });
    const raw = await response.text();
    expect(raw).not.toContain(withKey.SAATHI_REALTIME_KEY);
    // Not even a prefix: a logged prefix of a secret is still a logged secret.
    expect(raw).not.toContain("sk-real");
  });

  /** The two credentials are kept apart, so neither side's logs can contain the other's. */
  it("never forwards the caller's account token to the provider", async () => {
    const provider = happyProvider();
    const app = createApp(withKey, { fetchImpl: provider });
    await app.request("/realtime/session", {
      method: "POST",
      headers: { authorization: "Bearer good" },
    });

    const call = (provider as unknown as { mock: { calls: [string, RequestInit][] } }).mock.calls[0];
    expect(call).toBeDefined();
    const init = call![1];
    const sent = JSON.stringify({ headers: init.headers, body: init.body });
    expect(sent).not.toContain("Bearer good");
    expect(sent).toContain("sk-real-provider-key-do-not-leak");
  });

  it("refuses an unauthorised caller before it ever asks the provider", async () => {
    const provider = happyProvider();
    const response = await createApp(withKey, { fetchImpl: provider }).request("/realtime/session", {
      method: "POST",
      headers: { authorization: "Bearer wrong" },
    });
    expect(response.status).toBe(401);
    // A provider call for a request that was going to be refused anyway is a bill for nothing.
    expect(provider).not.toHaveBeenCalled();
  });

  it("applies the same auth rule as /session, rather than a second copy of it", async () => {
    const app = createApp({ SAATHI_TOKENS: "good" }, { fetchImpl: happyProvider() });
    for (const path of ["/session", "/realtime/session"]) {
      const bad = await app.request(path, { method: "POST", headers: { authorization: "Bearer no" } });
      expect(bad.status, `${path} with a bad token`).toBe(401);
      const none = await app.request(path, { method: "POST" });
      expect(none.status, `${path} with no token`).toBe(401);
    }
  });

  /**
   * A backend holding no provider key is a normal, supported posture — most self-hosted ones will
   * be exactly that. It must be distinguishable from a broken deployment.
   */
  it("says plainly that it offers no hosted voice, rather than failing obscurely", async () => {
    const response = await createApp({ SAATHI_TOKENS: "good" }).request("/realtime/session", {
      method: "POST",
      headers: { authorization: "Bearer good" },
    });
    expect(response.status).toBe(501);
    const body = (await response.json()) as { error: string; hint: string };
    expect(body.error).toContain("does not offer hosted voice");
    expect(body.hint).toContain("your own key");
  });

  /** A provider error body can quote the request that caused it, key included. */
  it("does not pass the provider's error body through to the client", async () => {
    const leaky = providerRespondingWith(
      { error: { message: "bad key sk-real-provider-key-do-not-leak in Authorization" } },
      401,
    );
    const response = await createApp(withKey, { fetchImpl: leaky }).request("/realtime/session", {
      method: "POST",
      headers: { authorization: "Bearer good" },
    });
    expect(response.status).toBe(502);
    expect(await response.text()).not.toContain("sk-real");
  });

  /** A missing expiry must not read as "never expires". */
  it("defaults a missing expiry to a minute rather than to forever", async () => {
    const provider = providerRespondingWith({ value: "ek_x", session: { model: "gpt-realtime" } });
    const response = await createApp(withKey, { fetchImpl: provider }).request("/realtime/session", {
      method: "POST",
      headers: { authorization: "Bearer good" },
    });
    const grant = (await response.json()) as { expiresAt: number };
    const seconds = grant.expiresAt - Math.floor(Date.now() / 1000);
    expect(seconds).toBeGreaterThan(0);
    expect(seconds).toBeLessThanOrEqual(60);
  });

  it("refuses a response with no secret in it", async () => {
    await expect(
      mintRealtimeGrant(
        { baseUrl: "https://api.openai.com/v1", apiKey: "k", model: "m" },
        providerRespondingWith({ session: { model: "m" } }),
      ),
    ).rejects.toBeInstanceOf(RealtimeMintError);
  });
});

describe("grant-time metering", () => {
  /**
   * Because the audio never crosses this backend, a session cannot be metered by what it spends —
   * only by what it is allowed to start. This is that limit working.
   */
  it("stops a caller past its daily allowance", async () => {
    const app = createApp(withKey, { fetchImpl: happyProvider(), ledger: inMemoryLedger(2) });
    const ask = () =>
      app.request("/realtime/session", { method: "POST", headers: { authorization: "Bearer good" } });

    expect((await ask()).status).toBe(200);
    expect((await ask()).status).toBe(200);
    const third = await ask();
    expect(third.status).toBe(429);
    expect((await third.json() as { error: string }).error).toContain("limit");
  });

  it("counts each caller separately", async () => {
    const app = createApp(
      { ...withKey, SAATHI_TOKENS: "alice,bob" },
      { fetchImpl: happyProvider(), ledger: inMemoryLedger(1) },
    );
    const ask = (token: string) =>
      app.request("/realtime/session", { method: "POST", headers: { authorization: `Bearer ${token}` } });

    expect((await ask("alice")).status).toBe(200);
    expect((await ask("bob")).status).toBe(200);
    expect((await ask("alice")).status).toBe(429);
  });

  /**
   * The limit is checked before the provider is called, so a refused caller costs nothing. The
   * predecessor had the opposite bug in a different place — work done and then not charged for.
   */
  it("refuses without calling the provider", async () => {
    const provider = happyProvider();
    const app = createApp(withKey, { fetchImpl: provider, ledger: inMemoryLedger(1) });
    const ask = () =>
      app.request("/realtime/session", { method: "POST", headers: { authorization: "Bearer good" } });
    await ask();
    await ask();
    expect((provider as unknown as { mock: { calls: unknown[] } }).mock.calls).toHaveLength(1);
  });

  /**
   * An in-memory ledger on a serverless deployment is per-isolate and therefore not a real shared
   * limit. An operator must be able to see that from /health rather than assuming they are covered.
   */
  it("health says what is actually enforcing limits, and whether voice is on at all", async () => {
    const off = await createApp({}).request("/health");
    expect(await off.json()).toMatchObject({ voice: "off", limits: expect.stringContaining("none") });

    const on = await createApp(withKey, { ledger: inMemoryLedger(5) }).request("/health");
    const body = (await on.json()) as { voice: string; limits: string };
    expect(body.voice).toBe("hosted");
    expect(body.limits).toContain("this process only");
  });

  it("health still never reveals whether a key is valid, only that one is present", async () => {
    const response = await createApp(withKey).request("/health");
    expect(await response.text()).not.toContain("sk-real");
  });
});
