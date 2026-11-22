#!/usr/bin/env bash
# Local end-to-end test of the rock build + smoke test, without GitHub Actions.
#
# Usage: sudo scripts/local-build-test.sh [variant] [arch]
#   e.g. sudo scripts/local-build-test.sh duckdb amd64
#
# Needs: snap rockcraft (latest/stable), docker, skopeo, jq, network access to
# github.com and public.cdn.getdbt.com. Run with sudo because rockcraft
# --destructive-mode chowns the rootfs. Produces and smoke-tests one rock for
# one variant/arch, exactly like the CI build job does.
set -euo pipefail
variant="${1:-duckdb}"
arch="${2:-amd64}"
cd "$(dirname "$0")/.."

v=$(sed -n 's/^version:[[:space:]]*"\([^"]*\)".*/\1/p' rockcraft.yaml | head -n 1)
echo "pinned dbt version: $v; testing variant=$variant arch=$arch"

# resolve tarball checksums the same way CI does
eval "$(env -u GITHUB_OUTPUT bash scripts/check-upstream.sh --shas "$v")"
: "${sha_amd64:?}" "${sha_arm64:?}"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/out"

env DBT_VERSION="$v" DBT_SHA256_AMD64="$sha_amd64" DBT_SHA256_ARM64="$sha_arm64" \
  DBT_ADBC_DRIVERS="$variant" \
  rockcraft pack --destructive-mode --build-for "$arch" -o "$work/out/"

rock="$work/out/dbt_${v}_${arch}.rock"
echo "packed $rock"
bash scripts/smoke-test.sh "$rock" "$v" "$variant"
echo "local build + smoke test OK: $v $variant $arch"
