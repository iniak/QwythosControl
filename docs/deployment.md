# Deployment and Operations

This page describes behavior in a Qwythos Control build that includes the
deployment feature. It is not a statement that Qwythos Control, its LaunchAgent,
runtime, or model has been deployed on this Mac.

## Supported Macs

The current deployment scope is Apple Silicon only:

- `arm64` Apple Silicon Mac
- macOS 13 or newer
- 16 GB or more unified memory
- 8 GB or more free on the selected volume
- Writable selected location
- Port `18080` available, or owned by a recognized Qwythos service

Intel Macs and Macs with 8 GB of unified memory are not supported. The automatic
profile uses an 8K context on 16 GB Macs and a 16K context on Macs with 24 GB or
more. The wizard also offers 4K, 8K, and 16K choices.

## What Deploy Does

Choose **Deploy Qwythos...** from the menu-bar app. The wizard performs device
and storage checks, collects the storage, context, and network choices, and
shows a review before enabling **Deploy Qwythos**.

That single confirmed app action:

1. Downloads the manifest-pinned Apple Silicon runtime and Q4_K_M model.
2. Streams them into managed `.partial` files and verifies exact byte counts
   and SHA-256 digests.
3. Extracts the runtime into staging, validates its arm64 executable and local
   dynamic libraries, and runs its version check.
4. Promotes the model and runtime only after validation.
5. Generates the LaunchAgent property list and managed log paths.
6. Starts the user service and checks `http://127.0.0.1:18080/health`.
7. Writes the installed record only after health succeeds.

The app does not use Homebrew, request administrator access, run a downloaded
installer script, or require manual Terminal commands. It installs a LaunchAgent
for the current user, not a system daemon.

The exact pinned payload is 6,227,864,749 bytes: a 10,896,813-byte runtime and a
6,216,967,936-byte model. This is about 6.23 GB decimal or 5.80 GiB. Keep at
least 8 GB free for downloads, staging, and installed content.

## Storage

The default root is:

`~/Library/Application Support/Qwythos Control/`

It contains:

```text
config/
  deployment.json
  api-keys.txt
  legacy-launch-agent.plist
downloads/
logs/
models/
runtime/
  current
  versions/
staging/
```

The wizard can use another writable folder or volume. A custom or removable
volume must remain mounted whenever the service starts or runs. The app keeps a
small location record at:

`~/Library/Application Support/Qwythos Control/installation-location.json`

That locator is written before resumable work begins. If a custom volume is
disconnected, the app reports it as unavailable without silently changing or
deleting the saved location.

Choose a dedicated empty folder for a custom root. Qwythos Control creates its
managed-named subdirectories there, but it does not claim unrelated content
that already exists in the selected folder or is later placed in `config`,
`downloads`, `logs`, `models`, `runtime`, or `staging`.

## Interruption and Recovery

Closing the wizard does not cancel an active deployment. Quitting the app pauses
at a safe operation boundary. Downloaded bytes remain in `.partial` files, and
the installation locator remains available.

On the next launch, reopen the deployment wizard and use **Resume Deployment**
or **Retry** when offered. The downloader checks the retained file and resumes
with an HTTP Range request. If a server ignores the range, the app safely
restarts that one file. A complete retained partial is reused only after its
size and SHA-256 digest pass again.

A failed health check, checksum mismatch, invalid runtime, network failure, or
other deployment error does not create an installed record. The failure screen
keeps the phase and component, offers safe recovery, and links to the managed
logs. Verified model data is preserved across service startup failures.

## Existing Installation Migration

A recognized Qwythos `llama-server` LaunchAgent without a managed deployment
record is presented as a migration candidate. Migration:

- Accepts only the recognized Qwythos label and executable shape.
- Requires the pinned managed runtime to be verifiable before changing the
  existing service.
- Backs up the existing property list as
  `config/legacy-launch-agent.plist`.
- Reuses a cache model only when its digest exactly matches the manifest.
- Starts and health-checks the managed service before recording success.
- Restores the prior property list and service state if migration fails.

Migration does not uninstall Homebrew or delete its caches. It also does not
delete unrelated Hugging Face or `llama.cpp` cache content.

## Network Access

### This Mac Only

This is the default. The service binds `127.0.0.1:18080`, and its LaunchAgent
does not contain an API-key argument. Other devices cannot reach this endpoint
through a LAN address.

### Share on Local Network

Shared mode binds `0.0.0.0:18080`. Before publishing that configuration, the app
creates a cryptographically random 32-byte key encoded as unpadded base64url.
The key is stored one per line at:

`<selected-root>/config/api-keys.txt`

The file has exact `0600` permissions. The secret value is not embedded in the
LaunchAgent property list, deployment record, progress snapshots, or managed
logs. It is hidden by default. **Copy API key** and **Reveal API key** read it
directly from the protected file only after that explicit action; hiding it
clears the displayed value. Regeneration hides any previously revealed value,
restarts the service, and requires a fresh explicit copy or reveal. The
LaunchAgent receives only the key-file path.

