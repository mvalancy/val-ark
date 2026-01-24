#!/bin/bash
###############################################################################
# Val Ark - Release Helper
#
# Usage: ./scripts/release.sh 1.2.0 [--push]
#
# Creates an annotated git tag and optionally pushes to origin.
###############################################################################

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

VERSION="${1:-}"
PUSH="${2:-}"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [--push]"
    echo ""
    echo "Examples:"
    echo "  $0 1.0.0          # Create tag v1.0.0"
    echo "  $0 1.2.0 --push   # Create and push tag v1.2.0"
    exit 1
fi

# Normalize: strip leading 'v' if present, then add it
VERSION="${VERSION#v}"
TAG="v${VERSION}"

# Verify clean working tree
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo -e "${RED}Error:${NC} Working tree is not clean. Commit or stash changes first."
    git status --short
    exit 1
fi

# Check if tag already exists
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo -e "${RED}Error:${NC} Tag ${TAG} already exists."
    exit 1
fi

# Show changelog preview
echo ""
echo -e "${BOLD}Release: ${TAG}${NC}"
echo ""

PREV_TAG=$(git tag --sort=-version:refname 2>/dev/null | head -1)
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
