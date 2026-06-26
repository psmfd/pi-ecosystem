# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A build pipeline that renders a single static `index.html` dashboard for the **Pi Ecosystem** and publishes it to GitHub Pages. There is no application server and no client framework — the entire output is a self-contained HTML file generated from data fetched at build time.

The **editorial source of truth is external**: the [psmfd Projects v2 board #3](https://github.com/orgs/psmfd/projects/3). Repos are added/edited there, not in this codebase. The build reads the board, enriches each repo with its latest release/tag and **commit SHA**, and renders cards. Changing the catalog means editing the board; changing the *presentation* means editing this repo.

## Commands

```sh
./scripts/build-dashboard.sh        # build → _site/index.html (default OUT_DIR=_site)
open _site/index.html               # preview, or: python3 -m http.server -d _site
VERBOSE=1 ./scripts/build-dashboard.sh   # extra per-step detail
OUT_DIR=somewhere ./scripts/build-dashboard.sh
```

There is **no test suite, linter config, or package manager** here — the only dependencies are `gh` and `jq` (the script exits 2 if either is missing). To validate a change, run the build and inspect the generated HTML.

Auth: locally, a logged-in `gh` (keyring) works if your account can read the board. In CI the build uses `GH_TOKEN` from the `CATALOG_PAT` secret — a fine-grained PAT with **Projects: Read-only** (+ optionally **Contents: Read-only** to unmask a private repo). The default Actions `GITHUB_TOKEN` will **not** work — it lacks `read:project` scope.

## Build pipeline (scripts/build-dashboard.sh)

The script is a 5-stage `jq`/`gh` pipeline over temp files in a `mktemp -d` workdir. Understanding the data shape flowing between stages is the key to working here:

1. **Catalog** — `gh project item-list` → parse each item's `body` by the ` · ` delimiter convention (`<url> · <public|private> · <description>`) into `{name, url, description, category, visibility, status}`.
2. **Repo pairs** — extract `owner/name` from each item URL.
3. **Batched GraphQL** — one `gh api graphql` call builds the query dynamically with **index-based aliases** (`r0`, `r1`, …) — deliberately, to avoid name collisions like `pi-config`/`pi_config`. Each alias fetches `latestRelease` with a fallback to the newest git **tag**, plus the commit `oid`.
4. **Merge** — left-join release data onto the catalog by derived repo name; repos with no release data get null fields and `source: "none"`.
5. **Render** — `scripts/render.jq` produces the card HTML; `build-dashboard.sh` substitutes `{{CARDS}}`/`{{TITLE}}`/`{{DESC}}`/`{{UPDATED}}`/`{{BOARD_URL}}` into `templates/page.html` via bash `${var//find/replace}`.

### Critical: partial-failure tolerance in the release query

`gh api graphql` **exits non-zero if any aliased repo errors** (e.g. a private repo the CI token can't read), but still writes a full `data` object with the readable repos populated and the rest null. The script therefore captures the call inside `set +e`/`set -e` and **decides on the response body, not the exit code**: an absent `data` object is fatal; per-repo `NOT_FOUND` errors become `warn`s and that repo renders degraded (masked with 🔒, no version/SHA). Do not "fix" this by treating the non-zero exit as failure — that breaks the by-design private-repo masking.

## SHA-pinning convention (applies to two distinct things)

This is a load-bearing convention in this repo, in two places:

- **Workflow actions** (`.github/workflows/dashboard.yml`) are pinned to a **full commit SHA**, never a floating tag, with the version in a trailing comment. To bump: `gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq '.object.sha'`, then update both the SHA and the comment.
- **The dashboard itself** surfaces each cataloged repo's **release commit SHA** (copy-to-clipboard button) for the same reason — consumers pin to the immutable SHA, not the mutable tag. Release SHA is preferred; the newest tag's commit is the fallback.

## Output conventions

`scripts/lib/log.sh` provides `ok`/`skip`/`warn`/`info`/`err`/`detail`/`fatal`/`print_summary` and owns `LOG_ERROR_COUNT`/`LOG_WARN_COUNT`. `warn`/`err` go to stderr; everything else to stdout. The build ends with a `print_summary` block and exits 1 if any errors were counted. Labels are 6-char left-aligned (`OK    [name] message`). `log.sh` is defined inline (not sourced from a shared framework lib) because this repo is standalone and must stay bash-3.2 safe.

## Categories and rendering order

`render.jq` groups cards into a fixed category order: `Runtime`, `Source`, `Config mirror`, `Extension mirror`, `Related`. Any category present in the data but not in that list is appended afterward in alphabetical order. All user-derived strings pass through the `esc` HTML-escaping helper — preserve that when editing the renderer, since board content is untrusted input rendered into a public page.

`render.jq` also hardcodes one **entry-point special-case**: the card whose URL slug is `pi-config` (the public Config-distribution mirror — *not* the private `pi_config` underscore monorepo) gets the `entry` CSS class and a `★ Start here` badge marking it as the install/configuration entry point. The match is on the URL slug, not the display title. To move the marker, change the `$slug == "pi-config"` test.

The static intro paragraph is hardcoded in `templates/page.html` (the `.about` section), independent of board data and unaffected by token substitution.

### Build gotcha: ampersands in template substitution

The build assembles the page with bash `${template//'{{TOKEN}}'/$value}`. Under **bash 5.x** (local and CI's `ubuntu-latest`), an unescaped `&` in the *replacement* value expands to the matched pattern, and `\` is an escape — so raw board content (title/description) or generated HTML containing `&` would corrupt as `{{TOKEN}}`. `/` is *not* special in the replacement. The `esc_repl` helper in `build-dashboard.sh` escapes each value (`\`→`\\`, then `&`→`\&`) in place before substitution, so all five tokens substitute literally. Preserve that escaping if you add a new `{{TOKEN}}` — run the value through `esc_repl` too.
