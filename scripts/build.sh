#!/usr/bin/env bash
# Build script for the dbt part (invoked from override-build in rockcraft.yaml).
#
# Parameterised via environment variables so a build pipeline can package any
# dbt OSS release:
#   DBT_VERSION        dbt OSS release tag, e.g. "v2.0.11" (bare "2.0.11" also
#                      accepted). Defaults to `version:` in rockcraft.yaml and
#                      must match it unless DBT_ALLOW_VERSION_MISMATCH=1.
#   DBT_SHA256_AMD64   SHA256 of dbt-core-<ver>-x86_64-unknown-linux-gnu.tar.gz
#   DBT_SHA256_ARM64   SHA256 of dbt-core-<ver>-aarch64-unknown-linux-gnu.tar.gz
#                      Only the one for the arch being built is required; take
#                      them from the release's SHA256SUMS file.
#   DBT_ADBC_DRIVERS   Required, no default. Space-separated ADBC drivers to
#                      cache, "all" to cache every driver, or "none" to ship
#                      no cached drivers.
set -euo pipefail

yaml_version=$(sed -n 's/^version:[[:space:]]*"\([^"]*\)".*/\1/p' "$CRAFT_PROJECT_DIR/rockcraft.yaml" | head -n 1)
DBT_VERSION="${DBT_VERSION:-$yaml_version}"
: "${DBT_VERSION:?set DBT_VERSION or keep version: in rockcraft.yaml}"
# The git/URL tag keeps the "v", the tarball asset name drops it.
ver="${DBT_VERSION#v}"
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || {
  echo "DBT_VERSION must look like v2.0.11, got: $DBT_VERSION" >&2; exit 1; }
if [ "$ver" != "${yaml_version#v}" ] && [ "${DBT_ALLOW_VERSION_MISMATCH:-0}" != "1" ]; then
  echo "DBT_VERSION ($DBT_VERSION) does not match rockcraft.yaml version ($yaml_version); update version: or set DBT_ALLOW_VERSION_MISMATCH=1" >&2
  exit 1
fi
tag="v${ver}"
: "${DBT_ADBC_DRIVERS:?set DBT_ADBC_DRIVERS: space-separated drivers to cache, 'all', or 'none'}"

# release tarballs are per-arch; checksums from the release's SHA256SUMS
case "$CRAFT_ARCH_BUILD_FOR" in
  amd64) plat="x86_64-unknown-linux-gnu"; sha_var="DBT_SHA256_AMD64" ;;
  arm64) plat="aarch64-unknown-linux-gnu"; sha_var="DBT_SHA256_ARM64" ;;
  *) echo "unsupported build arch: $CRAFT_ARCH_BUILD_FOR" >&2; exit 1 ;;
esac
sha="${!sha_var:-}"
if [ -z "$sha" ]; then
  echo "$sha_var must be set: SHA256 of dbt-core-${ver}-${plat}.tar.gz" >&2
  exit 1
fi

url="https://github.com/dbt-labs/dbt/releases/download/${tag}/dbt-core-${ver}-${plat}.tar.gz"
curl -fsSL --retry 3 "$url" -o "$CRAFT_PART_SRC/dbt.tar.gz"
echo "$sha  $CRAFT_PART_SRC/dbt.tar.gz" | sha256sum -c -
tar -xzf "$CRAFT_PART_SRC/dbt.tar.gz" -C "$CRAFT_PART_SRC"
src_dir=$(echo "$CRAFT_PART_SRC"/dbt-core-*)
install -Dm755 "$src_dir/dbt" "$CRAFT_PART_INSTALL/usr/bin/dbt"
# Ship the license text that came with the checksum-verified tarball; if the
# tarball has none, take it from the repo at the pinned tag.
if [ -f "$src_dir/LICENSE" ]; then
  install -Dm644 "$src_dir/LICENSE" "$CRAFT_PART_INSTALL/usr/share/doc/dbt/copyright"
else
  curl -fsSL --retry 3 "https://raw.githubusercontent.com/dbt-labs/dbt/${tag}/LICENSE" \
    | install -Dm644 /dev/stdin "$CRAFT_PART_INSTALL/usr/share/doc/dbt/copyright"
fi

# Pre-cache ADBC drivers so the runtime needs no CDN access.
# "none" skips the download entirely; "all" keeps everything install-drivers
# fetches; otherwise prune down to the listed adapters (one driver per dbt
# project is the norm).
cache_dir="$CRAFT_PART_INSTALL/var/cache/dbt"
if [ "$DBT_ADBC_DRIVERS" != "none" ]; then
  XDG_CACHE_HOME="$cache_dir" \
    "$CRAFT_PART_INSTALL/usr/bin/dbt" system install-drivers
  if [ "$DBT_ADBC_DRIVERS" != "all" ]; then
    for so in "$cache_dir/com.getdbt/adbc/"*/*.so; do
      base=$(basename "$so")
      keep_it=0
      for k in $DBT_ADBC_DRIVERS; do
        # match libadbc_driver_<name>-<ver>.so and libadbc_driver_<name>_<variant>-<ver>.so,
        # so e.g. "duckdb" also keeps duckdb_extended
        case "$base" in
          "libadbc_driver_${k}-"*|"libadbc_driver_${k}_"*) keep_it=1 ;;
        esac
      done
      if [ "$keep_it" -eq 0 ]; then rm -f "$so"; fi
    done
    find "$cache_dir" -type d -empty -delete
  fi
fi
# Record what was downloaded; the chisel manifest only covers the slices.
prov="$CRAFT_PART_INSTALL/var/lib/dbt/provenance"
mkdir -p "$(dirname "$prov")"
{
  echo "dbt_version: $ver"
  echo "tarball_url: $url"
  echo "tarball_sha256: $sha"
  # set by the nightly build workflow (digest of the floating build-base image)
  if [ -n "${DBT_BASE_DIGEST:-}" ]; then echo "build_base_digest: $DBT_BASE_DIGEST"; fi
  echo "adbc_drivers: $DBT_ADBC_DRIVERS"
  licenses="Apache-2.0 (arrow-adbc)"
  case " $DBT_ADBC_DRIVERS " in *" duckdb "*|*" all "*) licenses="$licenses, MIT (duckdb)" ;; esac
  echo "license: Apache-2.0 (dbt OSS); ADBC drivers: $licenses"
  if [ -d "$cache_dir" ]; then
    (cd "$cache_dir" && find . -name '*.so' -exec sha256sum {} +)
  fi
} > "$prov"
# Writable only by the run user. rockcraft maps run-user _daemon_ to a fixed
# uid/gid 584792 in every rock (rockcraft/usernames.py), so chown by number;
# by name it would resolve to uid 1 in the build base and not match at runtime.
# scripts/smoke-test.sh asserts this owner matches the image's configured user.
if [ -d "$cache_dir" ]; then
  chown -R 584792:584792 "$cache_dir"
  chmod -R u+rwX,go+rX "$cache_dir"
fi
