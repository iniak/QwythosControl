# Qwythos One-Click Deployment Design

## Goal

Enable Qwythos Control to deploy and manage the complete Qwythos model service
on a clean Apple Silicon Mac without Homebrew, administrator privileges, remote
scripts, or manual Terminal commands.

The first release supports Apple Silicon Macs running macOS 13 or newer.

## Product Scope

The app owns the complete installation lifecycle:

- device and storage preflight
- app-managed `llama-server` runtime installation
- resumable Q4_K_M model download
- integrity verification
- LaunchAgent configuration
- service startup and health verification
- existing installation migration
- repair, runtime reinstall, and uninstall
- optional authenticated local-network access

Intel Macs and Macs with 8 GB of unified memory are not supported.

## Verified Upstream Inputs

The initial deployment manifest pins these immutable inputs:

### Runtime

- Project: `ggml-org/llama.cpp`
- Release: `b10159`
- Asset: `llama-b10159-bin-macos-arm64.tar.gz`
- Size: `10,896,813` bytes
- SHA-256:
  `fa8710855b9432ed0df1917f3beba2ec68d6b57bbd45f4234bf33e6afa0c311c`
- URL:
  `https://github.com/ggml-org/llama.cpp/releases/download/b10159/llama-b10159-bin-macos-arm64.tar.gz`

### Model

- Repository:
  `llmfan46/Qwythos-9B-Claude-Mythos-5-1M-uncensored-heretic-GGUF`
- Repository commit: `5a91ab33c680ecfbd6731810bba2c068cb8427df`
- Asset:
  `Qwythos-9B-Claude-Mythos-5-1M-uncensored-heretic-Q4_K_M.gguf`
- Size: `6,216,967,936` bytes
- SHA-256:
  `1ee1cd89574b1b2e57447d6dab8328a6c39b20d18557a322d928215a8a8a96de`
- URL:
  `https://huggingface.co/llmfan46/Qwythos-9B-Claude-Mythos-5-1M-uncensored-heretic-GGUF/resolve/5a91ab33c680ecfbd6731810bba2c068cb8427df/Qwythos-9B-Claude-Mythos-5-1M-uncensored-heretic-Q4_K_M.gguf`

The manifest is bundled with the app. The app never resolves a moving `latest`
release or a Hugging Face `main` branch during deployment.

## Architecture

Create a focused `QwythosDeployment` Swift target. Deployment behavior must not
be added directly to `AppDelegate`.

### DeploymentCoordinator

An actor owns the deployment state machine and serializes all mutating
operations. It coordinates preflight, download, verification, installation,
service activation, repair, migration, and uninstall.

The coordinator exposes immutable snapshots through an `AsyncStream` so the UI
can render progress without polling implementation details.

### DeploymentManifest

A Codable value loaded from a bundled JSON resource defines:

- manifest schema version
- runtime version, URL, byte size, SHA-256, and expected executable names
- model repository commit, URL, byte size, SHA-256, and filename
- service label and port
- supported architecture and minimum macOS version

Unknown schema versions fail closed with an actionable app-update message.

### ResumableDownloader

The downloader uses `URLSession` and explicit `.partial` files.

- It validates HTTP status and expected content length.
- It resumes with an HTTP `Range` request from the partial file length.
- It verifies that a resumed response is `206 Partial Content` with the
  expected range.
- If a server ignores the range and returns `200`, it safely restarts the file.
- It publishes bytes received, total bytes, throughput, and estimated time.
- It retries transient network failures three times with exponential backoff.
- Cancellation closes the stream and preserves the partial file.

The final file is not exposed to the installer until its SHA-256 matches.

### InstallationLayout

The default root is:

`~/Library/Application Support/Qwythos Control/`

The user may select another writable volume. The selected root contains:

```text
Qwythos Control/
  config/
    deployment.json
    api-keys.txt
    legacy-launch-agent.plist
  downloads/
  logs/
  models/
    Qwythos-9B-Claude-Mythos-5-1M-uncensored-heretic-Q4_K_M.gguf
  runtime/
    current
    versions/
      b10159/
  staging/
```

