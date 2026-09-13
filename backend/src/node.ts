//
//  node.ts
//  @saathi/backend
//
//  Runs the app under Node. `npm run dev -w backend` during development.
//

import { serve } from "@hono/node-server";
import { createApp } from "./app.js";

const port = Number(process.env.PORT ?? 8787);
const app = createApp({
  SAATHI_TOKENS: process.env.SAATHI_TOKENS,
  SAATHI_ALLOW_ANONYMOUS: process.env.SAATHI_ALLOW_ANONYMOUS,
  SAATHI_REALTIME_KEY: process.env.SAATHI_REALTIME_KEY,
  SAATHI_REALTIME_BASE_URL: process.env.SAATHI_REALTIME_BASE_URL,
  SAATHI_REALTIME_MODEL: process.env.SAATHI_REALTIME_MODEL,
  SAATHI_REALTIME_VOICE: process.env.SAATHI_REALTIME_VOICE,
});

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`saathi backend on http://localhost:${info.port}`);
});
