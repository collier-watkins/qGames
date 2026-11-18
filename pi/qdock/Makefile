# qdock for the games Pi (arm64). `make` builds in the qdock-cross Docker image (Dockerfile here); `make install`
# copies it to the Pi (PI=qpi) with its config (first time only), and restarts it.
.RECIPEPREFIX = >
PI ?= qpi
PROTO := wlr-foreign-toplevel-management-unstable-v1
PKGS := gtk+-3.0 gtk-layer-shell-0 wayland-client

qdock: qdock.c $(PROTO).xml Dockerfile
>docker build -q -t qdock-cross . >/dev/null
>docker run --rm -u $$(id -u):$$(id -g) -v $(CURDIR):/src -w /src qdock-cross sh -ec '\
  wayland-scanner client-header $(PROTO).xml /tmp/$(PROTO)-client-protocol.h; \
  wayland-scanner private-code $(PROTO).xml /tmp/$(PROTO).c; \
  export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig; \
  aarch64-linux-gnu-gcc -O2 -Wall -Wextra -Wno-unused-parameter -I/tmp -o qdock qdock.c /tmp/$(PROTO).c \
    $$(pkg-config --cflags --libs $(PKGS)) && aarch64-linux-gnu-strip qdock'

install: qdock
>ssh $(PI) 'mkdir -p ~/.local/bin ~/.config/qdock'
>scp -q qdock $(PI):.local/bin/qdock.new
>ssh $(PI) 'mv ~/.local/bin/qdock.new ~/.local/bin/qdock && { pkill -x qdock; true; }'
>ssh $(PI) 'test -f ~/.config/qdock/pinned' || scp -q pinned $(PI):.config/qdock/pinned

.PHONY: install
