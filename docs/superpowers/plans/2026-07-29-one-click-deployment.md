# Qwythos One-Click Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a native, resumable, verified deployment wizard that installs and manages Qwythos on a clean Apple Silicon Mac without Homebrew or administrator privileges.

**Architecture:** Add a `QwythosDeployment` Swift library target that owns manifests, preflight, downloads, installation, migration, service configuration, repair, and uninstall. The existing executable adds a thin AppKit window hosting SwiftUI wizard views and continues to use `QwythosCore` for routine service start/stop observation.

**Tech Stack:** Swift 6, Swift Concurrency, Foundation, CryptoKit, Network, AppKit, SwiftUI, XCTest, Swift Package Manager, launchd

## Global Constraints

- Support Apple Silicon and macOS 13 or newer only.
- Require at least 16 GB unified memory and 8 GB free storage.
- Use the pinned `llama.cpp` `b10159` macOS arm64 release and pinned Q4_K_M model commit from the approved design.
- Never install Homebrew, request administrator privileges, or execute a remote script.
- Keep local-only access as the default; LAN sharing must require a generated API key file with mode `0600`.
- Preserve partial downloads, the model during runtime rollback, and the model during uninstall unless the user explicitly selects deletion.
- Use staging plus atomic promotion; never record an installation as complete before service health succeeds.
- Bind the managed service to port `18080`.

---

## File Structure

Create the deployment module with one responsibility per file:

```text
Sources/QwythosDeployment/
  DeploymentCoordinator.swift
  DeploymentManifest.swift
  DeploymentModels.swift
  DeploymentPreflight.swift
  InstallationInspector.swift
  InstallationLayout.swift
  InstallationLocator.swift
  InstallationRecord.swift
  LANAddressProvider.swift
  LaunchAgentInstaller.swift
  LegacyInstallationMigrator.swift
  ResumableDownloader.swift
  RuntimeInstaller.swift
  SHA256Hasher.swift
  Resources/deployment-manifest.json
```

Keep UI-only code in the executable:

```text
Sources/QwythosControlApp/
  AppDelegate.swift
  DeploymentWizardModel.swift
  DeploymentWizardWindowController.swift
  Views/
    CompletionStepView.swift
    ConfigurationStepView.swift
    DeploymentWizardView.swift
    DeviceCheckStepView.swift
    ManagementView.swift
    ProgressStepView.swift
    ReviewStepView.swift
```

Move the current `AppDelegate` implementation out of `main.swift`; leave
`main.swift` as the minimal application entry point.

Create a separate deployment test target:

```text
Tests/QwythosDeploymentTests/
  DeploymentCoordinatorTests.swift
  DeploymentManifestTests.swift
  DeploymentPreflightTests.swift
  InstallationInspectorTests.swift
  InstallationLayoutTests.swift
  LANAddressProviderTests.swift
  LaunchAgentInstallerTests.swift
  LegacyInstallationMigratorTests.swift
  ResumableDownloaderTests.swift
  RuntimeInstallerTests.swift
  SHA256HasherTests.swift
  Support/RangeHTTPServer.swift
  Support/TestDoubles.swift
Tests/QwythosControlAppTests/
  AppIntegrationTests.swift
  DeploymentWizardLayoutTests.swift
  DeploymentWizardModelTests.swift
```

---

### Task 1: Deployment Target, Pinned Manifest, and Installation Layout

**Files:**
- Modify: `Package.swift`
- Create: `Sources/QwythosDeployment/DeploymentManifest.swift`
- Create: `Sources/QwythosDeployment/InstallationLayout.swift`
- Create: `Sources/QwythosDeployment/InstallationLocator.swift`
- Create: `Sources/QwythosDeployment/Resources/deployment-manifest.json`
- Create: `Tests/QwythosDeploymentTests/DeploymentManifestTests.swift`
- Create: `Tests/QwythosDeploymentTests/InstallationLayoutTests.swift`

**Interfaces:**
- Produces: `DeploymentManifest.load(data:)`, `DeploymentArtifact`,
  `ServiceDefaults`, and `InstallationLayout`.
- Consumed by: every later deployment task.

- [ ] **Step 1: Add failing manifest tests**

```swift
final class DeploymentManifestTests: XCTestCase {
    func testLoadsPinnedProductionManifest() throws {
        let manifest = try DeploymentManifest.load(
            data: DeploymentManifest.productionData()
        )

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.runtime.version, "b10159")
        XCTAssertEqual(manifest.runtime.size, 10_896_813)
        XCTAssertEqual(manifest.model.size, 6_216_967_936)
        XCTAssertEqual(manifest.service.port, 18_080)
    }

    func testRejectsUnknownSchemaVersion() {
        let data = Data(#"{"schemaVersion":2}"#.utf8)
        XCTAssertThrowsError(try DeploymentManifest.load(data: data))
    }
}
```

- [ ] **Step 2: Add failing layout containment tests**

```swift
final class InstallationLayoutTests: XCTestCase {
    func testBuildsAllManagedPathsUnderSelectedRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/Qwythos Root")
        let layout = InstallationLayout(root: root)

        XCTAssertEqual(layout.configDirectory, root.appending(path: "config"))
        XCTAssertEqual(layout.downloadsDirectory, root.appending(path: "downloads"))
        XCTAssertEqual(layout.runtimeCurrent, root.appending(path: "runtime/current"))
        XCTAssertNoThrow(try layout.requireManaged(layout.modelFile))
        XCTAssertThrowsError(
            try layout.requireManaged(URL(fileURLWithPath: "/tmp/outside"))
        )
    }
}
```

- [ ] **Step 3: Run the new target tests and verify compilation fails**

Run:

```bash
swift test --filter 'DeploymentManifestTests|InstallationLayoutTests'
```

Expected: failure because `QwythosDeployment` and its types do not exist.

