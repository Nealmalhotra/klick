/*
 * config.h — hand-written replacement for LAME's autoconf output, for
 * building libmp3lame with Xcode on macOS (arm64 / x86_64, clang).
 * Only what the encoder library needs: no decoder (mpglib), no frontend,
 * no assembly or SSE routines.
 *
 * Vendored from the official LAME 3.100 release
 * (https://sourceforge.net/projects/lame/files/lame/3.100/lame-3.100.tar.gz,
 * sha256 ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e):
 * libmp3lame/ (minus mpglib_interface.c, the decoder glue), include/lame.h and
 * COPYING (LGPL-2.0), unmodified. This file is the only addition. Klick links
 * it dynamically as Contents/Frameworks/LAME.framework.
 */
#ifndef LAME_CONFIG_H
#define LAME_CONFIG_H

#define PACKAGE "lame"
#define VERSION "3.100"

#define STDC_HEADERS 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_LIMITS_H 1
#define HAVE_MEMCPY 1
#define HAVE_STDINT_H 1
#define HAVE_STRCHR 1

/* Both supported architectures use IEEE 754 floats. */
#define TAKEHIRO_IEEE754_HACK 1
#define USE_FAST_LOG 1

typedef float ieee754_float32_t;
typedef double ieee754_float64_t;
typedef long double ieee854_float80_t;

#endif /* LAME_CONFIG_H */
