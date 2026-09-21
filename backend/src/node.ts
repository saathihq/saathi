//
//  node.ts
//  @saathi/backend
//
//  Runs the app under Node. `npm run dev -w backend` during development.
//

import { serve } from "@hono/node-server";
import { createApp } from "./app.js";
import { supabaseFromEnv, supabaseLedger } from "./realtime.js";

const port = Number(process.env.PORT ?? 8787);
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
  SAATHI_SKILL_KEY: process.env.SAATHI_SKILL_KEY,
  SAATHI_SKILL_BASE_URL: process.env.SAATHI_SKILL_BASE_URL,
  SAATHI_SKILL_MODEL: process.env.SAATHI_SKILL_MODEL,
}, supabase ? { ledger: supabaseLedger(supabase) } : {});

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`saathi backend on http://localhost:${info.port}`);
});
