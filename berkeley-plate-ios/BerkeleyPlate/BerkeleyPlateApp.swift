import ARKit
import AVFoundation
import SwiftUI
import os

private let appLifecycleLog = Logger(subsystem: "BerkeleyPlate", category: "Lifecycle")

@main
struct BerkeleyPlateApp: App {
    @State private var store = AppStore()
    @State private var daily = DailyStore()
    @State private var planStore = PlanStore()
    @Environment(\.scenePhase) private var scenePhase
    private let support = DeviceSupport.current

    var body: some Scene {
        WindowGroup {
            Group {
                if !support.canOpenShell {
                    ContentUnavailableView("Device not supported", systemImage: "iphone.slash",
                        description: Text("Berkeley Plate requires an iPhone with LiDAR or at least two rear cameras. This iPhone does not meet that requirement."))
                } else if !daily.hasCompletedOnboarding {
                    OnboardingScreen(store: daily)
                        .tint(PlateStyle.green)
                } else {
                    MainTabView(store: store, daily: daily, planStore: planStore, simulator: support.isSimulator)
                }
            }
            // Only load the menu after onboarding is complete.
            // During onboarding, the user doesn't need the menu and any background
            // network/location work causes re-renders that jank UI interactions.
            .task {
                if daily.hasCompletedOnboarding, support.canOpenShell {
                    await store.foreground()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                appLifecycleLog.info("scenePhase → \(String(describing: phase)) at \(Date().timeIntervalSinceReferenceDate, format: .fixed(precision: 3))")
                if phase == .active, support.canOpenShell, daily.hasCompletedOnboarding {
                    Task { await store.foreground() }
                }
            }
            // Trigger the first foreground() call the moment onboarding finishes.
            .onChange(of: daily.hasCompletedOnboarding) { _, completed in
                if completed, support.canOpenShell {
                    Task { await store.foreground() }
                }
            }
        }
    }
}

struct MainTabView: View {
    var store: AppStore
    var daily: DailyStore
    var planStore: PlanStore
    let simulator: Bool
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardScreen(store: store, daily: daily)
                .tag(0)
                .tabItem { Label("Today", systemImage: "sun.max.fill") }
            MenuScreen(store: store, daily: daily, simulator: simulator)
                .tag(1)
                .tabItem { Label("Menu", systemImage: "fork.knife") }
            PlanMyDayScreen(planStore: planStore, store: store, daily: daily)
                .tag(2)
                .tabItem { Label("Plan", systemImage: "calendar.badge.plus") }
            ProfileScreen(daily: daily, store: store)
                .tag(3)
                .tabItem { Label("Profile", systemImage: "person.circle") }
        }
        .tint(CP.navy)
        .toolbarBackground(.regularMaterial, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .simultaneousGesture(
            DragGesture(minimumDistance: 50)
                .onEnded { value in
                    let h = value.translation.width
                    let v = value.translation.height
                    guard abs(h) > abs(v) * 1.5 else { return }
                    withAnimation {
                        if h < -50 { selectedTab = min(3, selectedTab + 1) }
                        else if h > 50 { selectedTab = max(0, selectedTab - 1) }
                    }
                }
        )
    }
}

struct DeviceSupport {
    let canOpenShell: Bool
    let isSimulator: Bool
    static var current: DeviceSupport {
        #if targetEnvironment(simulator)
        return DeviceSupport(canOpenShell: true, isSimulator: true)
        #else
        let cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera,
            .builtInUltraWideCamera, .builtInTelephotoCamera], mediaType: .video, position: .back).devices
        let lidar = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        return DeviceSupport(canOpenShell: UIDevice.current.userInterfaceIdiom == .phone && (lidar || cameras.count >= 2), isSimulator: false)
        #endif
    }
}
