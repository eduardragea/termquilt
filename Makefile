PREFIX ?= $(HOME)/.local
SKILL_LINK := $(HOME)/.claude/skills/termquilt

UNIVERSAL_BINARY := .build/apple/Products/Release/termquilt
ARCHIVE := termquilt-macos.tar.gz

.PHONY: build test integration integration-iterm test-install dist install uninstall install-skill uninstall-skill

build:
	swift build -c release

test:
	swift test

# Opens a few throwaway Terminal windows and drives the real binary against them.
integration: build
	scripts/integration-test.sh .build/release/termquilt

# The same idea for iTerm2. Needs iTerm2 installed.
integration-iterm: build
	scripts/integration-iterm.sh .build/release/termquilt

# Checks install.sh against a locally built release, in throwaway home folders.
test-install: dist
	scripts/install-test.sh dist

# What a release uploads: one program for both kinds of Mac, plus the skill.
dist:
	swift build -c release --arch arm64 --arch x86_64
	rm -rf dist
	mkdir dist
	cp $(UNIVERSAL_BINARY) .claude/skills/termquilt/SKILL.md dist/
	codesign --force --sign - dist/termquilt
	COPYFILE_DISABLE=1 tar -czf dist/$(ARCHIVE) -C dist termquilt SKILL.md
	cd dist && shasum -a 256 $(ARCHIVE) > $(ARCHIVE).sha256
	rm dist/termquilt dist/SKILL.md

install: build
	install -d "$(PREFIX)/bin"
	install .build/release/termquilt "$(PREFIX)/bin/termquilt"

uninstall:
	rm -f "$(PREFIX)/bin/termquilt"

# The skill already works inside this repo. This makes it available from every folder.
install-skill:
	@if [ -e "$(SKILL_LINK)" ] && [ ! -L "$(SKILL_LINK)" ]; then \
		echo "$(SKILL_LINK) already exists and isn't a link, so it was left alone."; exit 1; \
	fi
	install -d "$(dir $(SKILL_LINK))"
	ln -sfn "$(CURDIR)/.claude/skills/termquilt" "$(SKILL_LINK)"

uninstall-skill:
	@if [ -L "$(SKILL_LINK)" ]; then rm "$(SKILL_LINK)"; fi
