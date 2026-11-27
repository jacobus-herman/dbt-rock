#!/usr/bin/env bash
# Delete ghcr package versions by tag via the Packages REST API.
#
#   cleanup-tags.sh <package-name> pr              # delete versions tagged only with pr-<n>-* of closed PRs
#   cleanup-tags.sh <package-name> nightly <keep>  # additionally delete all but the newest <keep> nightly-* sets
#
# pr-<n>-* tags whose PR number is still OPEN are kept (the PR may still be
# tested/pulled); only tags of closed or merged PRs (orphans) are deleted.
#
# A version is deleted only when EVERY one of its tags is pr-<n>-* (of a closed
# PR) or an old nightly-* one: multi-arch manifest lists reference the per-arch
# images by digest, and the Packages API deletes whole versions, not single
# tags — deleting a per-arch version that also carries a v-*/latest-*/nightly-*
# tag would break that manifest.
#
# GHCR has no registry DELETE endpoint (skopeo delete fails with "unsupported")
# and no retention UI, so versions are deleted via the Packages REST API.
# The package must be linked to the repository (package page -> Settings ->
# Repository -> Connect repository); the default GITHUB_TOKEN (packages: write)
# can then manage it. NB: for a package in a USER namespace the repo-scoped
# endpoint /repos/<owner>/<repo>/packages/... 404s even when the package is
# linked — the owner-scoped /users/<owner>/packages/... endpoint is used
# directly.
# Needs gh + jq; GH_TOKEN and GITHUB_REPOSITORY come from the environment.
set -euo pipefail

pkg="${1:?usage: cleanup-tags.sh <package> pr | cleanup-tags.sh <package> nightly <keep>}"
mode="${2:?missing mode (pr|nightly)}"
keep="${3:-0}"
: "${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY}"
owner="${GITHUB_REPOSITORY%%/*}"

open_prs=$(gh api --paginate "repos/${GITHUB_REPOSITORY}/pulls?state=open&per_page=100" \
  --jq '.[].number' | jq -Rn '[inputs | tonumber]')
echo "open PRs: ${open_prs}"

base="users/${owner}/packages/container/${pkg}"
gh api --paginate "${base}/versions?per_page=100" \
  --jq '.[] | {id, created_at, tags: (.metadata.container.tags // [])}' > /tmp/pkg-versions.jsonl

ids=$(jq -s --arg mode "$mode" --argjson keep "$keep" --argjson open "$open_prs" '
  [ .[] | select(.tags | length > 0) | select(all(.tags[]; startswith("pr-")))
    | (.tags | map(sub("^pr-"; "") | split("-")[0] | tonumber? // empty)) as $prs
    # index($n), not contains($n): both lists hold numbers
    | select(all($prs[]; . as $n | ($open | index($n)) | not))
    | .id ]
  # nightly retention: keep whole nightly-<date>-<digest> sets (the per-arch
  # images and their manifest lists share the prefix), not loose versions
  + (if $mode == "nightly"
     then [ .[] | select(.tags | any(startswith("nightly-")))
            | {id, g: (.tags | map(select(startswith("nightly-")))[0] | split("-") | .[0:3] | join("-"))} ]
           | group_by(.g)
           | if length > $keep then .[0:(length - $keep)] else [] end
           | map(.[].id)
     else [] end)
  | unique[]' /tmp/pkg-versions.jsonl)

count=0
for id in $ids; do
  if gh api -X DELETE "${base}/versions/${id}"; then
    echo "deleted version $id"
    count=$((count + 1))
  else
    echo "warn: could not delete version $id"
  fi
done
echo "deleted $count package version(s)"
