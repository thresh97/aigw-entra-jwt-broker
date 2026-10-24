#!/usr/bin/env bash
# Builds the broker image on an x86 Docker host (so no cross-build when the host is x86) and pushes it to GHCR. Prints the
# image reference on stdout; pass it to infra/deploy.sh. The tag is a hash of the sources.
# Needs a gh login whose token has the write:packages scope (gh auth refresh -s write:packages). The token travels over
# ssh on stdin into a throwaway Docker config that is deleted afterwards; it is never printed or stored on the host.
# Env: BUILD_HOST (required, ssh target of an x86 Docker host), IMAGE_REPO (default ghcr.io/<gh user>/aigw-entra-jwt-broker).
# The package must be public so Container Apps can pull it anonymously. GitHub only offers that in the web UI
# (package settings, Change visibility), so the script checks and says so.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

BUILD_HOST="${BUILD_HOST:?set BUILD_HOST, the ssh target of an x86 Docker host}"
OWNER=$(gh api user -q .login)
IMAGE_REPO="${IMAGE_REPO:-ghcr.io/$OWNER/aigw-entra-jwt-broker}"
TAG=$(find src package.json package-lock.json tsconfig.json Dockerfile -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -c1-12)
IMAGE="$IMAGE_REPO:$TAG"

# One stdin stream: the token on the first line, then the build context as a tar.
{ gh auth token; COPYFILE_DISABLE=1 tar -cf - Dockerfile .dockerignore package.json package-lock.json tsconfig.json src test; } \
  | ssh "$BUILD_HOST" "set -e
  ctx=\$(mktemp -d -p \$HOME) && cfg=\$(mktemp -d -p \$HOME)
  trap 'rm -rf \"\$ctx\" \"\$cfg\"' EXIT
  read -r token
  export DOCKER_CONFIG=\$cfg
  printf '%s' \"\$token\" | docker login ghcr.io -u '$OWNER' --password-stdin >&2
  tar -xf - -C \"\$ctx\" 2>/dev/null
  docker build -t '$IMAGE' \"\$ctx\" >&2
  docker push '$IMAGE' >&2"

vis=$(gh api "/user/packages/container/${IMAGE_REPO##*/}" -q .visibility 2>/dev/null || echo unknown)
[[ "$vis" == public ]] || echo "WARNING: package visibility is '$vis'. Make it public in the GitHub package settings before deploying." >&2
echo "$IMAGE"
