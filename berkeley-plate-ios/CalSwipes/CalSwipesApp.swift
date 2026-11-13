import ARKit
import AVFoundation
import BackgroundTasks
import SwiftUI
import os

private let appLifecycleLog = Logger(subsystem: "CalSwipes", category: "Lifecycle")
private let prefetchLog     = Logger(subsystem: "CalSwipes", category: "MenuPrefetch")

private let menuPrefetchTaskId: String =
    (Bundle.main.bundleIdentifier ?? "calswipes") + ".menu-prefetch"
private let preloadDateKey = "calswipes.preloadDate"

@main
struct CalSwipesApp: App {
    init() {
        // Make all scroll views pass touches to buttons immediately instead of waiting
        // ~300ms to decide if the gesture will become a scroll.
        UIScrollView.appearance().delaysContentTouches = false
    }

    @State private var store = AppStore()
    @State private var daily = DailyStore()
    @State private var planStore = PlanStore()
    @State private var preloadDone: Bool = {
        UserDefaults.standard.string(forKey: preloadDateKey) == BerkeleyClock.serviceDate()
    }()
    @Environment(\.scenePhase) private var scenePhase
    private let support = DeviceSupport.current

    var body: some Scene {
        WindowGroup {
            Group {
                if !support.canOpenShell {
                    ContentUnavailableView("Device not supported", systemImage: "iphone.slash",
                        description: Text("CalSwipes requires an iPhone with LiDAR or at least two rear cameras. This iPhone does not meet that requirement."))
                } else if !daily.hasCompletedOnboarding {
                    OnboardingScreen(store: daily)
                        .tint(PlateStyle.green)
                } else if !preloadDone {
                    PreloadingView()
                        .task {
                            // Race: complete as soon as all menus are cached OR 15 s pass.
                            // The 15-second fallback ensures users are never permanently blocked
                            // (e.g. if the server is down or the device is offline).
                            await withTaskGroup(of: Void.self) { group in
                                group.addTask { await prefetchTodayMenus() }
                                group.addTask { try? await Task.sleep(for: .seconds(15)) }
                                _ = await group.next()
                                group.cancelAll()
                            }
                            UserDefaults.standard.set(BerkeleyClock.serviceDate(), forKey: preloadDateKey)
                            preloadDone = true
                        }
                } else {
                    MainTabView(store: store, daily: daily, planStore: planStore, simulator: support.isSimulator)
                }
            }
            // Only load the menu after onboarding is complete.
            // During onboarding, the user doesn't need the menu and any background
            // network/location work causes re-renders that jank UI interactions.
            .task {
                scheduleMenuPrefetch()
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
        .backgroundTask(.appRefresh(menuPrefetchTaskId)) {
            prefetchLog.info("Background menu prefetch started")
            await prefetchTodayMenus()
            // Mark today's cache as ready so the launch gate is skipped when the user opens the app.
            UserDefaults.standard.set(BerkeleyClock.serviceDate(), forKey: preloadDateKey)
            scheduleMenuPrefetch()
            prefetchLog.info("Background menu prefetch complete")
        }
    }
}

// MARK: - Background menu prefetch

/// Schedule the next background prefetch for 5:30 AM PT (or the next occurrence if already past).
private func scheduleMenuPrefetch() {
    let cal = BerkeleyClock.calendar
    let now = Date()
    var comps = cal.dateComponents([.year, .month, .day], from: now)
    comps.hour = 5
    comps.minute = 30
    let todayTarget = cal.date(from: comps) ?? now
    let nextRun = todayTarget > now ? todayTarget
        : cal.date(byAdding: .day, value: 1, to: todayTarget) ?? now

    let request = BGAppRefreshTaskRequest(identifier: menuPrefetchTaskId)
    request.earliestBeginDate = nextRun
    try? BGTaskScheduler.shared.submit(request)
    prefetchLog.info("Next prefetch scheduled for \(nextRun)")
}

/// Fetch all dining-hall menus for today and write them to the on-device cache.
/// Runs in a detached background context — does not touch AppStore or any @MainActor state.
private func prefetchTodayMenus() async {
    let baseURL = (Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String)
        .flatMap { URL(string: $0) } ?? URL(string: "https://api.example.invalid")!
    let api = APIClient(baseURL: baseURL)
    let repo = MenuRepository(api: api)
    let date = BerkeleyClock.serviceDate()
    let halls = Hall.allCases.filter { $0.isDiningHall }
    let meals: [Meal] = [.breakfast, .lunch, .dinner]

    await withTaskGroup(of: Void.self) { group in
        for hall in halls {
            for meal in meals {
                group.addTask {
                    let key = MenuKey(hall: hall, date: date, meal: meal)
                    if let result = try? await repo.load(key) {
                        prefetchLog.info("Prefetched \(hall.rawValue)/\(meal.rawValue) — offline=\(result.isOffline)")
                    }
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

    // Tabs: 0 Today · 1 Menu · 2 Log (intercepted, opens a sheet) · 3 Plan · 4 Profile
    private enum Tab: Int { case today = 0, menu = 1, log = 2, plan = 3, profile = 4 }
    @State private var selectedTab = Tab.today.rawValue
    @State private var lastRealTab = Tab.today.rawValue
    @AppStorage("appearancePref") private var appearancePref = "system"
    @AppStorage("seenLogHint.v1") private var seenLogHint = false
    @State private var subscription = SubscriptionStore()
    @State private var assistant: AssistantRouter?

    // Log flow
    @State private var showLogSheet = false
    @State private var pendingRoute: LogRoute?
    @State private var coverRoute: LogRoute?      // tray camera, label scan
    @State private var sheetRoute: LogRoute?      // manual entry, AI chat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var preferredColorScheme: ColorScheme? {
        switch appearancePref {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    /// Room for the raised Log button so the last row of every list scrolls fully above it.
    private func bottomRoom<V: View>(_ v: V) -> some View {
        v.safeAreaInset(edge: .bottom) { Color.clear.frame(height: CP.sp24) }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            bottomRoom(DashboardScreen(store: store, daily: daily))
                .tag(Tab.today.rawValue)
                .tabItem { Label("Today", systemImage: "sun.max") }
            bottomRoom(MenuScreen(store: store, daily: daily, simulator: simulator))
                .tag(Tab.menu.rawValue)
                .tabItem { Label("Menu", systemImage: "fork.knife") }
            Color.clear
                .tag(Tab.log.rawValue)
                .tabItem { Text("Log") }
                .accessibilityLabel("Log a meal")
            bottomRoom(PlanMyDayScreen(planStore: planStore, store: store, daily: daily))
                .tag(Tab.plan.rawValue)
                .tabItem { Label("Plan", systemImage: "calendar") }
            bottomRoom(ProfileScreen(daily: daily, store: store))
                .tag(Tab.profile.rawValue)
                .tabItem { Label("Profile", systemImage: "person.circle") }
                .badge(weightDueToday ? "New" : nil)
        }
        .tint(CP.accent)
        .preferredColorScheme(preferredColorScheme)
        .toolbarBackground(reduceTransparency ? AnyShapeStyle(CP.surface1) : AnyShapeStyle(.regularMaterial), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onChange(of: selectedTab) { old, new in
            if new == Tab.log.rawValue {
                selectedTab = lastRealTab        // the Log tab never stays selected
                openLog()
            } else {
                lastRealTab = new
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: CP.sp8) {
                if !seenLogHint {
                    LogHintBubble { seenLogHint = true }
                }
                RaisedLogButton { openLog() }
            }
            .padding(.bottom, CP.sp24)   // raised about 20pt above the bar's icon row
        }
        .environment(assistant)
        .environment(subscription)
        .sheet(isPresented: $showLogSheet, onDismiss: {
            guard let route = pendingRoute else { return }
            pendingRoute = nil
            switch route {
            case .tray, .label: coverRoute = route
            case .manual, .ai:  sheetRoute = route
            }
        }) {
            LogSheet(assistantAvailable: assistant != nil) { pendingRoute = $0 }
                .presentationDetents([.medium])
        }
        .fullScreenCover(item: $coverRoute) { route in
            switch route {
            case .tray:
                TrayCameraPicker { jpeg in
                    guard let assistant else { return }
                    assistant.open(with: .none)
                    sheetRoute = .ai
                    Task { await assistant.scan(jpeg: jpeg) }
                }
                .ignoresSafeArea()
            default:
                NutritionLabelScanScreen { name, macros in
                    daily.logManualMeal(name: name, macros: macros)
                    Haptics.logged()
                }
            }
        }
        .sheet(item: $sheetRoute) { route in
            switch route {
            case .manual:
                ManualMealEntryScreen(store: daily)
            default:
                if let assistant {
                    AssistantChatView(router: assistant, subscription: subscription)
                        .presentationDetents([.medium, .large])
                }
            }
        }
        .task {
            if assistant == nil {
                assistant = AssistantRouter(store: store, daily: daily, subscription: subscription)
            }
            await subscription.load()
        }
    }

    private var weightDueToday: Bool {
        !daily.weightEntries.contains { $0.date == BerkeleyClock.serviceDate() }
    }

    private func openLog() {
        seenLogHint = true
        assistant?.open(with: .none)
        showLogSheet = true
    }
}

private struct PreloadingView: View {
    var body: some View {
        VStack(spacing: CP.sp20) {
            Spacer()
            Text("CalSwipes")
                .font(.system(.largeTitle, design: .serif, weight: .semibold))
                .foregroundStyle(CP.navy)
            ProgressView()
                .padding(.top, CP.sp8)
            Text("Loading today's menus…")
                .font(.subheadline)
                .foregroundStyle(CP.textSec)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CP.bg)
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
