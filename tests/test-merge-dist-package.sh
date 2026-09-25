#!/usr/bin/env bash
# Tests for merge_dist_package_json. Sources scripts/merge-dist-package.sh
# from the same repo so test/impl drift is structurally prevented.
#
# Run from anywhere:  bash gh/tests/test-merge-dist-package.sh
set -e

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

# shellcheck source=../scripts/merge-dist-package.sh
source "$REPO_ROOT/scripts/merge-dist-package.sh"

WORK=$(mktemp -d -t merge-dist-package-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

PASS=0
FAIL=0

# Compare two JSON snippets as canonicalized strings.
check_json() {
  local desc="$1" expected="$2" actual="$3"
  local expected_norm actual_norm
  expected_norm=$(echo "$expected" | jq -S .)
  actual_norm=$(echo "$actual" | jq -S .)
  if [ "$expected_norm" = "$actual_norm" ]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc"
    echo "  expected: $expected_norm"
    echo "  actual:   $actual_norm"
    FAIL=$((FAIL + 1))
  fi
}

# ----- Scenario 1: preserve mode keeps ./dist/* exports verbatim -----
# This is the bug: in preserve mode the merge branch must NOT flatten ./dist/.
cat > dist.json <<'EOF'
{
  "name": "pkg",
  "version": "0.1.0-dist.abc1234",
  "exports": { "./dist/*": "./dist/*", "./basic": "./lib/index-basic.js" }
}
EOF
cat > src.json <<'EOF'
{
  "name": "pkg",
  "version": "0.2.0",
  "exports": { "./dist/*": "./dist/*", "./basic": "./lib/index-basic.js" }
}
EOF
actual=$(merge_dist_package_json dist.json src.json "dist" "name,version,exports" "dist,lib")
expected='{
  "name": "pkg",
  "version": "0.2.0",
  "exports": { "./dist/*": "./dist/*", "./basic": "./lib/index-basic.js" }
}'
check_json "preserve mode: ./dist/* exports preserved verbatim" "$expected" "$actual"

# ----- Scenario 2: non-preserve (default) flattens ./dist/* -----
cat > dist.json <<'EOF'
{
  "name": "pkg",
  "version": "0.1.0-dist.abc1234",
  "exports": { "./foo": "./foo.js" }
}
EOF
cat > src.json <<'EOF'
{
  "name": "pkg",
  "version": "0.2.0",
  "exports": { "./foo": "./dist/foo.js", "./bar": "./dist/bar.js" }
}
EOF
actual=$(merge_dist_package_json dist.json src.json "dist" "name,version,exports" "")
expected='{
  "name": "pkg",
  "version": "0.2.0",
  "exports": { "./foo": "./foo.js", "./bar": "./bar.js" }
}'
check_json "default flatten: ./dist/foo → ./foo in exports values" "$expected" "$actual"

# ----- Scenario 3: non-preserve also rewrites `main` -----
cat > dist.json <<'EOF'
{ "name": "pkg", "main": "./index.js" }
EOF
cat > src.json <<'EOF'
{ "name": "pkg", "main": "./dist/index.js" }
EOF
actual=$(merge_dist_package_json dist.json src.json "dist" "name,main" "")
expected='{ "name": "pkg", "main": "./index.js" }'
check_json "default flatten: main rewritten" "$expected" "$actual"

# ----- Scenario 4: preserve mode keeps `main` as ./dist/index.js -----
cat > dist.json <<'EOF'
{ "name": "pkg", "main": "./dist/index.js" }
EOF
cat > src.json <<'EOF'
{ "name": "pkg", "main": "./dist/index.js" }
EOF
actual=$(merge_dist_package_json dist.json src.json "dist" "name,main" "dist")
expected='{ "name": "pkg", "main": "./dist/index.js" }'
check_json "preserve: main untouched" "$expected" "$actual"

# ----- Scenario 5: fields not in include-list are kept from dist as-is -----
cat > dist.json <<'EOF'
{ "name": "pkg", "version": "0.1.0", "scripts": { "custom": "ok" } }
EOF
cat > src.json <<'EOF'
{ "name": "pkg", "version": "0.2.0", "scripts": { "build": "tsc" } }
EOF
actual=$(merge_dist_package_json dist.json src.json "dist" "name,version" "")
expected='{ "name": "pkg", "version": "0.2.0", "scripts": { "custom": "ok" } }'
check_json "non-listed fields kept from dist" "$expected" "$actual"

# ----- Scenario 6: listed field absent from source is removed from dist -----
cat > dist.json <<'EOF'
{ "name": "pkg", "version": "0.1.0", "bin": { "pkg": "./cli.js" }, "exports": { "./dist/*": "./dist/*" } }
EOF
cat > src.json <<'EOF'
{ "name": "pkg", "version": "0.2.0" }
EOF
actual=$(merge_dist_package_json dist.json src.json "dist" "name,version,bin,exports" "dist")
expected='{ "name": "pkg", "version": "0.2.0" }'
check_json "listed fields absent from source: removed from dist" "$expected" "$actual"

# ----- Scenario 7: preserve mode treats any non-empty preserve_dirs as preserve -----
# Even if it's an unrelated dir (lib), preserve mode is signaled by non-empty string.
cat > dist.json <<'EOF'
{ "name": "pkg", "exports": { "./dist/*": "./dist/*" } }
EOF
cat > src.json <<'EOF'
{ "name": "pkg", "exports": { "./dist/*": "./dist/*" } }
EOF
actual=$(merge_dist_package_json dist.json src.json "dist" "name,exports" "lib")
expected='{ "name": "pkg", "exports": { "./dist/*": "./dist/*" } }'
check_json "preserve mode signal: any non-empty preserve_dirs disables flattening" "$expected" "$actual"

# ----- Scenario 8: source exports replace dist exports (removed keys don't survive) -----
cat > dist.json <<'EOF'
{ "name": "pkg", "exports": { ".": "./index.js", "./old": "./old.js" } }
EOF
cat > src.json <<'EOF'
{ "name": "pkg", "exports": { ".": "./dist/index.js" } }
EOF
actual=$(merge_dist_package_json dist.json src.json "dist" "name,exports" "")
expected='{ "name": "pkg", "exports": { ".": "./index.js" } }'
check_json "exports key removed in source is removed on dist" "$expected" "$actual"

# ----- Scenario 9: dependencies losing a key -----
cat > dist.json <<'EOF'
{ "name": "pkg", "dependencies": { "a": "^1.0.0", "b": "^2.0.0" }, "custom": { "x": 1 } }
EOF
cat > src.json <<'EOF'
{ "name": "pkg", "dependencies": { "a": "^1.1.0" }, "custom": { "y": 2 } }
EOF
actual=$(merge_dist_package_json dist.json src.json "dist" "name,dependencies" "")
expected='{ "name": "pkg", "dependencies": { "a": "^1.1.0" }, "custom": { "x": 1 } }'
check_json "dependency removed in source is removed on dist; unlisted field kept from dist" "$expected" "$actual"

echo ""
echo "================================"
echo "Passed: $PASS / $((PASS + FAIL))"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed: $FAIL"
  exit 1
fi
