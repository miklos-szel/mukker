# Build helpers. The Xcode project is generated from project.yml by xcodegen;
# treat project.yml as the source of truth and run `make generate` after changing it.
#
# Nothing here hardcodes the product name — SCHEME is read out of project.yml, so
# renaming the app (see scripts/rename.sh) needs no edits in this file.

SCHEME       := $(shell awk '/^name:/{print $$2; exit}' project.yml)
PROJECT      := $(SCHEME).xcodeproj
CONFIG       := Debug
DERIVED      := build
APP          := $(DERIVED)/Build/Products/$(CONFIG)/$(SCHEME).app
TESTS        := AppTests
XCODEBUILD   := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) -derivedDataPath $(DERIVED)

.PHONY: all generate build build-tests run rebuild test test-one quit clean dmg

all: build

## Regenerate the Xcode project from project.yml
generate:
	xcodegen generate

## Build the app (regenerates the project first)
build: generate
	$(XCODEBUILD) build

## Compile the tests without running them (`make build` skips the test target,
## so a broken test import otherwise hides until `make test`)
build-tests: generate
	$(XCODEBUILD) build-for-testing

## Build and launch the app
run: build quit
	open $(APP)

## Quit a running instance cleanly (no Dock icon, so use AppleScript)
quit:
	-osascript -e 'tell application "$(SCHEME)" to quit' 2>/dev/null || true
	-pkill -f $(SCHEME).app 2>/dev/null || true

## Full rebuild: quit, clean, regenerate, build, launch
rebuild: quit clean run

## Run the unit tests
test: generate
	$(XCODEBUILD) -destination 'platform=macOS' test

## Run a single test, e.g. make test-one ONLY=SnippetBundleImporterTests/testParsesProvidedFixture
test-one: generate
	$(XCODEBUILD) -destination 'platform=macOS' test -only-testing:$(TESTS)/$(ONLY)

## Build a Release .dmg into dist/ (ad-hoc signed)
dmg:
	./scripts/build-dmg.sh

## Rename the app (product name only; data locations stay put)
rename:
	./scripts/rename.sh $(NAME)

## Remove build artifacts
clean:
	rm -rf $(DERIVED)
