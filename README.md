# pi-ecosystem

A public dashboard for the **Pi Ecosystem** — a catalog of Pi-related repos
(runtime, config distribution mirror, extension mirrors, source, and related
services). The catalog content is curated on the
[Pi Ecosystem project board](https://github.com/orgs/psmfd/projects/3); this
repo renders it as a clean, branded static page on GitHub Pages and enriches
each repo with its **latest release and commit SHA** so consumers can pin by an
immutable SHA rather than a moving tag/branch.

## How it works

```
Projects v2 board (psmfd #3) ─┐
                              ├─► scripts/build-dashboard.sh ─► _site/index.html ─► GitHub Pages
each repo's release / tags ───┘   (run on a 6-hourly cron by Actions)
```

1. **Catalog** comes from the project board via `gh project item-list` — name,
   repo URL, description, Category, Visibility.
2. **Release info** is fetched in one batched GraphQL call per refresh:
   `latestRelease` with a fallback to the newest git tag, plus the underlying
   **commit SHA**.
3. The merged data is rendered to a self-contained `index.html` (card grid
   grouped by Category, dark-mode aware) and published to Pages.

The project board stays the single editorial source of truth. Add or edit a
repo there and the dashboard reflects it on the next run — no code change.

## Setup

GitHub Pages and the workflow need two one-time setup steps:

### 1. Create the data token (required)

Projects v2 is GraphQL-only and **always requires authentication**, even for a
public project. The default Actions `GITHUB_TOKEN` does **not** carry
`read:project` scope, so a PAT is required:

1. Create a **fine-grained PAT** — Resource owner `psmfd`, permission
   **Projects: Read-only** (required to read the board). Private repos in the
   catalog are intentionally **masked** — they render with a 🔒 and a "private"
   pill, and no version/SHA is published. The build tolerates repos the token
   cannot read (logs a warning, keeps going). If you ever want a private repo's
   release + SHA shown publicly, additionally grant **Contents: Read-only**
   including that repo; otherwise it stays masked.
2. Store it as a repo secret (run it yourself so the value never lands in a
   file or this repo's history):

   ```sh
   gh secret set CATALOG_PAT --repo psmfd/pi-ecosystem
   ```

Fine-grained PATs expire (90 days by default) — rotating `CATALOG_PAT` is the
only recurring maintenance task.

### 2. Enable Pages

Repo **Settings → Pages → Build and deployment → Source: GitHub Actions**.

Then trigger the first build: **Actions → dashboard → Run workflow**, or
`gh workflow run dashboard.yml --repo psmfd/pi-ecosystem`. The published URL is
`https://psmfd.github.io/pi-ecosystem/`.

## Local build

With a logged-in `gh` (keyring auth is fine locally — no PAT needed if your
account can read the board and repos):

```sh
./scripts/build-dashboard.sh      # writes _site/index.html
open _site/index.html             # or: python3 -m http.server -d _site
```

`VERBOSE=1` prints extra detail; `OUT_DIR=somewhere` changes the output path.

## Layout

| Path | Role |
|---|---|
| `.github/workflows/dashboard.yml` | Scheduled + manual build → Pages deploy (actions SHA-pinned) |
| `scripts/build-dashboard.sh` | Fetch board + releases, merge, render |
| `scripts/render.jq` | Merged data → grouped card HTML |
| `scripts/lib/log.sh` | Structured output helpers |
| `templates/page.html` | Page skeleton (CSS + copy-SHA JS); tokens replaced at build |

## Conventions

- **Actions are pinned to a full commit SHA**, never a floating tag/branch, with
  the human-readable version in a trailing comment. To bump a version, re-resolve
  the SHA (`gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq '.object.sha'`)
  and update both the SHA and the comment.
- The dashboard surfaces each repo's **release commit SHA** for the same reason:
  pin to the immutable SHA, not the mutable tag.