Clients must send:

```http
Authorization: Bearer <key>
```

Requests without the key, or with an old key after regeneration, are rejected.
Changing access mode or regenerating the key restarts and health-checks the
service. Switching back to local-only binds loopback and removes the key-file
argument from the LaunchAgent; the protected key file may remain for a future
shared-mode session.

Shared mode is LAN exposure, not public hosting. Qwythos Control does not add a
macOS firewall exception, configure UPnP, open a router port, or create a public
tunnel. Do not enable it on public Wi-Fi, do not forward port `18080`, and share
the key only with clients you trust.

## Repair, Runtime Reinstall, and Uninstall

**Repair** inspects the runtime, model digest, configuration, LaunchAgent,
loaded-service state, and health endpoint. It downloads only damaged components,
then rewrites configuration and performs a fresh health check.

**Update Runtime** or **Reinstall Runtime** stages and validates the pinned
runtime again while preserving the model and settings. If the replacement does
not become healthy, the app restores the previous runtime and starts it again.

**Uninstall** first validates the installation-record schema, saved root,
supported context, and a strictly safe recorded runtime-version component. It
does not require the recorded runtime version, manifest schema, or model digest
to equal the currently bundled manifest, so a valid older or newer installation
can still be removed. It then stops the service and removes its property list.

Uninstall deletes only known Qwythos entries: the current-runtime link, the
recorded runtime version directory, the API-key and legacy-backup files, the two
current-manifest partial downloads, and the two managed service logs. Runtime
directory removal is pinned to its filesystem identity: the exact version
directory is atomically quarantined without replacement and traversed through
directory descriptors without following links. Before recursive deletion, a
durable cleanup tombstone records the quarantine name, filesystem identity, and
installation record. If cleanup fails while the recorded public name is vacant,
the same directory inode is restored for a normal retry. If another directory
has appeared at that name, it is preserved and the tombstone remains so the next
uninstall removes only the exact quarantined inode. A quarantine identity
mismatch fails closed instead of touching either directory. After the
quarantine is durably gone, the tombstone remains as a completion guard until
the installed record is removed, so another failed uninstall cannot mistake a
replacement for managed content. The installed record is removed after content
cleanup and before the saved location.

The model is preserved by default. Enable **Delete downloaded model when
uninstalling** only when the exact manifest model file should also be removed.
Managed-named parent directories are removed only when empty. Unknown files or
directories anywhere else under the selected root are retained, including
content inside `config`, `downloads`, `logs`, `models`, `runtime`, or `staging`.
The exact recorded runtime version directory is managed as one unit, so do not
store unrelated files inside that version directory.

Uninstall removes the saved location only after managed cleanup succeeds. If
content cleanup fails, both the record and saved location remain for a full
retry. If only the final saved-location removal fails after the record is gone,
the next uninstall performs a locator-only retry without repeating service or
content deletion. This locator-only retry is separate from the runtime tombstone
retry, which requires the matching installation record and quarantine identity.
If record removal succeeded but final tombstone or locator cleanup did not, the
locator-only retry removes the completed tombstone before the locator. It never
removes the selected parent folder, Homebrew, legacy caches, or unrelated user
files.

## Logs and Troubleshooting

Managed service logs are under:

`<selected-root>/logs/`

The two runtime streams are:

- `llama-server.stdout.log`
- `llama-server.stderr.log`

Use **View Logs** on a deployment failure or from the status menu. When the
installation uses a custom root, the app resolves the log folder from the
installed record instead of assuming the default path.

Common recovery checks:

- **Device check is blocked:** confirm Apple Silicon, macOS 13 or newer, at
  least 16 GB memory, 8 GB free, a writable root, and port `18080` availability.
- **Custom volume unavailable:** reconnect the same volume and reopen the
  wizard. Do not choose a different path merely to bypass the saved locator.
- **Download stopped:** reopen the wizard and resume. Keep the `.partial` files;
  deleting them forces a full download.
- **Checksum or archive validation failed:** retry the operation. The rejected
  artifact is never promoted or recorded as installed.
- **Service did not become healthy:** inspect both managed logs, then use
  **Retry**, **Repair**, or **Reinstall Runtime** according to the offered
  management state.
- **LAN request is unauthorized:** confirm shared mode is active and send the
  current key in the Bearer header.
- **LAN endpoint is unreachable:** confirm both devices are on the same trusted
  network and review local firewall policy. The app does not bypass the
  firewall or router.
- **Uninstall stopped partway:** reopen management and retry. The saved locator
  is intentionally retained until cleanup finishes. When only locator removal
  remains, retry clears that locator without touching installation content
  again.
