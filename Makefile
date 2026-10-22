# Install copies this bundle to <share>/langs/tmux, where `x -l` looks: a lang is
# installed when its files are there. No registry, no database.

X ?= x

# The version is derived from git describe, never committed: lang.xon declares
# what this lang requires; the installed artifact carries what it is.
LANG_VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
SHARE := $(if $(PREFIX),$(PREFIX)/share/x,$(shell $(X) --share-dir))
DEST  := $(SHARE)/langs/tmux

# What a consumer needs to run the lang: the declaration, the entry, the
# modules.  Not the suite, not the tooling, not CI.
PAYLOAD := lang.xon run.x tmux

.PHONY: install
install: ## Install into <share>/langs/tmux
	@test -n "$(SHARE)" || { echo "x-tmux: cannot find an x tree -- set PREFIX or X" >&2; exit 1; }
	@test -d "$(SHARE)" || { echo "x-tmux: no x tree at $(SHARE)" >&2; exit 1; }
	rm -rf "$(DEST)"
	mkdir -p "$(DEST)"
	cp -R $(PAYLOAD) "$(DEST)/"
	printf '%s\n' '$(LANG_VERSION)' > "$(DEST)/version"
	@echo "x-tmux: installed to $(DEST)"
	@echo "x-tmux: writing the boot image"
	"$(X)" --image -l tmux || true
	@echo "x-tmux: try  x -l tmux"

.PHONY: uninstall
uninstall: ## Remove it again
	rm -rf "$(DEST)"
	@echo "x-tmux: removed $(DEST)"

.PHONY: test
test: ## Run the spec suite (every failure is loud)
	X="$(X)" sh tests/spec-runner.sh

.PHONY: check
check: ## Run the suite against tests/contract/known-failures.txt -- what CI gates on
	X="$(X)" sh tests/spec-gate.sh

.PHONY: help
help: ## Show targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  \033[32m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
