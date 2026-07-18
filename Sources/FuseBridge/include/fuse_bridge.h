#ifndef X68_FUSE_BRIDGE_H
#define X68_FUSE_BRIDGE_H

#include <sys/stat.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*x68_getattr_fn)(const char *path, struct stat *stbuf);
typedef int (*x68_readdir_fn)(const char *path, void *buf, void *filler_ctx);
/** flags: open(2) flags (O_RDONLY / O_WRONLY / O_RDWR / O_CREAT etc.). */
typedef int (*x68_open_fn)(const char *path, int flags, uint64_t *out_fh, uint64_t *out_size);
typedef int (*x68_read_fn)(uint64_t fh, char *buf, size_t size, off_t offset);
typedef int (*x68_release_fn)(uint64_t fh);

typedef int (*x68_write_fn)(uint64_t fh, const char *buf, size_t size, off_t offset);
typedef int (*x68_create_fn)(const char *path, mode_t mode, uint64_t *out_fh);
typedef int (*x68_unlink_fn)(const char *path);
typedef int (*x68_mkdir_fn)(const char *path, mode_t mode);
typedef int (*x68_truncate_fn)(const char *path, off_t size);
typedef int (*x68_rename_fn)(const char *from, const char *to);
/** Commit dirty open file (flush/fsync). Keep handle open. */
typedef int (*x68_flush_fn)(uint64_t fh);
/** Fills *block_size, *blocks, *bfree, *bavail (block counts). Return 0 or -errno. */
typedef int (*x68_statfs_fn)(
    uint64_t *block_size,
    uint64_t *blocks,
    uint64_t *bfree,
    uint64_t *bavail
);

/** Register Swift/C callbacks. Call before x68_fuse_run. */
void x68_fuse_set_callbacks(
    x68_getattr_fn getattr_fn,
    x68_readdir_fn readdir_fn,
    x68_open_fn open_fn,
    x68_read_fn read_fn,
    x68_release_fn release_fn
);

/** Optional. Without it Finder often shows 0 free and refuses copy-in. */
void x68_fuse_set_statfs_callback(x68_statfs_fn statfs_fn);

/** Optional write ops. NULL → EROFS. Call after set_callbacks when experimental-write. */
void x68_fuse_set_write_callbacks(
    x68_write_fn write_fn,
    x68_create_fn create_fn,
    x68_unlink_fn unlink_fn,
    x68_mkdir_fn mkdir_fn,
    x68_truncate_fn truncate_fn,
    x68_rename_fn rename_fn,
    x68_flush_fn flush_fn
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
