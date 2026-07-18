#ifndef X68_FUSE_BRIDGE_H
#define X68_FUSE_BRIDGE_H

#include <sys/stat.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*x68_getattr_fn)(const char *path, struct stat *stbuf);
typedef int (*x68_readdir_fn)(const char *path, void *buf, void *filler_ctx);
typedef int (*x68_open_fn)(const char *path, uint64_t *out_fh, uint64_t *out_size);
typedef int (*x68_read_fn)(uint64_t fh, char *buf, size_t size, off_t offset);
typedef int (*x68_release_fn)(uint64_t fh);

/** Register Swift/C callbacks. Call before x68_fuse_run. */
void x68_fuse_set_callbacks(
    x68_getattr_fn getattr_fn,
    x68_readdir_fn readdir_fn,
    x68_open_fn open_fn,
    x68_read_fn read_fn,
    x68_release_fn release_fn
);

/**
 * Run fuse_main in foreground. Returns process exit code from fuse.
 * Tries to dlopen libfuse-t / libfuse first so symbols resolve.
 */
int x68_fuse_run(int argc, char **argv);

/** Helper for readdir: add a name to the directory listing. */
int x68_fuse_add_direntry(void *filler_ctx, const char *name);

#ifdef __cplusplus
}
#endif

#endif
