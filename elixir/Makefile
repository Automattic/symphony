.PHONY: help all setup deps build package fmt fmt-check lint test coverage ci dialyzer e2e

MIX ?= mix

help:
	@echo "Targets: setup, deps, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, ci"

setup:
	$(MIX) setup

deps:
	$(MIX) deps.get

build:
	$(MIX) build

package:
	MIX_ENV=prod $(MIX) deps.get --only prod
	MIX_ENV=prod $(MIX) release symphony --overwrite
	@if [ -f burrito_out/symphony_macos_arm64 ]; then mv burrito_out/symphony_macos_arm64 burrito_out/symphony-macos-arm64; fi
	@if [ -f burrito_out/symphony_macos_x86_64 ]; then mv burrito_out/symphony_macos_x86_64 burrito_out/symphony-macos-x86_64; fi

fmt:
	$(MIX) format

fmt-check:
	$(MIX) format --check-formatted

lint:
	$(MIX) lint

coverage:
	$(MIX) test --cover

test:
	$(MIX) test

dialyzer:
	$(MIX) deps.get
	$(MIX) dialyzer --format short

e2e:
	SYMPHONY_RUN_LIVE_E2E=1 $(MIX) test test/symphony_elixir/live_e2e_test.exs

ci:
	$(MAKE) setup
	$(MAKE) build
	$(MAKE) fmt-check
	$(MAKE) lint
	$(MAKE) coverage
	$(MAKE) dialyzer

all: ci
