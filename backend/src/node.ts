//
//  node.ts
//  @saathi/backend
//
//  Runs the app under Node. `npm run dev -w backend` during development.
//

import { serve } from "@hono/node-server";
import { createApp } from "./app.js";

const port = Number(process.env.PORT ?? 8787);
const app = createApp({ SAATHI_TOKENS: process.env.SAATHI_TOKENS });

serve({ fetch: app.fetch, port }, (info) => {
  console.log(`saathi backend on http://localhost:${info.port}`);
});
