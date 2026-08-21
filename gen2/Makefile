# qGames2 build tooling.
#
# GAME is required for the single-game targets (import/run/test/export-*).
# Games are auto-discovered from games/*/project.godot — adding a new game
# needs no edit here (see tools/new_game.sh).

.RECIPEPREFIX = >

SHELL := /bin/bash
GODOT ?= godot

# Godot resolves an --export-release output path relative to the PROJECT dir
# (games/<name>), not the working directory — so every export path here must be
# absolute or the artifact lands inside the game folder, or fails outright.
ROOT := $(CURDIR)

GAMES      := $(patsubst games/%/project.godot,%,$(wildcard games/*/project.godot))
GAMES_LIST  = $(if $(GAMES),$(GAMES),(none found under games/*/project.godot))

.DEFAULT_GOAL := help

.PHONY: help _check-game import run test test-all export-linux export-arm64 export-all \
        dist dist-tar deploy install uninstall bake bake-clean version new-game clean

help:
>@echo "qGames2 — available targets:"
>@echo "  make import        GAME=<name>              headless import for one game"
>@echo "  make run           GAME=<name>               run one game"
>@echo "  make test          GAME=<name>               headless tests for one game"
>@echo "  make test-all                                headless tests for every game"
>@echo "  make export-linux  GAME=<name>                export 'Linux x86_64' into dist/"
>@echo "  make export-arm64  GAME=<name>                export 'Linux arm64' into dist/"
>@echo "  make export-all                               export both arches, every game"
>@echo "  make new-game      NAME=<name> [TITLE=\"Display Name\"]     scaffold a new game"
>@echo "  make clean                                    remove dist/ and games/*/.godot/"
>@echo ""
>@echo "Discovered games: $(GAMES_LIST)"

# Common guard for targets that take a single GAME=.
_check-game:
>@test -n "$(GAME)" || { echo "error: GAME is required. Discovered games: $(GAMES_LIST)" >&2; exit 1; }
>@test -f "games/$(GAME)/project.godot" || { echo "error: no such game 'games/$(GAME)' (missing project.godot). Discovered games: $(GAMES_LIST)" >&2; exit 1; }

import: _check-game
>$(GODOT) --headless --path games/$(GAME) --import

run: _check-game
>$(GODOT) --path games/$(GAME)

# A fresh clone has no games/<g>/.godot — it is generated, and correctly
# gitignored. Without it Godot has no global class registry, so every
# `class_name` in the project fails to resolve and the whole suite dies with
# "Parse error" that says nothing about the real cause. Importing first when
# the cache is absent costs seconds once and makes `make test` work on a
# checkout, which is what anyone tries first.
define ensure_import
if [ ! -d "games/$(1)/.godot" ]; then 	echo "-- first run: importing $(1)"; 	$(GODOT) --headless --path "games/$(1)" --import >/dev/null 2>&1 || true; fi
endef

test: _check-game
>@$(call ensure_import,$(GAME))
>$(GODOT) --headless --path games/$(GAME) --script res://tests/run.gd

test-all:
>@games="$(GAMES)"; if [ -z "$$games" ]; then echo "no games found under games/*/project.godot"; exit 0; fi; status=0; for g in $$games; do echo "== test: $$g =="; if [ ! -d "games/$$g/.godot" ]; then echo "-- first run: importing $$g"; $(GODOT) --headless --path "games/$$g" --import >/dev/null 2>&1 || true; fi; $(GODOT) --headless --path "games/$$g" --script res://tests/run.gd || status=1; done; exit $$status

export-linux: _check-game
>@mkdir -p "dist/$(GAME)"
>$(GODOT) --headless --path games/$(GAME) --export-release "Linux x86_64" "$(ROOT)/dist/$(GAME)/$(GAME)-x86_64"

export-arm64: _check-game
>@mkdir -p "dist/$(GAME)"
>$(GODOT) --headless --path games/$(GAME) --export-release "Linux arm64" "$(ROOT)/dist/$(GAME)/$(GAME)-arm64"

ARCHES := x86_64 arm64 x86_32 arm32
VERSION = $(shell tools/version.sh)

version:
>@tools/version.sh

# Write games/*/build_config.cfg — the settings that ride INSIDE the export.
bake:
>@tools/bake_config.sh --all

bake-clean:
>@tools/bake_config.sh --clean

# A self-contained, shippable dist/: every game, every architecture, plus the
# installer and each game's icon. Copy the directory to a target machine and
# run ./install.sh — no toolchain, no environment, nothing else needed.
dist: bake
>@rm -rf dist && mkdir -p dist
>@echo "$(VERSION)" > dist/VERSION
>@games="$(GAMES)"; status=0; for g in $$games; do \
>	mkdir -p "dist/$$g"; \
>	name=$$(grep -oP 'config/name="\K[^"]+' "games/$$g/project.godot"); \
>	printf 'id=%s\nname=%s\nversion=%s\n' "$$g" "$$name" "$(VERSION)" > "dist/$$g/meta"; \
>	cp "games/$$g/icon.svg" "dist/$$g/icon.svg"; \
>	for a in $(ARCHES); do \
>		echo "== export: $$g ($$a) =="; \
>		$(GODOT) --headless --path "games/$$g" --export-release "Linux $$a" \
>			"$(ROOT)/dist/$$g/$$g-$$a" || status=1; \
>	done; \
> done; \
> cp tools/install.sh dist/install.sh; chmod +x dist/install.sh; \
> echo ""; echo "dist/ built for $(VERSION) — copy it anywhere and run ./install.sh"; \
> exit $$status

dist-tar: dist
>@tar -C dist -czf "qgames-$(VERSION).tar.gz" .
>@echo "qgames-$(VERSION).tar.gz"

# Build for the target's actual architecture, copy it there, install it.
#   make deploy PI=pi@raspberrypi.local
deploy:
>@test -n "$(PI)" || { echo "error: PI is required, e.g. make deploy PI=pi@raspberrypi.local" >&2; exit 1; }
>@tools/deploy.sh "$(PI)" $(GAME)

install: dist
>@dist/install.sh

uninstall:
>@tools/install.sh --uninstall

export-all:
>@games="$(GAMES)"; if [ -z "$$games" ]; then echo "no games found under games/*/project.godot"; exit 0; fi; status=0; for g in $$games; do mkdir -p "dist/$$g"; echo "== export: $$g (Linux x86_64) =="; $(GODOT) --headless --path "games/$$g" --export-release "Linux x86_64" "$(ROOT)/dist/$$g/$$g-x86_64" || status=1; echo "== export: $$g (Linux arm64) =="; $(GODOT) --headless --path "games/$$g" --export-release "Linux arm64" "$(ROOT)/dist/$$g/$$g-arm64" || status=1; done; exit $$status

new-game:
># NOTE: the variable is TITLE, not DISPLAY — Make imports the environment,
># and DISPLAY is already set to the X display (":0") on a desktop session.
>@test -n "$(NAME)" || { echo "error: NAME is required, e.g. make new-game NAME=foo [TITLE=\"Foo Game\"]" >&2; exit 1; }
>./tools/new_game.sh "$(NAME)" $(if $(TITLE),"$(TITLE)")

clean:
>rm -rf dist
>@for d in games/*/.godot; do [ -d "$$d" ] && rm -rf "$$d"; done; true
