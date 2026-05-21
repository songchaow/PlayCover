# Makefile for gputrace_replay_bridge (skill-bundled)
#
# Self-contained build configuration for the GPU trace analysis skill.
# Compiles the ObjC bridge with ad-hoc signing — no external dependencies
# beyond the system clang toolchain and macOS PrivateFrameworks.

CC = clang
BINARY = gputrace_replay_bridge
SOURCE = gputrace_replay_bridge.m

FRAMEWORKS = -framework Foundation -framework Metal
LIBS = -ldl -lobjc
CFLAGS = -O2 -Wall -Wextra -Wno-unused-parameter -fobjc-arc
SIGN_IDENTITY = -

.PHONY: all clean sign test check

all: $(BINARY) sign

$(BINARY): $(SOURCE)
	$(CC) $(CFLAGS) $(FRAMEWORKS) $(LIBS) -o $@ $<

sign: $(BINARY)
	codesign --force --sign "$(SIGN_IDENTITY)" $(BINARY)
	@echo "[OK] ad-hoc signed: $(BINARY)"

clean:
	rm -f $(BINARY)

# Verify compilation only (no signing)
check: $(BINARY)
	@echo "[OK] Compilation successful: $(BINARY)"
	@file $(BINARY)

# Run integration tests. Pass GPUTRACE_PATH=/path/to/sample.gputrace
# for live trace tests beyond the offline assertions.
test: $(BINARY) sign
	./test_bridge.sh
