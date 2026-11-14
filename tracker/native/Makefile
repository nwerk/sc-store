# Native polyphonic pitch tracker. Needs only a C++17 compiler (g++ or clang++); JACK is loaded at runtime.
#   make            -> build/polytracker
#   make clean
CXX  ?= g++
ARCH := $(shell uname -m)
ifeq ($(ARCH),x86_64)
  CPUFLAGS ?= -march=native
else ifneq ($(filter armv7l armv8l,$(ARCH)),)
  # 32-bit Raspberry Pi OS: NEON is not enabled by default there
  CPUFLAGS ?= -mcpu=native -mfpu=neon-fp-armv8 -mfloat-abi=hard
else
  CPUFLAGS ?= -mcpu=native
endif
CXXFLAGS ?= -O3 -std=c++17 -Wall -Wextra -fno-math-errno $(CPUFLAGS)
LDLIBS   := -ldl -lpthread

SRC := src/main.cpp src/model.cpp src/frontend.cpp src/decoder.cpp
HDR := $(wildcard src/*.h)

# Linked under a temporary name and renamed when complete: a power loss during the build (the Pi can lose power
# at any moment) leaves the previous binary or none, never a half-written one that sclang would try to start.
build/polytracker: $(SRC) $(HDR)
	@mkdir -p build
	$(CXX) $(CXXFLAGS) -o $@.tmp $(SRC) $(LDLIBS)
	sync $@.tmp
	mv -f $@.tmp $@
	sync build

clean:
	rm -rf build

.PHONY: clean
