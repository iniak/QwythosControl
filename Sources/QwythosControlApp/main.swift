import AppKit
import Darwin
import QwythosDeployment

if CommandLine.arguments.dropFirst() == ["--verify-deployment-resources"] {
    do {
        let manifest = try DeploymentManifest.load(
            data: DeploymentManifest.productionData()
        )
        print(manifest.runtime.version)
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(
            Data("Deployment resources are unavailable.\n".utf8)
        )
        exit(EXIT_FAILURE)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
