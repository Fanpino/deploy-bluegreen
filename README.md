# deploy-bluegreen

Zero-downtime deploys for a single `docker compose` service — no Swarm, no
Kubernetes, no extra orchestrator. Just a ~70-line bash script.

We run this in production for several self-hosted services and wrote it up
because most "zero-downtime docker compose deploy" advice online assumes
you're already on Swarm or k8s. If you're just running `docker compose` on a
box, this fills that gap.

## How it works

A plain `docker compose up -d` always reconciles to exactly one container
per service — it stops the old one before the new one is ready, so your
reverse proxy 502s for a few seconds. This script instead:

1. Starts a second container (`<name>_green`) alongside the running one
   (`<name>`), using `docker compose run` instead of `up` — `run` always
   creates a fresh container, `up` never gives you two.
2. Polls the new container's healthcheck until it reports `healthy`.
   Label-based reverse proxies (Traefik, and most others) pool every
   container sharing the same service labels regardless of container name or
   count, so both old and new are already serving traffic at this point.
3. Removes the old container and renames the new one into its place.
4. On healthcheck timeout, it removes the new container and leaves the old
   one untouched — a safe no-op failure, not a rollback of a swap that
   already happened.

## Requirements

- Your service needs a working `HEALTHCHECK` (in the Dockerfile or compose
  file) — this is how the script knows when to cut over.
- `python3` on the host (used to read `container_name` from `docker compose config`),
  and an explicit `container_name` on the service.
- The new image must already be present locally (pulled, built, or loaded)
  before you run this — it never triggers a pull itself.

## Install

```bash
curl -fsSLO https://raw.githubusercontent.com/Fanpino/deploy-bluegreen/main/deploy-bluegreen.sh
chmod +x deploy-bluegreen.sh
```

Put it next to your compose file, or anywhere and point `COMPOSE_FILE` at it.

## Usage

```bash
COMPOSE_FILE=docker-compose.yml ENV_FILE=.env \
  ./deploy-bluegreen.sh <compose-service> [timeout-seconds]
```

```bash
./deploy-bluegreen.sh backend        # default 120s healthcheck timeout
./deploy-bluegreen.sh backend 180
```

### Example with Traefik

Nothing special is needed on the Traefik side. Give the service a
healthcheck, an explicit `container_name` (the script reads it to name the
green container) and the usual labels:

```yaml
services:
  backend:
    image: myapp-backend:latest
    container_name: backend
    healthcheck:
      test: ["CMD", "curl", "-fs", "http://localhost:8000/health"]
      interval: 5s
      retries: 5
    labels:
      - traefik.enable=true
      - traefik.http.routers.backend.rule=Host(`api.example.com`)
      - traefik.http.services.backend.loadbalancer.server.port=8000
```

Then a deploy is: build or load the new image, run `./deploy-bluegreen.sh backend`.

## Gotcha if you deploy this same service again later

The container this leaves behind carries compose's `oneoff` label (an
artifact of using `run` instead of `up`). A later plain `docker compose up
-d` on that service will try to create a *second* container under the same
name and fail with a conflict. Always redeploy that service through this
script again, not a bare `up -d`.

## License

MIT, see [LICENSE](LICENSE).

---

Built and used in production by [Fanpino](https://fanpino.com/en/), a Dubai-based software studio making multi-tenant SaaS (helpdesk, MES, self-hosted email).
