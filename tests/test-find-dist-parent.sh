#!/usr/bin/env bash
# Tests for find_dist_parent. Sources scripts/find-dist-parent.sh from the same repo,
# so test/impl drift is structurally prevented.
#
# Run from anywhere:  bash gh/tests/test-find-dist-parent.sh
set -e

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

# Source the real function.
# shellcheck source=../scripts/find-dist-parent.sh
source "$REPO_ROOT/scripts/find-dist-parent.sh"

# Work in a scratch git repo so we don't disturb anything.
WORK=$(mktemp -d -t find-dist-parent-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
git init -q -b main
git config user.name test
git config user.email test@test

PASS=0
FAIL=0

commit() {
  git commit --allow-empty -q -m "$1"
  git rev-parse HEAD
}

dist_commit() {
  local msg="$1"; shift
  local tree
  tree=$(git write-tree)
  local args=()
  for p in "$@"; do args+=(-p "$p"); done
  git commit-tree "$tree" "${args[@]}" -m "$msg"
}

reset_repo() {
  cd /
  rm -rf "$WORK"
  mkdir -p "$WORK"
  cd "$WORK"
  git init -q -b main
  git config user.name test
  git config user.email test@test
}

check() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

check_fails() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL: $desc — expected non-zero exit, got success"
    FAIL=$((FAIL + 1))
  else
    echo "PASS: $desc (errored as expected)"
    PASS=$((PASS + 1))
  fi
}

# ----- Scenario 1: normal forward push (no force-push) -----
# main: m0 -- m1; dist: d0(parent=m0) -- d1(parents=d0,m1)
# new source = m2 (child of m1). Expect: find_dist_parent returns d1.
reset_repo
m0=$(commit m0)
d0=$(dist_commit "d0" "$m0")
m1=$(commit m1)
d1=$(dist_commit "d1" "$d0" "$m1")
m2=$(commit m2)
result=$(find_dist_parent "$d1" "$m2" "rewrite")
check "normal forward push (rewrite) → dist tip" "$d1" "$result"

# ----- Scenario 2: force-push amends m1 -> m2 -----
# Expect: find_dist_parent returns d0 (walked back from d1).
reset_repo
m0=$(commit m0)
d0=$(dist_commit "d0" "$m0")
m1=$(commit m1)
d1=$(dist_commit "d1" "$d0" "$m1")
git reset --hard -q "$m0"
m2=$(commit m2)
result=$(find_dist_parent "$d1" "$m2" "rewrite" 2>/dev/null)
check "amend force-push (rewrite) → walk back to d0" "$d0" "$result"

# ----- Scenario 3: force-push to completely unrelated history -----
reset_repo
m0=$(commit m0)
d0=$(dist_commit "d0" "$m0")
m1=$(commit m1)
d1=$(dist_commit "d1" "$d0" "$m1")
git checkout --orphan unrelated -q
git rm -rf -q . 2>/dev/null || true
x=$(commit "unrelated-x")
check_fails "unrelated-history force-push (rewrite) → error" find_dist_parent "$d1" "$x" "rewrite"

# ----- Scenario 4: error mode, normal forward push -----
reset_repo
m0=$(commit m0)
d0=$(dist_commit "d0" "$m0")
m1=$(commit m1)
d1=$(dist_commit "d1" "$d0" "$m1")
m2=$(commit m2)
result=$(find_dist_parent "$d1" "$m2" "error")
check "normal push (error mode) → dist tip" "$d1" "$result"

# ----- Scenario 5: error mode, force-push -----
reset_repo
m0=$(commit m0)
d0=$(dist_commit "d0" "$m0")
m1=$(commit m1)
d1=$(dist_commit "d1" "$d0" "$m1")
git reset --hard -q "$m0"
m2=$(commit m2)
check_fails "force-push (error mode) → error" find_dist_parent "$d1" "$m2" "error"

# ----- Scenario 6: preserve mode always returns dist tip -----
reset_repo
m0=$(commit m0)
d0=$(dist_commit "d0" "$m0")
m1=$(commit m1)
d1=$(dist_commit "d1" "$d0" "$m1")
git reset --hard -q "$m0"
m2=$(commit m2)
result=$(find_dist_parent "$d1" "$m2" "preserve")
check "force-push (preserve mode) → dist tip" "$d1" "$result"

# ----- Scenario 7: longer chain, walks back through one merge commit -----
# main: m0 -- m1 -- m2; dist: d0(m0) -- d1(d0,m1) -- d2(d1,m2)
# force-push: amend m2 -> m3 (parent m1). Expect d1 (m1 is ancestor of m3; m2 is not).
reset_repo
m0=$(commit m0)
d0=$(dist_commit "d0" "$m0")
m1=$(commit m1)
d1=$(dist_commit "d1" "$d0" "$m1")
m2=$(commit m2)
d2=$(dist_commit "d2" "$d1" "$m2")
git reset --hard -q "$m1"
m3=$(commit m3)
result=$(find_dist_parent "$d2" "$m3" "rewrite" 2>/dev/null)
check "rewrite from middle of chain → d1" "$d1" "$result"

# ----- Scenario 8: rebase rewrites two commits, walks back further -----
reset_repo
m0=$(commit m0)
d0=$(dist_commit "d0" "$m0")
m1=$(commit m1)
d1=$(dist_commit "d1" "$d0" "$m1")
m2=$(commit m2)
d2=$(dist_commit "d2" "$d1" "$m2")
git reset --hard -q "$m0"
m1p=$(commit "m1-rewritten")
m2p=$(commit "m2-rewritten")
result=$(find_dist_parent "$d2" "$m2p" "rewrite" 2>/dev/null)
check "rebase rewrites 2 → walks back to d0" "$d0" "$result"

