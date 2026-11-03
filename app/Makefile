# The brioctl menu bar app: a universal brioctl.app with the CLI inside (Contents/Resources/brioctl), ad-hoc signed.
#
#   make              build/brioctl.app
#   make zip          build/brioctl-app-VERSION.zip
#   make test         unit tests (builds the fake CLI of the repository first)
#   make smoke        build the app, then start it on an emulated camera and drive it with a brioctl:// URL
#   make clean

# Plain assignment: make VERSION=x overrides it, the environment does not.
VERSION = 1.1.0

# The CLI is built from ../brioctl.c with the flags of the root Makefile (make universal), into build/cli, so the
# ./brioctl of the repository is left alone.
CFLAGS ?= -Wall -Wextra -Wno-missing-field-initializers -O2
LIBS = -framework IOKit -framework CoreFoundation -framework CoreAudio -framework CoreMediaIO -lsqlite3 \
	-framework AVFoundation -framework CoreMedia -framework CoreVideo -framework ImageIO -framework CoreGraphics
UNIVERSAL = -arch arm64 -arch x86_64 -mmacosx-version-min=12.0

BUILD = build
APP = $(BUILD)/brioctl.app
ZIP = $(BUILD)/brioctl-app-$(VERSION).zip
SWIFTFLAGS = -c release --arch arm64 --arch x86_64

all: $(APP)

# Always rebuilt: the binary embeds VERSION, which can differ from run to run (make zip VERSION=x).
cli:
	$(MAKE) -C .. skill-embedded.h
	mkdir -p $(BUILD)/cli
	sed 's|@VERSION@|$(VERSION)|g' ../brioctl-info.plist > $(BUILD)/cli/info.plist
	$(CC) $(CFLAGS) -DVERSION=\"$(VERSION)\" $(UNIVERSAL) -fobjc-arc -o $(BUILD)/cli/brioctl ../brioctl.c ../capture.m $(LIBS) \
		-Wl,-sectcreate,__TEXT,__info_plist,$(BUILD)/cli/info.plist

# SwiftPM decides what is out of date.
swift:
	swift build $(SWIFTFLAGS)

$(APP): swift cli Resources/Info.plist.in Makefile
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp "$$(swift build $(SWIFTFLAGS) --show-bin-path)/brioctl-app" $(APP)/Contents/MacOS/brioctl-app
	cp $(BUILD)/cli/brioctl $(APP)/Contents/Resources/brioctl
	cp ../LICENSE $(APP)/Contents/Resources/LICENSE
	sed -e 's|@VERSION@|$(VERSION)|g' Resources/Info.plist.in > $(APP)/Contents/Info.plist
	plutil -lint $(APP)/Contents/Info.plist
	xattr -cr $(APP)
	codesign --force --deep -s - $(APP)
	codesign --verify --deep --strict $(APP)
	@echo "$(APP)"

zip: $(APP)
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	@echo "$(ZIP)"

test:
	$(MAKE) -C .. tests/brioctl-fake
	swift test

smoke: $(APP)
	$(MAKE) -C .. tests/brioctl-fake
	sh Tests/smoke.sh

clean:
	rm -rf $(BUILD) .build

.PHONY: all swift cli zip test smoke clean
