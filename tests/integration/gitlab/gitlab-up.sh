#!/bin/bash
set -euo pipefail

. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
NAME="$ZENSU_GITLAB_IT_CONTAINER"
PORT="${ZENSU_GITLAB_IT_PORT:-8929}"
MEMORY="${ZENSU_GITLAB_IT_MEMORY:-4g}"
BOOT_SECONDS="${ZENSU_GITLAB_IT_BOOT_SECONDS:-1200}"
STATE="$ZENSU_GITLAB_IT_STATE"
URL="http://127.0.0.1:$PORT"

die() {
  local code="$1"
  shift
  printf 'gitlab-up: %s\n' "$*" >&2
  exit "$code"
}

dump_logs() {
  docker logs --tail 200 "$NAME" >&2 2>&1 || true
}

command -v docker >/dev/null 2>&1 || die 2 'docker is not installed'
command -v node >/dev/null 2>&1 || die 2 'node is not installed'
command -v curl >/dev/null 2>&1 || die 2 'curl is not installed'
printf '%s' "$PORT" | grep -Eq '^[0-9]+$' || die 2 "invalid port '$PORT'"
printf '%s' "$BOOT_SECONDS" | grep -Eq '^[0-9]+$' || die 2 "invalid boot bound '$BOOT_SECONDS'"
IMAGE="$(gitlab_it_pin image)" || die 2 "$ZENSU_GITLAB_IT_VERSIONS carries no pinned GitLab image digest"
[ -n "$IMAGE" ] || die 2 "$ZENSU_GITLAB_IT_VERSIONS carries no pinned GitLab image digest"

token_works() {
  [ -f "$STATE/header" ] || return 1
  [ "$(cat "$STATE/url" 2>/dev/null)" = "$URL" ] || return 1
  curl -fsS --max-time 20 -H @"$STATE/header" "$URL/api/v4/user" 2>/dev/null | node -e '
    let raw = "";
    process.stdin.on("data", (chunk) => { raw += chunk; });
    process.stdin.on("end", () => {
      let user;
      try { user = JSON.parse(raw); } catch { process.exit(1); }
      process.exit(user && user.username === "root" ? 0 : 1);
    });
  '
}

started="$(date +%s)"
existing="$(docker inspect -f "{{index .Config.Labels \"$ZENSU_GITLAB_IT_LABEL\"}} {{.State.Running}} {{.Config.Image}}" "$NAME" 2>/dev/null || true)"
if [ -n "$existing" ]; then
  set -- $existing
  [ "${1:-}" = 1 ] || die 2 "container $NAME exists but was not started by gitlab-up.sh"
  [ "${3:-}" = "$IMAGE" ] || die 2 "container $NAME runs ${3:-another image}, not $IMAGE; run gitlab-down.sh first"
  [ "${2:-}" = true ] || die 2 "container $NAME is stopped; run gitlab-down.sh first"
  if token_works; then
    printf 'GitLab reused at %s (image %s)\n' "$URL" "$IMAGE"
    exit 0
  fi
else
  config="external_url '$URL'; puma['worker_processes'] = 0; sidekiq['concurrency'] = 10; prometheus_monitoring['enable'] = false"
  docker run -d --name "$NAME" --label "$ZENSU_GITLAB_IT_LABEL=1" --memory "$MEMORY" --shm-size 256m \
    -p "127.0.0.1:$PORT:$PORT" -e GITLAB_OMNIBUS_CONFIG="$config" "$IMAGE" >/dev/null \
    || die 1 "docker run failed for $IMAGE"
fi

answering() {
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$URL/users/sign_in" 2>/dev/null || true)" = 200 ] || return 1
  docker exec "$NAME" curl -fsS --max-time 10 "http://127.0.0.1:$PORT/-/readiness?all=1" 2>/dev/null \
    | grep -q '"status":"ok"'
}

deadline=$((started + BOOT_SECONDS))
until answering; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null || echo false)" != true ]; then
    dump_logs
    die 1 "container $NAME stopped during boot"
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    dump_logs
    die 1 "GitLab did not answer $URL/users/sign_in within ${BOOT_SECONDS}s"
  fi
  sleep 5
done
booted="$(date +%s)"

token="glpat-$(node -e 'process.stdout.write(require("crypto").randomBytes(10).toString("hex"))')"
printf '%s' "$token" | docker exec -i -u git "$NAME" sh -c 'umask 077; cat > /tmp/zensu-it-token' \
  || die 1 'cannot hand the token to the container'
docker exec -i -u git "$NAME" sh -c 'umask 077; cat > /tmp/zensu-it-seed.rb' <<'RUBY' || die 1 'cannot hand the token script to the container'
user = User.find_by_username!('root')
token = user.personal_access_tokens.build(name: 'zensu-gitlab-it', scopes: [:api], expires_at: Date.today + 2)
if token.respond_to?(:organization_id=) && token.organization_id.nil? && defined?(Organizations::Organization)
  token.organization_id = Organizations::Organization.order(:id).first&.id
end
token.set_token(File.read('/tmp/zensu-it-token').strip)
token.save!
puts 'token-ready'
RUBY
seeded="$(docker exec "$NAME" gitlab-rails runner /tmp/zensu-it-seed.rb 2>&1 || true)"
docker exec "$NAME" rm -f /tmp/zensu-it-token /tmp/zensu-it-seed.rb >/dev/null 2>&1 || true
case "$seeded" in
  *token-ready*) ;;
  *)
    printf '%s\n' "$seeded" | tail -n 40 >&2
    die 1 'gitlab-rails runner did not create the personal access token'
    ;;
esac

mkdir -p "$STATE"
chmod 700 "$STATE"
(
  umask 077
  printf 'PRIVATE-TOKEN: %s\n' "$token" > "$STATE/header"
  printf '%s' "$token" > "$STATE/token"
)
printf '%s\n' "$URL" > "$STATE/url"
printf '%s\n' "$IMAGE" > "$STATE/image"
token_works || die 1 "the seeded token does not authenticate against $URL/api/v4/user"

finished="$(date +%s)"
printf 'GitLab ready at %s (image %s, answered after %ss, token after %ss)\n' \
  "$URL" "$IMAGE" "$((booted - started))" "$((finished - started))"
