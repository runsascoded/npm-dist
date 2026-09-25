# npm-dist

GitHub Action for building and maintaining npm package distribution branches.

## Quick Start

### Option 1: Reusable Workflow (recommended)

```yaml
# .github/workflows/build-dist.yml
name: Build dist branch
on:
  workflow_dispatch:
jobs:
  build-dist:
    permissions:
      contents: write
    uses: runsascoded/npm-dist/.github/workflows/build-dist.yml@v1
```

### Option 2: Composite Action

```yaml
# .github/workflows/build-dist.yml
name: Build dist branch
on:
  workflow_dispatch:
jobs:
  build-dist:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: runsascoded/npm-dist@v1
```

## How It Works

1. Checks out your source code at the specified ref (or repository default branch)
2. **Auto-detects package manager** from lock files (`pnpm-lock.yaml`, `yarn.lock`, `package-lock.json`, `bun.lockb`)
3. Sets up the detected package manager and Node.js, installs dependencies
4. Runs your build command (default: `<detected-pm> run build`)
5. Creates/updates the dist branch with built artifacts at root
6. Creates merge commits linking dist to source (two parents: previous dist + source)
7. Pushes to the dist branch
8. Outputs the dist SHA and install commands (in logs and as workflow annotations)

On first run (no dist branch exists), it auto-generates `package.json` by transforming paths from source (`./dist/index.js` → `./index.js`). On subsequent runs, it keeps the dist branch's `package.json` but replaces the fields taken from source (`pkg_include`, or the defaults) wholesale, so e.g. an export or dependency removed in source is removed from dist too; a listed field missing from source is removed. Other fields (manual edits on the dist branch) are kept.

## Using the dist branch

After the workflow runs, you can install the package directly from the dist branch:

```bash
pnpm add github:owner/repo#<dist-sha>
```

Or use [pnpm-dep-source] to manage switching between local, GitHub, and npm sources:

```bash
pds github <dep> dist
```

[pnpm-dep-source]: https://github.com/runsascoded/pnpm-dep-source

## Inputs

