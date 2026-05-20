# Makefile for gputrace_replay_bridge
# R6.1f: Compilation + ad-hoc signing

CC = clang
BINARY = gputrace_replay_bridge
SOURCE = gputrace_replay_bridge.m

FRAMEWORKS = -framework Foundation -framework Metal
LIBS = -ldl -lobjc
CFLAGS = -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc
SIGN_IDENTITY = -

.PHONY: all clean sign test

all: $(BINARY) sign

$(BINARY): $(SOURCE)
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(LIBS) -o $@ $<

sign: $(BINARY)
	codesign --force --sign "$(SIGN_IDENTITY)" $(BINARY)
	@echo "[OK] ad-hoc signed: $(BINARY)"

clean:
	rm -f $(BINARY)

test: $(BINARY)
	./test_gputrace_replay_bridge.sh

# Verify compilation only (no signing)
check: $(BINARY)
	@echo "[OK] Compilation successful: $(BINARY)"
	@file $(BINARY)
