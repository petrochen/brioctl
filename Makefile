CFLAGS ?= -Wall -Wextra -Wno-missing-field-initializers -O2
# Plain assignment: make VERSION=x overrides it, the environment does not.
VERSION = 1.2.0
PREFIX ?= $(HOME)
LABEL = com.github.petrochen.brioctl
AGENT = $(HOME)/Library/LaunchAgents/$(LABEL).plist
LOG = $(HOME)/Library/Logs/brioctl.log

# sqlite3 is the system library: `import optionsplus` reads Logi Options+'s database with it
LIBS = -framework IOKit -framework CoreFoundation -framework CoreAudio -framework CoreMediaIO -lsqlite3
# capture.m is the only file that uses AVFoundation (`brioctl capture`); the rest never triggers the camera prompt.
OBJLIBS = -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework ImageIO -framework CoreGraphics -framework Vision
DEFS = -DVERSION=\"$(VERSION)\"
# Embedded Info.plist (camera usage string): a host app without its own still gets the permission prompt, not a crash.
INFOPLIST = -Wl,-sectcreate,__TEXT,__info_plist,brioctl-info.generated.plist

# Release build: one binary for Apple Silicon and Intel, runs on macOS 12 and later.
UNIVERSAL = -arch arm64 -arch x86_64 -mmacosx-version-min=12.0
DIST = brioctl-$(VERSION)-macos-universal

# `make` builds the CLI (the plist rule below would otherwise be the default goal).
all: brioctl

# VERSION goes into the embedded plist; written every time so that make VERSION=x is never stale.
brioctl-info.generated.plist: brioctl-info.plist FORCE
	sed 's|@VERSION@|$(VERSION)|g' brioctl-info.plist > $@.new
	cmp -s $@.new $@ && rm $@.new || mv $@.new $@

FORCE:

# The skill text built into the binary (install-skill falls back to it): a C string made from the file, so it cannot
# drift from skills/brioctl/SKILL.md.
skill-embedded.h: skills/brioctl/SKILL.md Makefile
	{ echo 'static const char SKILL_TEXT[] ='; \
	  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/^/    "/' -e 's/$$/\\n"/' skills/brioctl/SKILL.md; \
	  echo ';'; } > $@.new && mv $@.new $@

brioctl: brioctl.c capture.m capture.h skill-embedded.h Makefile brioctl-info.generated.plist
	$(CC) $(CFLAGS) $(DEFS) -fobjc-arc -o $@ brioctl.c capture.m $(LIBS) $(OBJLIBS) $(INFOPLIST)

# Offline tests: the same source against a camera read from tests/mxbrio-1.1.394.snap
tests/brioctl-fake: brioctl.c capture.m capture.h skill-embedded.h Makefile
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
universal: brioctl-info.generated.plist skill-embedded.h
	$(CC) $(CFLAGS) $(DEFS) $(UNIVERSAL) -fobjc-arc -o brioctl brioctl.c capture.m $(LIBS) $(OBJLIBS) $(INFOPLIST)

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
	install -d $(PREFIX)/share/brioctl/skills/brioctl
	install -m 644 skills/brioctl/SKILL.md $(PREFIX)/share/brioctl/skills/brioctl/SKILL.md

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
	rm -rf skill-embedded.h brioctl brioctl-info.generated.plist tests/brioctl-fake tests/brioctl-fake.dSYM brioctl.dSYM brioctl-*-macos-universal brioctl-*.tar.gz

.PHONY: all FORCE universal dist install agent unagent clean test fixtures app app-zip test-app