| Input | Description | Default |
|-------|-------------|---------|
| `prebuilt_dir` | Path to pre-built output (skips checkout/setup/build) | `''` |
| `source_ref` | Source ref to build from | Repository default branch |
| `node_version` | Node.js version | `'20'` |
| `pnpm_version` | pnpm version (only if pnpm detected) | `'10'` |
| `build_command` | Build command to run | Auto-detect |
| `dist_branch` | Name of dist branch (slashes allowed — see [Namespaced dist branches](#namespaced-dist-branches-distpkg)) | `'dist'` |
| `build_dir` | Directory created by build command | `'dist'` |
| `source_dirs` | Comma-separated directories to include (e.g., `"src,types"`) | `''` |
| `extra_files` | Additional files to include (e.g., `"README.md,LICENSE"`) | `''` |
| `version_suffix` | Add `-dist.<sha>` suffix to version | `'true'` |
| `pkg_include` | package.json fields to include from source | (see below) |
| `pkg_exclude` | package.json fields to exclude | `''` |
| `pkg_kvs` | JSON object of package.json overrides | `''` |
| `on_source_rewrite` | How to handle force-pushes to source ref: `rewrite` (walk dist back to a shared ancestor and rebuild on top; fail if there is none), `preserve` (chain onto current dist tip), `error` (fail if dist tip's source-parent isn't an ancestor of the new source SHA), `fresh` (start a new dist lineage). See [Rebased / force-pushed source](#rebased--force-pushed-source-starting-a-fresh-dist-lineage) | `'rewrite'` |
| `old_dist_tag` | Tag for an old dist tip the new dist commit doesn't descend from (`{branch}`, `{sha}` placeholders; `none` disables) | `'{branch}-{sha}'` |

Default `pkg_include` fields: `name,description,keywords,repository,author,license,homepage,bugs,exports`

### `prebuilt_dir` mode

For non-JS builds (Rust/WASM, Go, etc.) where you handle the build yourself, use `prebuilt_dir` to skip all setup and just manage the dist branch:

```yaml
# Rust/WASM example
steps:
  - uses: actions/checkout@v4
    with:
      fetch-depth: 0
  - uses: Swatinem/rust-cache@v2
  - uses: jetli/wasm-pack-action@v0.4.0
  - run: wasm-pack build --target web
  - uses: runsascoded/npm-dist@v1
    with:
      prebuilt_dir: pkg
```

When `prebuilt_dir` is set, npm-dist skips checkout, Node.js setup, dependency installation, and build command—it only manages the git operations for the dist branch.

### `source_dirs` mode

For packages that don't use a `dist/` output folder (e.g., pure ESM packages with generated types), use `source_dirs` to specify which directories to include:

```yaml
- uses: runsascoded/npm-dist@v1
  with:
    source_ref: master
    build_command: pnpm run build:types
    source_dirs: src,types
```

This preserves the specified directories as-is instead of moving `dist/*` to root.

### `package_dir` mode

For a **single package inside a monorepo** that consumers pin by git SHA: `pkgs` mode keeps each package under its path beneath a private workspace root, so `github:owner/repo#<sha>` resolves to the workspace, not the package (git deps have no subdir selector). `package_dir` packs one subdir package and **flattens it to the dist branch root**, so the git dep resolves it directly:

```yaml
- uses: runsascoded/npm-dist@v1
  with:
    package_dir: packages/react   # → dist branch root IS @scope/react
```

Then `pnpm add github:owner/repo#<dist-sha>` installs that package. Mutually exclusive with `pkgs`.

### Namespaced dist branches (`dist/<pkg>`)

A repo that publishes **more than one** dist branch (e.g. a monorepo running one `package_dir` workflow per package) can namespace them under `dist/` — `dist/treemap`, `dist/react`, … — so `git branch --list 'dist/*'` enumerates every dist target and they cluster in listings. This is a naming convention, not a new mechanism: slashes are valid ref names, and consumers pin the resolved **SHA** (`github:owner/repo#<sha>`), so the branch name never reaches `package.json`. Just set `dist_branch` to the namespaced name:

```yaml
- uses: runsascoded/npm-dist@v1
  with:
    package_dir: packages/treemap
    dist_branch: dist/treemap
```

**The one constraint — git's directory/file (D/F) rule:** git stores each branch as a file under `refs/heads/`, so a bare `dist` branch (the file `refs/heads/dist`) and `dist/<anything>` (which needs `refs/heads/dist` to be a *directory*) **cannot coexist**. A repo currently on the default bare `dist` must first rename it (e.g. to `dist/<pkg>`) before adding another `dist/<x>` — its old SHA pins keep resolving, since SHAs are immutable. npm-dist detects this conflict before building and fails with an actionable message rather than a cryptic git error. For this reason the default stays bare `dist`; namespacing is opt-in.

### Rebased / force-pushed source: starting a fresh dist lineage

With no dist branch yet, every mode does a first build: the new dist commit's only parent is the source commit. After that, when the source ref is force-pushed, `on_source_rewrite` decides the new dist commit's first parent. The default, `rewrite`, walks back to the newest dist commit whose source commit still exists in the new history and builds on top of it. If none does (e.g. after rebasing a fork onto a new upstream release), the build **fails** without changing anything.

To start over instead, use `fresh`: a first build even though the branch exists (source commit as the only parent, `package.json` regenerated from source), force-pushed over the old dist branch. To use it for **one push**, with no config change, add a [git trailer] to the pushed tip commit's message, e.g. by amending it:

```bash
git commit --amend --no-edit --trailer "NPM-Dist-On-Source-Rewrite: fresh"
git push -f
```

The trailer overrides `on_source_rewrite` for that build only (only the pushed tip commit's message is read), and later pushes use the configured mode again, chaining onto the new lineage. Since the trailer stays in that commit's message, it's ignored once the dist branch has been built from that commit (or a descendant): re-running the build for it doesn't start yet another lineage. Setting `on_source_rewrite` itself to `fresh` would instead apply to every build.

Whenever the new dist commit doesn't descend from the old dist tip (`fresh`, or `rewrite` walking back past dist commits built from since-rewritten source commits), the old tip is **tagged and pushed** first, so dist SHAs that consumers have pinned stay reachable (and aren't garbage-collected). If a tag with that name already exists at a different commit, the build fails before anything is force-pushed. Pushing that tag doesn't start a CI run: a tag push runs the CI config in the tagged commit's tree, and a dist commit has none (on GitHub, pushes made with `GITHUB_TOKEN` don't trigger workflows anyway).

The tag defaults to `{branch}-{sha}`: the dist branch plus the 7-char SHA of the old tip's source commit, matching its `-dist.<sha>` version suffix (e.g. `dist-6b27ac9`, `dist/treemap-6b27ac9`). Set `old_dist_tag` (or trailer `NPM-Dist-Old-Dist-Tag: <template>`) to another template or literal name, or to `none` to skip tagging. An empty value means the default (so a workflow that forwards an unset input doesn't silently disable tagging).

[git trailer]: https://git-scm.com/docs/git-interpret-trailers

## Used By

- [aws-static-sso] ([usage][aws-static-sso-search]) - monorepo mode (`pkgs`)
- [hyparquet] ([npm][hyparquet-npm], [usage][hyparquet-search]) - `source_dirs` mode
- [og-lambda] ([usage][og-lambda-search])
- [pnpm-dep-source] ([npm][pnpm-dep-source-npm], [usage][pnpm-dep-source-search])
- [shapes] ([usage][shapes-search]) - Rust/WASM, `prebuilt_dir` + monorepo mode
- [slidev] ([usage][slidev-search]) - monorepo mode (`pkgs`)
- [use-kbd] ([npm][use-kbd-npm], [usage][use-kbd-search])
- [use-prms] ([npm][use-prms-npm], [usage][use-prms-search])
- [vite-plugin-dvc] ([usage][vite-plugin-dvc-search])

### GitLab Version

See [npm-dist (GitLab)] for the GitLab CI version and its consumers, e.g.:

- [npm-dist (GitLab)] - GitLab CI version of this tool
- [pnpm-release] - Sibling action for npm publishing and GitHub releases

[npm-dist (GitLab)]: https://gitlab.com/runsascoded/js/npm-dist
[aws-static-sso]: https://github.com/runsascoded/aws-static-sso
[aws-static-sso-search]: https://github.com/search?q=repo%3Arunsascoded%2Faws-static-sso+npm-dist&type=code
[hyparquet]: https://github.com/hyparam/hyparquet
[hyparquet-npm]: https://www.npmjs.com/package/hyparquet
[hyparquet-search]: https://github.com/search?q=repo%3Ahyparam%2Fhyparquet+pnpm-dist&type=code
[og-lambda]: https://github.com/runsascoded/og-lambda
[og-lambda-search]: https://github.com/search?q=repo%3Arunsascoded%2Fog-lambda+pnpm-dist&type=code
[pnpm-dep-source]: https://github.com/runsascoded/pnpm-dep-source
[pnpm-dep-source-npm]: https://www.npmjs.com/package/pnpm-dep-source
[pnpm-dep-source-search]: https://github.com/search?q=repo%3Arunsascoded%2Fpnpm-dep-source+npm-dist&type=code
[shapes]: https://github.com/runsascoded/shapes
[shapes-search]: https://github.com/search?q=repo%3Arunsascoded%2Fshapes+npm-dist&type=code
[slidev]: https://github.com/Open-Athena/slidev
[slidev-search]: https://github.com/search?q=repo%3AOpen-Athena%2Fslidev+npm-dist&type=code
[use-kbd]: https://github.com/runsascoded/use-kbd
[use-kbd-npm]: https://www.npmjs.com/package/use-kbd
[use-kbd-search]: https://github.com/search?q=repo%3Arunsascoded%2Fuse-kbd+npm-dist&type=code
[use-prms]: https://github.com/runsascoded/use-prms
[use-prms-npm]: https://www.npmjs.com/package/use-prms
[use-prms-search]: https://github.com/search?q=repo%3Arunsascoded%2Fuse-prms+npm-dist&type=code
[vite-plugin-dvc]: https://github.com/runsascoded/vite-plugin-dvc
[vite-plugin-dvc-search]: https://github.com/search?q=repo%3Arunsascoded%2Fvite-plugin-dvc+npm-dist&type=code
[pnpm-release]: https://github.com/runsascoded/pnpm-release

## License

MIT
