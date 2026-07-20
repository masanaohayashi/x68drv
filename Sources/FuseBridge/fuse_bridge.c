#define FUSE_USE_VERSION 26
#define _FILE_OFFSET_BITS 64

#include "fuse_bridge.h"

#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>

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
static x68_rename_fn g_rename;
static x68_flush_fn g_flush;
static x68_statfs_fn g_statfs;

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
    x68_truncate_fn truncate_fn,
    x68_rename_fn rename_fn,
    x68_flush_fn flush_fn
) {
    g_write = write_fn;
    g_create = create_fn;
    g_unlink = unlink_fn;
    g_mkdir = mkdir_fn;
    g_truncate = truncate_fn;
    g_rename = rename_fn;
    g_flush = flush_fn;
}

void x68_fuse_set_statfs_callback(x68_statfs_fn statfs_fn) {
    g_statfs = statfs_fn;
}

int x68_fuse_add_direntry(void *filler_ctx, const char *name) {
    return x68_fuse_add_direntry_stat(filler_ctx, name, 0, 0, 0, 0, 0);
}

int x68_fuse_add_direntry_stat(
    void *filler_ctx,
    const char *name,
    int is_dir,
    uint64_t size,
    uid_t uid,
    gid_t gid,
    int64_t mtime_sec
) {
    struct filler_pack *p = (struct filler_pack *)filler_ctx;
    if (!p || !p->filler || !name) return -EINVAL;
    struct stat st;
    memset(&st, 0, sizeof(st));
    if (is_dir) {
        st.st_mode = S_IFDIR | 0777;
        st.st_nlink = 2;
    } else {
        st.st_mode = S_IFREG | 0666;
        st.st_nlink = 1;
        st.st_size = (off_t)size;
        st.st_blocks = (blkcnt_t)((size + 511) / 512);
    }
    st.st_uid = uid ? uid : getuid();
    st.st_gid = gid ? gid : getgid();
    st.st_blksize = 1024;
    if (mtime_sec > 0) {
        st.st_mtimespec.tv_sec = (time_t)mtime_sec;
        st.st_atimespec.tv_sec = (time_t)mtime_sec;
        st.st_ctimespec.tv_sec = (time_t)mtime_sec;
    }
    /* macFUSE/fuse-t high-level filler: (buf, name, stbuf, off) */
    return p->filler(p->buf, name, &st, 0);
}

static int op_access(const char *path, int mask) {
    (void)path;
    (void)mask;
    /* We do our own permission model; never return EACCES to Finder. */
    return 0;
}

static int op_chmod(const char *path, mode_t mode) {
    (void)path;
    (void)mode;
    return 0;
}

static int op_chown(const char *path, uid_t uid, gid_t gid) {
    (void)path;
    (void)uid;
    (void)gid;
    return 0;
}

static int op_utimens(const char *path, const struct timespec tv[2]) {
    (void)path;
    (void)tv;
    return 0;
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

static int op_rename(const char *from, const char *to) {
    if (!g_rename) return -EROFS;
    return g_rename(from, to);
}

static int op_flush(const char *path, struct fuse_file_info *fi) {
    (void)path;
    if (!g_flush) return 0;
    return g_flush(fi->fh);
}

static int op_fsync(const char *path, int isdatasync, struct fuse_file_info *fi) {
    (void)path;
    (void)isdatasync;
    if (!g_flush) return 0;
    return g_flush(fi->fh);
}

static int op_statfs(const char *path, struct statvfs *stbuf) {
    (void)path;
    if (!g_statfs || !stbuf) return -EIO;
    uint64_t bsize = 0, blocks = 0, bfree = 0, bavail = 0;
    int rc = g_statfs(&bsize, &blocks, &bfree, &bavail);
    if (rc != 0) return rc;
    memset(stbuf, 0, sizeof(*stbuf));
    stbuf->f_bsize = (unsigned long)(bsize ? bsize : 1024);
    stbuf->f_frsize = stbuf->f_bsize;
    stbuf->f_blocks = (fsblkcnt_t)blocks;
    stbuf->f_bfree = (fsblkcnt_t)bfree;
    stbuf->f_bavail = (fsblkcnt_t)bavail;
    /* File-count limits are soft; Human68k has no inode table. */
    stbuf->f_files = 100000;
    stbuf->f_ffree = 100000;
    stbuf->f_favail = 100000;
    stbuf->f_namemax = 255;
    return 0;
}

static struct fuse_operations x68_ops = {
    .getattr = op_getattr,
    .access = op_access,
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
    .rename = op_rename,
    .flush = op_flush,
    .fsync = op_fsync,
    .statfs = op_statfs,
    .chmod = op_chmod,
    .chown = op_chown,
    .utimens = op_utimens,
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