`runtime/current` is an atomic symbolic link to a verified version directory.
The LaunchAgent always references the stable `runtime/current` path.

The custom root must remain mounted for the service to run. The wizard explains
this before accepting removable storage.

A small locator is always stored at:

`~/Library/Application Support/Qwythos Control/installation-location.json`

It contains the selected installation root and lets the app rediscover a custom
or removable-volume installation after relaunch. The locator is written when a
deployment starts so interrupted downloads can resume, and it is removed only
after a successful uninstall. If the selected volume is unavailable, inspection
reports a disconnected-volume state without rewriting or deleting the locator.

### LaunchAgentInstaller

The installer uses `PropertyListEncoder` to generate a plist and writes it
atomically to:

`~/Library/LaunchAgents/com.local.qwythos-9b.plist`

The service runs the local model with these fixed defaults:

- alias: `qwythos-9b`
- port: `18080`
- parallel requests: `1`
- GPU layers: `99`
- Jinja chat template support: enabled
- temperature: `0.6`
- top-p: `0.95`
- top-k: `20`
- repeat penalty: `1.05`

The model is passed with `--model <verified-local-path>`. The runtime never
downloads a model on its own.

### InstallationInspector

The inspector classifies the machine as:

- not installed
- partially downloaded
- legacy installation detected
- managed installation healthy
- managed installation repairable
- managed installation incompatible

It verifies deployment metadata, expected files, SHA-256 values, the installed
plist, the loaded LaunchAgent, and the health endpoint.

## State Machine

The coordinator uses these user-visible phases:

```text
idle
preflighting
ready
downloadingRuntime
verifyingRuntime
installingRuntime
downloadingModel
verifyingModel
writingConfiguration
startingService
checkingHealth
installed
paused
repairing
uninstalling
failed
```

Each snapshot includes:

- current phase
- current component
- completed and total bytes when applicable
- overall progress fraction
- concise status text
- recoverable error and available recovery actions

Only the coordinator may transition state. A second deployment action is
rejected while an operation is active.

## Wizard Experience

The menu shows `Deploy Qwythos...` when no managed installation exists and
`Manage Installation...` after deployment.

### Step 1: Device Check

Validate:

- `arm64` architecture
- macOS 13 or newer
- at least 16 GB unified memory
- writable installation root
- at least 8 GB free on the selected volume
- port `18080` is available or owned by the recognized existing service

An 8 GB Mac is blocked with a clear explanation.

### Step 2: Storage and Performance

Default to Application Support and allow another folder through `NSOpenPanel`.

Automatic performance profiles:

- 16 GB memory: Q4_K_M with 8K context
- 24 GB or more: Q4_K_M with 16K context

Advanced settings allow 4K, 8K, or 16K context. Values above 16K are outside
the first-release UI even though the model advertises a larger maximum.

This step also contains the network access control:

- `This Mac only` is the default.
- `Share on local network` is optional.

### Step 3: Review

Show:

- pinned runtime version
- model quantization
- download size
- selected storage path
- context size
- access mode and port

The primary command is `Deploy Qwythos`.

### Step 4: Installation

Show each deployment phase, component progress, throughput, and estimated time.

Closing the window does not cancel deployment. Quitting the app offers to pause;
partial downloads and deployment state remain available for the next launch.

### Step 5: Completion

Show:

- service health
- local chat URL
- local-network URL when enabled
- `Open Chat`
- `Done`

## Optional Local-Network Access

Local-network access is disabled by default.

### Local Mode

- Bind to `127.0.0.1`.
- Do not pass an API key to `llama-server`.

### Shared Mode

- Bind to `0.0.0.0`.
- Generate a 32-byte cryptographically secure random API key encoded as
  unpadded base64url.
- Store it one-per-line in `config/api-keys.txt`.
- Set file permissions to `0600`.
- Start the server with `--api-key-file <path>`.
- Show the active LAN URL and controls to copy, reveal, or regenerate the key.
- Restart the service immediately after changing access mode or regenerating
  the key.

The app does not configure UPnP, router port forwarding, a public tunnel, or a
macOS firewall exception. The wizard warns against enabling shared mode on
public Wi-Fi.

