# Vendored FUSE headers

Headers from **libfuse 2.9.5** (LGPL-2.1) are vendored under `include/` so `x68mount-helper` can compile without FUSE-T installed.

At **runtime**, `fuse_bridge.c` `dlopen`s:

- `libfuse-t.dylib` (FUSE-T)
- or `libfuse.2.dylib` / `libfuse.dylib` (macFUSE)

Install FUSE-T: https://www.fuse-t.org/ or  
`brew install macos-fuse-t/cask/fuse-t` (requires admin password).
