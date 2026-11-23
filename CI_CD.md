# CI/CD implementation notes

Implemented as four workflows:

- `.github/workflows/builder-image.yml` — builds and pushes the shared CI
  builder image `ghcr.io/<owner>/dbt-rock-builder` (see "Builder image" below);
  all other workflows run their jobs inside it.

- `.github/workflows/upstream-release.yml` — daily schedule + manual dispatch
  (active once on the default branch). `scripts/check-upstream.sh` resolves
  the newest stable dbt release and its SHA256SUMs; if newer than `version:`,
  it opens a PR from `release/dbt-<version>` with `version:` bumped.
- `.github/workflows/build.yml` — on every PR to main: resolves version +
  SHA256s (`check-upstream.sh --shas`), builds one rock per ADBC driver
  variant x arch, smoke tests, and pushes `pr-<n>-<variant>-<arch>` images
  (no version tag yet). Also runs nightly (schedule, default branch): rebuilds
  the version pinned on main as `nightly-<yyyymmdd>-<variant>` manifests so the
  floating Ubuntu base slices pick up security fixes; the dbt binary and ADBC
  drivers stay pinned by checksum.
- `.github/workflows/release.yml` — on PR merge: promotes the `pr-<n>` images
  to multi-arch `<version>-<variant>` manifests, seeds `latest-<variant>` from
  them, creates the git tag and GitHub release. The temporary `pr-<n>` image
  tags are deleted via the Packages REST API with the default `GITHUB_TOKEN`
  (GHCR has no registry DELETE endpoint, so `skopeo delete` fails with
  "unsupported"; the dbt package is repo-linked and workflow-published, so
  the repository has admin on it and the token may delete versions).
- GHCR has no native retention UI, so `build.yml`'s nightly run also prunes
  via the same API (`scripts/cleanup-tags.sh`): all `pr-*` tags of closed/merged
  PRs (tags of still-open PRs are kept) and all but the newest 60 `nightly-*`
  package versions.
- `latest-<variant>` (e.g. `latest-duckdb`) always points at the newest nightly
  of the latest dbt version: seeded from the release manifest at merge time,
  then re-pointed by every nightly build.

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
4. Build per variant x arch inside the builder image container (jobs run as
   root, so no `sudo`):
   `mkdir -p out && env DBT_VERSION=... DBT_SHA256_AMD64=... DBT_SHA256_ARM64=... DBT_ADBC_DRIVERS=<drivers> rockcraft pack --destructive-mode --build-for <arch> -o out/`
   (`--destructive-mode` chowns the unpacked rootfs, so it needs root; pass the
   `DBT_*` vars via `env` explicitly; rockcraft does not create the `-o` dir
   itself. Host env propagates into the build.)
5. Smoke test:
   `scripts/smoke-test.sh out/dbt_${DBT_VERSION}_<variant>_<arch>.rock "$DBT_VERSION" <drivers...>`
6. Push each `.rock` with skopeo (`oci-archive:` transport — .rock files are OCI
   archives, not docker-archives) to `ghcr.io/<owner>/dbt:pr-<n>-<variant>-<arch>`
   (build.yml); release.yml on merge re-tags them into the multi-arch
   `<version>-<variant>` manifests. Registry credentials are the default
   GITHUB_TOKEN; there are no other secrets — releases are public and
   checksum-gated.

## Builder image (all workflow jobs run inside it)

All jobs of build.yml, release.yml and upstream-release.yml run inside
`ghcr.io/<owner>/dbt-rock-builder:v1` (`builder/Dockerfile`, built and pushed
by `.github/workflows/builder-image.yml`), so no step installs tools on the
runner anymore. This also removes the flaky `snap install rockcraft` step:
when snapd self-refreshes mid-install, the snap CLI fails with
`Waiting for automatic snapd restart...` / `The operation was canceled.` even
though the snap actually got installed.

