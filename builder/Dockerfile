# syntax=docker/dockerfile:1
#
# Shared CI builder image for the dbt-rock workflows. build.yml, release.yml
# and upstream-release.yml run their jobs inside this container, so no step
# has to apt/snap-install tools on the runner anymore. That removes the flaky
# `snap install rockcraft` step (when snapd self-refreshes mid-install the
# snap CLI dies with "Waiting for automatic snapd restart..." /
# "The operation was canceled.") and gives every job pinned tool versions.
#
# rockcraft 1.x is distributed as a classic snap only (there is no official
# ghcr.io/canonical/rockcraft image), so this image vendors the snap the same
# way the official snapcore/snapcraft image does: download the .snap from the
# Snap Store API and unsquashfs it to /snap/<name>/current. The snap's
# binaries request the core24 base snap's ELF loader
# (/snap/core24/current/lib64/ld-linux-*.so) and RPATH its libs, so the core24
# base snap is vendored as well.
#
# Built and pushed (multi-arch) by .github/workflows/builder-image.yml to
# ghcr.io/<owner>/dbt-rock-builder. Use locally:
#   docker run --rm -it -v "$PWD":/work -w /work \
#     ghcr.io/<owner>/dbt-rock-builder:v1 bash

ARG BASE_IMAGE=ubuntu:26.04
FROM ${BASE_IMAGE}

# TARGETARCH is provided automatically by docker buildx (amd64 / arm64); plain
# `docker build` leaves it empty, so fall back to the host arch.
ARG TARGETARCH
ARG ROCKCRAFT_CHANNEL=latest/stable # no 1.x snap track exists; latest/stable is 1.x
ARG CORE24_CHANNEL=latest/stable
ARG DOCKER_CLI_VERSION=29.10.0      # CLI only; the daemon is the runner's (mounted socket)
ARG GH_VERSION=2.105.0
ARG ACTIONLINT_VERSION=1.7.12

ENV DEBIAN_FRONTEND=noninteractive

