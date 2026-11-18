# Cross-build image for qdock (arm64, Debian trixie = the games Pi's OS; no qemu needed).
FROM debian:trixie
RUN dpkg --add-architecture arm64 && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    crossbuild-essential-arm64 pkg-config make libwayland-bin ca-certificates \
    libgtk-3-dev:arm64 libgtk-layer-shell-dev:arm64 libwayland-dev:arm64 && rm -rf /var/lib/apt/lists/*
