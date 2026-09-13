//
//  api/index.ts
//  The Vercel Function that serves api.saathi.dev.
//
//  This project serves api.saathi.dev only; the website is a separate repository.
//
//  ── Why the path arrives in a query parameter ────────────────────────────────
//  A Vercel rewrite replaces the request path, so a function reached by rewrite cannot see what
//  the caller actually asked for. The obvious fix — Vercel's own catch-all, `api/[...route].ts` —
//  does not work here: outside a framework, the `api/` directory compiles `[...route]` to
//  `^/api/([^/]+)$`, a SINGLE path segment. `/api/health` reaches it and `/api/a/b` gets a platform
//  404 without ever touching the function. Verified with `vercel dev`, not assumed.
//
//  So vercel.json carries the real path across in `__path`, and this file puts it back before Hono
//  sees the request. One mechanism, no dependence on how Vercel compiles bracket filenames.
//
//  ── Why the edge runtime ─────────────────────────────────────────────────────
//  `hono/vercel`'s `handle()` returns a web-standard `(Request) => Response`, which is the edge
//  signature. On the nodejs runtime Vercel expects `(req, res)` and the function simply hangs —
//  "still running after 30s" — rather than failing loudly. The backend uses nothing outside web
//  standards, so edge is a fit today. **If it ever needs a Node built-in, this is the line that has
//  to change**, and the nodejs runtime will need a `(req, res)` adapter rather than `hono/vercel`.
//

import { createApp } from "../backend/src/app.js";
import { supabaseFromEnv, supabaseLedger } from "../backend/src/realtime.js";

//  ── The ledger, and why it is in Postgres ───────────────────────────────────
//  Grant-time limits need a counter shared across callers, and on this runtime each isolate has
//  its own memory — an in-process counter here would be one quota per warm isolate, which is not a
//  limit at all. So the counter lives in Postgres and is reached over HTTPS (no TCP on the edge),
//  in a single statement that both checks and spends. See backend/migrations/0001_*.sql.
//
//  With no database configured this deploys with no ledger and /health says "limits: none", which
//  is the honest answer rather than a control that looks like it works.

export const config = { runtime: "edge" };

const supabase = supabaseFromEnv({
  SAATHI_SUPABASE_URL: process.env.SAATHI_SUPABASE_URL,
  SAATHI_SUPABASE_SECRET_KEY: process.env.SAATHI_SUPABASE_SECRET_KEY,
});

const app = createApp({
  SAATHI_TOKENS: process.env.SAATHI_TOKENS,
  SAATHI_ALLOW_ANONYMOUS: process.env.SAATHI_ALLOW_ANONYMOUS,
  SAATHI_REALTIME_KEY: process.env.SAATHI_REALTIME_KEY,
  SAATHI_REALTIME_BASE_URL: process.env.SAATHI_REALTIME_BASE_URL,
  SAATHI_REALTIME_MODEL: process.env.SAATHI_REALTIME_MODEL,
  SAATHI_REALTIME_VOICE: process.env.SAATHI_REALTIME_VOICE,
}, supabase ? { ledger: supabaseLedger(supabase) } : {});

export default function handler(request: Request): Response | Promise<Response> {
  const incoming = new URL(request.url);

  // Put the original path back, and take the marker out of the query so the app never sees it.
  const path = incoming.searchParams.get("__path") || "/";
  incoming.searchParams.delete("__path");

  const restored = new URL(path, incoming.origin);
  restored.search = incoming.search;

  return app.fetch(new Request(restored, request));
}
