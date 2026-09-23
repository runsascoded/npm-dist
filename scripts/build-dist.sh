#!/usr/bin/env bash
set -e

SOURCE_SHA="${1:-$(git rev-parse HEAD)}"
DIST_BRANCH="${DIST_BRANCH:-dist}"
BUILD_DIR="${BUILD_DIR:-dist}"
PRESERVE_DIRS="${PRESERVE_DIRS:-}"
SOURCE_DIRS="${SOURCE_DIRS:-}"
EXTRA_FILES="${EXTRA_FILES:-}"
VERSION_SUFFIX="${VERSION_SUFFIX:-true}"
PKG_INCLUDE="${PKG_INCLUDE:-}"
PKG_EXCLUDE="${PKG_EXCLUDE:-}"
PKG_KVS="${PKG_KVS:-}"
EXPORTS_MAP="${EXPORTS_MAP:-}"
ON_SOURCE_REWRITE="${ON_SOURCE_REWRITE:-rewrite}"
OLD_DIST_TAG="${OLD_DIST_TAG:-}"

# shellcheck source=./find-dist-parent.sh
source "$(dirname "${BASH_SOURCE[0]}")/find-dist-parent.sh"
# shellcheck source=./merge-dist-package.sh
source "$(dirname "${BASH_SOURCE[0]}")/merge-dist-package.sh"
# shellcheck source=./check-dist-branch.sh
source "$(dirname "${BASH_SOURCE[0]}")/check-dist-branch.sh"

# A commit trailer on the source commit can override this for a single push (likewise
# on_source_rewrite; resolved below, once the dist tip is known)
OLD_DIST_TAG=$(resolve_old_dist_tag "$SOURCE_SHA" "${OLD_DIST_TAG:-"{branch}-{sha}"}")

# Resolve preserve_dirs (with source_dirs deprecation)
if [ -n "$PRESERVE_DIRS" ] && [ -n "$SOURCE_DIRS" ]; then
  echo "::warning::Both preserve_dirs and source_dirs are set; using preserve_dirs"
fi
if [ -z "$PRESERVE_DIRS" ] && [ -n "$SOURCE_DIRS" ]; then
  PRESERVE_DIRS="$SOURCE_DIRS"
  echo "::warning::source_dirs is deprecated, use preserve_dirs instead"
  echo "⚠️ \`source_dirs\` is deprecated, use \`preserve_dirs\` instead." >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
fi

# Default fields to include from source package.json
DEFAULT_PKG_FIELDS="name,description,type,bin,main,keywords,repository,author,license,homepage,bugs,exports,dependencies,peerDependencies,optionalDependencies"

echo "Building $DIST_BRANCH from source commit: $SOURCE_SHA"

# Compute short SHA for version suffix
SHORT_SHA="${SOURCE_SHA:0:7}"

# Use local .tmp directory for staging files across branch switch
TMPDIR=".tmp-npm-dist"
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"

# Save source package.json before switching branches (for initial setup and version)
# For prebuilt mode (no root package.json), we use BUILD_DIR's package.json as-is
if [ -f package.json ]; then
  cp package.json package.json.source
  SOURCE_VERSION=$(jq -r .version package.json)
  PREBUILT_MODE=false
elif [ -f "$BUILD_DIR/package.json" ]; then
  # Prebuilt mode: caller provides complete package.json, we only add version suffix
  SOURCE_VERSION=$(jq -r .version "$BUILD_DIR/package.json")
  PREBUILT_MODE=true
else
  echo "ERROR: No package.json found in root or $BUILD_DIR"
  exit 1
fi

# Save build output dir before checkout (git clean would remove it)
if [ -d "$BUILD_DIR" ]; then
  cp -r "$BUILD_DIR" "$TMPDIR/build-output"
fi

# If PRESERVE_DIRS is set, save those directories
if [ -n "$PRESERVE_DIRS" ]; then
  mkdir -p "$TMPDIR/source-dirs"
  IFS=',' read -ra DIRS <<< "$PRESERVE_DIRS"
  for dir in "${DIRS[@]}"; do
    dir=$(echo "$dir" | xargs)  # trim whitespace
    if [ -d "$dir" ]; then
      cp -r "$dir" "$TMPDIR/source-dirs/"
    fi
  done
fi

# If EXTRA_FILES is set, save those files (preserving directory structure)
if [ -n "$EXTRA_FILES" ]; then
  mkdir -p "$TMPDIR/extra-files"
  IFS=',' read -ra FILES <<< "$EXTRA_FILES"
  for file in "${FILES[@]}"; do
    file=$(echo "$file" | xargs)  # trim whitespace
    if [ -f "$file" ]; then
      # Preserve directory structure
      mkdir -p "$TMPDIR/extra-files/$(dirname "$file")"
      cp "$file" "$TMPDIR/extra-files/$file"
    elif [ -d "$file" ]; then
      mkdir -p "$TMPDIR/extra-files/$(dirname "$file")"
      cp -r "$file" "$TMPDIR/extra-files/$file"
    fi
  done