## Atomic Installation and Rollback

Runtime extraction occurs inside `staging/`. The installer validates:

- the expected `llama-server` executable exists
- all referenced dynamic libraries remain inside the runtime version directory
- the executable is Apple Silicon compatible
- `llama-server --version` succeeds

Only then is the version moved to `runtime/versions/` and `runtime/current`
switched atomically.

For an upgrade or runtime reinstall:

1. Keep the current runtime and service configuration.
2. Stage and validate the replacement.
3. Stop the service.
4. Switch `runtime/current`.
5. Start the service and wait up to 90 seconds for health.
6. Roll back the link and restart the old runtime if health fails.

The model is never removed during runtime rollback.

## Existing Installation Migration

An existing plist with the Qwythos service label but no managed deployment
record is treated as a legacy installation.

The wizard offers `Migrate Existing Installation`.

Migration:

1. Parse the existing plist as structured property-list data.
2. Stop only the recognized Qwythos service.
3. Back up the plist to `config/legacy-launch-agent.plist`.
4. Search recognized llama.cpp and Hugging Face cache locations for the exact
   model digest.
5. Reuse a matching model with APFS clone-on-write where available, then a hard
   link on the same volume, then a normal copy; download only if none succeeds.
6. Install the pinned app-managed runtime.
7. Write the managed plist and deployment record.
8. Start and health-check the managed service.
9. Restore the legacy plist and service if migration fails.

Migration never uninstalls Homebrew or deletes the legacy cache.

## Repair and Uninstall

### Repair Installation

Inspect every managed component and redownload only files that are missing or
whose digest is incorrect. Rewrite configuration and restart the service after
repair.

### Reinstall Runtime

Install the pinned runtime again while preserving the model and settings. Use
the standard rollback procedure.

### Uninstall

1. Stop and boot out the managed LaunchAgent.
2. Remove the installed plist.
3. Remove runtime, configuration, partial downloads, and managed logs.
4. Preserve the model by default.
5. Delete the model only when the user explicitly checks a separate option.

Uninstall never removes Homebrew, unrelated cache content, or a user-selected
parent directory.

## Error Handling

Every failure records:

- phase
- component
- concise user-facing reason
- detailed diagnostic message
- timestamp
- safe recovery actions

The UI offers `Retry` and `View Logs` for recoverable failures.

Specific handling includes:

- insufficient storage before and during download
- disconnected custom volumes
- checksum mismatch
- invalid runtime archive
- occupied service port
- LaunchAgent bootstrap failure
- health timeout
- network loss and range mismatch

A failed operation never writes an `installed` deployment record.

## Testing

### Unit Tests

Test:

- Apple Silicon, macOS, memory, storage, and port preflight
- automatic context selection
- manifest decoding and schema rejection
- installation layout and path containment
- all coordinator state transitions
- progress aggregation
- LaunchAgent arguments for local and shared modes
- API key generation and `0600` permissions
- repair planning
- uninstall scope
- legacy plist recognition

### Download Tests

Use a local HTTP test server to cover:

- new download
- valid range resume
- ignored range restart
- connection loss
- exponential retry
- cancellation
- content length mismatch
- checksum mismatch

Automated tests never download the production model.

### Filesystem and Integration Tests

Use temporary directories, a small fake runtime archive, and a small fake model
to verify:

- staging and atomic promotion
- runtime link switching
- rollback after failed health
- model preservation
- migration reuse
- repair
- uninstall

### Manual Acceptance

Verify on 16 GB and 24 GB Apple Silicon Macs:

- default and external storage
- interrupted model download and resume
- clean deployment
- legacy migration
- login restart
- local-only access
- authenticated access from another LAN device
- access-mode changes
- repair and uninstall

## Success Criteria

Deployment is successful only when:

- all installed artifacts match the pinned manifest
- the LaunchAgent is loaded
- the service returns `{"status":"ok"}`
- `Open Chat` works
- the selected access mode is enforced
- the service starts again after the next login
- the existing menu-bar start and stop controls remain functional