- [ ] **Step 4: Add the SwiftPM targets and resources**

Add:

```swift
.library(name: "QwythosDeployment", targets: ["QwythosDeployment"])
```

Add target definitions:

```swift
.target(
    name: "QwythosDeployment",
    dependencies: ["QwythosCore"],
    resources: [.process("Resources")]
),
.testTarget(
    name: "QwythosDeploymentTests",
    dependencies: ["QwythosDeployment"]
)
```

Add `QwythosDeployment` to the executable target dependencies.

- [ ] **Step 5: Implement exact manifest models**

Define:

```swift
public struct DeploymentManifest: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let runtime: RuntimeArtifact
    public let model: DeploymentArtifact
    public let service: ServiceDefaults

    public static func productionData() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "deployment-manifest",
            withExtension: "json"
        ) else {
            throw ManifestError.missingResource
        }
        return try Data(contentsOf: url)
    }

    public static func load(data: Data) throws -> DeploymentManifest
}

public struct DeploymentArtifact: Codable, Equatable, Sendable {
    public let filename: String
    public let sourceURL: URL
    public let size: Int64
    public let sha256: String
}

public struct RuntimeArtifact: Codable, Equatable, Sendable {
    public let version: String
    public let archive: DeploymentArtifact
    public let directoryName: String
    public let serverRelativePath: String
}

public struct ServiceDefaults: Codable, Equatable, Sendable {
    public let label: String
    public let port: UInt16
}
```

Use `ManifestError.missingResource`, `ManifestError.unsupportedSchema(Int)`, and
`ManifestError.invalidSHA256(String)` for fail-closed validation.

- [ ] **Step 6: Add the pinned JSON resource**

Use exactly the release, URLs, sizes, SHA-256 values, service label, and port
from `docs/superpowers/specs/2026-07-29-one-click-deployment-design.md`.

- [ ] **Step 7: Implement the layout**

`InstallationLayout` must expose all directories from the design plus:

```swift
public var deploymentRecord: URL
public var apiKeyFile: URL
public var legacyPlistBackup: URL
public var modelFile: URL
public func runtimeVersion(_ version: String) -> URL
public func runtimeServer(version: String) -> URL
public func partialFile(for artifact: DeploymentArtifact) -> URL
public func requireManaged(_ url: URL) throws -> URL
```

Containment must compare standardized file paths and reject the root itself for
destructive operations.

- [ ] **Step 8: Implement persistent root discovery**

```swift
public struct InstallationLocation: Codable, Equatable, Sendable {
    public let root: URL
}

public protocol InstallationLocating: Sendable {
    func load() throws -> InstallationLocation?
    func save(_ location: InstallationLocation) throws
    func remove() throws
}
```

`InstallationLocator` atomically stores
`~/Library/Application Support/Qwythos Control/installation-location.json`.
Add a test that saves a custom-volume root, recreates the locator, and loads the
same standardized URL. Add a missing-volume test that preserves the locator and
returns the unavailable root for inspection.

- [ ] **Step 9: Run tests**

Run:

```bash
swift test --filter 'DeploymentManifestTests|InstallationLayoutTests'
```

Expected: all selected tests pass.

- [ ] **Step 10: Commit**

```bash
git add Package.swift Sources/QwythosDeployment Tests/QwythosDeploymentTests
git commit -m "feat: add deployment manifest and layout"
```

---

### Task 2: Device Preflight and Automatic Performance Profiles

**Files:**
- Create: `Sources/QwythosDeployment/DeploymentPreflight.swift`
- Create: `Tests/QwythosDeploymentTests/DeploymentPreflightTests.swift`
- Create: `Tests/QwythosDeploymentTests/Support/TestDoubles.swift`

**Interfaces:**
- Produces: `SystemProfileProviding`, `PortChecking`, `DeploymentPreflight`,
  `PreflightReport`, and `PerformanceProfile`.
- Consumed by: `DeploymentCoordinator` and the device-check wizard step.

- [ ] **Step 1: Write failing profile tests**

```swift
func testAutomaticContextUsesMemoryThresholds() throws {
    XCTAssertThrowsError(
        try PerformanceProfile.automatic(physicalMemory: 8 * 1_073_741_824)
    )
    XCTAssertEqual(
        try PerformanceProfile.automatic(physicalMemory: 16 * 1_073_741_824)
            .contextSize,
        8_192
    )
    XCTAssertEqual(
        try PerformanceProfile.automatic(physicalMemory: 24 * 1_073_741_824)
            .contextSize,
        16_384
    )
}
```

- [ ] **Step 2: Write failing preflight tests**

Use `FakeSystemProfile` and `FakePortChecker` to verify:

```swift
func testPreflightRejectsIntelAndInsufficientStorage() async {
    let preflight = DeploymentPreflight(
        profile: FakeSystemProfile(
            architecture: "x86_64",
            operatingSystem: .init(majorVersion: 14, minorVersion: 0, patchVersion: 0),
            physicalMemory: 16 * 1_073_741_824,
            availableCapacity: 7_999_999_999,
            writable: true
        ),
        portChecker: FakePortChecker(isAvailable: true)
    )

    let report = await preflight.run(
        root: URL(fileURLWithPath: "/tmp/root"),
        servicePort: 18_080
    )

    XCTAssertFalse(report.canDeploy)
    XCTAssertTrue(report.issues.contains(.unsupportedArchitecture("x86_64")))
    XCTAssertTrue(report.issues.contains(.insufficientStorage))
}
```

- [ ] **Step 3: Verify tests fail**

Run:

```bash
swift test --filter DeploymentPreflightTests
```

Expected: compilation failure for missing preflight types.

- [ ] **Step 4: Implement injectable system interfaces**

