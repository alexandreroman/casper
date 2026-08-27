#ifndef CLIBGIT2_SHIM_H
#define CLIBGIT2_SHIM_H
#include <git2.h>

/// Read the `:`-separated directory list libgit2 searches for configuration of
/// `level` (a `git_config_level_t`) into `out`, which the caller disposes with
/// `git_buf_dispose`.
///
/// Wrapped in C because `git_libgit2_opts` is variadic, and Swift cannot call a
/// C variadic function at all — the ClangImporter marks it explicitly
/// unavailable, the same way it does `git_commit_create_v`.
static inline int casper_git_get_config_search_path(int level, git_buf *out) {
    return git_libgit2_opts(GIT_OPT_GET_SEARCH_PATH, level, out);
}

/// Replace the `:`-separated directory list libgit2 searches for configuration
/// of `level` (a `git_config_level_t`). Wrapped in C for the same reason as
/// `casper_git_get_config_search_path`.
static inline int casper_git_set_config_search_path(int level, const char *path) {
    return git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH, level, path);
}

#endif
