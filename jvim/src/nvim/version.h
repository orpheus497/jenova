#pragma once

#include "nvim/api/private/defs.h"  // IWYU pragma: keep
#include "nvim/ex_cmds_defs.h"  // IWYU pragma: keep
#include "nvim/macros_defs.h"

// defined in version.c
extern char *Versions[];
extern char *longVersion;
#ifndef NDEBUG
extern char *version_cflags;
#endif

bool has_nvim_version(const char *const version_str);
bool has_jvim_version(const char *const version_str);
int min_vim_version(void);
