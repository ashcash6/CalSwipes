import ARKit
import AuthenticationServices
import AVFoundation
import SwiftUI

@main
struct BerkeleyPlateApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase
    private let support = DeviceSupport.current

    var body: some Scene {
        WindowGroup {
            Group {
                if !support.canOpenShell {
                    ContentUnavailableView("Device not supported", systemImage: "iphone.slash",
                        description: Text("Berkeley Plate requires an iPhone with LiDAR or at least two rear cameras. This iPhone does not meet that requirement."))
                } else if store.isRestoring {
                    ProgressView("Opening Berkeley Plate…")
                } else if store.session == nil {
                    WelcomeView(store: store)
                } else {
                    MenuScreen(store: store, simulator: support.isSimulator)
                }
            }
            .tint(PlateStyle.green)
            .task {
                if support.canOpenShell { await store.restore() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, !store.isRestoring, support.canOpenShell {
                    Task { await store.foreground() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
                Task { await store.checkCredential() }
            }
        }
    }
}

struct DeviceSupport {
    let canOpenShell: Bool
    let isSimulator: Bool
    static var current: DeviceSupport {
        #if targetEnvironment(simulator)
        // Simulator can exercise the shell, but cannot validate the camera/depth pipeline.
        return DeviceSupport(canOpenShell: true, isSimulator: true)
        #else
        let cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera,
            .builtInUltraWideCamera, .builtInTelephotoCamera], mediaType: .video, position: .back).devices
        let lidar = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        return DeviceSupport(canOpenShell: UIDevice.current.userInterfaceIdiom == .phone && (lidar || cameras.count >= 2), isSimulator: false)
        #endif
    }
}
