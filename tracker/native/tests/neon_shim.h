// The few ARM NEON intrinsics used by src/model.cpp, written with GCC vector types, so the 32-bit ARM kernel can be
// built and checked against Python on an x86 machine:
//     make clean && make SIMDFLAGS=-DPT_NEON_SHIM && cd .. && .venv/bin/python native/tests/compare.py
// Same results as the real intrinsics up to rounding (the real vmla is not fused). Says nothing about speed.
#pragma once

#include <cstring>

typedef float float32x4_t __attribute__((vector_size(16)));
typedef float float32x2_t __attribute__((vector_size(8)));

inline float32x4_t vld1q_f32(const float* p) { float32x4_t v; std::memcpy(&v, p, sizeof v); return v; }
inline void vst1q_f32(float* p, float32x4_t v) { std::memcpy(p, &v, sizeof v); }
inline float32x4_t vdupq_n_f32(float x) { return float32x4_t{x, x, x, x}; }
inline float32x2_t vget_low_f32(float32x4_t v) { return float32x2_t{v[0], v[1]}; }
inline float32x2_t vget_high_f32(float32x4_t v) { return float32x2_t{v[2], v[3]}; }
#define vmlaq_lane_f32(a, b, v, lane) ((a) + (b) * (v)[lane])
