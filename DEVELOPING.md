# Developing dbt-rock

How to test changes locally before pushing (several past bugs were only
reproducible in CI; this harness exists to catch them earlier).

## Prerequisites

Easiest — use the published builder image, the exact toolchain CI uses (only
docker is needed on the host; no snapd required):

    docker pull ghcr.io/<owner>/dbt-rock-builder:v1
    docker run --rm -it -v /var/run/docker.sock:/var/run/docker.sock \
      -v "$PWD":/work -w /work ghcr.io/<owner>/dbt-rock-builder:v1 bash
    # inside the container (running as root, like the CI job containers):
    bash -n scripts/*.sh && shellcheck scripts/*.sh
    actionlint .github/workflows/*.yml
    bash scripts/check-upstream.sh
    scripts/local-build-test.sh duckdb amd64

To build the image yourself from a checkout instead of pulling it:
`docker build -t dbt-rock-builder:dev builder/` (see
`.github/workflows/builder-image.yml` for how CI builds/pushes it).

Alternatively install the tools natively on an Ubuntu 24.04+/26.04 machine:
`sudo snap install rockcraft --channel=latest/stable --classic`,
`sudo apt-get install -y docker.io skopeo jq shellcheck`, plus the actionlint
release binary (pinned, same as the lint job). Plus network access to
`github.com`, `ghcr.io` and `public.cdn.getdbt.com`, and a running docker
daemon (`sudo systemctl start docker`, your user in the `docker` group).

## Quick checks (no root needed)

    bash -n scripts/*.sh                 # syntax
    shellcheck scripts/*.sh              # shell lint
    actionlint .github/workflows/*.yml   # workflow syntax + expression contexts
                                           # (catches e.g. `env` used in strategy.matrix,
                                           # bad runs-on labels need a runner though)
    bash scripts/check-upstream.sh                  # prints upgrade=... for the pinned version
    bash scripts/check-upstream.sh --shas v2.0.11   # prints the release tarball SHA256s

## Full local build + smoke test

Builds one rock exactly like the CI `build` job (same env vars, destructive
mode — needs root, so either run inside the builder image as above or with
`sudo` on a native setup) and runs the same smoke test:

    scripts/local-build-test.sh duckdb amd64
    # other variants: bigquery clickhouse databricks dbt mssql postgresql redshift salesforce spark snowflake
    # arch: amd64 or arm64 (arm64 needs an arm64 machine)

The script resolves the pinned `version:` from `rockcraft.yaml`, fetches the
SHA256s via `check-upstream.sh --shas`, packs with rockcraft and runs
`scripts/smoke-test.sh` (dbt --version, cached ADBC drivers, cache ownership).
The smoke test needs the docker daemon — when running inside the builder
image, mount the host socket as shown above.

## What cannot be tested locally

- GitHub-hosted runner labels (`ubuntu-latest`, `ubuntu-26.04-arm`) and queue
  behavior — check `Requested labels:` in the job log if a job never starts.
- Artifact upload/download action version skew — keep `upload-artifact` and
  `download-artifact` on the same major.
- The `GITHUB_TOKEN` permissions per job — declared at workflow level.
- Pulling `ghcr.io/<owner>/dbt-rock-builder:v1` from a PR before the first
  `builder-image` run on main — run the `builder-image` workflow manually on
  the branch once (workflow_dispatch) to push `:v1`.

CI (`.github/workflows/build.yml` on PRs) remains the final gate.
