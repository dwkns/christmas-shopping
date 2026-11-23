# Mill House task runner. `make help` lists targets. Same target names as dwkns/lifts.
.DEFAULT_GOAL := help

help: ## Show this help
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

ship: ## Build, install and launch on the plugged-in or paired iPhone (PHONE=<name or UDID> to pick)
	scripts/ship-ios.sh

release: ## Build and publish the next version; the phones offer the update themselves
	scripts/release-ios.sh

test-ios: ## Unit tests on an iPhone simulator
	scripts/test-ios.sh

lint: ## swiftformat --lint, node --check
	swiftformat --lint ios/MillHouse ios/MillHouseTests || true
	for f in netlify/functions/*.mjs netlify/lib/*.mjs; do node --check $$f; done
