#define FUSE_USE_VERSION 26
#define _FILE_OFFSET_BITS 64

#include "fuse_bridge.h"

#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>

#include <fuse.h>

static x68_getattr_fn g_getattr;
static x68_readdir_fn g_readdir;
static x68_open_fn g_open;
static x68_read_fn g_read;
static x68_release_fn g_release;

static x68_write_fn g_write;
static x68_create_fn g_create;
static x68_unlink_fn g_unlink;
static x68_mkdir_fn g_mkdir;
static x68_truncate_fn g_truncate;

struct filler_pack {
    fuse_fill_dir_t filler;
    void *buf;
};

void x68_fuse_set_callbacks(
    x68_getattr_fn getattr_fn,
    x68_readdir_fn readdir_fn,
    x68_open_fn open_fn,
    x68_read_fn read_fn,
    x68_release_fn release_fn
) {
    g_getattr = getattr_fn;
    g_readdir = readdir_fn;
    g_open = open_fn;
    g_read = read_fn;
    g_release = release_fn;
}

void x68_fuse_set_write_callbacks(
    x68_write_fn write_fn,
    x68_create_fn create_fn,
    x68_unlink_fn unlink_fn,
    x68_mkdir_fn mkdir_fn,
    x68_truncate_fn truncate_fn
) {
    g_write = write_fn;
    g_create = create_fn;
    g_unlink = unlink_fn;
    g_mkdir = mkdir_fn;
    g_truncate = truncate_fn;
}

int x68_fuse_add_direntry(void *filler_ctx, const char *name) {
    struct filler_pack *p = (struct filler_pack *)filler_ctx;
    if (!p || !p->filler || !name) return -EINVAL;
    /* macFUSE/fuse-t high-level filler: (buf, name, stbuf, off) */
    return p->filler(p->buf, name, NULL, 0);
}

static int op_getattr(const char *path, struct stat *stbuf) {
    if (!g_getattr) return -EIO;
    memset(stbuf, 0, sizeof(*stbuf));
    return g_getattr(path, stbuf);
}

static int op_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                      off_t offset, struct fuse_file_info *fi) {
    (void)offset;
    (void)fi;
    if (!g_readdir) return -EIO;
    struct filler_pack pack = { .filler = filler, .buf = buf };
    filler(buf, ".", NULL, 0);
    filler(buf, "..", NULL, 0);
    return g_readdir(path, buf, &pack);
}

static int op_open(const char *path, struct fuse_file_info *fi) {
    if (!g_open) return -EIO;
    /* Read-only unless write callbacks are installed */
    if ((fi->flags & O_ACCMODE) != O_RDONLY && !g_write) return -EROFS;
    uint64_t fh = 0, size = 0;
    int rc = g_open(path, fi->flags, &fh, &size);
    if (rc != 0) return rc;
    fi->fh = fh;
    fi->keep_cache = g_write ? 0 : 1;
    return 0;
}

static int op_read(const char *path, char *buf, size_t size, off_t offset,
                   struct fuse_file_info *fi) {
    (void)path;
    if (!g_read) return -EIO;
    return g_read(fi->fh, buf, size, offset);
}

static int op_release(const char *path, struct fuse_file_info *fi) {
    (void)path;
    if (!g_release) return 0;
    return g_release(fi->fh);
}

static int op_write(const char *path, const char *buf, size_t size, off_t offset,
                    struct fuse_file_info *fi) {
    (void)path;
    if (!g_write) return -EROFS;
    return g_write(fi->fh, buf, size, offset);
}

static int op_create(const char *path, mode_t mode, struct fuse_file_info *fi) {
    if (!g_create) return -EROFS;
    uint64_t fh = 0;
    int rc = g_create(path, mode, &fh);
    if (rc != 0) return rc;
    fi->fh = fh;
    fi->keep_cache = 0;
    return 0;
}

static int op_unlink(const char *path) {
    if (!g_unlink) return -EROFS;
    return g_unlink(path);
}

static int op_mkdir(const char *path, mode_t mode) {
    if (!g_mkdir) return -EROFS;
    return g_mkdir(path, mode);
}

static int op_truncate(const char *path, off_t size) {
    if (!g_truncate) return -EROFS;
    return g_truncate(path, size);
}

static int op_ftruncate(const char *path, off_t size, struct fuse_file_info *fi) {
    (void)fi;
    return op_truncate(path, size);
}

static struct fuse_operations x68_ops = {
    .getattr = op_getattr,
    .readdir = op_readdir,
    .open = op_open,
    .read = op_read,
    .release = op_release,
    .write = op_write,
    .create = op_create,
    .unlink = op_unlink,
    .mkdir = op_mkdir,
    .truncate = op_truncate,
    .ftruncate = op_ftruncate,
};

static void try_load_fuse_libs(void) {
    /* FUSE-T 1.x installs as a framework + versioned dylib under
     * /Library/Application Support/fuse-t — not always as libfuse-t.dylib
     * on the default dyld path. */
    const char *paths[] = {
        /* FUSE-T framework (current installer) */
        "/Library/Frameworks/fuse_t.framework/fuse_t",
        "/Library/Frameworks/fuse_t.framework/Versions/Current/fuse_t",
        "/Library/Frameworks/fuse_t.framework/Versions/A/fuse_t",
        /* FUSE-T Application Support tree */
        "/Library/Application Support/fuse-t/lib/libfuse-t-1.2.7.dylib",
        "/Library/Application Support/fuse-t/lib/libfuse-t.dylib",
        "/Library/Application Support/fuse-t/lib/libfuse3.dylib",
        /* Classic / Homebrew locations */
        "libfuse-t.dylib",
        "/usr/local/lib/libfuse-t.dylib",
        "/opt/homebrew/lib/libfuse-t.dylib",
        "libfuse.2.dylib",
        "/usr/local/lib/libfuse.2.dylib",
        "/opt/homebrew/lib/libfuse.2.dylib",
        "/usr/local/lib/libfuse.dylib",
        "/opt/homebrew/lib/libfuse.dylib",
        "libfuse3.dylib",
        NULL
    };
    for (int i = 0; paths[i]; i++) {
        void *h = dlopen(paths[i], RTLD_NOW | RTLD_GLOBAL);
        if (h) {
            fprintf(stderr, "x68mount-helper: loaded %s\n", paths[i]);
            return;
        }
    }
    fprintf(stderr, "x68mount-helper: warning: could not dlopen libfuse-t/libfuse (%s)\n", dlerror());
}

int x68_fuse_run(int argc, char **argv) {
    try_load_fuse_libs();
    return fuse_main(argc, argv, &x68_ops, NULL);
}
