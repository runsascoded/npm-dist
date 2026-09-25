# Source fields should replace their dist-branch counterparts, not deep-merge into them

*(From the `$oa/auth` session, 2026-09-25.)*

## Symptom

`Open-Athena/auth` removed two exports from its source `package.json` (`./cf-access` and `./schema.sql`, whose files were deleted). The next CI publish failed:

```
ERROR: exports map references files that don't exist on the dist branch:
  "./cf-access": "./dist/adapters/cf-access.js" → file not found
  "./schema.sql": "./schema.sql" → file not found
```

The source `package.json` no longer contained either key.

## Cause

`scripts/merge-dist-package.sh` builds the dist `package.json` as `$dist * $merge_obj`. jq's `*` is a **recursive** merge, so for an object-valued field like `exports` (or `dependencies`, `peerDependencies`, `bin`), keys that exist only on the previous dist `package.json` survive. A removed export, dependency or bin entry is never removed from the published package.

## Fix

The fields taken from source (`$fields_csv`) should **replace** the dist values wholesale. Use top-level `+` instead of `*`:

```jq
$dist + $merge_obj | with_entries(select(.value != null))
```

Fields *not* in `$fields_csv` still come from `$dist`, which is the point of merging at all.

- Add a case to `tests/test-merge-dist-package.sh`: dist `exports` has `{".": …, "./old": …}`, source has `{".": …}`, so the result must be exactly `{".": …}`. Also cover `dependencies` losing a key.
- Consider whether any caller relies on the deep merge (e.g. `pkg_kvs` overrides applied later use `. * $kvs`, which is separate and fine).
- After merging and retagging `v1`, the auth repo needs nothing more. Its workaround (a one-publish `exports_map: '{}'`, which makes the drop-missing-exports pass run) was already reverted in auth `4c28b9d`.

## Workaround until then

Add a non-empty `exports_map` for one publish; the drop-missing-exports pass removes the stale keys. Remove it after, since it also silently drops genuinely broken exports.
