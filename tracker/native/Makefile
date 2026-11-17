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
  # GCC uses NEON for float vector arithmetic on 32-bit ARM only with -funsafe-math-optimizations, because
  # ARMv7 NEON flushes denormals to zero (not IEEE). Without it every vector operation of the network and the
  # FFT is split into scalar ones (measured on a Pi 4: 11 ms per frame, slower than the Python tracker). Only the two files
  # with the vector code get the flag; the decoder's note decisions stay in plain IEEE arithmetic.
  # -Wvector-operation-performance: warns if vector code still ends up split into scalar operations.
  SIMDFLAGS ?= -funsafe-math-optimizations -DPT_ARM32_NEON_FLOAT -Wvector-operation-performance
else
  CPUFLAGS ?= -mcpu=native
endif
# -ffp-contract=fast: a * b + c becomes one fused multiply-add (GCC's default; stated because the inner loops
# of the network and the FFT depend on it)
CXXFLAGS ?= -O3 -std=c++17 -Wall -Wextra -fno-math-errno -ffp-contract=fast $(CPUFLAGS)
LDLIBS   := -ldl -lpthread

SRC      := src/main.cpp src/model.cpp src/frontend.cpp src/decoder.cpp
SIMD_SRC := src/model.cpp src/frontend.cpp  # get SIMDFLAGS
OBJ      := $(patsubst src/%.cpp,build/%.o,$(SRC))
HDR      := $(wildcard src/*.h)

# Every file is written under a temporary name and renamed when complete: a power loss during the build (the Pi
# can lose power at any moment) leaves the previous file or none, never a half-written one. The binary is also
# synced, since sclang starts it.
build/polytracker: $(OBJ)
	$(CXX) $(CXXFLAGS) -o $@.tmp $(OBJ) $(LDLIBS)
	sync $@.tmp
	mv -f $@.tmp $@
	sync build

# the Makefile is a prerequisite: a change of flags rebuilds everything
build/%.o: src/%.cpp $(HDR) Makefile
	@mkdir -p build
	$(CXX) $(CXXFLAGS) $(if $(filter $<,$(SIMD_SRC)),$(SIMDFLAGS)) -c -o $@.tmp $<
	mv -f $@.tmp $@

clean:
	rm -rf build

.PHONY: clean
