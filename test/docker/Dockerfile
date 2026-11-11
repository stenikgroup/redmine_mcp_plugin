# syntax=docker/dockerfile:1

# One cell of the CI matrix, to run the plugin test suite locally: a Redmine
# checkout at REDMINE_REF (branch or tag of github.com/redmine/redmine) on the
# given Ruby, with SQLite. The plugin is not copied in: mount the repository at
# /redmine/plugins/redmine_mcp_plugin. See docs/internals.md, "Running the tests".

ARG RUBY_VERSION=3.3
FROM ruby:${RUBY_VERSION}-bookworm

ARG REDMINE_REF=7.0-stable

ENV LANG=C.UTF-8 RAILS_ENV=test BUNDLE_JOBS=4

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential libsqlite3-dev libyaml-dev pkg-config git curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /redmine

RUN curl -fsSL "https://github.com/redmine/redmine/archive/${REDMINE_REF}.tar.gz" \
    | tar xz --strip-components=1

# Redmine's Gemfile reads this file to pick the database adapter gem, so it
# has to exist before bundle install.
COPY <<EOF config/database.yml
test:
  adapter: sqlite3
  database: db/redmine_test.sqlite3
EOF

# Redmine releases older than the minitest 6 lock (6.1.0) resolve to minitest 6
# on a fresh bundle, which the Rails 7.2 test runner cannot drive.
RUN grep -q "gem 'minitest'" Gemfile || echo "gem 'minitest', '~> 5.27'" > Gemfile.local

RUN bundle config set --local without development && bundle install

# The migrations print about 1800 lines; only their errors (stderr) are kept.
COPY --chmod=755 <<'EOF' /entrypoint.sh
#!/bin/sh
set -eu
bin/rails db:migrate redmine:plugins:migrate > /dev/null
exec "$@"
EOF

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bin/rails", "redmine:plugins:test", "NAME=redmine_mcp_plugin"]
