# syntax=docker/dockerfile:1

# ---------------------------------------------------------------
# Stage 1 — install dependencies (cached until package*.json change)
# ---------------------------------------------------------------
FROM node:20-alpine AS deps
WORKDIR /app
# Some transitive native deps (sharp and friends) expect glibc symbols
# that musl only provides through this shim.
RUN apk add --no-cache libc6-compat
# Only the manifests, so this layer (and the install below) stays
# cached until a dependency actually changes.
COPY package.json package-lock.json ./
# The npm bundled with node:20-alpine is the same major the lockfile
# was generated with, so `npm ci` is reproducible without pinning a
# different npm here. Do not "fix" a lockfile-out-of-sync error by
# installing a newer npm — regenerate the lockfile instead, or CI
# (which uses the bundled npm too) breaks in the opposite direction.
RUN npm ci --no-audit --no-fund

# ---------------------------------------------------------------
# Stage 2 — build
#
# NEXT_PUBLIC_* values are inlined into the client bundle at build
# time, so they must be provided as build args (docker-compose.yml
# forwards them from .env.local; on EasyPanel they go in Build Args).
# Server-only secrets (service role key, ENCRYPTION_KEY,
# META_APP_SECRET, ...) are read at runtime and must NOT be baked
# into the image.
# ---------------------------------------------------------------
FROM node:20-alpine AS builder
WORKDIR /app
RUN apk add --no-cache libc6-compat
COPY --from=deps /app/node_modules ./node_modules
COPY . .

ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY
ARG NEXT_PUBLIC_SITE_URL
ARG NEXT_PUBLIC_APP_LOCALE=en
ENV NEXT_PUBLIC_SUPABASE_URL=$NEXT_PUBLIC_SUPABASE_URL \
    NEXT_PUBLIC_SUPABASE_ANON_KEY=$NEXT_PUBLIC_SUPABASE_ANON_KEY \
    NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL \
    NEXT_PUBLIC_APP_LOCALE=$NEXT_PUBLIC_APP_LOCALE \
    NEXT_TELEMETRY_DISABLED=1

# Fail loudly instead of shipping an image whose client bundle has
# `undefined` baked in where the Supabase URL should be. Without this
# the build succeeds and the app only breaks in the browser, which is
# a miserable thing to debug on a hosted builder.
RUN if [ -z "$NEXT_PUBLIC_SUPABASE_URL" ] || [ -z "$NEXT_PUBLIC_SUPABASE_ANON_KEY" ]; then \
      echo "ERROR: NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY are required at BUILD time." >&2; \
      echo "  docker build : --build-arg NEXT_PUBLIC_SUPABASE_URL=... --build-arg NEXT_PUBLIC_SUPABASE_ANON_KEY=..." >&2; \
      echo "  compose      : docker compose --env-file .env.local up --build" >&2; \
      echo "  EasyPanel    : add them under Build -> Build Args (Environment is too late)." >&2; \
      exit 1; \
    fi

RUN npm run build

# ---------------------------------------------------------------
# Stage 3 — minimal runtime (standalone output)
# ---------------------------------------------------------------
FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

RUN addgroup -S nextjs && adduser -S nextjs -G nextjs

# Pre-created and owned by the app user so the server can write its
# ISR / fetch cache under .next/cache at runtime.
RUN mkdir -p .next/cache && chown -R nextjs:nextjs /app

COPY --from=builder --chown=nextjs:nextjs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nextjs /app/.next/static ./.next/static
COPY --from=builder --chown=nextjs:nextjs /app/public ./public

USER nextjs
EXPOSE 3000

# EasyPanel (and plain `docker run`, outside Compose) reads this
# HEALTHCHECK directly from the image — docker-compose.yml's own
# healthcheck only applies when deploying via Compose.
#
# 127.0.0.1 rather than localhost: the server binds IPv4 (HOSTNAME
# above), while `localhost` on Alpine can resolve to ::1 first and
# hang the probe. PORT is read at run time so overriding it doesn't
# leave the container permanently unhealthy.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:'+(process.env.PORT||3000)).then((r)=>process.exit(r.status<500?0:1)).catch(()=>process.exit(1))"]

CMD ["node", "server.js"]
