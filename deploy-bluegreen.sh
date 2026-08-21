#!/bin/bash
# Blue-green swap for a single service on plain `docker compose` — no Swarm,
# no Kubernetes, no extra orchestrator.
#
# Runs a second container ("green") from the already-loaded image, alongside
# the live one ("blue"). Traefik's docker provider (and most other
# label-based reverse proxies) pools every container that shares the same
# service labels regardless of container name, so both serve traffic the
# moment green passes its healthcheck. Once green is healthy, blue is
# removed and green is renamed into its place.
# Result: no window where the router has zero healthy backends.
#
# Prerequisite: the new image is already present locally under the tag the
# compose file expects (e.g. after `docker load` or `docker compose build`),
# so this script never waits on a pull.
#
# Usage:
#   COMPOSE_FILE=docker-compose.yml ENV_FILE=.env \
#     ./deploy-bluegreen.sh <compose-service> [timeout-seconds]
#
# Example:
#   ./deploy-bluegreen.sh backend
#   ./deploy-bluegreen.sh backend 180

set -euo pipefail

SERVICE="${1:?usage: deploy-bluegreen.sh <compose-service> [timeout-seconds]}"
TIMEOUT="${2:-120}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
ENV_FILE="${ENV_FILE:-.env}"
COMPOSE=(docker compose -f "$COMPOSE_FILE")
[ -f "$ENV_FILE" ] && COMPOSE+=(--env-file "$ENV_FILE")

BLUE_NAME=$("${COMPOSE[@]}" config --format json 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['services']['$SERVICE']['container_name'])")
GREEN_NAME="${BLUE_NAME}_green"

# Leftover from a previous failed run
docker rm -f "$GREEN_NAME" >/dev/null 2>&1 || true

echo "[1/4] starting green container ($GREEN_NAME)..."
# `compose up` always reconciles to exactly one container per service (it
# renames/recreates the existing one instead of adding a second), so a plain
# up -d with a container_name override does NOT give overlap. `compose run`
# unconditionally creates a fresh container, which is what overlap needs.
"${COMPOSE[@]}" run -d --no-deps --name "$GREEN_NAME" "$SERVICE"

echo "[2/4] waiting for healthy (max ${TIMEOUT}s)..."
elapsed=0
while true; do
  status=$(docker inspect -f '{{.State.Health.Status}}' "$GREEN_NAME" 2>/dev/null || echo "")
  [ "$status" = "healthy" ] && break
  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    echo "green never became healthy (last status: ${status:-none}), rolling back" >&2
    docker logs --tail 30 "$GREEN_NAME" >&2 || true
    docker rm -f "$GREEN_NAME" >/dev/null 2>&1 || true
    exit 1
  fi
  sleep 3
  elapsed=$((elapsed + 3))
done
echo "green healthy after ${elapsed}s (reverse proxy now load-balancing blue+green)"

echo "[3/4] removing blue ($BLUE_NAME)..."
docker rm -f "$BLUE_NAME" >/dev/null 2>&1 || true

echo "[4/4] renaming green -> $BLUE_NAME..."
docker rename "$GREEN_NAME" "$BLUE_NAME"
docker update --restart=always "$BLUE_NAME" >/dev/null

echo "done. $SERVICE deployed with zero downtime."
echo "note: next deploy must go through this script again, not a plain 'compose up -d' -- the running container carries compose's oneoff label (it was made via 'run'), so a bare up -d would try to create a second one under the same name and fail with a name conflict."
