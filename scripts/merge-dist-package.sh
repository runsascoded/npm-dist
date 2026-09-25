#!/usr/bin/env bash
# merge_dist_package_json: merge a subset of fields from a source package.json
# into an existing dist-branch package.json.
#
# Usage:
#   merge_dist_package_json <dist_json> <source_json> <build_dir> <fields_csv> <preserve_dirs>
#
# Behavior:
# - $fields_csv is a comma-separated list of top-level fields to take from source
#   (e.g. "name,version,exports,dependencies"). Source is authoritative for these: each
#   replaces its dist counterpart wholesale (no deep merge, so keys removed from e.g.
#   `exports` or `dependencies` in source are removed on dist too), and a listed field
#   absent from source is removed from dist. Unlisted fields keep their dist values.
# - When $preserve_dirs is empty, string values in merged fields have
#   "./<build_dir>/" rewritten to "./" (flatten mode, the default).
# - When $preserve_dirs is non-empty, no path transformation happens, since the
#   dist branch retains the build_dir structure as-is.
# - Output is printed to stdout (caller redirects).

merge_dist_package_json() {
  local dist_json="$1"
  local source_json="$2"
  local build_dir="$3"
  local fields="$4"
  local preserve_dirs="$5"

  jq -s --arg build_dir "$build_dir" --arg fields "$fields" --arg preserve "$preserve_dirs" '
    .[0] as $dist | .[1] as $src |
    def transform_paths:
      if ($preserve | length) > 0 then .
      else
        walk(
          if type == "string" then
            gsub("\\./\($build_dir)/"; "./") | gsub("\($build_dir)/"; "./")
          else
            .
          end
        )
      end;
    ($fields | split(",") | map(gsub("^\\s+|\\s+$"; ""))) as $field_list |
    (reduce $field_list[] as $field ({}; . + {($field): ($src[$field] | transform_paths)})) as $merge_obj |
    $dist + $merge_obj | with_entries(select(.value != null))
  ' "$dist_json" "$source_json"
}
