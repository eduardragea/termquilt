PREFIX ?= $(HOME)/.local
CLAUDE_SKILL_LINK := $(HOME)/.claude/skills/termquilt
CODEX_SKILL_LINK := $(HOME)/.agents/skills/termquilt

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

# Links the skill in this repo into Claude Code and Codex, so it works from every folder and edits
# apply at once.
install-skill:
	@for link in "$(CLAUDE_SKILL_LINK)" "$(CODEX_SKILL_LINK)"; do \
		if [ -e "$$link" ] && [ ! -L "$$link" ]; then \
			echo "$$link already exists and isn't a link, so it was left alone."; exit 1; \
		fi; \
		install -d "$$(dirname "$$link")" || exit 1; \
	done
	@for link in "$(CLAUDE_SKILL_LINK)" "$(CODEX_SKILL_LINK)"; do \
		ln -sfn "$(CURDIR)/.claude/skills/termquilt" "$$link" || exit 1; \
		echo "linked $$link"; \
	done

uninstall-skill:
	@for link in "$(CLAUDE_SKILL_LINK)" "$(CODEX_SKILL_LINK)"; do \
		if [ -L "$$link" ]; then rm "$$link"; fi; \
	done