# CLI tools the workflows and scripts call directly.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq shellcheck squashfs-tools tar xz-utils \
    && rm -rf /var/lib/apt/lists/*

# The runner bind-mounts the workspace into the job container owned by the
# runner uid, while the container runs as root — git then refuses the repo
# ("detected dubious ownership") for every git/gh call in a step. The
# container is an ephemeral CI sandbox, so allow any repo path for root.
RUN git config --global --add safe.directory '*'

# docker CLI (static build) — talks to the host daemon through the
# /var/run/docker.sock that the Actions runner mounts into job containers.
# NB: download.docker.com uses x86_64/aarch64, not amd64/arm64.
RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in amd64) darch=x86_64 ;; arm64) darch=aarch64 ;; *) darch="$arch" ;; esac; \
    curl -fsSL "https://download.docker.com/linux/static/stable/${darch}/docker-${DOCKER_CLI_VERSION}.tgz" \
      | tar -xz --strip-components=1 -C /usr/local/bin docker/docker

# GitHub CLI (static build).
RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.tar.gz" \
      | tar -xz --strip-components=2 -C /usr/local/bin "gh_${GH_VERSION}_linux_${arch}/bin/gh"

# actionlint (validates the workflow files in build.yml's lint job).
RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    curl -fsSL "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_${arch}.tar.gz" \
      | tar -xz -C /usr/local/bin actionlint

# `snap download` shim: rockcraft stages the pebble snap into every rock by
# running `snap download`, which needs snapd on a host. The job container has
# no snapd (and cannot run one unprivileged), so the shim resolves snaps from
# the public Snap Store API instead. craft-parts only ever calls
# `snap download <name> --channel <ch>` inside a container.
COPY snap-shim /usr/local/bin/snap
RUN chmod 0755 /usr/local/bin/snap

# The snap-bundled skopeo (unlike the apt one) ships no containers policy;
# without /etc/containers/policy.json every skopeo copy fails with
# "Error loading trust policy". Ship the same default the distro package uses.
RUN mkdir -p /etc/containers && printf '%s\n' \
      '{ "default": [{ "type": "insecureAcceptAnything" }] }' \
      > /etc/containers/policy.json

# Vendor the core24 base snap and the rockcraft snap, unsquashed to the paths
# snapd would use. The Snap Store v2 API maps channel+arch -> download URL.
RUN set -eux; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    fetch_snap() { \
      name="$1"; channel="$2"; out="$3"; \
      track="${channel%%/*}"; risk="${channel##*/}"; \
      curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 \
        -H 'Snap-Device-Series: 16' -H "Snap-Device-Channel: ${channel}" \
        "https://api.snapcraft.io/v2/snaps/info/${name}" -o "${out}.raw"; \
      jq -r --arg a "${arch}" --arg t "${track}" --arg r "${risk}" \
        '.["channel-map"][] | select(.channel.track==$t and .channel.risk==$r and .channel.architecture==$a) | [.revision, .version, .download.url] | @tsv' \
        "${out}.raw" > "$out"; \
    }; \
    fetch_snap core24 "${CORE24_CHANNEL}" /tmp/core24.tsv; \
    fetch_snap rockcraft "${ROCKCRAFT_CHANNEL}" /tmp/rockcraft.tsv; \
    read -r core_rev core_ver core_url < /tmp/core24.tsv; \
    read -r rc_rev rc_ver rc_url < /tmp/rockcraft.tsv; \
    test -n "${rc_url}" || { echo "no rockcraft snap for ${arch} on ${ROCKCRAFT_CHANNEL}" >&2; exit 1; }; \
    echo "core24 rev=${core_rev} ${core_ver}; rockcraft rev=${rc_rev} ${rc_ver} (${ROCKCRAFT_CHANNEL}, ${arch})"; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${core_url}" -o /tmp/core24.snap; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 "${rc_url}" -o /tmp/rockcraft.snap; \
    mkdir -p /snap/core24/current /snap/rockcraft/current /snap/bin; \
    unsquashfs -f -d /snap/core24/current /tmp/core24.snap; \
    unsquashfs -f -d /snap/rockcraft/current /tmp/rockcraft.snap; \
    rm -f /tmp/core24.snap /tmp/rockcraft.snap /tmp/core24.tsv /tmp/rockcraft.tsv /tmp/core24.tsv.raw /tmp/rockcraft.tsv.raw; \
    printf 'rockcraft %s (snap rev %s, channel %s)\ncore24 %s (snap rev %s)\n' \
      "${rc_ver}" "${rc_rev}" "${ROCKCRAFT_CHANNEL}" "${core_ver}" "${core_rev}" \
      > /usr/local/share/dbt-rock-builder.txt

# Put the snap's tools on PATH and replicate the environment snapd sets for
# the classic rockcraft snap: rockcraft resolves its bundled umoci/skopeo via
# $SNAP/bin only when SNAP_NAME=rockcraft, otherwise via PATH (both work here).
RUN set -eux; \
    ln -sf /snap/rockcraft/current/bin/rockcraft /usr/local/bin/rockcraft; \
    ln -sf /snap/rockcraft/current/bin/umoci /usr/local/bin/umoci; \
    ln -sf /snap/rockcraft/current/bin/skopeo /usr/local/bin/skopeo; \
    mkdir -p /var/snap/rockcraft/current /var/snap/rockcraft/common

ENV SNAP=/snap/rockcraft/current \
    SNAP_NAME=rockcraft \
    SNAP_DATA=/var/snap/rockcraft/current \
    SNAP_COMMON=/var/snap/rockcraft/common \
    LD_LIBRARY_PATH=/snap/rockcraft/current/none \
    PATH=/snap/rockcraft/current/libexec/rockcraft:/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Job containers run as root (rockcraft --destructive-mode chowns the unpacked
# rootfs and needs it); the Actions runner mounts the workspace, the tool
# cache and /var/run/docker.sock into the container itself.
ARG BASE_IMAGE
LABEL org.opencontainers.image.title="dbt-rock CI builder" \
      org.opencontainers.image.description="rockcraft 1.x (vendored snap) + skopeo/umoci + docker/gh CLIs + jq/shellcheck/actionlint, for the dbt-rock GitHub workflows" \
      org.opencontainers.image.base.name="${BASE_IMAGE}"
