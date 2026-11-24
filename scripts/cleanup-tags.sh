#!/usr/bin/env bash
# Delete ghcr package versions by tag via the Packages REST API.
#
#   cleanup-tags.sh <package-name> pr              # delete every pr-* version
#   cleanup-tags.sh <package-name> nightly <keep>  # delete every pr-* version and
#                                                  # all but the newest <keep> nightly-* versions
#
# pr-<n>-* tags whose PR number is still OPEN are kept (the PR may still be
# tested/pulled); only tags of closed or merged PRs (orphans) are deleted.
#
# GHCR has no registry DELETE endpoint (skopeo delete fails with "unsupported")
# and no retention UI. The package must be repository-linked and published by a
# workflow, so the default GITHUB_TOKEN (packages: write) has admin on it.
# Needs gh + jq; GH_TOKEN and GITHUB_REPOSITORY come from the environment.
set -euo pipefail

pkg="${1:?usage: cleanup-tags.sh <package> pr | cleanup-tags.sh <package> nightly <keep>}"
mode="${2:?missing mode (pr|nightly)}"
keep="${3:-0}"
: "${GITHUB_REPOSITORY:?set GITHUB_REPOSITORY}"

open_prs=$(gh api --paginate "repos/${GITHUB_REPOSITORY}/pulls?state=open&per_page=100" \
  --jq '.[].number' | jq -Rn '[inputs]')
echo "open PRs: ${open_prs}"

gh api --paginate "repos/${GITHUB_REPOSITORY}/packages/container/${pkg}/versions?per_page=100" \
  --jq '.[] | {id, created_at, tags: (.metadata.container.tags // [])}' > /tmp/pkg-versions.jsonl

ids=$(jq -s --arg mode "$mode" --argjson keep "$keep" --argjson open "$open_prs" '
  [ .[] | select(.tags | any(startswith("pr-")))
    | (.tags | map(select(startswith("pr-")) | sub("^pr-"; "") | split("-")[0] | tonumber? // empty)) as $prs
    | select(all($prs[]; . as $n | ($open | contains([$n])) | not))   # skip versions of open PRs
    | .id ]
  + (if $mode == "nightly"
     then ([ .[] | select(.tags | any(startswith("nightly-"))) ]
           | sort_by(.created_at)
           | if length > $keep then .[0:(length - $keep)] else [] end
           | map(.id))
     else [] end)
  | unique[]' /tmp/pkg-versions.jsonl)

count=0
for id in $ids; do
  if gh api -X DELETE "repos/${GITHUB_REPOSITORY}/packages/container/${pkg}/versions/${id}"; then
    echo "deleted version $id"
    count=$((count + 1))
  else
    echo "warn: could not delete version $id"
  fi
done
echo "deleted $count package version(s)"
