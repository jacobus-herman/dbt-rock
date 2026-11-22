# Developing dbt-rock

How to test changes locally before pushing (several past bugs were only
reproducible in CI; this harness exists to catch them earlier).

## Prerequisites (Ubuntu 24.04+/26.04 dev machine)

    sudo snap install rockcraft --channel=latest/stable --classic
    sudo apt-get install -y docker.io skopeo jq shellcheck
    # actionlint validates the workflow files incl. GitHub expressions
    # (pinned to a release asset, same as the lint job in build.yml):
    curl -fsSLo actionlint.tgz https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz && tar xzf actionlint.tgz actionlint && sudo mv actionlint /usr/local/bin/

Plus: network access to `github.com`, `ghcr.io` and `public.cdn.getdbt.com`,
and docker daemon running (`sudo systemctl start docker`, your user in the
`docker` group).

## Quick checks (no root needed)

    bash -n scripts/*.sh                 # syntax
    shellcheck scripts/*.sh              # shell lint
    actionlint .github/workflows/*.yml   # workflow syntax + expression contexts
                                           # (catches e.g. `env` used in strategy.matrix,
                                           # bad runs-on labels need a runner though)
    bash scripts/check-upstream.sh                  # prints upgrade=... for the pinned version
    bash scripts/check-upstream.sh --shas v2.0.11   # prints the release tarball SHA256s

## Full local build + smoke test (needs sudo)

Builds one rock exactly like the CI `build` job (same env vars, destructive
mode) and runs the same smoke test:

    sudo scripts/local-build-test.sh duckdb amd64
    # other variants: bigquery clickhouse databricks dbt mssql postgresql redshift salesforce spark snowflake
    # arch: amd64 or arm64 (arm64 needs an arm64 machine)

The script resolves the pinned `version:` from `rockcraft.yaml`, fetches the
SHA256s via `check-upstream.sh --shas`, packs with rockcraft and runs
`scripts/smoke-test.sh` (dbt --version, cached ADBC drivers, cache ownership).

## What cannot be tested locally

- GitHub-hosted runner labels (`ubuntu-latest`, `ubuntu-26.04-arm`) and queue
  behavior — check `Requested labels:` in the job log if a job never starts.
- Artifact upload/download action version skew — keep `upload-artifact` and
  `download-artifact` on the same major.
- `sudo` env handling on runners (`-E` is ignored; CI passes vars via `env`).
- The `GITHUB_TOKEN` permissions per job — declared at workflow level.

CI (`.github/workflows/build.yml` on PRs) remains the final gate.