```swift
public protocol SystemProfileProviding: Sendable {
    var architecture: String { get }
    var operatingSystem: OperatingSystemVersion { get }
    var physicalMemory: UInt64 { get }
    func availableCapacity(at url: URL) throws -> Int64
    func isWritable(_ url: URL) -> Bool
}

public protocol PortChecking: Sendable {
    func isAvailable(port: UInt16) async -> Bool
}
```

Production architecture uses `uname`, memory uses
`ProcessInfo.processInfo.physicalMemory`, capacity uses
`URLResourceKey.volumeAvailableCapacityForImportantUsageKey`, and the port
checker attempts a loopback bind with `Network.NWListener`.

- [ ] **Step 5: Implement exact preflight rules**

`PreflightReport` must retain individual checks and calculate `canDeploy`.
Require:

- architecture equals `arm64`
- OS major version at least `13`
- physical memory at least `16 * 1_073_741_824`
- available capacity at least `8_000_000_000`
- root is writable
- port is available, unless the inspector later identifies the recognized
  Qwythos service as its owner

- [ ] **Step 6: Run tests and commit**

```bash
swift test --filter DeploymentPreflightTests
git add Sources/QwythosDeployment/DeploymentPreflight.swift \
  Tests/QwythosDeploymentTests/DeploymentPreflightTests.swift \
  Tests/QwythosDeploymentTests/Support/TestDoubles.swift
git commit -m "feat: add deployment preflight checks"
```

---

### Task 3: Streaming SHA-256 and Resumable Downloads

**Files:**
- Create: `Sources/QwythosDeployment/SHA256Hasher.swift`
- Create: `Sources/QwythosDeployment/ResumableDownloader.swift`
- Create: `Tests/QwythosDeploymentTests/SHA256HasherTests.swift`
- Create: `Tests/QwythosDeploymentTests/ResumableDownloaderTests.swift`
- Create: `Tests/QwythosDeploymentTests/Support/RangeHTTPServer.swift`

**Interfaces:**
- Produces: `FileHashing`, `SHA256Hasher`, `ArtifactDownloading`,
  `ResumableDownloader`, and `DownloadProgress`.
- Consumed by: runtime/model installation, repair, migration, and coordinator.

- [ ] **Step 1: Write the failing streaming hash test**

```swift
func testHashesFileWithoutLoadingWholeFile() throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    try Data("abc".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertEqual(
        try SHA256Hasher().sha256(file: url),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
}
```

- [ ] **Step 2: Write failing range-download tests**

Start `RangeHTTPServer` on loopback with a deterministic payload. Verify:

```swift
private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []

    func append(_ value: Int64) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

func testResumesFromExistingPartialFile() async throws {
    let payload = Data("abcdefgh".utf8)
    let server = try RangeHTTPServer(payload: payload)
    try server.start()
    defer { server.stop() }

    let partialURL = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString)
    try Data(payload.prefix(4)).write(to: partialURL)
    defer { try? FileManager.default.removeItem(at: partialURL) }

    let artifact = DeploymentArtifact(
        filename: "fixture.bin",
        sourceURL: server.url,
        size: 8,
        sha256: "9c56cc51b374c3ba189210d5b6d4bf57790d351c96c47c02190ecf1e430635ab"
    )
    let recorder = ProgressRecorder()
    let downloader = ResumableDownloader()

    let result = try await downloader.download(
        artifact: artifact,
        partialURL: partialURL
    ) { progress in
        recorder.append(progress.completedBytes)
    }

    XCTAssertEqual(try Data(contentsOf: result), payload)
    XCTAssertEqual(server.requests.last?.rangeHeader, "bytes=4-")
    XCTAssertEqual(recorder.values.last, Int64(payload.count))
}
```

`RangeHTTPServer` is a loopback `NWListener` test helper with:

```swift
final class RangeHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let rangeHeader: String?
    }

    init(payload: Data) throws
    var url: URL { get }
    var requests: [Request] { get }
    func start() throws
    func stop()
}
```

Add separate tests for:

- a server ignoring `Range` and returning `200`
- transient disconnect followed by retry
- cancellation preserving `.partial`
- content-length mismatch
- SHA-256 mismatch

- [ ] **Step 3: Verify tests fail**

```bash
swift test --filter 'SHA256HasherTests|ResumableDownloaderTests'
```

- [ ] **Step 4: Implement file hashing**

```swift
public protocol FileHashing: Sendable {
    func sha256(file: URL) throws -> String
}
```

Read with `FileHandle.read(upToCount: 1_048_576)` and incrementally update
`CryptoKit.SHA256`.

- [ ] **Step 5: Implement downloader contracts**

```swift
public struct DownloadProgress: Equatable, Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64
    public let bytesPerSecond: Double
}

public protocol ArtifactDownloading: Sendable {
    func download(
        artifact: DeploymentArtifact,
        partialURL: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL
}
```

`ResumableDownloader` uses a `URLSessionDataDelegate` helper that appends
received `Data` chunks to an open file handle. Validate `200` versus `206`,
`Content-Range`, total size, and SHA-256 before returning.

- [ ] **Step 6: Implement retry and cancellation**

Retry only transport failures and HTTP `408`, `429`, and `5xx`, with delays of
1, 2, and 4 seconds. Do not retry checksum, range, permission, or storage
errors. Cancellation must call `URLSessionTask.cancel()` and close the file.

- [ ] **Step 7: Run tests and commit**

```bash
swift test --filter 'SHA256HasherTests|ResumableDownloaderTests'
git add Sources/QwythosDeployment/SHA256Hasher.swift \
  Sources/QwythosDeployment/ResumableDownloader.swift \
  Tests/QwythosDeploymentTests
git commit -m "feat: add verified resumable downloads"
```

---

### Task 4: Runtime Installation, API Keys, and LaunchAgent Generation

