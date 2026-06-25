#!/usr/bin/env bash
#
# build-dashboard.sh — generate the Pi Ecosystem dashboard (static index.html).
#
# Pulls the psmfd Projects v2 catalog (board #3) and each cataloged repo's
# latest release/tag — including the release commit SHA, so consumers can pin
# by SHA rather than a moving tag/branch — then renders a static card-grid
# page to $OUT_DIR/index.html.
#
# Usage:   ./scripts/build-dashboard.sh
# Env:     GH_TOKEN   auth for gh. In CI use a PAT with Projects:read +
#                     Contents:read. Local keyring auth works for interactive
#                     runs. NOTE: the default Actions GITHUB_TOKEN lacks
#                     read:project scope and will NOT work.
#          OUT_DIR    output directory (default: _site)
#          VERBOSE=1  print debug detail
#
# Exit codes: 0 success · 1 build error · 2 missing dependency / precondition
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/log.sh
. "$SCRIPT_DIR/lib/log.sh"

OWNER="psmfd"
PROJECT_NUMBER="3"
OUT_DIR="${OUT_DIR:-_site}"

# --- preconditions ---
for dep in gh jq; do
  command -v "$dep" >/dev/null 2>&1 || { err "deps" "missing required dependency: $dep"; exit 2; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- 1. catalog from the project board ---
info "fetching project #$PROJECT_NUMBER catalog for $OWNER"
gh project item-list "$PROJECT_NUMBER" --owner "$OWNER" --format json --limit 100 \
  > "$WORK/items.json" \
  || { err "catalog" "gh project item-list failed (token needs read:project scope)"; exit 1; }

# Body convention: "https://github.com/<owner>/<repo> · <public|private> · <description>"
jq '[ .items[]
  | (.content.body // "") as $body
  | {
      name:        .title,
      url:         ($body | split(" · ")[0] | select(type == "string" and startswith("http"))),
      description: (($body | split(" · ")[2]) // ""),
      category:    (.category // "Uncategorized"),
      visibility:  (.visibility // "Public"),
      status:      (.status // null)
    } ]' "$WORK/items.json" > "$WORK/catalog.json"

count="$(jq 'length' "$WORK/catalog.json")"
[ "$count" -gt 0 ] || { err "catalog" "no items found on the board"; exit 1; }
ok "catalog" "$count repos"

# --- 2. owner/name pairs for url-bearing items ---
jq -r '.[] | select(.url != null)
  | [ (.url | split("/")[3]), (.url | split("/")[4]) ] | @tsv' \
  "$WORK/catalog.json" > "$WORK/repos.tsv"

# --- 3. batched GraphQL: latest release + commit SHA, with tag fallback ---
# Index-based aliases (r0, r1, …) avoid the pi-config / pi_config collision.
ALIAS_MAP="$WORK/alias.tsv"
: > "$ALIAS_MAP"
{
  printf 'query {\n'
  i=0
  while IFS=$(printf '\t') read -r owner repo; do
    printf '  r%d: repository(owner: "%s", name: "%s") {\n' "$i" "$owner" "$repo"
    printf '    latestRelease { tagName publishedAt tagCommit { oid } }\n'
    printf '    refs(refPrefix: "refs/tags/", last: 1, orderBy: {field: TAG_COMMIT_DATE, direction: ASC}) {\n'
    printf '      nodes { name target { __typename oid ... on Tag { target { oid } } ... on Commit { committedDate } } }\n'
    printf '    }\n'
    printf '  }\n'
    printf 'r%d\t%s\n' "$i" "$repo" >> "$ALIAS_MAP"
    i=$((i + 1))
  done < "$WORK/repos.tsv"
  printf '}\n'
} > "$WORK/query.graphql"

n_repos="$(awk 'END {print NR}' "$ALIAS_MAP")"
info "querying latest release + commit SHA for $n_repos repos"
# gh exits non-zero if ANY aliased repo errors (e.g. a private repo the token
# cannot read), but still writes the full `data` object to stdout with the
# accessible repos populated and the rest null. Capture it and decide on the
# body, not the exit code: a per-repo NOT_FOUND is non-fatal (that repo simply
# renders without release data); only an absent `data` object is fatal.
set +e
gh api graphql -f query="$(cat "$WORK/query.graphql")" > "$WORK/releases.json" 2>"$WORK/releases.err"
set -e
if ! jq -e 'has("data") and (.data != null)' "$WORK/releases.json" >/dev/null 2>&1; then
  err "releases" "graphql release query returned no usable data"
  [ -s "$WORK/releases.err" ] && while IFS= read -r line; do detail "$line"; done < "$WORK/releases.err"
  exit 1
fi
# Surface per-repo errors (typically private repos the CI token cannot read) as
# warnings — the dashboard still publishes with those repos degraded.
while IFS= read -r msg; do
  [ -n "$msg" ] && warn "releases" "$msg"
done < <(jq -r '(.errors // [])[] | .message' "$WORK/releases.json")

# alias -> name map as JSON
jq -R 'split("\t") | {alias: .[0], name: .[1]}' "$ALIAS_MAP" | jq -s '.' > "$WORK/aliasmap.json"

# normalize release data, keyed by repo name (release SHA preferred, else tag commit)
jq --slurpfile amap "$WORK/aliasmap.json" '
  ($amap[0] | map({(.alias): .name}) | add) as $names
  | .data
  | to_entries
  | map(select(.key | test("^r[0-9]+$")))
  | map({
      name: $names[.key],
      tag:  (.value.latestRelease.tagName // (.value.refs.nodes[0].name // null)),
      date: (.value.latestRelease.publishedAt
             // .value.refs.nodes[0].target.committedDate // null),
      sha:  (.value.latestRelease.tagCommit.oid
             // .value.refs.nodes[0].target.target.oid
             // .value.refs.nodes[0].target.oid // null),
      source: (if .value.latestRelease != null then "release"
               elif ((.value.refs.nodes // []) | length) > 0 then "tag"
               else "none" end)
    })
  | map({(.name): {tag: .tag, date: .date, sha: .sha, source: .source}}) | add // {}
' "$WORK/releases.json" > "$WORK/releases-by-name.json"

# --- 4. merge catalog + release data (left join on derived repo name) ---
jq --slurpfile rel "$WORK/releases-by-name.json" '
  $rel[0] as $r
  | map(
      . as $item
      | (if (($item.url // "") == "") then null else ($item.url | split("/")[4]) end) as $rn
      | $item + ( ($r[$rn] // null) // {tag: null, date: null, sha: null, source: "none"} )
    )
' "$WORK/catalog.json" > "$WORK/merged.json"

# --- 5. render page from template (bash // replacement is safe with & and /) ---
title="$(gh project view "$PROJECT_NUMBER" --owner "$OWNER" --format json --jq '.title' 2>/dev/null || echo "Repo Catalog")"
desc="$(gh project view "$PROJECT_NUMBER" --owner "$OWNER" --format json --jq '.shortDescription' 2>/dev/null || echo "")"
updated="$(date -u '+%Y-%m-%d %H:%M UTC')"
board_url="https://github.com/orgs/$OWNER/projects/$PROJECT_NUMBER"
cards="$(jq -r -f "$SCRIPT_DIR/render.jq" "$WORK/merged.json")"

mkdir -p "$OUT_DIR"
template="$(cat "$ROOT/templates/page.html")"
page=${template//'{{CARDS}}'/$cards}
page=${page//'{{TITLE}}'/$title}
page=${page//'{{DESC}}'/$desc}
page=${page//'{{UPDATED}}'/$updated}
page=${page//'{{BOARD_URL}}'/$board_url}
printf '%s\n' "$page" > "$OUT_DIR/index.html"

ok "render" "$OUT_DIR/index.html ($count repos)"
print_summary
[ "$LOG_ERROR_COUNT" -eq 0 ] || exit 1
