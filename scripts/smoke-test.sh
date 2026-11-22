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
docker run --rm --entrypoint /usr/bin/dbt "$img" --version | grep -q "${want#v}"
ctr=$(docker create "$img")
trap 'docker rm -f "$ctr" >/dev/null' EXIT
list=$(docker cp "$ctr:/var/cache/dbt" - | tar -t)
echo "$list" | grep -q 'com.getdbt/adbc/.*\.so$'
for d in "$@"; do
  echo "$list" | grep -q "libadbc_driver_${d}-" || { echo "missing driver: $d" >&2; exit 1; }
done
# the cache dir must be owned by the image's run user (rockcraft fixes _daemon_
# at uid 584792), so a rockcraft change to that uid fails here instead of
# silently making the cache read-only at runtime
user=$(docker inspect --format '{{.Config.User}}' "$img")
owner=$(docker export "$ctr" | tar -tv --wildcards '*/var/cache/dbt' | head -1 | awk '{print $2}' | cut -d/ -f1)
[ "$owner" = "$user" ] || { echo "cache dir owner $owner != image user $user" >&2; exit 1; }
echo "smoke OK: $want"
