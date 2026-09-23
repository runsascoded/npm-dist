#!/usr/bin/env bash
# Source this file to define find_dist_parent. Safe to source multiple times.
#
# find_dist_parent <dist_tip> <source_sha> <mode>
#   <mode>: rewrite | preserve | error | fresh
#
# Echoes the SHA to use as the 1st parent of the new dist commit, or exits non-zero.
# An empty result (fresh mode) means: start a new dist lineage, with the source commit
# as the only parent.
# - fresh:    always returns "" (the old dist tip is preserved by `preserve_old_dist`).
# - preserve: always returns dist_tip (old behavior).
# - error:    returns dist_tip iff its source-parent is an ancestor of source_sha; else fails.
# - rewrite:  walks dist commits (via 1st parent) and returns the most recent whose
#             source-parent is an ancestor of source_sha. Lets dist ancestry mirror source
#             ancestry after a force-push of the source ref.
#
# A "dist commit" here is either:
#   - a 2-parent merge commit (built dist commit): source-parent is ^2
#   - the initial 1-parent dist commit: source-parent is ^1
#
# Anything else (e.g. hand-edited single-parent commit between builds) is not currently
# handled — the walk stops when it hits a non-merge that isn't the initial dist commit.

find_dist_parent() {
  local dist_tip="$1"
  local source_sha="$2"
  local mode="${3:-rewrite}"

  case "$mode" in
    fresh)
      echo ""
      return 0
      ;;
    preserve)
      echo "$dist_tip"
      return 0
      ;;
    error)
      local src
      if src=$(git rev-parse --verify "$dist_tip^2" 2>/dev/null) || src=$(git rev-parse --verify "$dist_tip^1" 2>/dev/null); then
        if git merge-base --is-ancestor "$src" "$source_sha"; then
          echo "$dist_tip"
          return 0
        fi
        echo "ERROR: dist tip $dist_tip's source-parent ($src) is not an ancestor of source $source_sha." >&2
        echo "       Source ref appears force-pushed. Set on_source_rewrite=rewrite to rebuild on a shared ancestor, =preserve to chain onto dist tip anyway, or =fresh to start a new dist lineage." >&2
        return 1
      fi
      echo "ERROR: dist tip $dist_tip has no parent — cannot determine source ancestry." >&2
      return 1
      ;;
    rewrite)
      ;;
    *)
      echo "ERROR: invalid on_source_rewrite=$mode (expected: rewrite|preserve|error|fresh)" >&2
      return 1
      ;;
  esac

  local node="$dist_tip"
  while [ -n "$node" ]; do
    local src
    if src=$(git rev-parse --verify "$node^2" 2>/dev/null); then
      if git merge-base --is-ancestor "$src" "$source_sha"; then
        if [ "$node" != "$dist_tip" ]; then
          echo "note: source ref appears force-pushed; rebuilding dist on top of $node (skipped intermediate dist commits whose source-parents are no longer reachable from $source_sha)" >&2
        fi
        echo "$node"
        return 0
      fi
      node=$(git rev-parse "$node^1")
    else
      if src=$(git rev-parse --verify "$node^1" 2>/dev/null); then
        if git merge-base --is-ancestor "$src" "$source_sha"; then
          if [ "$node" != "$dist_tip" ]; then
            echo "note: source ref appears force-pushed; rebuilding dist on top of initial dist commit $node" >&2
          fi
          echo "$node"
          return 0
        fi
      fi
      break
    fi
  done

  echo "ERROR: no dist commit's source-parent is an ancestor of $source_sha (force-push to unrelated history?)." >&2
  echo "       Set on_source_rewrite=fresh to start a new dist lineage (old dist tip gets tagged), or" >&2
  echo "       =preserve to chain onto dist tip anyway. One-off, per push: add a commit trailer" >&2
  echo "       \"NPM-Dist-On-Source-Rewrite: fresh\" to the pushed source commit." >&2
  return 1
}

# commit_trailer <sha> <key>
#   Echoes the (last) value of git trailer <key> (case-insensitive) in <sha>'s message, or "".
commit_trailer() {
  git log -1 --format="%(trailers:key=$2,valueonly,separator=%x0A)" "$1" | sed '/^[[:space:]]*$/d' | tail -1
}

