# npm-dist

Reusable GitHub Actions workflow for building and maintaining npm package distribution branches.

## Overview

This repo provides a reusable GitHub Actions workflow that automates building npm packages and maintaining a separate `dist` branch containing the compiled artifacts. This pattern is useful for:

- Publishing pre-built packages directly from GitHub (e.g., via `github:user/repo#dist`)
- Avoiding the need to commit build artifacts to the main branch
- Maintaining a clean separation between source and built code

## Architecture

### Key Components

1. **Composite Action** (`action.yml`)
   - Single-file action that other repos can call via `uses: runsascoded/npm-dist@v1`
   - Handles checkout, setup, build, commit, and push to dist branch
   - Configurable: node version, pnpm version, build command, dist branch name
   - Build script inlined in the action (no separate script file needed)

### Dist Branch Pattern

The dist branch:
- Contains **built artifacts** at the root (e.g., `index.js`, `index.cjs`, `index.d.ts`)
- Maintains its own `package.json` with **adjusted paths** (`./index.js` not `./dist/index.js`)
- Has a **parallel lineage** with occasional merges from main
- Can receive **direct commits** when metadata needs updating

Example commit structure:
```
main:  A --- B --- C --- D
                \       \
dist:            X --- Y --- Z
```

Where X, Y, Z are merge commits with two parents:
1. Previous dist commit (or orphan for first commit)
2. Source commit from main

### Package.json Management

On **first run** (no dist branch exists), the script auto-generates `package.json` by:
1. Copying fields from source `package.json` (configurable via `pkg_include`)
2. Transforming paths (`./dist/index.js` → `./index.js`)
3. Removing dev-only fields (`files`, `scripts`, `devDependencies`)

On **subsequent runs**, it merges source metadata into the existing dist `package.json`, preserving any manual customizations while updating fields like `version`, `exports`, etc.

You can customize this behavior with:
- `pkg_include`: Fields to copy from source (default: `name,description,keywords,repository,author,license,homepage,bugs,exports`)
- `pkg_exclude`: Fields to skip
- `pkg_kvs`: JSON overrides (e.g., `{"name":"custom-name"}`)

## Usage

```yaml
# .github/workflows/build-dist.yml
name: Build dist branch

on:
  workflow_dispatch:
    inputs:
      source_ref:
        description: 'Source ref to build from'
        default: 'main'

jobs:
  build-dist:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: runsascoded/npm-dist@v1
        with:
          source_ref: ${{ inputs.source_ref }}
```

### Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `prebuilt_dir` | Path to pre-built output (skips checkout/setup/build) | `''` |
| `source_ref` | Source ref to build from | Repository default branch |
| `node_version` | Node.js version | `'20'` |
| `pnpm_version` | pnpm version (only if pnpm detected) | `'10'` |
| `build_command` | Build command to run | Auto-detect |
| `dist_branch` | Name of dist branch | `'dist'` |
| `build_dir` | Directory created by build command | `'dist'` |
| `source_dirs` | Comma-separated directories to include | `''` |
| `extra_files` | Additional files to include | `''` |
| `version_suffix` | Add `-dist.<sha>` suffix to version | `'true'` |
| `pkg_include` | package.json fields to include from source | (see above) |
| `pkg_exclude` | package.json fields to exclude | `''` |
| `pkg_kvs` | JSON object of package.json overrides | `''` |
| `on_source_rewrite` | Force-push handling: `rewrite` (walk back to shared ancestor), `preserve` (chain onto tip), `error` (fail), `fresh` (new lineage). Per-push override: `NPM-Dist-On-Source-Rewrite: <mode>` commit trailer | `'rewrite'` |
| `old_dist_tag` | Tag for an old dist tip the new commit doesn't descend from (`{branch}`, `{sha}`; `none` disables). Trailer: `NPM-Dist-Old-Dist-Tag` | `'{branch}-{sha}'` |

## Implementation Tasks

### Phase 1: Core Functionality
- [x] Create composite action with inlined build script
- [x] Create initial README with usage instructions
- [x] Document initial dist branch setup process
- [ ] Test with use-url-params as the first consumer

### Phase 2: Parameterization
- [x] Add `build_dir` parameter (was hardcoded to `dist/`)
- [x] Add `source_dirs` parameter for preserving directory structure
- [x] Add `version_suffix` parameter for `-dist.<sha>` versioning
- [x] Add `extra_files` parameter for additional files
- [x] Add `pkg_include`/`pkg_exclude`/`pkg_kvs` for package.json control
- [x] Auto-detect package manager (pnpm, npm, yarn, bun)
- [x] Add `prebuilt_dir` for non-JS builds
- [ ] Add validation for required parameters

### Phase 3: Polish
- [ ] Add comprehensive error messages
- [ ] Document edge cases and troubleshooting
- [ ] Create example repos demonstrating usage

## Design Decisions

### Why preserve dist branch package.json?

The `package.json` on dist has different paths than main (`./index.js` vs `./dist/index.js`). Rather than auto-transforming paths (brittle), we:
1. Let dist branch manage its own `package.json`
2. Require manual initial setup
3. Update via direct commits to dist when needed

This makes the "parallel lineage" pattern more explicit and maintainable.

### Why inline the script in action.yml?

The build script is inlined in `action.yml` because:
1. Single-file distribution - callers just need `uses: runsascoded/npm-dist@v1`
2. No bootstrap problem - callers don't need to set up a script on their dist branch first
3. Script updates automatically available to all consumers using `@v1`

### Why use merge commits?

Merge commits create explicit connections between dist builds and source commits:
- Enables `git log --graph` visualization of the relationship
- Makes it easy to see which source commit produced a dist build
- Allows dist branch to have its own commits (package.json updates)

## Related Projects

- [use-url-params](https://github.com/runsascoded/use-url-params) - First consumer of this pattern
- [npm-dist-workflow](https://github.com/conventional-actions/npm-dist-workflow) - Similar but npm-focused (if exists)

## Notes for Future Sessions

- Consider whether to support multiple build outputs (e.g., both ESM and CJS in separate dirs)
- Investigate if GitHub's artifact retention could be used instead of dist branches
- GitLab version lives at https://gitlab.com/runsascoded/js/npm-dist (separate branch, cherry-pick to sync)
