#!/usr/bin/env bash
# Smoke test a packed dbt rock: the binary runs and prints the expected
# version, and the expected ADBC drivers are cached. Needs docker + skopeo.
# Usage: scripts/smoke-test.sh path/to/dbt_<version>_<arch>.rock <version-tag> [driver...]
#   e.g. scripts/smoke-test.sh out/dbt_v2.0.11_amd64.rock v2.0.11 postgresql duckdb
set -euo pipefail
rock="$1"; want="$2"; shift 2
img="dbt-smoke:ci"
# .rock files are OCI archives (index.json), not docker-archive (manifest.json)
skopeo copy "oci-archive:$rock" "docker-daemon:$img"
# NB: with pipefail, `... | grep -q` / `... | head -1` can fail with SIGPIPE when
# the reader exits early (big images) — capture into variables and match with
# here-strings instead
ver_out=$(docker run --rm --entrypoint /usr/bin/dbt "$img" --version)
grep -q "${want#v}" <<<"$ver_out"
ctr=$(docker create "$img")
trap 'docker rm -f "$ctr" >/dev/null' EXIT
list=$(docker cp "$ctr:/var/cache/dbt" - | tar -t)
grep -q 'com.getdbt/adbc/.*\.so$' <<<"$list"
for d in "$@"; do
  grep -q "libadbc_driver_${d}-" <<<"$list" || { echo "missing driver: $d" >&2; exit 1; }
done
# the cache dir must be owned by the image's run user (rockcraft fixes _daemon_
# at uid 584792), so a rockcraft change to that uid fails here instead of
# silently making the cache read-only at runtime
user=$(docker inspect --format '{{.Config.User}}' "$img")
# docker export tar entries have no leading slash, so the pattern must not start with */
listing=$(docker export "$ctr" | tar -tv --wildcards 'var/cache/dbt')
owner=$(head -n 1 <<<"$listing" | awk '{print $2}' | cut -d/ -f1)
[ "$owner" = "$user" ] || { echo "cache dir owner $owner != image user $user" >&2; exit 1; }
echo "smoke OK: $want"
