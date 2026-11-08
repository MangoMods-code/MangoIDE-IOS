FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Core languages (must install).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip python3 gcc g++ libc6-dev make \
      default-jdk-headless golang-go rustc ruby php-cli lua5.4 perl sqlite3 \
      gfortran fp-compiler \
    && rm -rf /var/lib/apt/lists/*

# Extra languages (skipped quietly if a package is unavailable).
RUN apt-get update && for p in nim elixir r-base-core mono-mcs mono-runtime ghc; do \
      apt-get install -y --no-install-recommends $p || echo "skipped $p"; \
    done && rm -rf /var/lib/apt/lists/*

# Kotlin compiler.
RUN curl -fsSL -o /tmp/kotlin.zip https://github.com/JetBrains/kotlin/releases/download/v2.0.21/kotlin-compiler-2.0.21.zip \
    && unzip -q /tmp/kotlin.zip -d /opt && rm /tmp/kotlin.zip \
    && ln -s /opt/kotlinc/bin/kotlinc /usr/local/bin/kotlinc || echo "skipped kotlin"

# TypeScript runner.
RUN npm install -g tsx@4 && npm cache clean --force

# Unprivileged user that user code runs as.
RUN useradd --create-home --shell /bin/bash runner

WORKDIR /app
COPY server.js /app/server.js
ENV NODE_ENV=production
EXPOSE 8080
CMD ["node", "/app/server.js"]
