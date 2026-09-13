# The Saathi backend as a container (the VPS runs Docker, not Node).
# Build context is the repo root — the backend is an npm workspace and the contract it imports is
# generated into backend/src by contract/generate.mjs:
#   docker build -f backend/Dockerfile -t saathi-backend .
FROM node:22-alpine AS build
WORKDIR /repo
COPY package.json package-lock.json ./
COPY backend/package.json backend/
COPY contract/package.json contract/
RUN npm ci --workspace backend --include-workspace-root --ignore-scripts
COPY contract contract
COPY backend backend
# Regenerate rather than trusting what was committed: if the schema and the checked-in contract have
# drifted, the image should fail to build here rather than serve a route list nobody agreed to.
RUN node contract/generate.mjs --check && npm run build -w backend

# The build stage needs TypeScript; the runtime must not ship it. Installing production dependencies
# separately keeps the compiler and the test runner out of the image that faces the internet.
FROM node:22-alpine AS production-dependencies
WORKDIR /repo
COPY package.json package-lock.json ./
COPY backend/package.json backend/
COPY contract/package.json contract/
RUN npm ci --workspace backend --include-workspace-root --ignore-scripts --omit=dev

FROM node:22-alpine
ENV NODE_ENV=production PORT=8787
WORKDIR /repo
COPY --from=build /repo/package.json /repo/package-lock.json ./
COPY --from=build /repo/backend/package.json backend/
COPY --from=production-dependencies /repo/node_modules node_modules
COPY --from=build /repo/backend/dist backend/dist
USER node
EXPOSE 8787
# Node 22 has a global fetch, so the check needs nothing installed in the image.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8787)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "backend/dist/node.js"]
