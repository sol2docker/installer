# Sol2Docker installer — developer workflow. Tooling runs in containers, so no host installs.
SHELLCHECK ?= koalaman/shellcheck:stable
SHFMT      ?= mvdan/shfmt:latest

.DEFAULT_GOAL := help

.PHONY: check
check: ## Gate: shellcheck + shfmt + parse (run before finishing)
	docker run --rm -v $(CURDIR):/mnt -w /mnt $(SHELLCHECK) install.sh
	docker run --rm -v $(CURDIR):/mnt -w /mnt $(SHFMT) -d -i 2 -ci install.sh
	bash -n install.sh
	@echo "ok: shellcheck, shfmt, parse"

.PHONY: fmt
fmt: ## Format install.sh in place
	docker run --rm -v $(CURDIR):/mnt -w /mnt $(SHFMT) -w -i 2 -ci install.sh

.PHONY: preview
preview: ## Walk the installer flow against this machine, changing nothing
	./install.sh --dry-run

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-8s\033[0m %s\n", $$1, $$2}'
