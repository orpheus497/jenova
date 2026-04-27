/*
 * patchlevel.h: Our life story.
 *
 * Two identity blocks live here:
 *   1. mcsh (Modern C Shell) - the package as redistributed.
 *   2. TCSH_BASELINE_* - the upstream tcsh snapshot mcsh was consolidated
 *      from; kept so compatibility consumers can probe the historic tcsh
 *      version number.
 */
#ifndef _h_patchlevel
#define _h_patchlevel

#define MCSH_NAME    "mcsh"
#define MCSH_LONG_NAME "Modern C Shell"
#define MCSH_VERSION "0.1.0"
#define MCSH_DATE    "2026-04-20"
#define MCSH_ORIGIN  "mcsh"

#define TCSH_BASELINE_VERS "6.24.13"
#define TCSH_BASELINE_DATE "2024-06-12"

/*
 * Legacy tcsh-style version decomposition, kept so tc.vers.c and any
 * downstream consumers that probed the tcsh identity still compile.
 * These now reflect mcsh's PACKAGE_VERSION, not the upstream tcsh version.
 */
#define ORIGIN     MCSH_ORIGIN
#define REV        0
#define VERS       1
#define PATCHLEVEL 0
#define DATE       MCSH_DATE

#endif /* _h_patchlevel */
