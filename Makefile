# clones Makefile
#   make build                       release build for the current architecture
#   make install                     into ~/.local/bin (PREFIX=/usr/local for /usr/local/bin, may need sudo)
#   make uninstall                   remove the binary and completion (profiles and data stay)
#   make universal                   arm64 + x86_64 (needs Xcode, not just the Command Line Tools)
#   make test / make e2e             unit tests / end-to-end scenario (CLONES_E2E_REAL=1 uses the real Claude)

PREFIX     ?= $(HOME)/.local
BINDIR     ?= $(PREFIX)/bin
ZSH_COMPDIR ?= $(PREFIX)/share/zsh/site-functions
SWIFT      ?= swift
BUILD_DIR  := .build/release
BIN        := $(BUILD_DIR)/clones

.PHONY: all build universal install uninstall test e2e clean

all: build

build:
	$(SWIFT) build -c release --disable-sandbox
	@echo "Built: $(BIN)"

universal:
	$(SWIFT) build -c release --disable-sandbox --arch arm64 --arch x86_64
	@echo "Built: .build/apple/Products/Release/clones"

install: build
	install -d "$(BINDIR)" "$(ZSH_COMPDIR)"
	install -m 755 "$(BIN)" "$(BINDIR)/clones"
	"$(BINDIR)/clones" completion zsh > "$(ZSH_COMPDIR)/_clones"
	@echo "Installed: $(BINDIR)/clones"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; *) echo "Add to ~/.zshrc: export PATH=\"$(BINDIR):\$$PATH\"";; esac
	@echo "Completion: $(ZSH_COMPDIR)/_clones (add to ~/.zshrc: fpath=($(ZSH_COMPDIR) \$$fpath); autoload -Uz compinit && compinit)"

uninstall:
	rm -f "$(BINDIR)/clones" "$(ZSH_COMPDIR)/_clones"
	@echo "Binary removed. Profiles and launchers are still there; see README, \"Uninstall clones\"."

test:
	$(SWIFT) test

e2e:
	$(SWIFT) build
	./scripts/e2e.sh

clean:
	rm -rf .build
