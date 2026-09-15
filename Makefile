APP_NAME := BatEcho
BUNDLE_DIR := build/$(APP_NAME).app
XCODE_DIR := build/xcode
PRODUCTS := $(XCODE_DIR)/Build/Products/Release
BINARY := $(PRODUCTS)/$(APP_NAME)
XCODE_FLAGS := -scheme $(APP_NAME) -destination 'platform=macOS,arch=arm64' -derivedDataPath $(XCODE_DIR) -skipPackagePluginValidation
# Keep compiler diagnostics and source locations portable inside the binary.
XCODE_FLAGS += 'OTHER_CFLAGS=$$(inherited) -ffile-prefix-map="$(HOME)=/build/home" -ffile-prefix-map="$(CURDIR)=/build/BatEcho"'
XCODE_FLAGS += 'OTHER_CPLUSPLUSFLAGS=$$(inherited) -ffile-prefix-map="$(HOME)=/build/home" -ffile-prefix-map="$(CURDIR)=/build/BatEcho"'
XCODE_FLAGS += 'OTHER_SWIFT_FLAGS=$$(inherited) -file-prefix-map "$(HOME)=/build/home" -file-prefix-map "$(CURDIR)=/build/BatEcho" -debug-prefix-map "$(HOME)=/build/home" -debug-prefix-map "$(CURDIR)=/build/BatEcho"'
XCODE_FLAGS += SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO
ASR_RUNTIME ?= $(or $(BATECHO_ASR_RUNTIME),$(VOICER_ASR_RUNTIME),$(HOME)/Library/Application Support/voicer/asr)

# A stable signing identity keeps TCC grants (Accessibility etc.) valid across
# rebuilds. Ad-hoc ("-") signatures change every build and invalidate them.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/{print $$2; exit}')
ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY := -
endif

.PHONY: build run install clean setup-asr test icon release

build:
	xcodebuild $(XCODE_FLAGS) -configuration Release ENABLE_CODE_COVERAGE=NO CLANG_ENABLE_CODE_COVERAGE=NO build
	rm -rf $(BUNDLE_DIR)
	mkdir -p $(BUNDLE_DIR)/Contents/MacOS
	cp $(BINARY) $(BUNDLE_DIR)/Contents/MacOS/$(APP_NAME)
	xcrun strip -S $(BUNDLE_DIR)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(BUNDLE_DIR)/Contents/Info.plist
	mkdir -p $(BUNDLE_DIR)/Contents/Resources
	cp -R $(PRODUCTS)/$(APP_NAME)_$(APP_NAME).bundle $(BUNDLE_DIR)/Contents/Resources/
	cp -R $(PRODUCTS)/mlx-swift_Cmlx.bundle $(BUNDLE_DIR)/Contents/Resources/
	cp Resources/BatEcho.icns $(BUNDLE_DIR)/Contents/Resources/
	printf 'APPL????' > $(BUNDLE_DIR)/Contents/PkgInfo
	codesign --force --options runtime --timestamp=none --entitlements Resources/BatEcho.entitlements --sign "$(SIGN_IDENTITY)" $(BUNDLE_DIR)
	scripts/verify-bundle.sh $(BUNDLE_DIR)
	@echo "Built $(BUNDLE_DIR)"

run: build
	@pkill -x $(APP_NAME) 2>/dev/null || true
	open $(BUNDLE_DIR)

install: build
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(BUNDLE_DIR) /Applications/$(APP_NAME).app
	@echo "Installed to /Applications/$(APP_NAME).app"

setup-asr: build
	BATECHO_ASR_RUNTIME="$(ASR_RUNTIME)" $(BUNDLE_DIR)/Contents/MacOS/$(APP_NAME) --prepare-model

test:
	xcodebuild $(XCODE_FLAGS) -configuration Debug test

icon:
	scripts/make-icon.sh

# Produces a signed, notarized ZIP locally; publishing is a separate CI step.
release:
	scripts/release.sh

clean:
	swift package clean
	rm -rf build
