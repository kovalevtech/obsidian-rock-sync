# The vaults to install into: .env, yours in .env.local
-include .env
-include .env.local

PLUGIN_DIR = .obsidian/plugins/rock-sync
ARTIFACTS = dist/main.js dist/manifest.json dist/styles.css
# The release: the tag on this commit
TAG ?= $(shell git describe --tags --exact-match 2>/dev/null)
# A beta (make beta) has a `-` in its version: a GitHub prerelease, the image without `latest`
PRERELEASE = $(findstring -,$(TAG))

.PHONY: phone-install desktop-install deps test lint build check-tag release-image release-plugin patch minor major beta ci-bump

# Restart Obsidian on the phone afterwards
phone-install:
	@test -n '$(ADB_VAULT)' || { echo 'ADB_VAULT not set (.env.local)' >&2; exit 1; }
	$(MAKE) build
	adb shell mkdir -p '$(ADB_VAULT)/$(PLUGIN_DIR)'
	adb push $(ARTIFACTS) '$(ADB_VAULT)/$(PLUGIN_DIR)/'

# Reload the plugin in Obsidian afterwards
desktop-install:
	@test -d '$(DESKTOP_VAULT)/.obsidian' || { echo "DESKTOP_VAULT '$(DESKTOP_VAULT)' is not a vault (.env.local)" >&2; exit 1; }
	$(MAKE) build
	mkdir -p '$(DESKTOP_VAULT)/$(PLUGIN_DIR)'
	cp $(ARTIFACTS) '$(DESKTOP_VAULT)/$(PLUGIN_DIR)/'

deps:
	npm ci

# Plugin and server (the gems installed)
test:
	npm test
	$(MAKE) -C ../backend test

# The community directory's scanner, as it would see src/ (eslint.config.mjs): errors fail, warnings are advice
lint:
	npm run lint

build:
	npm run build

check-tag:
	@version=$$(node -p "require('../manifest.json').version"); \
	test '$(TAG)' = "$$version" || { echo "tag '$(TAG)' != manifest.json version $$version" >&2; exit 1; }

# CI (.github/workflows/release.yml), one job each. The GitHub release last: devices update from it, so it means
# everything is out. GHCR_USER, GHCR_TOKEN / GH_TOKEN from the environment
release-image: check-tag
	$(MAKE) -C ../backend ghcr-login push VERSION='$(TAG)' $(if $(PRERELEASE),NO_LATEST=1)

# The plugin's release from what `build` left in dist/, not built again: CI attests those files in between, so the
# release carries exactly the attested bytes
release-plugin: check-tag
	@test -f dist/main.js || { echo 'dist/ is empty: make build first' >&2; exit 1; }
	gh release create '$(TAG)' $(ARTIFACTS) --generate-notes $(if $(PRERELEASE),--prerelease)

# Start a release: bump the version (package.json, the lockfile, ../manifest.json, ../versions.json), commit + tag
# without `v`, push; the tag starts CI. Here, not by npm: outside the repo root it neither commits nor tags
patch minor major:
	@test -z "$$(git status --porcelain)" || { echo 'Uncommitted changes: commit first' >&2; exit 1; }
	npm version $@ --no-git-tag-version
	git add package.json package-lock.json ../manifest.json ../versions.json
	version=$$(node -p "require('./package.json').version"); git commit -m "$$version" && git tag -a "$$version" -m "$$version"
	git push --follow-tags

# A beta of the next release (LEVEL=patch, the default, or minor / major): `<next>-beta.<n>`, from whatever is checked
# out (a branch too), to try on a server and a few devices before everyone gets it. Its version commit is made in a
# temporary worktree and stays off every branch: only the tag is pushed, and CI releases it like any tag. Obsidian
# offers updates by ../manifest.json on the default branch, which doesn't change, so no device is offered a beta.
# The release itself later: make patch (/ minor / major) on main, as usual
beta:
	@case '$(or $(LEVEL),patch)' in patch|minor|major) ;; *) echo "LEVEL '$(LEVEL)': patch, minor or major" >&2; exit 1;; esac
	@test -z "$$(git status --porcelain --untracked-files=no)" || { echo 'Uncommitted changes: commit first' >&2; exit 1; }
	@set -e; git fetch --tags --quiet origin; \
	next=$$(node -p "const [a, b, c] = require('../manifest.json').version.split('-')[0].split('.').map(Number); \
	  ({ patch: [a, b, c + 1], minor: [a, b + 1, 0], major: [a + 1, 0, 0] })['$(or $(LEVEL),patch)'].join('.')"); \
	n=$$(git tag -l "$$next-beta.*" | sed 's/.*-beta\.//' | sort -n | tail -1); \
	version="$$next-beta.$$(( $${n:-0} + 1 ))"; \
	dir=$$(mktemp -d); trap 'git -C "$(CURDIR)" worktree remove --force "$$dir"' EXIT; \
	git worktree add --quiet --detach "$$dir"; \
	cd "$$dir/plugin"; \
	npm version "$$version" --no-git-tag-version >/dev/null; \
	git add package.json package-lock.json ../manifest.json ../versions.json; \
	git commit --quiet -m "$$version"; git tag -a "$$version" -m "$$version"; \
	git push origin "refs/tags/$$version"; \
	echo "$$version: CI tests it, pushes the image as :$$version and makes a prerelease"

# CI, on Run workflow: the same, as the bot and from main only. GITHUB_OUTPUT: the ref for the workflow to release
ci-bump:
	@case '$(LEVEL)' in patch|minor|major) ;; *) echo "LEVEL '$(LEVEL)': patch, minor or major" >&2; exit 1;; esac
	@test "$$(git branch --show-current)" = main || { echo 'A release starts from main' >&2; exit 1; }
	git config user.name 'github-actions[bot]'
	git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
	$(MAKE) $(LEVEL)
	echo "ref=refs/tags/$$(git describe --tags --exact-match)" >> "$$GITHUB_OUTPUT"
