# Qwythos Control

Qwythos Control is a macOS menu-bar app for deploying and managing the local
Qwythos 9B model service. A release build with deployment resources can perform
the complete install from its native wizard. It does not require Homebrew,
administrator privileges, a remote install script, or manual Terminal work.

This repository does not imply that the app, service, runtime, or model is
installed on the current Mac.

## Requirements

- Apple Silicon only (`arm64`); Intel Macs are outside the current scope
- macOS 13 or newer
- At least 16 GB of unified memory; 8 GB memory Macs are not supported
- At least 8 GB free on the selected installation volume
- A writable installation location and available local port `18080`

The automatic context is 8K on a 16 GB Mac and 16K with 24 GB or more.
Use a dedicated empty folder when choosing a custom installation root. The app
preserves unknown sibling files, but the recorded runtime version directory is
managed as a unit. A dedicated root keeps ownership and backups clear.

## One-Click Deployment

Open the Qwythos Control status menu and choose **Deploy Qwythos...**. The
wizard checks the Mac, lets you confirm storage, context, and network access,
then shows the exact choices before the deploy command becomes available.

After confirmation, one app action:

1. Downloads the pinned Apple Silicon `llama.cpp` runtime and Q4_K_M model.
2. Verifies both SHA-256 digests before either artifact is installed.
3. Stages and validates `llama-server`, then switches the managed runtime.
4. Writes a user LaunchAgent and starts the service.
5. Records the installation only after the health check succeeds.

The pinned download is 6,227,864,749 bytes in total, about 6.23 GB decimal or
5.80 GiB. The 8 GB free-space requirement allows room for partial downloads,
staging, and the installed files.

Local-only access is the default. Optional local-network sharing binds port
`18080` on all interfaces and requires a generated API key. Use shared mode only
on a trusted network.

See [Deployment and Operations](docs/deployment.md) for storage paths, recovery,
LAN authentication, migration, repair, runtime reinstall, uninstall, and
troubleshooting.