# ----- Scenario 9: invalid mode -----
reset_repo
m0=$(commit m0)
d0=$(dist_commit "d0" "$m0")
check_fails "invalid mode → error" find_dist_parent "$d0" "$m0" "bogus"

# ----- Scenario 10: fresh mode → empty parent (new lineage), even when ancestry exists -----
reset_repo
m0=$(commit m0)
d0=$(dist_commit "d0" "$m0")
m1=$(commit m1)
result=$(find_dist_parent "$d0" "$m1" "fresh")
check "fresh mode → empty parent" "" "$result"

# ----- Scenario 11: commit trailer overrides mode; absent trailer keeps input mode -----
reset_repo
m0=$(commit m0)
git commit --allow-empty -q -m "Rebuild dist" -m "NPM-Dist-On-Source-Rewrite: fresh"
m1=$(git rev-parse HEAD)
check "trailer overrides mode" "fresh" "$(resolve_rewrite_mode "$m1" rewrite 2>/dev/null)"
check "no trailer → input mode" "error" "$(resolve_rewrite_mode "$m0" error 2>/dev/null)"
check "trailer key is case-insensitive" "fresh" "$(git commit --allow-empty -q -m x -m "npm-dist-on-source-rewrite: fresh" && resolve_rewrite_mode HEAD rewrite 2>/dev/null)"
git commit --allow-empty -q -m y -m "NPM-Dist-Old-Dist-Tag: keep-{sha}"
check "old-dist-tag trailer overrides template" "keep-{sha}" "$(resolve_old_dist_tag HEAD "{branch}-{sha}")"
check "no old-dist-tag trailer → template" "{branch}-{sha}" "$(resolve_old_dist_tag "$m0" "{branch}-{sha}")"

# ----- Scenario 12: old_dist_tag_name expands the old tip's *source* short SHA -----
reset_repo
m0=$(commit m0)
d0=$(dist_commit "d0" "$m0")
m1=$(commit m1)
d1=$(dist_commit "d1" "$d0" "$m1")
check "tag name: merge tip → ^2 source sha" "dist-${m1:0:7}" "$(old_dist_tag_name "$d1" dist "{branch}-{sha}")"
check "tag name: initial tip → ^1 source sha" "dist/treemap-${m0:0:7}" "$(old_dist_tag_name "$d0" dist/treemap "{branch}-{sha}")"
check "tag name: literal template" "old-dist" "$(old_dist_tag_name "$d1" dist old-dist)"
check "tag name: none → empty" "" "$(old_dist_tag_name "$d1" dist none)"

# ----- Scenario 13: preserve_old_dist tags + pushes the old tip; no-op when descending -----
reset_repo
git init -q --bare "$WORK/remote.git"
git --git-dir="$WORK/remote.git" config receive.advertisePushOptions true  # as GitLab does (gl pushes tags with -o ci.skip)
git remote add origin "$WORK/remote.git"
m0=$(commit m0)
d0=$(dist_commit "d0" "$m0")
m1=$(commit m1)
d1=$(dist_commit "d1" "$d0" "$m1")
preserve_old_dist "$d1" "$d1" dist "{branch}-{sha}" >/dev/null
check "descending build → no tag" "" "$(git tag -l)"
preserve_old_dist "$d1" "" dist "{branch}-{sha}" >/dev/null
check "fresh → local tag at old tip" "$d1" "$(git rev-parse "dist-${m1:0:7}^{commit}")"
check "fresh → tag pushed to remote" "$d1" "$(git --git-dir="$WORK/remote.git" rev-parse "dist-${m1:0:7}^{commit}")"
preserve_old_dist "$d1" "$d0" dist "{branch}-{sha}" >/dev/null
check "re-tagging same tip is idempotent" "$d1" "$(git rev-parse "dist-${m1:0:7}^{commit}")"
git tag -f clash "$d0"
check_fails "tag exists at another commit → error" preserve_old_dist "$d1" "" dist clash
preserve_old_dist "$d1" "" dist none 2>/dev/null
check "old_dist_tag=none → no new tag" "clash dist-${m1:0:7}" "$(git tag -l | sort | xargs)"

# ----- Scenario 14: trailer ignored once dist was already built from that commit -----
reset_repo
m0=$(commit m0)
d0=$(dist_commit "d0" "$m0")
git commit --allow-empty -q -m "Rebuild dist" -m "NPM-Dist-On-Source-Rewrite: fresh"
m1=$(git rev-parse HEAD)
check "dist tip not yet built from trailer commit → trailer applies" "fresh" "$(resolve_rewrite_mode "$m1" rewrite "$d0" 2>/dev/null)"
d1=$(dist_commit "d1" "$m1")  # the fresh build: source commit as only parent
check "re-run for same commit (tip built from it) → trailer ignored" "rewrite" "$(resolve_rewrite_mode "$m1" rewrite "$d1" 2>/dev/null)"
m2=$(commit m2)
d2=$(dist_commit "d2" "$d1" "$m2")
check "re-run for trailer commit after dist moved past it → trailer ignored" "rewrite" "$(resolve_rewrite_mode "$m1" rewrite "$d2" 2>/dev/null)"

echo ""
echo "================================"
echo "Passed: $PASS / $((PASS + FAIL))"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAIL"
  exit 1
fi
