FROM node:22-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# Core languages (must install).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip python3 gcc g++ libc6-dev make \
      default-jdk-headless golang-go rustc ruby php-cli lua5.4 perl sqlite3 \
      gfortran fp-compiler \
    && rm -rf /var/lib/apt/lists/*

# Extra languages (skipped quietly if a package is unavailable).
RUN apt-get update && for p in nim elixir r-base-core mono-mcs mono-runtime ghc \
      scala groovy clojure ocaml-nox erlang-nox racket swi-prolog-nox tcl gawk octave gnucobol3 gnucobol gnat gdc nasm \
      binutils libcurl4 libxml2 libz3-4 libgcc-12-dev libstdc++-12-dev zlib1g-dev libncurses-dev libedit2 libsqlite3-0 xz-utils; do \
      apt-get install -y --no-install-recommends $p || echo "skipped $p"; \
    done && rm -rf /var/lib/apt/lists/*

# Toolchains that aren't in Debian (each one is skipped if its download fails).
RUN curl -fsSL https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz | tar -xJ -C /opt \
    && ln -s /opt/zig-linux-x86_64-0.13.0/zig /usr/local/bin/zig || echo "skipped zig"
RUN curl -fsSL https://julialang-s3.julialang.org/bin/linux/x64/1.10/julia-1.10.5-linux-x86_64.tar.gz | tar -xz -C /opt \
    && ln -s /opt/julia-1.10.5/bin/julia /usr/local/bin/julia || echo "skipped julia"
RUN curl -fsSL -o /tmp/dart.zip https://storage.googleapis.com/dart-archive/channels/stable/release/3.5.4/sdk/dartsdk-linux-x64-release.zip \
    && unzip -q /tmp/dart.zip -d /opt && rm /tmp/dart.zip && chmod -R a+rx /opt/dart-sdk \
    && ln -s /opt/dart-sdk/bin/dart /usr/local/bin/dart || echo "skipped dart"
RUN curl -fsSL https://github.com/crystal-lang/crystal/releases/download/1.14.0/crystal-1.14.0-1-linux-x86_64.tar.gz | tar -xz -C /opt \
    && ln -s /opt/crystal-1.14.0-1/bin/crystal /usr/local/bin/crystal || echo "skipped crystal"
RUN curl -fsSL https://download.swift.org/swift-6.0.3-release/debian12/swift-6.0.3-RELEASE/swift-6.0.3-RELEASE-debian12.tar.gz | tar -xz -C /opt \
    && for f in /opt/swift-6.0.3-RELEASE-debian12/usr/bin/*; do ln -sf "$f" /usr/local/bin/; done || echo "skipped swift"

# Kotlin compiler.
RUN curl -fsSL -o /tmp/kotlin.zip https://github.com/JetBrains/kotlin/releases/download/v2.0.21/kotlin-compiler-2.0.21.zip \
    && unzip -q /tmp/kotlin.zip -d /opt && rm /tmp/kotlin.zip \
    && ln -s /opt/kotlinc/bin/kotlinc /usr/local/bin/kotlinc || echo "skipped kotlin"

# More languages (each skipped quietly if its package is unavailable).
RUN apt-get update && for p in fish zsh sbcl guile-3.0 gforth gnu-smalltalk polyml rakudo haxe valac yabasic bf \
      regina-rexx algol68g pike8.0 fennel jq bc m4 gobjc libgnustep-base-dev mono-vbnc python3-pip libicu72; do \
      apt-get install -y --no-install-recommends $p || echo "skipped $p"; \
    done && rm -rf /var/lib/apt/lists/*
RUN pip3 install --no-cache-dir --break-system-packages hy || echo "skipped hy"
RUN curl -fsSL -o /tmp/v.zip https://github.com/vlang/v/releases/latest/download/v_linux.zip \
    && unzip -q /tmp/v.zip -d /opt && rm /tmp/v.zip && chmod -R a+rwX /opt/v \
    && ln -s /opt/v/v /usr/local/bin/v || echo "skipped v"
RUN mkdir -p /opt/pwsh && curl -fsSL https://github.com/PowerShell/PowerShell/releases/download/v7.4.6/powershell-7.4.6-linux-x64.tar.gz | tar -xz -C /opt/pwsh \
    && chmod +x /opt/pwsh/pwsh && ln -s /opt/pwsh/pwsh /usr/local/bin/pwsh || echo "skipped powershell"
RUN curl -fsSL https://github.com/nushell/nushell/releases/download/0.99.1/nu-0.99.1-x86_64-unknown-linux-musl.tar.gz | tar -xz -C /opt \
    && ln -s /opt/nu-0.99.1-x86_64-unknown-linux-musl/nu /usr/local/bin/nu || echo "skipped nushell"

# TypeScript runner, CoffeeScript and the Prettier formatter.
RUN npm install -g tsx@4 prettier@3 coffeescript@2 && npm cache clean --force

# Formatters and checkers for Format Document and error underlines (each skipped if unavailable).
RUN apt-get update && for p in clang-format rustfmt black shfmt; do \
      apt-get install -y --no-install-recommends $p || echo "skipped $p"; \
    done && rm -rf /var/lib/apt/lists/*

# Unprivileged user that user code runs as.
RUN useradd --create-home --shell /bin/bash runner

WORKDIR /app
COPY *.js /app/
ENV NODE_ENV=production
EXPOSE 8080
CMD ["node", "/app/server.js"]
