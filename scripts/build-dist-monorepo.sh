#!/usr/bin/env bash
set -e

# Monorepo mode: pack specified packages and create dist branch with structure preserved

SOURCE_SHA="${1:-$(git rev-parse HEAD)}"
DIST_BRANCH="${DIST_BRANCH:-dist}"
PKGS="${PKGS:-}"
PACKAGE_DIR="${PACKAGE_DIR:-}"
VERSION_SUFFIX="${VERSION_SUFFIX:-true}"
ON_SOURCE_REWRITE="${ON_SOURCE_REWRITE:-rewrite}"
OLD_DIST_TAG="${OLD_DIST_TAG:-}"

# shellcheck source=./find-dist-parent.sh
source "$(dirname "${BASH_SOURCE[0]}")/find-dist-parent.sh"
# shellcheck source=./check-dist-branch.sh
source "$(dirname "${BASH_SOURCE[0]}")/check-dist-branch.sh"

# A commit trailer on the source commit can override this for a single push (likewise
# on_source_rewrite; resolved below, once the dist tip is known)
OLD_DIST_TAG=$(resolve_old_dist_tag "$SOURCE_SHA" "${OLD_DIST_TAG:-"{branch}-{sha}"}")

# package_dir mode: a single subdir package, flattened to the dist branch ROOT
# (its own package.json at root, no workspace wrapper) so a git dep resolves it
# directly — `github:owner/repo#<sha>` → that package. Contrast `pkgs` mode,
# which preserves each package's path under a private workspace root.
FLATTEN=false
if [ -n "$PACKAGE_DIR" ]; then
  if [ -n "$PKGS" ]; then
    echo "ERROR: set either package_dir or pkgs, not both"
    exit 1
  fi
  PKGS="$PACKAGE_DIR"
  FLATTEN=true
fi

if [ -z "$PKGS" ]; then
  echo "ERROR: PKGS or PACKAGE_DIR must be set for monorepo mode"
  exit 1
fi

# Normalize: convert newlines to commas, strip empty entries and whitespace
PKGS=$(echo "$PKGS" | tr '\n' ',' | sed 's/,,*/,/g; s/^,//; s/,$//')

echo "Building $DIST_BRANCH from source commit: $SOURCE_SHA"
echo "Packages: $PKGS"

SHORT_SHA="${SOURCE_SHA:0:7}"

# Local staging dir. NB: not named TMPDIR — that is the OS/Node temp env var,
# and setting it to a relative path redirects Node/pnpm temp writes into the CWD
# (e.g. a nested .tmp-npm-dist under a packed package).
STAGE_DIR=".tmp-npm-dist"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/dist-content"

