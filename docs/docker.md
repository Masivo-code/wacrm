# Running with Docker

The repo ships a multi-stage `Dockerfile` (Next.js standalone output,
runs as a non-root user) and a `docker-compose.yml` with a single
`app` service. Supabase is external — point the app at your hosted
(or self-hosted) Supabase project via env vars; no database container
is included.

## Quick start

1. Copy the env template and fill it in:

   ```bash
   cp .env.local.example .env.local
   ```

2. Build and start (the `--env-file` flag is required — Compose only
   reads `.env` by default for `${VAR}` substitution, and this project
   keeps its config in `.env.local`):

   ```bash
   docker compose --env-file .env.local up --build -d
   ```

3. The app is served on [http://localhost:3000](http://localhost:3000)
   (publish it elsewhere with `HOST_PORT=8080` in `.env.local`).

> Use `HOST_PORT`, not `PORT`, to move the published port. `PORT` is
> what the server listens on _inside_ the container, and `env_file`
> would inject it there — leaving the app on a port the mapping and
> the healthcheck don't target. Compose pins it to 3000 for that
> reason.

## Build-time vs runtime variables

- `NEXT_PUBLIC_*` variables are **inlined into the client bundle at
  build time**. They are passed as Docker build args by
  `docker-compose.yml`. If you change any of them, rebuild:
  `docker compose --env-file .env.local up --build -d`.
- Everything else (`SUPABASE_SERVICE_ROLE_KEY`, `ENCRYPTION_KEY`,
  `META_APP_SECRET`, …) is read at **runtime** from `.env.local` via
  `env_file` and is never baked into the image — safe to change with
  just a container restart.

## Plain Docker (no Compose)

```bash
docker build \
  --build-arg NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co \
  --build-arg NEXT_PUBLIC_SUPABASE_ANON_KEY=your-anon-key \
  -t wacrm .

docker run -d --env-file .env.local -e PORT=3000 -p 3000:3000 wacrm
```

## Deploying on EasyPanel

EasyPanel builds directly from the `Dockerfile` (it doesn't read
`docker-compose.yml`), so the build-arg / env-var split above applies
the same way, just entered through its UI instead of `--build-arg` /
`--env-file`:

1. **Create App → Source: Git repo**, pointing at this repository.
   Build method: **Dockerfile** (leave the path as `Dockerfile`).
2. **Build Args** — add the `NEXT_PUBLIC_*` values, since they get
   baked into the client bundle at build time:
   - `NEXT_PUBLIC_SUPABASE_URL`
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY`
   - `NEXT_PUBLIC_SITE_URL` (your EasyPanel domain, e.g. `https://crm.example.com`)
   - `NEXT_PUBLIC_APP_LOCALE` (optional, defaults to `en`)
3. **Environment Variables** — add the runtime-only secrets (never
   put these in Build Args, or they'd leak into the client bundle):
   - `SUPABASE_SERVICE_ROLE_KEY`
   - `ENCRYPTION_KEY`
   - `META_APP_SECRET`
   - any optional vars you need from `.env.local.example`
     (`AUTOMATION_CRON_SECRET`, `META_APP_ID`, …)
4. **Port**: the container listens on `3000` — EasyPanel picks this
   up from the Dockerfile's `EXPOSE 3000`, but confirm it in the
   service's Domain settings if it doesn't auto-detect.
5. Changing a `NEXT_PUBLIC_*` build arg requires a rebuild; changing
   a runtime env var only needs a restart — same rule as plain
   Docker above.
6. Point your WhatsApp webhook and (if used) an external scheduler
   for `/api/automations/cron` / `/api/flows/cron` at the domain
   EasyPanel assigns.

If you put `NEXT_PUBLIC_SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_ANON_KEY`
under Environment instead of Build Args, the build **stops with an
error** naming the two variables. That is deliberate: those values are
inlined into the client bundle, so supplying them at runtime is too
late — the image would build cleanly and then fail only in the
browser.

The image also declares a `HEALTHCHECK`, which EasyPanel uses to decide
whether a deploy came up. It probes the port the server is actually
listening on (`PORT`, default `3000`), so overriding `PORT` in
Environment stays consistent — just make sure EasyPanel's Domain
settings point at the same port.

## Notes

- Database migrations under `supabase/` are **not** run by the
  container — apply them with the Supabase CLI as described in the
  README.
- Received attachments are copied into the `chat-media` Supabase
  Storage bucket, because Meta deletes media roughly 30 days after it
  arrives and the copy is the only thing that outlives that. It grows
  with inbound volume, so it's worth watching your project's storage
  quota. Turn it off per account under Settings → WhatsApp →
  Attachment Storage; attachments received while it's off become
  unviewable once Meta drops them. Files over 16 MB (the bucket's
  limit) are never copied.
- Nothing inside the container is scheduled. If you use automation
  Wait steps or flows, point an external scheduler at
  `GET /api/automations/cron` and `GET /api/flows/cron` on this
  deployment, sending the shared secret in the `x-cron-secret` header
  (`AUTOMATION_CRON_SECRET`, see `.env.local.example`). Both return
  503 until that variable is set.
