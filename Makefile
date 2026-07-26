# =============================================================================
#  ThinClient OS — convenience wrapper around build.sh and the Docker env.
#
#  On a Debian/Ubuntu host you can also just run:  sudo ./build.sh
#  Everywhere else (macOS/Windows/CI) use the Docker targets below.
# =============================================================================

COMPOSE ?= docker compose -f docker/docker-compose.yml

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	 awk 'BEGIN{FS=":.*?## "}{printf "  \033[1;34m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: iso
iso: ## Build thinclient.iso inside the Docker builder (privileged)
	$(COMPOSE) run --rm builder

.PHONY: rebuild
rebuild: ## Clean + build the ISO
	BUILD_ARGS=--rebuild $(COMPOSE) run --rm builder

.PHONY: iso-native
iso-native: ## Build an ISO for the HOST arch (use on Apple Silicon to validate the pipeline; produces arm64)
	TC_PLATFORM=linux/arm64 TC_ARCH=arm64 $(COMPOSE) run --rm builder

.PHONY: test
test: ## Run lint + logic tests in a container
	$(COMPOSE) run --rm tester

.PHONY: lint
lint: ## Shellcheck all scripts
	$(COMPOSE) run --rm tester bash -lc './tests/lint.sh'

.PHONY: shell
shell: ## Interactive shell in the build environment
	$(COMPOSE) run --rm shell

.PHONY: native
native: ## Build the ISO natively (Debian/Ubuntu host only)
	sudo ./build.sh

.PHONY: clean
clean: ## Remove build artifacts and the produced ISO
	sudo ./build.sh --clean || true
	rm -rf build iso/thinclient.iso iso/thinclient.iso.sha256

.PHONY: images
images: ## Build the Docker images without running anything
	$(COMPOSE) build

.PHONY: test-rdp
test-rdp: ## Probe a real RDP server using the local config (see ./test-rdp.sh)
	./test-rdp.sh
