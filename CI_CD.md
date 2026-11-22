# CI/CD implementation notes

Implemented as three workflows:

- `.github/workflows/upstream-release.yml` — daily schedule + manual dispatch
  (active once on the default branch). `scripts/check-upstream.sh` resolves
  the newest stable dbt release and its SHA256SUMs; if newer than `version:`,
  it opens a PR from `release/dbt-<version>` with `version:` bumped.
- `.github/workflows/build.yml` — on every PR to main: resolves version +
  SHA256s (`check-upstream.sh --shas`), builds one rock per ADBC driver
  variant x arch, smoke tests, and pushes `pr-<n>-<variant>-<arch>` images
  (no version tag yet).
- `.github/workflows/release.yml` — on PR merge: promotes the `pr-<n>` images
  to multi-arch `<version>-<variant>` manifests, deletes the pr tags, creates
  the git tag and GitHub release.

Pipeline shape: scheduled check for a new release tag in `dbt-labs/dbt` →
release PR → per-variant per-arch build on the PR (images tagged
`pr-<n>-<variant>-<arch>`) → on merge, promote to multi-arch
`<version>-<variant>` manifests (no bare `<version>`, `latest`, or combined
default tag — every image names exactly one driver variant).
Variants: one per driver, with `duckdb` shipping both duckdb and duckdb_extended.

## Steps (per dbt release tag, e.g. `v2.0.11`)

1. Resolve inputs — never hand-copy hashes:
   `DBT_VERSION=<tag>`; fetch
   `https://github.com/dbt-labs/dbt/releases/download/$DBT_VERSION/SHA256SUMS`
   and parse out `DBT_SHA256_AMD64` / `DBT_SHA256_ARM64`.
2. Align the image label with the release (rockcraft 1.x cannot interpolate
   env vars in `rockcraft.yaml`):
   `yq -i '.version = env(DBT_VERSION)' rockcraft.yaml`
   The build also self-checks this and fails on mismatch
   (override only with `DBT_ALLOW_VERSION_MISMATCH=1`).
3. Lint: `shellcheck scripts/build.sh` and `rockcraft expand-extensions`.
4. Build per variant x arch on matching runners:
   `DBT_ADBC_DRIVERS=<drivers> rockcraft pack --build-for <arch> -o out/`
   (LXD by default; `--destructive-mode` is fine on disposable runners. Host
   env vars propagate into the build, so export the `DBT_*` vars first.)
5. Smoke test:
   `scripts/smoke-test.sh out/dbt_${DBT_VERSION}_<variant>_<arch>.rock "$DBT_VERSION" <drivers...>`
6. Push each `.rock` with skopeo to `ghcr.io/<owner>/dbt:pr-<n>-<variant>-<arch>`
   (build.yml); release.yml on merge re-tags them into the multi-arch
   `<version>-<variant>` manifests. Registry credentials are the default
   GITHUB_TOKEN; there are no other secrets — releases are public and
   checksum-gated.

## Runner requirements

- rockcraft pinned to the 1.x channel — this yaml uses 1.x schema
  (`snap install rockcraft --channel=1.x/stable --classic`)
- `yq`, `shellcheck`, `skopeo`, `docker`
- network access to `github.com` and `public.cdn.getdbt.com` (driver downloads
  at build time)

## Guardrails already enforced in the build

- tarball sha256 verified against the release's SHA256SUMS (build fails on mismatch)
- `DBT_VERSION` must match `version:` in rockcraft.yaml
- provenance (dbt version, tarball URL+sha256, sha256 of each cached driver
  `.so`) is written to `/var/lib/dbt/provenance` inside the image — the chisel
  manifest only covers the Ubuntu slices
- driver cache is writable only by the runtime user (`_daemon_`, uid/gid 584792
  — the fixed mapping rockcraft applies to `run-user` in every rock), not
  world-writable; the smoke test asserts the owner matches the image user
- image runs as `_daemon_`, `base: bare`, chiselled slices only, license texts kept

## Accepted risks

- `DBT_ALLOW_EXPERIMENTAL_ADAPTERS=true` ships the experimental postgresql
  adapter (required for the cached driver to load).
- `build-base: ubuntu@24.04` floats with Ubuntu updates — good for security
  patches, less bit-reproducible; rockcraft records the base digest in the OCI
  annotations.