**Files:**
- Create: `Sources/QwythosDeployment/RuntimeInstaller.swift`
- Create: `Sources/QwythosDeployment/LaunchAgentInstaller.swift`
- Create: `Sources/QwythosDeployment/LANAddressProvider.swift`
- Create: `Sources/QwythosDeployment/DeploymentModels.swift`
- Create: `Tests/QwythosDeploymentTests/RuntimeInstallerTests.swift`
- Create: `Tests/QwythosDeploymentTests/LANAddressProviderTests.swift`
- Create: `Tests/QwythosDeploymentTests/LaunchAgentInstallerTests.swift`

**Interfaces:**
- Produces: `DeploymentOptions`, `NetworkAccessMode`, `RuntimeInstalling`,
  `RuntimeInstaller`, `APIKeyStore`, `LaunchAgentInstalling`, and
  `LaunchAgentInstaller`.
- Consumed by: coordinator, repair, migration, and management UI.

- [ ] **Step 1: Write failing runtime promotion and rollback tests**

Use a tiny tar archive containing:

```text
llama-b10159/llama-server
llama-b10159/libllama.dylib
```

Verify the installer stages the archive, runs `llama-server --version`, moves
the directory into `runtime/versions/b10159`, and atomically points
`runtime/current` at it. Add a test where validation fails and the old link is
unchanged.

- [ ] **Step 2: Write failing LaunchAgent tests**

```swift
func testSharedModeBindsAllInterfacesAndRequiresKeyFile() throws {
    let data = try installer.makePlist(
        layout: layout,
        options: .init(
            root: layout.root,
            contextSize: 16_384,
            accessMode: .shared
        ),
        manifest: manifest
    )
    let plist = try XCTUnwrap(
        PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
    )
    let args = try XCTUnwrap(plist["ProgramArguments"] as? [String])
    let hostIndex = try XCTUnwrap(args.firstIndex(of: "--host"))
    let keyIndex = try XCTUnwrap(args.firstIndex(of: "--api-key-file"))

    XCTAssertEqual(args[hostIndex + 1], "0.0.0.0")
    XCTAssertEqual(args[keyIndex + 1], layout.apiKeyFile.path)
}
```

Add a local-mode test asserting `127.0.0.1` and no `--api-key-file`.

- [ ] **Step 3: Verify tests fail**

```bash
swift test --filter 'RuntimeInstallerTests|LaunchAgentInstallerTests|LANAddressProviderTests'
```

- [ ] **Step 4: Define deployment options**

```swift
public enum NetworkAccessMode: String, Codable, Equatable, Sendable {
    case local
    case shared
}

public struct DeploymentOptions: Codable, Equatable, Sendable {
    public let root: URL
    public let contextSize: Int
    public let accessMode: NetworkAccessMode
}
```

Only context sizes `4_096`, `8_192`, and `16_384` are accepted.

Define:

```swift
public protocol RuntimeInstalling: Sendable {
    func install(
        archive: URL,
        manifest: RuntimeArtifact,
        layout: InstallationLayout
    ) async throws

    func rollBackCurrentRuntime(
        to previousVersion: String,
        layout: InstallationLayout
    ) throws
}

public protocol LaunchAgentInstalling: Sendable {
    func install(
        layout: InstallationLayout,
        options: DeploymentOptions,
        manifest: DeploymentManifest
    ) throws

    func restoreLegacyPlist(layout: InstallationLayout) throws
    func uninstall() throws
}
```

- [ ] **Step 5: Implement API key storage**

Generate 32 bytes with `SecRandomCopyBytes`, encode unpadded base64url, write
one key plus a trailing newline, and set POSIX permissions to `0o600`.

Expose:

```swift
public protocol APIKeyStoring: Sendable {
    func load() throws -> String?
    func generate() throws -> String
    func remove() throws
}
```

`generate()` atomically replaces the previous key.

- [ ] **Step 6: Implement LAN address discovery**

Use `getifaddrs` to return active, non-loopback IPv4 addresses. Exclude
`127.0.0.0/8`, `169.254.0.0/16`, and interfaces without `IFF_UP`. Expose:

```swift
public protocol LANAddressProviding: Sendable {
    func activeIPv4Addresses() -> [String]
}
```

Add table-driven tests for loopback, link-local, inactive, Wi-Fi, Ethernet, and
multiple active interfaces. Completion UI formats each result as
`http://<address>:18080`.

- [ ] **Step 7: Implement plist generation**

Use `PropertyListSerialization` or `PropertyListEncoder`, never string
templates. Include the exact model parameters from the design, stdout/stderr
paths, `RunAtLoad`, `KeepAlive`, and `ProcessType=Interactive`.

- [ ] **Step 8: Implement runtime staging**

Run `/usr/bin/tar -xzf <archive> -C <staging>` with a deployment command runner
whose timeout is 60 seconds. Require the extracted root to equal the manifest
directory name and reject resolved paths outside staging. Validate:

```bash
file <staging>/llama-b10159/llama-server
<staging>/llama-b10159/llama-server --version
```

In Swift, inspect `file` output for `arm64` and require version command exit
code `0`.

- [ ] **Step 9: Run tests and commit**

```bash
swift test --filter 'RuntimeInstallerTests|LaunchAgentInstallerTests|LANAddressProviderTests'
git add Sources/QwythosDeployment Tests/QwythosDeploymentTests
git commit -m "feat: install runtime and launch agent"
```

---

### Task 5: Installation Records, Inspection, and Legacy Migration

**Files:**
- Create: `Sources/QwythosDeployment/InstallationRecord.swift`
- Create: `Sources/QwythosDeployment/InstallationInspector.swift`
- Create: `Sources/QwythosDeployment/LegacyInstallationMigrator.swift`
- Create: `Tests/QwythosDeploymentTests/InstallationInspectorTests.swift`
- Create: `Tests/QwythosDeploymentTests/LegacyInstallationMigratorTests.swift`

