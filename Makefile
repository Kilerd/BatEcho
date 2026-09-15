APP_NAME := voicer
BUNDLE_DIR := build/$(APP_NAME).app
BINARY := .build/release/$(APP_NAME)

# A stable signing identity keeps TCC grants (Accessibility etc.) valid across
# rebuilds. Ad-hoc ("-") signatures change every build and invalidate them.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $$2; exit}')
ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY := -
endif

.PHONY: build run install clean

build:
	swift build -c release
	rm -rf $(BUNDLE_DIR)
	mkdir -p $(BUNDLE_DIR)/Contents/MacOS
	cp $(BINARY) $(BUNDLE_DIR)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(BUNDLE_DIR)/Contents/Info.plist
	printf 'APPL????' > $(BUNDLE_DIR)/Contents/PkgInfo
	codesign --force --sign "$(SIGN_IDENTITY)" $(BUNDLE_DIR)
	@echo "Built $(BUNDLE_DIR)"

run: build
	@pkill -x $(APP_NAME) 2>/dev/null || true
	open $(BUNDLE_DIR)

install: build
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(BUNDLE_DIR) /Applications/$(APP_NAME).app
	@echo "Installed to /Applications/$(APP_NAME).app"

clean:
	swift package clean
	rm -rf build
