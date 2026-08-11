# Horizontal — the single build entry point.
#
# Every target here drives `xcodebuild` against Horizontal.xcodeproj, so
# `make build` produces exactly what Build & Run in Xcode produces: the same
# targets, the same build settings, the same DerivedData. There is deliberately
# no second way to assemble the app — the old scripts/build-app.sh compiled the
# package with SwiftPM and hand-linked the QuickLook extensions, which could
# (and did) drift from what Xcode shipped.
#
# Package.swift stays: the Xcode project consumes it as a local package
# (XCLocalSwiftPackageReference ".") for HorizontalProjectIO, HorizontalStepImporter
# and HorizontalPlaneClipper. It is the dependency
# manifest Xcode reads, not a rival build system.
#
#   make            Debug build of the macOS app
#   make run        build it, then launch it
#   make release    Release build
#   make ios        build for the iOS Simulator
#   make test       run the test suite (see the note on `test` below)
#   make deps       build the vendored dependencies (OpenCascade)
#   make clean      remove build products
#   make help       list targets

PROJECT     := Horizontal.xcodeproj
SCHEME      := Horizontal
CONFIG      ?= Debug
DESTINATION ?= platform=macOS
# Extra xcodebuild settings, e.g. CI passing CODE_SIGNING_ALLOWED=NO.
XCODE_FLAGS ?=

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG)

# OpenCascade is gitignored and built from the Vendor/OCCT submodule, so it is a
# real prerequisite and the only vendored dependency that has to be built.
OCCT_XCFRAMEWORK := Vendor/OpenCascadeStatic/OpenCascadeStairs.xcframework
OCCT_LIB         := $(OCCT_XCFRAMEWORK)/macos-arm64/libOpenCascadeStairs-macos-arm64.a

.PHONY: all build run release ios test deps clean help app-path archive upload

all: build

## deps: build the vendored OpenCascade xcframework if it is missing
deps: $(OCCT_LIB)

# Order matters: the macOS and iOS static installs are built first, then merged
# into one xcframework. The iOS slices are what let `make ios` link.
$(OCCT_LIB):
	@echo "==> Building OpenCascade — one-time and slow (tens of minutes)"
	git submodule update --init --recursive Vendor/OCCT Vendor/RapidJSON
	scripts/build-occt.sh
	scripts/build-occt-ios.sh
	scripts/build-occt-xcframework.sh

## build: build the macOS app exactly as Xcode's Build & Run does
build: deps
	$(XCODEBUILD) -destination '$(DESTINATION)' $(XCODE_FLAGS) build

## release: Release-configuration build
release:
	$(MAKE) build CONFIG=Release

## ios: build for the iOS Simulator (unsigned, as Xcode does for a generic destination)
ios: deps
	$(XCODEBUILD) -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

## app-path: print the path of the built .app (inside Xcode's DerivedData)
app-path:
	@$(XCODEBUILD) -destination '$(DESTINATION)' -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2 "/Horizontal.app"; exit}'

## run: build the app and launch it
run: build
	@app="$$($(MAKE) --no-print-directory app-path)"; \
		echo "==> Launching $$app"; \
		open "$$app"

# The test suite lives in the Swift package (four XCTest bundles), and Xcode does
# not currently surface those targets to the Horizontal scheme — its <Testables>
# list is empty, so Cmd-U runs nothing. Until they are added there (Edit Scheme ▸
# Test ▸ +, which makes Xcode write the correct target references), this runs
# them through SwiftPM's test runner over the very same package Xcode compiles.
# It builds no app and produces no bundle, so it is not a second way to ship.
## test: run the package test suite
test: deps
	swift test

# ---------------------------------------------------------------------------
# App Store distribution
#
# `make archive` then `make upload` is exactly what the release workflow runs,
# so a release can be reproduced locally with the same flags. Signing uses
# Xcode's cloud signing: with -allowProvisioningUpdates and an App Store Connect
# API key, Xcode creates and refreshes the distribution certificate and the
# App Store provisioning profiles itself, so no .p12 or .mobileprovision has to
# be stored anywhere.
#
# The API key is passed through XCODE_FLAGS, e.g.
#   make archive upload PLATFORM=macOS \
#     XCODE_FLAGS='-authenticationKeyPath /path/AuthKey.p8 \
#                  -authenticationKeyID ABC123 \
#                  -authenticationKeyIssuerID 1234-...'
PLATFORM       ?= macOS
ARCHIVE_PATH   ?= build/release/Horizontal-$(PLATFORM).xcarchive
EXPORT_PATH    ?= build/release/export-$(PLATFORM)
EXPORT_OPTIONS ?= App/ExportOptions-AppStore.plist

## archive: Release .xcarchive for PLATFORM (macOS or iOS)
archive: deps
	xcodebuild archive \
		-project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination 'generic/platform=$(PLATFORM)' \
		-archivePath '$(ARCHIVE_PATH)' \
		-allowProvisioningUpdates \
		$(XCODE_FLAGS)

## upload: export the archive and send it to App Store Connect
upload:
	xcodebuild -exportArchive \
		-archivePath '$(ARCHIVE_PATH)' \
		-exportOptionsPlist '$(EXPORT_OPTIONS)' \
		-exportPath '$(EXPORT_PATH)' \
		-allowProvisioningUpdates \
		$(XCODE_FLAGS)

# Cleans Xcode's products and the SwiftPM directory `make test` uses. It leaves
# build/ alone: that holds release artifacts and archives, not build output.
## clean: remove build products
clean:
	$(XCODEBUILD) -destination '$(DESTINATION)' clean
	rm -rf .build

## help: list targets
help:
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /'