fi

# Remove node_modules before checkout (it would conflict)
rm -rf node_modules

# Abort early on a git dir/file conflict (e.g. dist/treemap while a bare dist exists)
check_dist_branch "$DIST_BRANCH" origin

# Fetch dist branch if it exists
DIST_EXISTS=false
if git fetch origin "$DIST_BRANCH:$DIST_BRANCH" 2>/dev/null; then
  git checkout -f "$DIST_BRANCH"
  DIST_EXISTS=true
  ON_SOURCE_REWRITE=$(resolve_rewrite_mode "$SOURCE_SHA" "$ON_SOURCE_REWRITE" "$(git rev-parse HEAD)")
  # Save existing package.json from dist branch (not in fresh mode: a new lineage
  # regenerates it from source, as on a first build)
  if [ -f package.json ] && [ "$ON_SOURCE_REWRITE" != fresh ]; then
    cp package.json package.json.dist
  fi
else
  git checkout --orphan "$DIST_BRANCH"
fi

# Configure git
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

# Remove everything (preserve our tmpdir and package.json backups)
git rm -rf . 2>/dev/null || true
git clean -fdx -e "$TMPDIR" -e package.json.dist -e package.json.source

if [ -n "$PRESERVE_DIRS" ]; then
  # preserve_dirs mode: restore saved directories
  cp -r "$TMPDIR/source-dirs"/* .
else
  # Default mode: restore build output and move contents to root
  if [ -d "$TMPDIR/build-output" ]; then
    cp -r "$TMPDIR/build-output"/* .
  else
    echo "ERROR: No $BUILD_DIR/ directory found"
    exit 1
  fi
fi

# Restore extra files (if any)
if [ -d "$TMPDIR/extra-files" ] && [ -n "$(ls -A "$TMPDIR/extra-files" 2>/dev/null)" ]; then
  cp -r "$TMPDIR/extra-files"/* .
fi

# Clean up tmpdir
rm -rf "$TMPDIR"

# Restore or create package.json
if [ "$PREBUILT_MODE" = "true" ]; then
  # Prebuilt mode: package.json already in build output, use as-is
  echo "Prebuilt mode: using package.json from $BUILD_DIR"
else
  # Standard mode: merge/transform package.json

  # Compute effective field list (include - exclude)
  if [ -n "$PKG_INCLUDE" ]; then
    FIELDS_TO_INCLUDE="$PKG_INCLUDE"
  else
    FIELDS_TO_INCLUDE="$DEFAULT_PKG_FIELDS"
  fi

  # Remove excluded fields
  if [ -n "$PKG_EXCLUDE" ]; then
    IFS=',' read -ra EXCLUDE_ARR <<< "$PKG_EXCLUDE"
    for exclude in "${EXCLUDE_ARR[@]}"; do
      exclude=$(echo "$exclude" | xargs)
      FIELDS_TO_INCLUDE=$(echo "$FIELDS_TO_INCLUDE" | sed "s/$exclude//g" | sed 's/,,/,/g' | sed 's/^,//' | sed 's/,$//')
    done
  fi

  echo "Fields to include from source: $FIELDS_TO_INCLUDE"

  if [ -f package.json.dist ]; then
    # Merge: use dist structure but update key fields from source.
    # In preserve_dirs mode, the merge must NOT flatten ./$BUILD_DIR/ paths,
    # since the dist branch retains $BUILD_DIR as-is (mirrors first-run gate).
    merge_dist_package_json package.json.dist package.json.source "$BUILD_DIR" "$FIELDS_TO_INCLUDE" "$PRESERVE_DIRS" > package.json
    rm -f package.json.dist package.json.source
  elif [ -f package.json.source ]; then
    # First run: transform source package.json for dist branch
    echo "Creating initial package.json for $DIST_BRANCH branch..."
    if [ -n "$PRESERVE_DIRS" ]; then
      # preserve_dirs mode: just remove dev fields, no path transformation
      jq 'del(.files, .scripts, .devDependencies)' package.json.source > package.json
    else
      # Default mode: remove dev fields and transform build_dir paths
      jq --arg build_dir "$BUILD_DIR" '
        # Remove fields not needed on dist branch
        del(.files, .scripts, .devDependencies) |
        # Transform paths: ./$build_dir/... -> ./...
        walk(
          if type == "string" then
            gsub("\\./\($build_dir)/"; "./") | gsub("\($build_dir)/"; "./")
          else
            .
          end
        )
      ' package.json.source > package.json
    fi
    rm -f package.json.source
  else
    echo "ERROR: No package.json found"
    exit 1
  fi
fi

# Update version with dist suffix if enabled
if [ "$VERSION_SUFFIX" = "true" ]; then
  DIST_VERSION="${SOURCE_VERSION}-dist.${SHORT_SHA}"
  echo "Setting version to $DIST_VERSION"
  jq --arg v "$DIST_VERSION" '.version = $v' package.json > package.json.tmp
  mv package.json.tmp package.json
fi

# Apply key-value overrides if specified
if [ -n "$PKG_KVS" ]; then
  echo "Applying package.json overrides: $PKG_KVS"
  jq --argjson kvs "$PKG_KVS" '. * $kvs' package.json > package.json.tmp
  mv package.json.tmp package.json
fi

# Rewrite exports using exports_map (if provided)
if [ -n "$EXPORTS_MAP" ] && jq -e '.exports // empty' package.json > /dev/null 2>&1; then
  echo "Rewriting exports using exports_map..."
  jq --argjson map "$EXPORTS_MAP" '
    # Rewrite `main` if it matches a key in the map
    (if .main and $map[.main] then .main = $map[.main] else . end) |
    # Rewrite exports entries
    if .exports then
      .exports |= with_entries(
        # Resolve the target value (handle conditional exports objects)
        (.value | if type == "object" then (.import // .require // .default // "") else . end) as $target |
        if $map[$target] then
          # Mapped: replace value (or replace within conditional exports object)
          if .value | type == "object" then
            .value |= map_values(if . == $target then $map[$target] else . end)
          else
            .value = $map[$target]
          end
        else
          .
        end
      )
    else
      .
    end
  ' package.json > package.json.tmp
  mv package.json.tmp package.json

  # Drop exports pointing at missing files/directories
  EXPORTS_TO_DROP=""
  while IFS=$'\t' read -r key value; do
    if [[ "$value" == *'*'* ]]; then
      # Glob pattern: check if the base directory exists (e.g. "./lib/*" → check "./lib")
      glob_dir="${value%%\**}"
      glob_dir="${glob_dir%/}"
      if [ -n "$glob_dir" ] && [ ! -d "$glob_dir" ]; then
        EXPORTS_TO_DROP="${EXPORTS_TO_DROP}${key}\n"
        echo "  Dropping export \"${key}\" → \"${value}\" (directory not found)"
      fi
    elif [ ! -f "$value" ] && [ ! -d "${value%/}" ]; then
      EXPORTS_TO_DROP="${EXPORTS_TO_DROP}${key}\n"
      echo "  Dropping export \"${key}\" → \"${value}\" (target not found)"
    fi
  done < <(jq -r '.exports | to_entries[] | [.key, (.value | if type == "object" then (.import // .require // .default // "") else . end)] | @tsv' package.json)

  if [ -n "$EXPORTS_TO_DROP" ]; then
    # Build jq filter to remove the marked keys
    DROP_KEYS=$(echo -e "$EXPORTS_TO_DROP" | sed '/^$/d' | jq -R . | jq -s .)
    jq --argjson drop "$DROP_KEYS" '
      .exports |= with_entries(select(.key as $k | ($drop | index($k)) | not))
    ' package.json > package.json.tmp
    mv package.json.tmp package.json
  fi
  echo "Exports rewriting complete"
fi

# Validate exports: error if any entry points to a file that doesn't exist
if jq -e '.exports // empty' package.json > /dev/null 2>&1; then
  echo "Validating exports map..."
  EXPORTS_ERRORS=""
  while IFS=$'\t' read -r key value; do
    if [[ "$value" == *'*'* ]]; then
      # Glob: check if base directory exists
      glob_dir="${value%%\**}"
      glob_dir="${glob_dir%/}"
      if [ -n "$glob_dir" ] && [ ! -d "$glob_dir" ]; then
        EXPORTS_ERRORS="${EXPORTS_ERRORS}\n  \"${key}\": \"${value}\" → directory not found"
      fi
    elif [ ! -f "$value" ]; then
      EXPORTS_ERRORS="${EXPORTS_ERRORS}\n  \"${key}\": \"${value}\" → file not found"
    fi
  done < <(jq -r '.exports | to_entries[] | [.key, (.value | if type == "object" then (.import // .require // .default // "") else . end)] | @tsv' package.json)

  if [ -n "$EXPORTS_ERRORS" ]; then
    echo ""
    echo "ERROR: exports map references files that don't exist on the dist branch:"
    echo -e "$EXPORTS_ERRORS"
    echo ""
    echo "Fix by either:"
    echo "  1. Using exports_map to rewrite source paths to dist paths"
    echo "  2. Including the files in the build output (source_dirs or extra_files)"
    echo "  3. Overriding exports via pkg_kvs"
    echo "  4. Removing broken exports from source package.json"
    exit 1
  fi
  echo "All exports validated ✓"
fi

# Stage all changes
git add -A

# Get package info for commit message
PKG_NAME=$(jq -r .name package.json)
PKG_VERSION=$(jq -r .version package.json)

# Create commit with proper parent(s)
TREE=$(git write-tree)

COMMIT_MSG="${PKG_NAME}@${PKG_VERSION}

Built from ${SOURCE_SHA}"

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
  # First dist commit: single parent (source commit)
  COMMIT=$(git commit-tree "$TREE" -p "$SOURCE_SHA" -m "$COMMIT_MSG")
fi

git reset --hard "$COMMIT"

echo "$DIST_BRANCH branch built successfully"
