CFLAGS ?= -Wall -Wextra -Wno-missing-field-initializers -O2
# Plain assignment: make VERSION=x overrides it, the environment does not.
VERSION = 1.0.0
PREFIX ?= $(HOME)
LABEL = com.github.petrochen.brioctl
AGENT = $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG = $(HOME)/Library/Logs/brioctl.log

LIBS = -framework IOKit -framework CoreFoundation -framework CoreAudio -framework CoreMediaIO
DEFS = -DVERSION=\"$(VERSION)\"

# Release build: one binary for Apple Silicon and Intel, runs on macOS 12 and later.
UNIVERSAL = -arch arm64 -arch x86_64 -mmacosx-version-min=12.0
DIST = brioctl-$(VERSION)-macos-universal

brioctl: brioctl.c Makefile
	$(CC) $(CFLAGS) $(DEFS) -o $@ $< $(LIBS)

# Offline tests: the same source against a camera read from tests/mxbrio-1.1.394.snap
tests/brioctl-fake: brioctl.c Makefile
	$(CC) $(CFLAGS) $(DEFS) -DBRIOCTL_FAKE -o $@ $< $(LIBS)

# Rewrite the generated camera fixtures (tests/generic-uvc*.snap, tests/brio500-sim.snap) from the MX Brio snapshot.
fixtures:
	python3 tests/make-fixtures.py

# Built from scratch every time: the binary embeds VERSION and CFLAGS, which can differ from run to run.
test:
	rm -f tests/brioctl-fake
	$(MAKE) tests/brioctl-fake
	VERSION=$(VERSION) sh tests/run.sh

# Always rebuilt: it replaces ./brioctl with the universal binary.
universal:
	$(CC) $(CFLAGS) $(DEFS) $(UNIVERSAL) -o brioctl brioctl.c $(LIBS)

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
	rm -rf brioctl tests/brioctl-fake tests/brioctl-fake.dSYM brioctl.dSYM brioctl-*-macos-universal brioctl-*.tar.gz

.PHONY: universal dist install agent unagent clean test fixtures
