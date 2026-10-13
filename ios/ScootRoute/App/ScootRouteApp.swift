import SwiftUI
import SwiftData

@main
struct ScootRouteApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.route)
                .onAppear { model.location.start() }
                .task { await model.loadServerMeta() }
                .onOpenURL { url in
                    // scootroute://go?q=<adresse ou coordonnées>  ou lien Apple Plans / Google Maps
                    Task { await model.importText(url.absoluteString, into: .customer) }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.consumePendingImport() } }
                }
        }
        .modelContainer(for: TripRecord.self)
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var context

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Trajet", systemImage: "scooter") }
            HistoryView()
                .tabItem { Label("Historique", systemImage: "clock.arrow.circlepath") }
            ReportsView()
                .tabItem { Label("Signaler", systemImage: "exclamationmark.bubble") }
            ProfileView()
                .tabItem { Label("Profil", systemImage: "person.crop.circle") }
            SettingsView()
                .tabItem { Label("Réglages", systemImage: "gearshape") }
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
