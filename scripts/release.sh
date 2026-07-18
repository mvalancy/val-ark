#!/bin/bash
###############################################################################
# Val Ark - Release Helper
#
# Usage: ./scripts/release.sh [version] [--push]
#
# Tags HEAD as a release. The repo-root VERSION file is the single source of
# truth (scripts/server.js serves it at /api/health): with no argument the tag
# is taken from it; with an argument the two must match (bump VERSION in the
# release commit first). Tags follow the adopted UNPREFIXED 0.x scheme
# (0.1.7, 0.1.8, 0.1.9, ...) — a leading 'v' on the argument is stripped,
# never minted. See docs/knowledge/decisions.md (release process).
###############################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

die() { echo -e "${RED}Error:${NC} $*" >&2; exit 1; }

VERSION="${1:-}"
PUSH="${2:-}"

if [ "$VERSION" = "-h" ] || [ "$VERSION" = "--help" ]; then
    echo "Usage: $0 [version] [--push]"
    echo ""
    echo "Examples:"
    echo "  $0                  # Tag the version in the VERSION file (e.g. 0.1.10)"
    echo "  $0 0.1.10           # Tag 0.1.10 (must match the VERSION file)"
    echo "  $0 --push           # Tag from the VERSION file and push the tag"
    exit 0
fi

# Allow `release.sh --push` (version comes from the VERSION file).
if [ "$VERSION" = "--push" ]; then
    PUSH="--push"
    VERSION=""
fi

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
VERSION_FILE="${REPO_ROOT}/VERSION"
[ -f "$VERSION_FILE" ] || die "missing ${VERSION_FILE} — the single source of truth for the app version"
FILE_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"

# Canonical scheme is UNPREFIXED 0.x tags (0.1.7, 0.1.8, 0.1.9, ...). Accept a
# leading 'v' on input for convenience but never mint one: under version sort a
# v-tag permanently outranks every unprefixed tag, which would corrupt any
# "latest tag" logic for the rest of the series.
VERSION="${VERSION#v}"

if [ -z "$VERSION" ]; then
    VERSION="$FILE_VERSION"
elif [ "$VERSION" != "$FILE_VERSION" ]; then
    die "VERSION file says ${FILE_VERSION}, but you asked to release ${VERSION}.
Bump the VERSION file in the release commit first (it is served at /api/health)."
fi

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'${VERSION}' is not a plain X.Y.Z version"

TAG="${VERSION}"

# Clean tree = no uncommitted changes to TRACKED files. Untracked local cruft
# (scratch dirs, caches) cannot change what the tag captures — HEAD — and must
# not block a release; the old any-file check tripped on exactly that.
if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo -e "${RED}Error:${NC} Uncommitted changes to tracked files. Commit or stash first." >&2
    git status --short --untracked-files=no >&2
    exit 1
fi

# Refuse to double-release under either scheme.
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    die "Tag ${TAG} already exists."
fi
if git rev-parse -q --verify "refs/tags/v${TAG}" >/dev/null; then
    die "Tag v${TAG} already exists — the series is unprefixed; reconcile it first."
fi

echo ""
echo -e "${BOLD}Release: ${TAG}${NC}"
echo ""

# Changelog baseline: the nearest ancestor tag on THIS lineage. (Not the
# highest version-sorted tag repo-wide — that breaks across mixed prefixes and
# picks up tags that sit on other branches.)
PREV_TAG=$(git describe --tags --abbrev=0 HEAD 2>/dev/null || true)
echo -e "${BOLD}Changelog:${NC}"
if [ -n "$PREV_TAG" ]; then
    echo -e "  ${YELLOW}(since ${PREV_TAG})${NC}"
    git log --pretty=format:"  - %s (%h)" "${PREV_TAG}..HEAD" 2>/dev/null
else
    echo -e "  ${YELLOW}(initial release)${NC}"
    git log --pretty=format:"  - %s (%h)" 2>/dev/null | head -20
fi
echo ""
echo ""

# Create annotated tag
git tag -a "$TAG" -m "Release ${TAG}"
echo -e "${GREEN}✓${NC} Created tag: ${TAG}"

# Optionally push
if [ "$PUSH" = "--push" ]; then
    git push origin "$TAG"
    echo -e "${GREEN}✓${NC} Pushed tag to origin"
else
    echo ""
    echo "  To push: git push origin ${TAG}"
fi