**Interfaces:**
- Produces: `InstallationRecordStore`, `InstallationStatus`,
  `InstallationInspector`, `LegacyModelLocating`, `ModelReusing`, and
  `LegacyInstallationMigrator`.
- Consumed by: coordinator, menu integration, migration, repair, and uninstall.

- [ ] **Step 1: Write failing inspector classification tests**

Cover:

```swift
let emptyStatus = await inspector.inspect()
let partialStatus = await inspectorWithPartial.inspect()
let legacyStatus = await inspectorWithLegacyPlist.inspect()
let missingVolumeStatus = await inspectorWithMissingVolume.inspect()
let healthyStatus = await inspectorWithHealthyRecord.inspect()
let damagedStatus = await inspectorWithBadRuntime.inspect()

XCTAssertEqual(emptyStatus, .notInstalled)
XCTAssertEqual(partialStatus, .partiallyDownloaded)
XCTAssertEqual(legacyStatus, .legacyDetected)
XCTAssertEqual(missingVolumeStatus, .installationRootUnavailable(externalRoot))
XCTAssertEqual(healthyStatus, .managedHealthy(record))
XCTAssertEqual(
    damagedStatus,
    .managedRepairable(record, [.runtime])
)
```

- [ ] **Step 2: Write failing model reuse tests**

Create a fake Hugging Face cache blob named by the expected SHA-256. Verify the
migrator selects it, reuses it at `layout.modelFile`, verifies the result, and
does not delete the source. Add a mismatch test that chooses download instead.

- [ ] **Step 3: Verify tests fail**

```bash
swift test --filter 'InstallationInspectorTests|LegacyInstallationMigratorTests'
```

- [ ] **Step 4: Define the durable installation record**

```swift
public struct InstallationRecord: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let manifestSchemaVersion: Int
    public let root: URL
    public let runtimeVersion: String
    public let modelSHA256: String
    public let contextSize: Int
    public let accessMode: NetworkAccessMode
    public let installedAt: Date
}
```

`InstallationRecordStore` reads and atomically replaces the selected layout's
`deployment.json`.

- [ ] **Step 5: Implement status inspection**

```swift
public enum RepairComponent: Hashable, Sendable {
    case runtime
    case model
    case configuration
    case launchAgent
}

public enum InstallationStatus: Equatable, Sendable {
    case notInstalled
    case partiallyDownloaded
    case legacyDetected
    case installationRootUnavailable(URL)
    case managedHealthy(InstallationRecord)
    case managedRepairable(InstallationRecord, Set<RepairComponent>)
    case managedIncompatible(String)
}
```

Define the coordinator-facing protocols in the same files:

```swift
public protocol InstallationRecordStoring: Sendable {
    func load(layout: InstallationLayout) throws -> InstallationRecord?
    func save(_ record: InstallationRecord, layout: InstallationLayout) throws
    func remove(layout: InstallationLayout) throws
}

public protocol InstallationInspecting: Sendable {
    func inspect() async -> InstallationStatus
}

public protocol LegacyMigrating: Sendable {
    func migrate(options: DeploymentOptions) async throws
}
```

Recognize a legacy installation only when the plist label is
`com.local.qwythos-9b` and its program or arguments reference
`llama-server`. Do not adopt an arbitrary plist that merely uses port `18080`.

- [ ] **Step 6: Implement safe model reuse**

Search:

- the current `LLAMA_CACHE` from a recognized legacy plist
- `~/Library/Caches/llama.cpp`
- `~/.cache/llama.cpp`

Check the digest-named blob path first. Validate SHA-256 before reuse. Attempt
`clonefile`, then a hard link on the same volume, then `copyItem`. Validate the
managed result after every strategy.

- [ ] **Step 7: Implement migration rollback**

Back up the plist, stop the recognized legacy service, install the managed
runtime/configuration, and start/health-check it. On any failure, restore the
old plist and bootstrap the old service. Never remove Homebrew or the old cache.

- [ ] **Step 8: Run tests and commit**

```bash
swift test --filter 'InstallationInspectorTests|LegacyInstallationMigratorTests'
git add Sources/QwythosDeployment Tests/QwythosDeploymentTests
git commit -m "feat: inspect and migrate existing installs"
```

---

### Task 6: Deployment State Machine, Repair, and Uninstall

**Files:**
- Create: `Sources/QwythosDeployment/DeploymentCoordinator.swift`
- Create: `Tests/QwythosDeploymentTests/DeploymentCoordinatorTests.swift`
- Modify: `Tests/QwythosDeploymentTests/Support/TestDoubles.swift`

**Interfaces:**
- Produces: the complete `DeploymentCoordinator` public API and
  `DeploymentSnapshot` stream.
- Consumed by: wizard model and menu integration.

- [ ] **Step 1: Define failing state-sequence tests**

```swift
func testCleanDeploymentPublishesOrderedPhasesAndRecordsOnlyAfterHealth() async throws {
    let fixture = CoordinatorFixture()
    let snapshots = await fixture.captureSnapshots {
        try await fixture.coordinator.deploy(options: fixture.options)
    }

    XCTAssertEqual(
        snapshots.map(\.phase),
        [
            .preflighting,
            .downloadingRuntime,
            .verifyingRuntime,
            .installingRuntime,
            .downloadingModel,
            .verifyingModel,
            .writingConfiguration,
            .startingService,
            .checkingHealth,
            .installed
        ]
    )
    XCTAssertEqual(fixture.events.values.filter { $0 == .recordSaved }.count, 1)
    XCTAssertLessThan(
        try XCTUnwrap(fixture.events.values.firstIndex(of: .healthSucceeded)),
        try XCTUnwrap(fixture.events.values.firstIndex(of: .recordSaved))
    )
}
```

Add these exact shared test types to `Support/TestDoubles.swift`:

