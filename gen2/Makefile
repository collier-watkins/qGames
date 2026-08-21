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

.PHONY: help _check-game import run test test-all export-linux export-arm64 export-all new-game clean

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

test: _check-game
>$(GODOT) --headless --path games/$(GAME) --script res://tests/run.gd

test-all:
>@games="$(GAMES)"; if [ -z "$$games" ]; then echo "no games found under games/*/project.godot"; exit 0; fi; status=0; for g in $$games; do echo "== test: $$g =="; $(GODOT) --headless --path "games/$$g" --script res://tests/run.gd || status=1; done; exit $$status

export-linux: _check-game
>@mkdir -p "dist/$(GAME)"
>$(GODOT) --headless --path games/$(GAME) --export-release "Linux x86_64" "$(ROOT)/dist/$(GAME)/$(GAME)-x86_64"

export-arm64: _check-game
>@mkdir -p "dist/$(GAME)"
>$(GODOT) --headless --path games/$(GAME) --export-release "Linux arm64" "$(ROOT)/dist/$(GAME)/$(GAME)-arm64"

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
