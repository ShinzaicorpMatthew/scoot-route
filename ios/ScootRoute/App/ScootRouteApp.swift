import SwiftUI
import SwiftData
import UserNotifications

@main
struct ScootRouteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.route)
                .onAppear { model.location.start() }
                .task {
                    await ServerLink.refresh()   // adresse du serveur à jour après un redémarrage du PC
                    await model.loadServerMeta()
                }
                .onOpenURL { url in
                    // scootroute://go?q=<adresse ou coordonnées>  ou lien Apple Plans / Google Maps
                    Task { await model.importText(url.absoluteString, into: .customer) }
                }
                .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openOfferTab)) { _ in
                    openOfferTabIfRequested()
                }
                .onChange(of: scenePhase) { _, phase in
                    // La veille des offres ne lit pas l'écran quand Scoot Route est affiché
                    WatchStatus.setAppForeground(phase == .active)
                    if phase == .active {
                        model.reloadLastOffer()   // une offre a pu être analysée par la veille ou le raccourci
                        openOfferTabIfRequested()
                        Task {
                            await ServerLink.refresh()
                            await model.consumePendingImport()
                        }
                    }
                }
        }
        .modelContainer(for: TripRecord.self)
    }

    /// Notification d'offre touchée : on ouvre l'onglet Offre.
    private func openOfferTabIfRequested() {
        guard AppDelegate.pendingOfferTab else { return }
        AppDelegate.pendingOfferTab = false
        model.reloadLastOffer()
        model.selectedTab = .offer
    }
}

/// Reçoit les notifications de la veille des offres.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let openOfferTab = Notification.Name("scootroute.openOfferTab")
    static var pendingOfferTab = false

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.userInfo[OfferNotifier.tabKey] as? String == "offer" {
            DispatchQueue.main.async {
                AppDelegate.pendingOfferTab = true
                NotificationCenter.default.post(name: AppDelegate.openOfferTab, object: nil)
            }
        }
        completionHandler()
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            HomeView()
                .tabItem { Label("Trajet", systemImage: "scooter") }
                .tag(AppModel.Tab.route)
            OfferView()
                .tabItem { Label("Offre", systemImage: "eurosign.circle") }
                .tag(AppModel.Tab.offer)
            HistoryView()
                .tabItem { Label("Historique", systemImage: "clock.arrow.circlepath") }
                .tag(AppModel.Tab.history)
            ReportsView()
                .tabItem { Label("Signaler", systemImage: "exclamationmark.bubble") }
                .tag(AppModel.Tab.reports)
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape") }
                .tag(AppModel.Tab.settings)
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.navigation != nil },
            set: { presented in if !presented, model.navigation != nil { model.finishNavigation(context: context, batteryEndPercent: nil) } }
        )) {
            if let nav = model.navigation {
                NavigationScreen(engine: nav)
                    .environment(model)
            }
        }
    }
}

enum Theme {
    static let route = Color.blue                 // itinéraire sélectionné
    static let cycle = Color.green                // pistes et bandes cyclables
    static let difficulty = Color.orange          // pavés, non revêtu, fortes pentes
    static let restriction = Color.red            // accès incertain, chantiers
    static let alternative = Color.gray.opacity(0.55)
    static let guidance = Color(red: 0.05, green: 0.46, blue: 0.29)      // bandeau de guidage (vert GPS)
    static let guidanceDark = Color(red: 0.03, green: 0.35, blue: 0.22)

    static func color(for kind: RouteSegment.Kind) -> Color {
        switch kind {
        case .cycle: return cycle
        case .difficulty: return difficulty
        case .restriction: return restriction
        case .normal: return route
        }
    }

    static func color(for risk: BatteryEstimate.Risk) -> Color {
        switch risk {
        case .comfortable: return .green
        case .tight: return .orange
        case .insufficient: return .red
        }
    }

    static func color(forReliability level: String) -> Color {
        switch level {
        case "high": return .green
        case "medium": return .orange
        default: return .red
        }
    }
}