- rockcraft 1.x is distributed as a classic snap only — there is no public
  `ghcr.io/canonical/rockcraft` OCI image — so the image vendors the snap the
  same way the official `snapcore/snapcraft` image does: the `.snap` is
  downloaded from the Snap Store API and `unsquashfs`-ed to
  `/snap/rockcraft/current`. The snap's binaries request the core24 base
  snap's ELF loader, so core24 is vendored at `/snap/core24/current` too.
  `SNAP`/`SNAP_NAME=rockcraft` are set so rockcraft resolves its bundled
  `umoci`/`skopeo` via `$SNAP/bin` exactly like under snapd; the binaries are
  also symlinked into `/usr/local/bin`.
- rockcraft stages the `pebble` snap into every rock by running
  `snap download pebble`, which needs snapd on a host. A job container has no
  snapd (and cannot run one unprivileged), so the image ships a `snap` shim
  (`builder/snap-shim`) that implements `snap download` against the public
  Snap Store API.
- Also baked in (pinned versions): docker CLI (talks to the host daemon via the
  `/var/run/docker.sock` that the runner mounts into job containers), `gh`,
  `git`, `jq`, `curl`, `shellcheck`, `actionlint`.
- The image is versioned separately from the dbt rocks, as its own GHCR
  package `dbt-rock-builder`: `v1` + `latest` (mutable, rebuilt on pushes to
  main that touch `builder/**` or the builder workflow) and `sha-<n>`
  (immutable, for rollback). The workflows reference `:v1`. Bootstrap: the
  first `:v1` is pushed by the first run on main; to validate a PR that
  changes the builder before that, run `builder-image` manually on the PR
  branch (workflow_dispatch pushes `:v1` from that branch).
- Jobs run as root inside the container (rockcraft `--destructive-mode` chowns
  the unpacked rootfs). The runner OS only picks the host that runs the
  container, and the image is multi-arch (amd64 + arm64), so the arm64 build
  cells use it too.

## Runner requirements

- runners: `ubuntu-latest` (amd64) and `ubuntu-26.04-arm` (arm64); the runner
  OS does not affect the rock content (rockcraft builds the rootfs from
  `build-base` itself, inside the builder container).
  Note: there is **no `ubuntu-latest-arm` label** (that alias exists only for
  macOS) — Ubuntu arm64 runners only have versioned labels (`ubuntu-26.04-arm`,
  `ubuntu-24.04-arm`, ...), so keep the arm label in sync with what
  `ubuntu-latest` points to. GitHub has no queue timeout for hosted runners —
  `timeout-minutes` only covers execution — so a `runs-on` label that matches
  no runner leaves the job queued forever; cancel the run manually in that case.
  Arm runners are also a smaller shared pool, so arm jobs may legitimately wait
  at "Waiting for a runner to pick up this job" while amd64 jobs start
  immediately (build.yml uses max-parallel: 22 so waiting arm jobs don't block
  amd64 ones).
- the runner mounts the workspace and `/var/run/docker.sock` into job
  containers (smoke test + `docker manifest` commands use the host daemon)
- network access to `github.com`, `ghcr.io` and `public.cdn.getdbt.com` (driver
  downloads at build time); `api.snapcraft.io` only for builder-image builds

## Guardrails already enforced in the build

- every image carries a `com.getdbt.adbc-driver` OCI manifest annotation naming
  the bundled ADBC driver variant (set post-pack via the umoci bundled in the
  rockcraft snap, since rockcraft 1.x has no custom annotations key)

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
- `build-base: ubuntu@26.04` floats with Ubuntu updates — good for security
  patches, less bit-reproducible. The nightly build short-circuits when the
  base digest is unchanged: the digest is embedded in the nightly tag
  (`nightly-<yyyymmdd>-<digest12>-<variant>`) and recorded in the image's
  /var/lib/dbt/provenance (bare-base rocks carry no base-digest OCI annotation).
