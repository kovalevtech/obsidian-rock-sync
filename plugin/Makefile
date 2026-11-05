# The vaults to install into: .env, yours in .env.local
-include .env
-include .env.local

PLUGIN_DIR = .obsidian/plugins/rock-sync
ARTIFACTS = dist/main.js dist/manifest.json dist/styles.css
# The release: the tag on this commit
TAG ?= $(shell git describe --tags --exact-match 2>/dev/null)

.PHONY: phone-install desktop-install deps test lint build check-tag release-image release-plugin patch minor major ci-bump

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
	$(MAKE) -C ../backend ghcr-login push VERSION='$(TAG)'

release-plugin: check-tag build
	gh release create '$(TAG)' $(ARTIFACTS) --generate-notes

# Start a release: bump the version (package.json, the lockfile, ../manifest.json, ../versions.json), commit + tag
# without `v`, push; the tag starts CI. Here, not by npm: outside the repo root it neither commits nor tags
patch minor major:
	@test -z "$$(git status --porcelain)" || { echo 'Uncommitted changes: commit first' >&2; exit 1; }
	npm version $@ --no-git-tag-version
	git add package.json package-lock.json ../manifest.json ../versions.json
	version=$$(node -p "require('./package.json').version"); git commit -m "$$version" && git tag -a "$$version" -m "$$version"
	git push --follow-tags

# CI, on Run workflow: the same, as the bot and from main only. GITHUB_OUTPUT: the ref for the workflow to release
ci-bump:
	@case '$(LEVEL)' in patch|minor|major) ;; *) echo "LEVEL '$(LEVEL)': patch, minor or major" >&2; exit 1;; esac
	@test "$$(git branch --show-current)" = main || { echo 'A release starts from main' >&2; exit 1; }
	git config user.name 'github-actions[bot]'
	git config user.email '41898282+github-actions[bot]@users.noreply.github.com'
	$(MAKE) $(LEVEL)
	echo "ref=refs/tags/$$(git describe --tags --exact-match)" >> "$$GITHUB_OUTPUT"
