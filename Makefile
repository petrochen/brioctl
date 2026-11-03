CFLAGS ?= -Wall -Wextra -Wno-missing-field-initializers -O2
# Plain assignment: make VERSION=x overrides it, the environment does not.
VERSION = 1.1.0
PREFIX ?= $(HOME)
LABEL = com.github.petrochen.brioctl
AGENT = $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG = $(HOME)/Library/Logs/brioctl.log

# sqlite3 is the system library: `import optionsplus` reads Logi Options+'s database with it
LIBS = -framework IOKit -framework CoreFoundation -framework CoreAudio -framework CoreMediaIO -lsqlite3
# capture.m is the only file that uses AVFoundation (`brioctl capture`); the rest never triggers the camera prompt.
OBJLIBS = -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework ImageIO -framework CoreGraphics
DEFS = -DVERSION=\"$(VERSION)\"

# Release build: one binary for Apple Silicon and Intel, runs on macOS 12 and later.
UNIVERSAL = -arch arm64 -arch x86_64 -mmacosx-version-min=12.0
DIST = brioctl-$(VERSION)-macos-universal

brioctl: brioctl.c capture.m capture.h Makefile
	$(CC) $(CFLAGS) $(DEFS) -fobjc-arc -o $@ brioctl.c capture.m $(LIBS) $(OBJLIBS)

# Offline tests: the same source against a camera read from tests/mxbrio-1.1.394.snap
tests/brioctl-fake: brioctl.c capture.m capture.h Makefile
	$(CC) $(CFLAGS) $(DEFS) -DBRIOCTL_FAKE -fobjc-arc -o $@ brioctl.c capture.m $(LIBS) $(OBJLIBS)

# Rewrite the generated camera fixtures (tests/generic-uvc*.snap, tests/brio500-sim.snap) from the MX Brio snapshot.
fixtures:
	python3 tests/make-fixtures.py

# Built from scratch every time: the binary embeds VERSION and CFLAGS, which can differ from run to run.
test:
	rm -f tests/brioctl-fake
	$(MAKE) tests/brioctl-fake
	VERSION=$(VERSION) sh tests/run.sh

# The menu bar app (app/): build/brioctl.app, universal, ad-hoc signed, with this CLI inside. Not part of `make` or
# `make test`; it needs Swift. See app/README.md.
app:
	$(MAKE) -C app VERSION=$(VERSION)

# app/build/brioctl-app-$(VERSION).zip, the file of the release and of the Homebrew cask.
app-zip:
	$(MAKE) -C app zip VERSION=$(VERSION)

# Unit tests of the app (they build tests/brioctl-fake first and never touch a real camera).
test-app:
	$(MAKE) -C app test

# Always rebuilt: it replaces ./brioctl with the universal binary.
universal:
	$(CC) $(CFLAGS) $(DEFS) $(UNIVERSAL) -fobjc-arc -o brioctl brioctl.c capture.m $(LIBS) $(OBJLIBS)

# $(DIST).tar.gz with the universal binary, README.md and LICENSE.
dist: universal
	rm -rf $(DIST) $(DIST).tar.gz
	mkdir $(DIST)
	cp brioctl README.md LICENSE $(DIST)/
	COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --uname root --gname root -czf $(DIST).tar.gz $(DIST)
	rm -rf $(DIST)
	@echo "$(DIST).tar.gz"

install: brioctl
	install -d $(PREFIX)/bin
	install -m 755 brioctl $(PREFIX)/bin/brioctl

# LaunchAgent that applies ~/.config/brioctl/settings whenever the camera is connected
agent: install
	test -f $(HOME)/.config/brioctl/settings || $(PREFIX)/bin/brioctl save
	sed -e 's|@LABEL@|$(LABEL)|' -e 's|@BIN@|$(PREFIX)/bin/brioctl|' -e 's|@LOG@|$(LOG)|' \
		launchd/brioctl.plist.in > $(AGENT)
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) $(AGENT)

unagent:
	launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null || true
	rm -f $(AGENT)

clean:
	$(MAKE) -C tools clean
	$(MAKE) -C app clean
	rm -rf brioctl tests/brioctl-fake tests/brioctl-fake.dSYM brioctl.dSYM brioctl-*-macos-universal brioctl-*.tar.gz

.PHONY: universal dist install agent unagent clean test fixtures app app-zip test-app