# Pack each package
IFS=',' read -ra PKG_PATHS <<< "$PKGS"
for pkg_path in "${PKG_PATHS[@]}"; do
  pkg_path=$(echo "$pkg_path" | xargs)  # trim whitespace
  if [ ! -d "$pkg_path" ]; then
    echo "ERROR: Package directory not found: $pkg_path"
    exit 1
  fi

  echo "Packing $pkg_path..."
  cd "$pkg_path"
  pnpm pack
  cd - > /dev/null

  # Find the tarball (most recent .tgz file)
  tarball=$(ls -t "$pkg_path"/*.tgz 2>/dev/null | head -1)
  if [ -z "$tarball" ]; then
    echo "ERROR: No tarball created for $pkg_path"
    exit 1
  fi

  # Extract to dist-content. package_dir mode flattens to the root; monorepo
  # mode preserves the package's path.
  if [ "$FLATTEN" = "true" ]; then
    dest="$STAGE_DIR/dist-content"
  else
    dest="$STAGE_DIR/dist-content/$pkg_path"
  fi
  mkdir -p "$dest"
  tar -xzf "$tarball" -C "$dest" --strip-components=1

  # Update version suffix if enabled
  if [ "$VERSION_SUFFIX" = "true" ]; then
    pkg_json="$dest/package.json"
    if [ -f "$pkg_json" ]; then
      pkg_version=$(jq -r .version "$pkg_json")
      dist_version="${pkg_version}-dist.${SHORT_SHA}"
      jq --arg v "$dist_version" '.version = $v' "$pkg_json" > "$pkg_json.tmp"
      mv "$pkg_json.tmp" "$pkg_json"
      echo "  Version: $dist_version"
    fi
  fi

  # Clean up tarball
  rm -f "$tarball"
done

# Create a workspace root package.json for the dist branch — but not in
# package_dir mode, where the single package's own package.json IS the root.
if [ "$FLATTEN" != "true" ]; then
  repo_name=$(jq -r .name package.json 2>/dev/null || echo "monorepo")
  cat > "$STAGE_DIR/dist-content/package.json" << EOF
{
  "name": "${repo_name}-dist",
  "private": true,
  "description": "Dist branch with resolved dependencies",
  "repository": $(jq .repository package.json 2>/dev/null || echo '{}')
}
EOF
fi

# Reset any build-generated changes and clean untracked build artifacts
# before checkout. Untracked files (e.g. client/dist/) created by prior
# build steps conflict with tracked files on the dist branch.
git checkout -- . 2>/dev/null || true
git clean -fd -e "$STAGE_DIR" 2>/dev/null || true
rm -rf node_modules

# Abort early on a git dir/file conflict (e.g. dist/treemap while a bare dist exists)
check_dist_branch "$DIST_BRANCH" origin

# Fetch dist branch if it exists
if git fetch origin "$DIST_BRANCH:$DIST_BRANCH" 2>/dev/null; then
  git checkout "$DIST_BRANCH"
  ON_SOURCE_REWRITE=$(resolve_rewrite_mode "$SOURCE_SHA" "$ON_SOURCE_REWRITE" "$(git rev-parse HEAD)")
else
  git checkout --orphan "$DIST_BRANCH"
fi

# Configure git
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

# Remove everything (preserve our tmpdir)
git rm -rf . 2>/dev/null || true
git clean -fdx -e "$STAGE_DIR"

# Copy dist content to root
cp -r "$STAGE_DIR/dist-content"/* .

# Clean up tmpdir
rm -rf "$STAGE_DIR"

# Stage all changes
git add -A

# Get the package name for the commit message. In FLATTEN (package_dir) mode
# the working tree has already been replaced with the flattened dist-content,
# so the manifest is at ./package.json — reading the original source path
# (packages/foo/package.json) would fail and fall back to "monorepo".
if [ "$FLATTEN" = "true" ]; then
  PKG_NAME=$(jq -r .name package.json 2>/dev/null || echo "package")
else
  first_pkg=$(echo "$PKGS" | cut -d',' -f1 | xargs)
  PKG_NAME=$(jq -r .name "$first_pkg/package.json" 2>/dev/null || echo "monorepo")
fi

# Create commit with proper parent(s)
TREE=$(git write-tree)

if [ "$FLATTEN" = "true" ]; then
  COMMIT_MSG="dist: ${PKG_NAME}

Built from ${SOURCE_SHA}"
else
  COMMIT_MSG="dist: ${PKG_NAME} and $(echo "$PKGS" | tr ',' '\n' | wc -l | xargs) packages

Built from ${SOURCE_SHA}"
fi

if DIST_TIP=$(git rev-parse --verify HEAD 2>/dev/null); then
  # dist branch exists: create merge commit with two parents
  # Parent 1: previous dist commit (or an earlier one, if source was force-pushed; see find_dist_parent)
  # Parent 2: source commit from main
  # In fresh mode (empty DIST_PARENT), start a new lineage: the source commit is the only parent.
  DIST_PARENT=$(find_dist_parent "$DIST_TIP" "$SOURCE_SHA" "$ON_SOURCE_REWRITE")
  preserve_old_dist "$DIST_TIP" "$DIST_PARENT" "$DIST_BRANCH" "$OLD_DIST_TAG"
  if [ -n "$DIST_PARENT" ]; then
    COMMIT=$(git commit-tree "$TREE" -p "$DIST_PARENT" -p "$SOURCE_SHA" -m "$COMMIT_MSG")
  else
    COMMIT=$(git commit-tree "$TREE" -p "$SOURCE_SHA" -m "$COMMIT_MSG")
  fi
else
  COMMIT=$(git commit-tree "$TREE" -p "$SOURCE_SHA" -m "$COMMIT_MSG")
fi

git reset --hard "$COMMIT"

echo "$DIST_BRANCH branch built successfully"
