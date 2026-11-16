# Network Build-Time Assets in Sandbox

Some CMake projects download assets at build time — Web UIs (npm-based), pre-built dist tarballs from HuggingFace, ML model weight files, etc. These fail in the Portage build sandbox because the sandbox blocks network access.

## The Pattern

### Identify the failure

Look for these during the build phase:
```
-- UI: running npm install
-- UI: npm install failed (1)
--   stderr: npm error code ENETUNREACH
-- UI: downloading from ... failed: "Could not resolve hostname"
```

Or during install:
```
CMake Warning at .../scripts/ui-assets.cmake:353 (message):
  UI: no assets available - building without an embedded UI.
```

### The solution: pkg_postinst instructions

Don't try to make the sandbox download work — it's intentionally network-isolated. Instead:

1. Let the build complete with the feature disabled/empty.
2. In `pkg_postinst()`, add instructions for the user to get the assets post-install.

```bash
pkg_postinst() {
    if use server; then
        elog "llama-server was built without the embedded Web UI (the build"
        elog "sandbox has no network access). To add the UI:"
        elog "  1. Download the pre-built UI assets from the project's"
        elog "     release page: https://github.com/owner/project/releases"
        elog "  2. Extract them to a known path:"
        elog "     mkdir -p /usr/share/llama.cpp/ui"
        elog "     tar xzf llama-ui-*.tar.gz -C /usr/share/llama.cpp/ui"
        elog "  3. Pass --path /usr/share/llama.cpp/ui to the server"
    fi
}
```

### Alternative: pre-download distfiles

For projects where the asset is a static tarball from a known URL (not npm), you can add the tarball to `SRC_URI` and patch the CMakeLists.txt to use the pre-downloaded file instead of fetching at build time. This is more involved but gives a fully-offline build.

### Indicators this pattern is needed

Look for signs in the project's CMakeLists.txt:
- `FetchContent` calls that download from external URLs (npm, HuggingFace, GitHub releases)
- `ExternalProject_Add` for JS/web assets
- Custom CMake scripts that invoke `curl` or `wget`
- Variables like `LLAMA_USE_PREBUILT_UI`, `LLAMA_BUILD_UI`, or similar that control download behavior

### CMake options to disable downloads

Some projects provide cmake flags to skip the download and stub the feature:

```bash
-DLLAMA_BUILD_UI=OFF         # skip building the web UI entirely
-DLLAMA_USE_PREBUILT_UI=OFF  # don't download pre-built assets
```
