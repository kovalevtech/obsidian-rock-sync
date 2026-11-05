# Development

The repository holds the plugin (`plugin/`) and the server (`backend/`). `manifest.json` and `versions.json` stay in the root, where Obsidian reads them. Detailed notes on how everything works and why: [`CLAUDE.md`](../CLAUDE.md).

## Server

[`backend/.env`](../backend/.env) lists every setting with a comment and its dev default. It's committed and holds no secrets: don't change it for your machine, override what you need in `backend/.env.local` (gitignored, wins over `.env`). Every other `.env*` file is gitignored too.

```sh
cd backend
bundle install
bundle exec rackup   # localhost:9292
make test
```

Out of the box it keeps its data in `backend/tmp/data` and `backend/tmp/db` (gitignored). `make vault NAME=…` creates a vault, `make vault-code VAULT=…` prints a connection code for it and its connection link (the plugin's **Connect**, or curl's `POST /pair`), both without the admin panel.

## Plugin

[`plugin/.env`](../plugin/.env) lists the vaults the plugin gets installed into; set yours in `plugin/.env.local` (gitignored). In `plugin/`, after `npm install`:

| Command | Does |
|---|---|
| `npm run dev` | Rebuilds into the test vault (`DEV_VAULT`) on every change, for the Hot Reload plugin. Never point this at a real vault |
| `make desktop-install` | A minified build into a vault on this machine (`DESKTOP_VAULT`) |
| `make phone-install` | The same into a vault on the phone over adb (`ADB_VAULT`) |
| `npm test` | The plugin's tests |
| `make test` | The plugin's and the server's tests |
| `make lint` | The community directory's checks |

The community directory runs [`eslint-plugin-obsidianmd`](https://github.com/obsidianmd/eslint-plugin) over every submitted plugin, with most rules as warnings. `obsidianmd/no-forbidden-elements` is one that blocks: no `<style>` or `<link>` elements. `make lint` (`plugin/eslint.config.mjs`) runs it the way the scanner does for a new plugin: the rules that block are errors, the rest warnings. The repository has no `jsconfig.json`, so neither the scanner nor `make lint` has type information, and the rules that need it, `no-unsupported-api` among them, don't run. CI doesn't lint.

A copy installed by hand lives in the same folder (`rock-sync`) as one from the community list, so an update from there replaces its files. Settings, token and sync state are kept in Obsidian's localStorage, not in the plugin folder, so they survive.

## Releases

One release publishes both the plugin and the server's image under one version. Either way of starting it does the same:

- **Nothing to run locally:** Actions tab → Release → Run workflow on `main`, pick patch, minor or major. The version commit lands on `main` from `github-actions[bot]`, so `git pull` afterwards.
- **From your machine,** with a clean working tree and a branch that has an upstream:

  ```sh
  cd plugin
  make patch    # or: make minor, make major
  ```

The bump:

- updates `version` in `plugin/package.json` and `plugin/package-lock.json` (`npm version <level>`);
- writes it to `manifest.json` and adds `"<version>": "<minAppVersion>"` to `versions.json` (`plugin/version-bump.mjs`);
- commits and tags the commit with the version, without a `v`;
- pushes the commit and the tag (`git push --follow-tags`).

`.github/workflows/release.yml` only calls `plugin/Makefile`:

1. `make deps test`: the plugin's and the server's tests.
2. Run workflow only: `make ci-bump`, the bump above. A failing test leaves the version alone. A tag pushed from your machine starts the workflow here, with the version already bumped.
3. `make release-image`: a check that the tag equals `version` in `manifest.json`, then the image pushed to `ghcr.io/<owner>/obsidian-rock-sync` as `<version>` and `latest`.
4. `make deps release-plugin`: the same check, the plugin's build, then a GitHub release with `main.js`, `manifest.json` and `styles.css` from `plugin/dist/`, and notes generated from the commits.

Each is a job of its own, the GitHub release last: if any fails, there's no GitHub release; the image may already be pushed. There are no secrets to set up: the workflow logs in to GHCR with its own `GITHUB_TOKEN`.

### Redoing a failed release

If nothing needs fixing, a run from Run workflow included: "Re-run failed jobs" on the run. Not "Re-run all jobs", and not Run workflow again, which would bump the version once more.

Otherwise:

```sh
gh release delete 0.0.2 -y          # only if the release was created
git push --delete origin 0.0.2
git tag -d 0.0.2
# fix, commit, push
git tag 0.0.2 && git push origin 0.0.2
```

An image already pushed under that version is overwritten.
