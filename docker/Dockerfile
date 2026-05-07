FROM debian:bookworm

ARG MISE_VERSION=2026.4.27
ARG SYMPHONY_UID=1000
ARG SYMPHONY_GID=1000

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/home/symphony \
    MISE_DATA_DIR=/opt/mise \
    MISE_CACHE_DIR=/opt/mise/cache \
    MISE_CONFIG_DIR=/opt/mise/config \
    MIX_ENV=prod \
    PATH=/opt/mise/shims:/home/symphony/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        autoconf \
        build-essential \
        ca-certificates \
        curl \
        git \
        libncurses-dev \
        libssl-dev \
        m4 \
        openssh-client \
        procps \
    && rm -rf /var/lib/apt/lists/*

RUN curl https://mise.run | MISE_VERSION="v${MISE_VERSION}" MISE_INSTALL_PATH=/usr/local/bin/mise sh

RUN groupadd --gid ${SYMPHONY_GID} symphony \
    && useradd --uid ${SYMPHONY_UID} --gid ${SYMPHONY_GID} --create-home --shell /bin/bash symphony \
    && mkdir -p /opt/mise /app/elixir /app/docker /workspace \
    && chown -R symphony:symphony /opt/mise /app /workspace

USER symphony

WORKDIR /app/elixir

COPY --chown=symphony:symphony elixir/mise.toml elixir/mix.exs elixir/mix.lock ./

RUN mise trust ./mise.toml \
    && mise install \
    && mise exec -- mix local.hex --force \
    && mise exec -- mix local.rebar --force \
    && mise exec -- mix deps.get --only prod

COPY --chown=symphony:symphony elixir /app/elixir
COPY --chown=symphony:symphony docker/entrypoint.sh /app/docker/entrypoint.sh

RUN mise exec -- mix escript.build \
    && chmod +x /app/docker/entrypoint.sh

WORKDIR /workspace

ENTRYPOINT ["/app/docker/entrypoint.sh"]
CMD ["/workspace/WORKFLOW.md"]
