# check=skip=InvalidDefaultArgInFrom
# Production image of the server: make image (local), make push (GHCR, linux/amd64). Runs under any uid (compose
# `user:` = owner of /vaults and /db); writes only under /vaults and /db (the database, a writable directory:
# SQLite puts its -wal / -shm files next to it).
# From .ruby-version (Makefile)
ARG RUBY_VERSION

# Native gems (puma, nio4r) need a compiler (sqlite3 comes precompiled); the final image doesn't
FROM ruby:${RUBY_VERSION}-slim AS gems
RUN apt-get update && apt-get install -y --no-install-recommends build-essential && rm -rf /var/lib/apt/lists/*
ENV BUNDLE_FROZEN=1 BUNDLE_WITHOUT=development:test
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4 && rm -rf /usr/local/bundle/cache

FROM ruby:${RUBY_VERSION}-slim
RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*

ARG VERSION=dev
LABEL org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.source=https://github.com/kovalevtech/obsidian-vault-sync

# BUNDLE_USER_HOME: any uid has HOME=/, not writable — Bundler would warn and look for a temp home on every start
ENV BUNDLE_FROZEN=1 BUNDLE_WITHOUT=development:test BUNDLE_USER_HOME=/nonexistent \
    RACK_ENV=production PORT=9292 VAULTS_DIR=/vaults DB_DIR=/db
WORKDIR /app
COPY --from=gems /usr/local/bundle /usr/local/bundle
COPY . .

EXPOSE 9292
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD ["ruby", "-rnet/http", "-e", "exit Net::HTTP.get_response(URI(\"http://127.0.0.1:#{ENV['PORT']}/health\")).is_a?(Net::HTTPOK)"]
CMD ["bundle", "exec", "puma"]
