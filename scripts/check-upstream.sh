#!/usr/bin/env bash
# Check whether dbt-labs/dbt has a newer stable release than the `version:`
# pinned in rockcraft.yaml, and if so resolve that release's tarball checksums.
#
# Emits key=value lines to $GITHUB_OUTPUT (or stdout when unset):
#   upgrade=true|false
#   dbt_version=<tag>      e.g. v2.0.12   (only set when upgrade=true)
#   sha_amd64=<sha256>     of dbt-core-<ver>-x86_64-unknown-linux-gnu.tar.gz
#   sha_arm64=<sha256>     of dbt-core-<ver>-aarch64-unknown-linux-gnu.tar.gz
#
# Used by .github/workflows/upstream-release.yml; also runnable locally.
# Needs curl + jq.
set -euo pipefail

upstream="dbt-labs/dbt"

# Resolve just the tarball checksums for a given release tag (used by
# build.yml on pull requests, where there is no check job to inherit them from):
#   check-upstream.sh --shas v2.0.11   →  sha_amd64=... / sha_arm64=...
if [ "${1:-}" = "--shas" ]; then
  t="${2:?usage: check-upstream.sh --shas <release-tag>}"
  v="${t#v}"
  sums=$(curl -fsSL "https://github.com/${upstream}/releases/download/${t}/SHA256SUMS")
  out="${GITHUB_OUTPUT:-/dev/stdout}"
  sha_amd64=$(awk -v a="dbt-core-${v}-x86_64-unknown-linux-gnu.tar.gz" '$2 == a {print $1}' <<<"$sums")
  sha_arm64=$(awk -v b="dbt-core-${v}-aarch64-unknown-linux-gnu.tar.gz" '$2 == b {print $1}' <<<"$sums")
  if [ -z "$sha_amd64" ] || [ -z "$sha_arm64" ]; then
    echo "tarball checksums not found in ${upstream} ${t} SHA256SUMS" >&2
    exit 1
  fi
  {
    echo "sha_amd64=$sha_amd64"
    echo "sha_arm64=$sha_arm64"
  } >> "$out"
  exit 0
fi

current=$(sed -n 's/^version:[[:space:]]*"\([^"]*\)".*/\1/p' rockcraft.yaml | head -n 1)
current_ver="${current#v}"

# Newest stable (non-draft, non-prerelease) vX.Y.Z tag by semver, scanning the
# 100 most recent releases.
mapfile -t tags < <(
  curl -fsSL -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${upstream}/releases?per_page=100" \
    | jq -r '.[] | select(.draft | not) | select(.prerelease | not) | .tag_name'
)
cands=()
for t in "${tags[@]}"; do
  v="${t#v}"
  if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    cands+=("$v")
  fi
done
if [ "${#cands[@]}" -eq 0 ]; then
  # fail loudly instead of silently reporting upgrade=false on an API hiccup
  echo "no stable vX.Y.Z release tags found in ${upstream} (API or parsing failure?)" >&2
  exit 1
fi
latest=$(printf '%s\n' "${cands[@]}" | sort -V | tail -n 1)

# sort -V decides: upgrade only if latest is strictly greater than current
# (lexicographic compare would wrongly rank 2.0.9 > 2.0.11).
upgrade=false
if [ -n "$latest" ] && [ "$latest" != "$current_ver" ] \
   && [ "$latest" = "$(printf '%s\n%s\n' "$current_ver" "$latest" | sort -V | tail -n 1)" ]; then
  upgrade=true
fi

dbt_version="" sha_amd64="" sha_arm64=""
if [ "$upgrade" = true ]; then
  dbt_version="v${latest}"
  sums=$(curl -fsSL "https://github.com/${upstream}/releases/download/${dbt_version}/SHA256SUMS")
  sha_amd64=$(awk -v f="dbt-core-${latest}-x86_64-unknown-linux-gnu.tar.gz" '$2 == f {print $1}' <<<"$sums")
  sha_arm64=$(awk -v f="dbt-core-${latest}-aarch64-unknown-linux-gnu.tar.gz" '$2 == f {print $1}' <<<"$sums")
  if [ -z "$sha_amd64" ] || [ -z "$sha_arm64" ]; then
    echo "tarball checksums not found in ${upstream} ${dbt_version} SHA256SUMS" >&2
    exit 1
  fi
fi

out="${GITHUB_OUTPUT:-/dev/stdout}"
{
  echo "upgrade=$upgrade"
  echo "dbt_version=$dbt_version"
  echo "sha_amd64=$sha_amd64"
  echo "sha_arm64=$sha_arm64"
} >> "$out"
echo "current=$current_ver latest=${latest:-none} upgrade=$upgrade"