```swift
enum CoordinatorEvent: Equatable {
    case healthSucceeded
    case recordSaved
}

final class LockedCoordinatorEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CoordinatorEvent] = []

    var values: [CoordinatorEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ event: CoordinatorEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

struct CoordinatorFixture {
    let events: LockedCoordinatorEvents
    let options: DeploymentOptions
    let coordinator: DeploymentCoordinator

    init(
        healthResults: [Bool] = [true],
        damaged: Set<RepairComponent> = []
    ) {
        let events = LockedCoordinatorEvents()
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        let recordStore = FakeInstallationRecordStore(events: events)
        let healthChecker = SequenceHealthChecker(
            results: healthResults,
            events: events
        )

        self.events = events
        self.options = DeploymentOptions(
            root: root,
            contextSize: 8_192,
            accessMode: .local
        )
        self.coordinator = DeploymentCoordinator(
            manifest: .fixture,
            locator: FakeInstallationLocator(root: root),
            preflight: .passingFixture,
            downloader: FakeArtifactDownloader(),
            hasher: FakeFileHasher(),
            runtimeInstaller: FakeRuntimeInstaller(),
            launchAgentInstaller: FakeLaunchAgentInstaller(),
            inspector: FakeInstallationInspector(damaged: damaged),
            migrator: FakeLegacyMigrator(),
            recordStore: recordStore,
            service: FakeManagedService(),
            healthChecker: healthChecker
        )
    }

    func captureSnapshots(
        operation: @escaping @Sendable () async throws -> Void
    ) async rethrows -> [DeploymentSnapshot]
}
```

Add the named fake types, `DeploymentManifest.fixture`, and
`DeploymentPreflight.passingFixture` to `TestDoubles.swift`. Each fake conforms
to its production protocol, uses only the fixture root, and records calls in
locked storage; none may touch the real LaunchAgent or network.

Add tests for:

- second operation rejected while busy
- pause preserves partial downloads
- health timeout removes no model and writes no installed record
- runtime reinstall rolls back on failed health
- an older installed runtime is upgraded to the bundled pinned version with
  the same rollback guarantees
- repair downloads only damaged components
- uninstall preserves the model by default
- uninstall deletes the model only when `deleteModel` is true
- access-mode change rewrites configuration and restarts service

- [ ] **Step 2: Verify tests fail**

```bash
swift test --filter DeploymentCoordinatorTests
```

- [ ] **Step 3: Define state and snapshot types**

```swift
public enum DeploymentPhase: String, Codable, Sendable {
    case idle
    case preflighting
    case ready
    case downloadingRuntime
    case verifyingRuntime
    case installingRuntime
    case downloadingModel
    case verifyingModel
    case writingConfiguration
    case startingService
    case checkingHealth
    case installed
    case paused
    case repairing
    case uninstalling
    case failed
}

public struct DeploymentSnapshot: Equatable, Sendable {
    public let phase: DeploymentPhase
    public let component: RepairComponent?
    public let completedBytes: Int64?
    public let totalBytes: Int64?
    public let overallProgress: Double?
    public let statusText: String
    public let failure: DeploymentFailure?
}
```

- [ ] **Step 4: Implement the public coordinator API**

```swift
public protocol DeploymentCoordinating: Sendable {
    func snapshots() async -> AsyncStream<DeploymentSnapshot>
    func inspect() async -> InstallationStatus
    func deploy(options: DeploymentOptions) async throws
    func migrate(options: DeploymentOptions) async throws
    func pause() async
    func repair() async throws
    func reinstallRuntime() async throws
    func setAccessMode(_ mode: NetworkAccessMode) async throws
    func regenerateAPIKey() async throws -> String
    func uninstall(deleteModel: Bool) async throws
}

public actor DeploymentCoordinator: DeploymentCoordinating {
    public init(
        manifest: DeploymentManifest,
        locator: any InstallationLocating,
        preflight: DeploymentPreflight,
        downloader: any ArtifactDownloading,
        hasher: any FileHashing,
        runtimeInstaller: any RuntimeInstalling,
        launchAgentInstaller: any LaunchAgentInstalling,
        inspector: any InstallationInspecting,
        migrator: any LegacyMigrating,
        recordStore: any InstallationRecordStoring,
        service: any ManagedServiceControlling,
        healthChecker: any HealthChecking
    )

    public func snapshots() async -> AsyncStream<DeploymentSnapshot>
    public func inspect() async -> InstallationStatus
    public func deploy(options: DeploymentOptions) async throws
    public func migrate(options: DeploymentOptions) async throws
    public func pause() async
    public func repair() async throws
    public func reinstallRuntime() async throws
    public func setAccessMode(_ mode: NetworkAccessMode) async throws
    public func regenerateAPIKey() async throws -> String
    public func uninstall(deleteModel: Bool) async throws
}
```

Define `ManagedServiceControlling` in this task:

```swift
public protocol ManagedServiceControlling: Sendable {
    func start() async throws
    func stop() async throws
}
```

Use one operation token and a `defer` cleanup to prevent concurrent mutation.
Health polling uses the existing `HealthChecking` protocol every second for at
most 90 seconds. `deploy(options:)` creates
`InstallationLayout(root: options.root)` and saves the locator before the first
download so a relaunch can resume. `inspect()` and management operations load
the root through the locator. Successful uninstall removes the locator last;
failed uninstall preserves it.

- [ ] **Step 5: Implement atomic completion and recovery**

Save `InstallationRecord` only after successful health. On runtime switch
failure, restore the old `runtime/current` link, rewrite the old plist if
needed, and restart the prior service. Never remove the verified model in a
runtime error path.

- [ ] **Step 6: Implement repair and uninstall scope**

Repair consumes the exact `Set<RepairComponent>` from inspection. Uninstall
calls `InstallationLayout.requireManaged` for every deletion and never deletes
the selected root itself.

- [ ] **Step 7: Run tests and commit**