# dist_source_parent <dist_commit>
#   Echoes the source commit a dist commit was built from: ^2 of a (2-parent) build commit,
#   ^1 of a single-parent (first or fresh) one. Empty if it has no parents.
dist_source_parent() {
  git rev-parse -q --verify "$1^2" || git rev-parse -q --verify "$1^1" || true
}

# resolve_rewrite_mode <source_sha> <mode> [dist_tip]
#   A "NPM-Dist-On-Source-Rewrite: <mode>" trailer on the source commit overrides <mode>,
#   so a one-off mode (e.g. fresh) can ride along with a single push, without a config change.
#   The trailer stays in that commit's message forever, so it's ignored when <dist_tip> was
#   already built from <source_sha> (or a descendant of it): re-running the build for that
#   commit mustn't start yet another lineage.
resolve_rewrite_mode() {
  local source_sha="$1" mode="$2" dist_tip="${3:-}" trailer tip_src
  trailer=$(commit_trailer "$source_sha" NPM-Dist-On-Source-Rewrite)
  [ -z "$trailer" ] && { echo "$mode"; return 0; }
  if [ -n "$dist_tip" ]; then
    tip_src=$(dist_source_parent "$dist_tip")
    if [ -n "$tip_src" ] && git merge-base --is-ancestor "$source_sha" "$tip_src"; then
      echo "note: ignoring \"NPM-Dist-On-Source-Rewrite: $trailer\" trailer on ${source_sha:0:7}: dist tip ${dist_tip:0:7} was already built from it (or a descendant); using on_source_rewrite=$mode" >&2
      echo "$mode"
      return 0
    fi
  fi
  echo "note: on_source_rewrite=$trailer (from commit trailer on ${source_sha:0:7})" >&2
  echo "$trailer"
}

# resolve_old_dist_tag <source_sha> <template>
#   A "NPM-Dist-Old-Dist-Tag: <template>" trailer on the source commit overrides <template>.
resolve_old_dist_tag() {
  local trailer
  trailer=$(commit_trailer "$1" NPM-Dist-Old-Dist-Tag)
  echo "${trailer:-$2}"
}

# old_dist_tag_name <dist_tip> <dist_branch> <template>
#   Expands {branch} and {sha} (7-char SHA of dist_tip's source commit, matching the
#   `-dist.<sha>` version suffix) in <template>. Echoes "" for template "none".
old_dist_tag_name() {
  local tip="$1" branch="$2" template="$3" src name
  [ "$template" = none ] && return 0
  src=$(dist_source_parent "$tip")
  src="${src:-$tip}"
  name="${template//\{branch\}/$branch}"
  name="${name//\{sha\}/${src:0:7}}"
  echo "$name"
}

# preserve_old_dist <dist_tip> <new_parent> <dist_branch> <template> [remote]
#   When the new dist commit won't descend from <dist_tip> (fresh mode, or rewrite walking
#   back), tag <dist_tip> and push the tag, so commits consumers may have pinned stay
#   reachable (not GC'd). No-op when <new_parent> is <dist_tip>. Fails (before anything
#   is force-pushed) if the tag already exists at a different commit.
preserve_old_dist() {
  local tip="$1" parent="$2" branch="$3" template="$4" remote="${5:-origin}" tag existing
  [ "$parent" = "$tip" ] && return 0
  tag=$(old_dist_tag_name "$tip" "$branch" "$template")
  if [ -z "$tag" ]; then
    echo "warning: old dist tip ${tip:0:7} will no longer be reachable from $branch (old_dist_tag=none)" >&2
    return 0
  fi
  if existing=$(git rev-parse -q --verify "refs/tags/$tag^{commit}"); then
    if [ "$existing" != "$tip" ]; then
      echo "ERROR: tag $tag already exists at ${existing:0:7}, not old dist tip ${tip:0:7}. Set old_dist_tag to another name." >&2
      return 1
    fi
  else
    git tag "$tag" "$tip"
  fi
  git push -q "$remote" "refs/tags/$tag"
  echo "Tagged old dist tip ${tip:0:7} as $tag"
  echo "🏷️ Old \`$branch\` tip \`${tip:0:7}\` preserved as tag \`$tag\`." >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
}
