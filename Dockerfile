# The Helmsman server image (add-release-distribution decision 2).
#
#   docker build -t helmsman .
#   docker build --build-arg DAEMON_DIST=daemon-dist -t helmsman .
#
# The build context is the repository root: the server has a path dependency
# on ../protocol and every project reads ../VERSION. DAEMON_DIST names a
# directory of the context (daemon-dist/ or dist/, see .dockerignore) with
# helmsman-<target> binaries and their .sha256 files (scripts/build-daemon.sh);
# they are served by /downloads/daemon/<target> and /install.sh. Without it the
# image bundles no binary.
#
# The versions match .tool-versions; see docs/DEPLOY.md.

ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=28.5.0.7
# The Debian bookworm snapshot of the hexpm/elixir image; the runner uses the
# same one.
ARG DEBIAN_DATE=20261005
ARG NODE_VERSION=24

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-bookworm-${DEBIAN_DATE}"
ARG RUNNER_IMAGE="docker.io/debian:bookworm-${DEBIAN_DATE}-slim"
ARG NODE_IMAGE="docker.io/node:${NODE_VERSION}-bookworm-slim"

# npm dependencies of the assets (Mermaid), bundled by esbuild below.
FROM ${NODE_IMAGE} AS node_modules

WORKDIR /assets
COPY server/assets/package.json server/assets/package-lock.json ./
RUN npm ci --no-audit --no-fund

# The daemon binaries, if any: only helmsman-* files of DAEMON_DIST.
FROM ${RUNNER_IMAGE} AS daemon_dist

ARG DAEMON_DIST=.
RUN --mount=type=bind,source=${DAEMON_DIST},target=/src \
    mkdir -p /daemon-dist \
  && find /src -maxdepth 1 -type f -name 'helmsman-*' -exec cp {} /daemon-dist/ \; \
  && find /daemon-dist -type f -exec chmod 0644 {} + \
  && ls -l /daemon-dist

FROM ${BUILDER_IMAGE} AS builder

# git: the lucide and daisyUI dependencies are git repositories.
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force

WORKDIR /build
COPY VERSION ./
COPY protocol/mix.exs protocol/mix.lock ./protocol/
COPY protocol/lib ./protocol/lib
# Read at compile time (MCP resources, the REST API's public documents).
COPY docs ./docs

WORKDIR /build/server
COPY server/mix.exs server/mix.lock ./
RUN mix deps.get --only prod

# Compile-time configuration first, so dependencies are cached across code
# changes.
RUN mkdir config
COPY server/config/config.exs server/config/prod.exs config/
RUN mix deps.compile

RUN mix tailwind.install --if-missing && mix esbuild.install --if-missing

COPY server/priv priv
COPY server/lib lib
COPY server/assets assets
COPY --from=node_modules /assets/node_modules assets/node_modules

RUN mix compile
RUN mix assets.deploy

# Runtime configuration and the release overlays (bin/start, bin/server,
# bin/migrate) do not need a recompile.
COPY server/config/runtime.exs config/
COPY server/rel rel
RUN mix release helmsman

FROM ${RUNNER_IMAGE} AS runner

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    libstdc++6 openssl libncurses6 locales ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod \
    PORT=4000 \
    HELMSMAN_DATA_DIR=/var/lib/helmsman \
    HELMSMAN_DAEMON_DIST_DIR=/app/daemon-dist

RUN groupadd --system --gid 10001 helmsman \
  && useradd --system --uid 10001 --gid helmsman --home-dir /app --shell /usr/sbin/nologin helmsman \
  && mkdir -p /app /var/lib/helmsman \
  && chown helmsman:helmsman /app /var/lib/helmsman

WORKDIR /app

COPY --from=builder --chown=helmsman:helmsman /build/server/_build/prod/rel/helmsman ./
COPY --from=daemon_dist --chown=root:root /daemon-dist /app/daemon-dist

USER helmsman

VOLUME ["/var/lib/helmsman"]
EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT:-4000}/healthz" || exit 1

CMD ["/app/bin/start"]
