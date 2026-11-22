# dbt-rock
Source code for dbt Rock images.

## Building

    rockcraft pack

The build logic is in `scripts/build.sh` and is parameterised via environment
variables, so a pipeline can build any dbt OSS release:

| Variable           | Default                      | Purpose                                        |
|--------------------|------------------------------|------------------------------------------------|
| `DBT_VERSION`      | `version:` in rockcraft.yaml (release tag, e.g. `v2.0.11`; bare `2.0.11` also accepted) | dbt release to package |
| `DBT_SHA256_AMD64` | (required for amd64 builds)  | SHA256 of the x86_64 release tarball           |
| `DBT_SHA256_ARM64` | (required for arm64 builds)  | SHA256 of the aarch64 release tarball          |
| `DBT_ADBC_DRIVERS` | (required — no default)      | ADBC drivers to cache: space-separated names, `all`, or `none` |

The SHAs come from the release's `SHA256SUMS`. Example:

    DBT_VERSION=v2.0.11 \
    DBT_SHA256_AMD64=bf468f6f43f6d64eb636c2dd9deb7d1eb17f7c57a09d509c0836b44c60688b4c \
    DBT_SHA256_ARM64=68192de14b71e490209104ab7b3ee022be35db0b2b9f4870e50dcd142fe52d9f \
      rockcraft pack

Note: rockcraft 1.x does not interpolate env vars in `rockcraft.yaml`, so the
image's `version:` label stays as written there; a pipeline building other
versions should set it too (e.g. `yq -i '.version = env(DBT_VERSION)' rockcraft.yaml`).
The build fails if `DBT_VERSION` does not match `version:` in rockcraft.yaml
(set `DBT_ALLOW_VERSION_MISMATCH=1` to override).

After packing, smoke test the rock:

    scripts/smoke-test.sh out/dbt_v2.0.11_amd64.rock v2.0.11 postgresql duckdb

See `CI_CD.md` for the full pipeline.

## Image variants

The pipeline builds one image per ADBC driver variant, per arch, tagged
`ghcr.io/<owner>/dbt:<version>-<variant>-<arch>` and published as multi-arch
manifests `<version>-<variant>`: `bigquery`, `clickhouse`, `databricks`, `dbt`,
`duckdb` (ships both `duckdb` and `duckdb_extended`), `mssql`, `postgresql`,
`redshift`, `salesforce`, `spark`, `snowflake`. There is deliberately no bare
`<version>`, `latest`, or combined `default` tag — every image names exactly
one driver variant.

    docker pull ghcr.io/<owner>/dbt:v2.0.11-duckdb       # duckdb + duckdb_extended
    docker pull ghcr.io/<owner>/dbt:v2.0.11-postgresql   # postgresql only Accepted risk: the image sets
`DBT_ALLOW_EXPERIMENTAL_ADAPTERS=true` because the postgresql adapter is
experimental in dbt OSS v2.

## Licenses

- dbt OSS v2 is Apache-2.0, matching `license:` in rockcraft.yaml (also stamped
  as the OCI `org.opencontainers.image.licenses` annotation). The license text
  ships in the image at `/usr/share/doc/dbt/copyright`.
- ADBC drivers: Apache-2.0 (apache/arrow-adbc), except the DuckDB driver (MIT).
  Their sha256 hashes are recorded in `/var/lib/dbt/provenance`.
- Ubuntu slices: per-package copyright texts are kept under
  `/usr/share/doc/*/copyright`; the exact slice list is in
  `/var/lib/chisel/manifest.yaml`.
- CA certificates (`ca-certificates_data`): certificate data under mixed
  licenses; the `ca-certificates` package copyright file is kept.
