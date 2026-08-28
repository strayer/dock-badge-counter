#!/usr/bin/env bash
# Tag the next release. Lists the PRs merged since the last v* tag, computes
# the version bump from their labels, and confirms with the user before
# committing the version bump in Sources/Commands/DockBadgeCounter.swift,
# pushing it to main and pushing a signed annotated tag on top of it. The tag
# push triggers .github/workflows/release.yml, which verifies the signature
# and that the source declares the tag's version, then publishes the GitHub
# release; Renovate then bumps the formula in strayer/homebrew-tap.
#
# The bump commit is pushed straight to main: the branch ruleset requires
# PRs for everyone else, but repository admins bypass it.
#
# Label → bump mapping (highest wins):
#   breaking              → major (minor while still on 0.x)
#   feature, enhancement  → minor
#   anything else         → patch
#
# Usage: scripts/release.sh [vX.Y.Z]   (explicit version skips computation)
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
valid_version() { [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

override="${1:-}"
if [[ -n "$override" ]]; then
  valid_version "$override" || die "version must look like v1.2.3"
fi

[[ "$(git rev-parse --abbrev-ref HEAD)" == "main" ]] || die "switch to main first"
[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty"
git fetch --quiet --tags origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "main is not in sync with origin/main"

last_tag="$(git tag --list 'v*' --sort=-version:refname | head -n1)"

# List the merged PRs that would ship in this release (all of them when no
# tag exists yet) and derive the bump from their labels.
if [[ -n "$last_tag" ]]; then
  commits="$(git rev-list "$last_tag..HEAD")"
  [[ -n "$commits" ]] || die "no commits since $last_tag"
  echo "PRs merged since $last_tag:"
else
  commits="$(git rev-list HEAD)"
  echo "No previous v* tag. All merged PRs:"
fi

bump="patch"
while IFS=$'\t' read -r num oid labels title; do
  [[ -n "$oid" ]] || continue
  grep -qx "$oid" <<<"$commits" || continue
  echo "  #$num [$labels] $title"
  case ",$labels," in
    *,breaking,*) bump="major" ;;
    *,feature,* | *,enhancement,*) [[ "$bump" == "major" ]] || bump="minor" ;;
  esac
done < <(gh pr list --state merged --base main --limit 200 \
  --json number,title,labels,mergeCommit \
  --jq '.[] | [(.number|tostring), (.mergeCommit.oid // ""), ([.labels[].name] | join(",")), .title] | @tsv')

if [[ -n "$override" ]]; then
  next="$override"
  echo
  echo "Proposed release: $next (explicit version, computation skipped)"
elif [[ -z "$last_tag" ]]; then
  next="v0.1.0"
  echo
  echo "Proposed release: $next (first release)"
else
  IFS=. read -r major minor patch <<<"${last_tag#v}"
  if [[ "$bump" == "major" && "$major" == "0" ]]; then
    # semver while on 0.x: breaking changes only bump the minor version
    bump="minor"
  fi
  case "$bump" in
    major) major=$((major + 1)); minor=0; patch=0 ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    patch) patch=$((patch + 1)) ;;
  esac
  next="v$major.$minor.$patch"
  echo
  echo "Proposed release: $next ($bump bump from $last_tag)"
fi

printf 'Confirm [y], enter a different version (vX.Y.Z), or abort [N]: '
read -r answer
case "$answer" in
  y | Y | yes) ;;
  v*)
    valid_version "$answer" || die "version must look like v1.2.3"
    next="$answer"
    ;;
  *) die "aborted" ;;
esac

git tag --list | grep -qx "$next" && die "tag $next already exists"

# Bump the version in source and push that commit first, so the tag points at it.
version_file="Sources/Commands/DockBadgeCounter.swift"
sed -i '' "s/^let version = \".*\"$/let version = \"${next#v}\"/" "$version_file"
grep -q "^let version = \"${next#v}\"$" "$version_file" || die "failed to set version in $version_file"
if git diff --quiet -- "$version_file"; then
  echo "$version_file already declares ${next#v}; nothing to commit"
else
  git commit --quiet -m "chore: release $next" -- "$version_file"
  git push origin main
fi

git tag -s "$next" -m "Release $next"
git push origin "$next"
echo "Pushed $next — watch https://github.com/strayer/dock-badge-counter/actions/workflows/release.yml"
