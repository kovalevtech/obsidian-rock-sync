.PHONY: test vault-code vault session-secret totp-secret image ghcr-user ghcr-login push

# Image tag: the commit (or tag) the image is built from
VERSION ?= $(shell git describe --tags --always --dirty)
# GHCR account: environment, else .env.local (GHCR_USER=…)
GHCR_USER ?= $(shell sed -n 's/^GHCR_USER=//p' .env.local 2>/dev/null)
IMAGE = ghcr.io/$(GHCR_USER)/obsidian-rock-sync
BUILD_ARGS = --build-arg RUBY_VERSION=$(shell cat .ruby-version) --build-arg VERSION=$(VERSION)

test:
	bundle exec ruby -Itest -e 'Dir["test/**/*_test.rb"].each { |f| require File.expand_path(f) }'

# make vault-code VAULT=personal: a one-time code connecting a device to the vault (dev database), for the plugin's
# Connect or curl's POST /pair; valid 10 minutes, like the admin panel's
vault-code:
	@VAULT='$(VAULT)' bundle exec ruby -r ./environment -e 'code = Pairings.issue(ENV["VAULT"]).first; puts code, "#{Config.public_url}?code=#{code}"'

# make vault NAME=personal: VAULTS_DIR/<name> (tree + empty repo; an existing one is kept) + its row in the dev database
vault:
	@NAME='$(NAME)' bundle exec ruby -r ./environment -e 'puts Vault.create(ENV["NAME"]).tree'

# Admin panel secrets (1Password, then the env). SESSION_SECRET: 64 random bytes as hex
session-secret:
	@ruby -rsecurerandom -e 'puts SecureRandom.hex(64)'

# ADMIN_TOTP_SECRET: base32, 160 bits; the same string goes into 1Password's one-time password field
totp-secret:
	@bundle exec ruby -rrotp -e 'puts ROTP::Base32.random'

# Local build for this machine's platform, for trying it out: obsidian-rock-sync:<version>, obsidian-rock-sync:latest
image:
	docker build $(BUILD_ARGS) -t obsidian-rock-sync:$(VERSION) -t obsidian-rock-sync:latest .

ghcr-user:
	@test -n '$(GHCR_USER)' || { echo 'GHCR_USER not set (environment or .env.local)' >&2; exit 1; }

# docker login: GHCR_TOKEN from the environment (CI: the workflow's token), else .env.local (PAT with write:packages)
ghcr-login: ghcr-user
	@token="$${GHCR_TOKEN:-$$(sed -n 's/^GHCR_TOKEN=//p' .env.local 2>/dev/null)}"; \
	test -n "$$token" || { echo 'GHCR_TOKEN not set (environment or .env.local)' >&2; exit 1; }; \
	printf '%s' "$$token" | docker login ghcr.io -u '$(GHCR_USER)' --password-stdin

# The homelab image (linux/amd64) to GHCR (make ghcr-login first). An uncommitted tree gets a `-dirty` tag
push: ghcr-user
# 	@test -z "$$(git status --porcelain)" || { echo 'Uncommitted changes: commit first' >&2; exit 1; }
	docker buildx build --platform linux/amd64 $(BUILD_ARGS) -t $(IMAGE):$(VERSION) -t $(IMAGE):latest --push .