```bash
swift test --filter DeploymentCoordinatorTests
git add Sources/QwythosDeployment/DeploymentCoordinator.swift \
  Sources/QwythosDeployment/DeploymentModels.swift \
  Tests/QwythosDeploymentTests
git commit -m "feat: orchestrate deployment lifecycle"
```

---

### Task 7: Wizard Presentation Model and Native Multi-Step UI

**Files:**
- Create: `Sources/QwythosControlApp/DeploymentWizardModel.swift`
- Create: `Sources/QwythosControlApp/DeploymentWizardWindowController.swift`
- Create: `Sources/QwythosControlApp/Views/DeploymentWizardView.swift`
- Create: `Sources/QwythosControlApp/Views/DeviceCheckStepView.swift`
- Create: `Sources/QwythosControlApp/Views/ConfigurationStepView.swift`
- Create: `Sources/QwythosControlApp/Views/ReviewStepView.swift`
- Create: `Sources/QwythosControlApp/Views/ProgressStepView.swift`
- Create: `Sources/QwythosControlApp/Views/CompletionStepView.swift`
- Create: `Sources/QwythosControlApp/Views/ManagementView.swift`
- Modify: `Package.swift`
- Create: `Tests/QwythosControlAppTests/DeploymentWizardLayoutTests.swift`
- Create: `Tests/QwythosControlAppTests/DeploymentWizardModelTests.swift`

**Interfaces:**
- Produces: `DeploymentWizardModel` and `DeploymentWizardWindowController`.
- Consumed by: `AppDelegate`.

- [ ] **Step 1: Write failing wizard model tests**

Add a test target:

```swift
.testTarget(
    name: "QwythosControlAppTests",
    dependencies: ["QwythosControlApp", "QwythosDeployment"]
)
```

Test:

```swift
func testWizardCannotAdvanceUntilPreflightPasses() async {
    let model = DeploymentWizardModel(coordinator: failingCoordinator)
    await model.start()

    XCTAssertEqual(model.step, .deviceCheck)
    XCTAssertFalse(model.canContinue)
}

func testHealthyInstallOpensManagementInsteadOfDeployFlow() async {
    let model = DeploymentWizardModel(coordinator: installedCoordinator)
    await model.start()

    XCTAssertEqual(model.step, .management)
}
```

Also verify automatic context selection, custom storage selection, local/shared
mode, deployment progress rendering, delete-model confirmation, and pause on
quit.

- [ ] **Step 2: Verify tests fail**

```bash
swift test --filter DeploymentWizardModelTests
```

- [ ] **Step 3: Implement the main-actor model**

```swift
@MainActor
final class DeploymentWizardModel: ObservableObject {
    enum Step: Equatable {
        case deviceCheck
        case configuration
        case review
        case progress
        case completion
        case management
    }

    @Published private(set) var step: Step = .deviceCheck
    @Published private(set) var snapshot: DeploymentSnapshot
    @Published var selectedRoot: URL
    @Published var contextSize: Int
    @Published var accessMode: NetworkAccessMode = .local
    @Published var deleteModelOnUninstall = false

    init(coordinator: any DeploymentCoordinating)

    func start() async
    func continueToNextStep()
    func deploy() async
    func migrate() async
    func retry() async
    func repair() async
    func reinstallRuntime() async
    func uninstall() async
}
```

Expose command-specific booleans such as `canContinue`, `canDeploy`, and
`isBusy`; views do not derive state-machine rules independently.

- [ ] **Step 4: Build the wizard shell**

Use an `NSWindow` sized `640 x 560`, an `NSHostingController`, and a stable
toolbar-free layout. The primary screen is the actual wizard, not explanatory
marketing.

Use:

- checkmarks and warning icons for preflight
- `NSOpenPanel` for folder selection
- segmented control for 4K/8K/16K context
- toggle for LAN sharing
- determinate progress bars for downloads
- indeterminate progress for service startup
- destructive confirmation sheet for uninstall
- icon buttons with tooltips for copy/reveal/regenerate API key

- [ ] **Step 5: Implement every state view**

Each view consumes the model only. Keep display text inside the available
window width and support light/dark appearance. LAN mode must show the API-key
and public Wi-Fi warning before review; completion shows the LAN URL only after
successful health. Management shows `Update Runtime` when the installed record
is older than the bundled manifest and `Reinstall Runtime` when versions match.
Runtime updates arrive through a newer signed app manifest; the app never
installs an unlisted GitHub `latest` release.

- [ ] **Step 6: Run tests and perform visual checks**

```bash
swift test --filter DeploymentWizardModelTests
swift build
```

Add `DeploymentWizardModel.preview(step:)` under `#if DEBUG`. In
`DeploymentWizardLayoutTests`, mount each step in an `NSHostingController`,
set the view frame to `640 x 560`, call `layoutSubtreeIfNeeded()`, render with
`bitmapImageRepForCachingDisplay(in:)`, and attach the PNG to the XCTest result.
Inspect device check, configuration, progress, failure, completion, and
management attachments in light and dark appearance. Assert the rendered image
is `640 x 560` and that every primary button frame is contained by the root
view bounds.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/QwythosControlApp Tests/QwythosControlAppTests
git commit -m "feat: add Qwythos deployment wizard"
```

---

### Task 8: Menu Integration, Resource Packaging, and Existing Controls

**Files:**
- Modify: `Sources/QwythosControlApp/main.swift`
- Create: `Sources/QwythosControlApp/AppDelegate.swift`
- Modify: `scripts/build-app.sh`
- Modify: `Tests/QwythosCoreTests/LiveServiceControllerTests.swift`
- Create: `Tests/QwythosControlAppTests/AppIntegrationTests.swift`

**Interfaces:**
- Consumes: `DeploymentCoordinator`, `DeploymentWizardWindowController`, and
  `InstallationStatus`.
- Produces: the final app entry points and packaged manifest resource.

- [ ] **Step 1: Add failing integration assertions**

Test that:

- no managed or legacy installation shows `Deploy Qwythos...`
- a legacy installation shows `Migrate Existing Installation...`
- a managed installation shows `Manage Installation...`
- a missing plist no longer produces a terminal failed state when deployment
  is available
- completing deployment refreshes the existing service controller

- [ ] **Step 2: Verify integration tests fail**

```bash
swift test --filter AppIntegrationTests
```

- [ ] **Step 3: Split the app entry point**

Leave `main.swift` with only:

```swift
import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
```

Move the delegate implementation into `AppDelegate.swift`.

- [ ] **Step 4: Add the deployment menu item**

Insert one menu item below the status row. Its action opens the single retained
wizard window. Refresh its title from `InstallationStatus` after launch,
deployment completion, repair, migration, and uninstall.

Keep the existing model toggle, Open Chat, logs, notifications, and polling.
When no plist exists, disable the toggle and render `Status: Not Installed`
rather than a failure.

- [ ] **Step 5: Resolve dynamic managed paths**

Routine service control keeps the fixed label, plist path, loopback health URL,
and chat URL. `View Logs` reads the current `InstallationRecord.root` each time
and falls back to the legacy logs directory when no managed record exists.

- [ ] **Step 6: Package the SwiftPM resource bundle**

After `swift build -c release`, require and copy:

```zsh
DEPLOYMENT_BUNDLE="$ROOT/.build/release/QwythosControl_QwythosDeployment.bundle"
test -d "$DEPLOYMENT_BUNDLE"
ditto "$DEPLOYMENT_BUNDLE" \
    "$APP/Contents/Resources/QwythosControl_QwythosDeployment.bundle"
```

Then sign the complete app as the existing script does.

- [ ] **Step 7: Verify package contents**

```bash
scripts/build-app.sh
test -f \
  "build/Qwythos Control.app/Contents/Resources/QwythosControl_QwythosDeployment.bundle/deployment-manifest.json"
codesign --verify --deep --strict "build/Qwythos Control.app"
```

- [ ] **Step 8: Run tests and commit**

```bash
swift test
git add Sources/QwythosControlApp scripts/build-app.sh \
  Tests/QwythosCoreTests Tests/QwythosControlAppTests
git commit -m "feat: integrate deployment into control center"
```

---

### Task 9: End-to-End Fixture, Security Verification, and Documentation

**Files:**
- Create: `Tests/QwythosDeploymentTests/DeploymentEndToEndTests.swift`
- Create: `docs/deployment.md`
- Modify: `README.md` if present; otherwise create `README.md`

**Interfaces:**
- Consumes: the complete deployed feature.
- Produces: final automated acceptance coverage and user-facing deployment
  documentation.

- [ ] **Step 1: Add the end-to-end fixture**

Use:

- a temporary installation root
- `RangeHTTPServer`
- a tiny tar archive with an executable fake `llama-server`
- a small fake GGUF payload
- a temporary LaunchAgents directory injected into the installer
- a fake health checker that becomes healthy after startup

The test runs clean deploy, access-mode switch, repair, runtime reinstall, and
uninstall without touching the real user service.

- [ ] **Step 2: Assert security boundaries**

Verify:

```swift
XCTAssertEqual(apiKeyPermissions, 0o600)
XCTAssertFalse(localArguments.contains("--api-key-file"))
XCTAssertTrue(sharedArguments.contains("--api-key-file"))
XCTAssertFalse(sharedArguments.contains("0.0.0.0") && apiKeyFile == nil)
XCTAssertTrue(allDeletedURLs.allSatisfy(layout.isManaged))
```

Also assert no command invokes `sudo`, `brew`, `/bin/sh -c`, or a downloaded
script.

- [ ] **Step 3: Run the full automated suite**

```bash
swift test
```

Expected: all unit and integration tests pass; the existing live service test
remains skipped unless `QWYTHOS_LIVE_INTEGRATION=1`.

- [ ] **Step 4: Build and validate the release app**

```bash
scripts/generate-iconset.sh
scripts/build-app.sh
plutil -lint "build/Qwythos Control.app/Contents/Info.plist"
codesign --verify --deep --strict "build/Qwythos Control.app"
```

- [ ] **Step 5: Document the feature**

Document:

- supported hardware and memory
- default storage and custom-volume behavior
- expected download size
- deployment, migration, repair, reinstall, and uninstall
- local-only and authenticated LAN modes
- API key use with `Authorization: Bearer <key>`
- recovery after interruption
- log locations

- [ ] **Step 6: Perform manual acceptance on this Mac**

Use the wizard to detect the current Homebrew-based legacy service. Confirm it
offers migration, reuses the digest-matched cache blob, installs the managed
runtime, preserves the old plist backup, starts healthy, and leaves Homebrew
untouched.

From another LAN device, verify unauthenticated requests fail and a request
with the generated bearer key succeeds. Switch back to local-only and verify
the LAN endpoint is no longer reachable.

- [ ] **Step 7: Commit**

```bash
git add Tests/QwythosDeploymentTests README.md docs/deployment.md
git commit -m "test: verify one-click deployment lifecycle"
```

---

## Final Verification

Run from a clean worktree:

```bash
swift test
scripts/generate-iconset.sh
scripts/build-app.sh
test -f \
  "build/Qwythos Control.app/Contents/Resources/QwythosControl_QwythosDeployment.bundle/deployment-manifest.json"
codesign --verify --deep --strict "build/Qwythos Control.app"
git diff --check
git status --short
```

Expected:

- all automated tests pass
- the release app builds and signs
- the deployment manifest is packaged
- no uncommitted source changes remain
- the real model service is unchanged until the user explicitly approves the
  manual migration acceptance step
