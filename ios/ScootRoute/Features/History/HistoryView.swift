import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \TripRecord.date, order: .reverse) private var trips: [TripRecord]
    @Environment(\.modelContext) private var context

    var body: some View {
        NavigationStack {
            List {
                if !trips.isEmpty {
                    Section("Total") {
                        LabeledContent("Trajets", value: "\(trips.count)")
                        LabeledContent("Distance", value: Fmt.distance(trips.reduce(0) { $0 + $1.traveledDistanceM }))
                        LabeledContent("Dénivelé positif", value: Fmt.meters(trips.reduce(0) { $0 + $1.ascentM }))
                        LabeledContent("Énergie estimée", value: "\(Int(trips.reduce(0) { $0 + $1.estimatedWh }.rounded())) Wh")
                    }
                }
                Section {
                    if trips.isEmpty {
                        ContentUnavailableView("Aucun trajet", systemImage: "scooter",
                                               description: Text("Vos trajets apparaîtront ici après une navigation."))
                    }
                    ForEach(trips) { trip in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(trip.toTitle).font(.headline).lineLimit(1)
                                Spacer()
                                Text(trip.date, format: .dateTime.day().month().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(trip.profileLabel) · depuis \(trip.fromTitle)").font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 12) {
                                Label(Fmt.distance(trip.traveledDistanceM > 0 ? trip.traveledDistanceM : trip.plannedDistanceM), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                                Label(Fmt.duration(trip.actualDurationS), systemImage: "timer")
                                Label(Fmt.meters(trip.ascentM), systemImage: "arrow.up.right")
                                Label("\(Int(trip.estimatedWh.rounded())) Wh", systemImage: "bolt")
                            }
                            .font(.caption)
                            if let s = trip.batteryStartPercent, let e = trip.batteryEndPercent {
                                Text("Batterie réelle : \(Int(s)) % → \(Int(e)) %").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { idx in
                        idx.map { trips[$0] }.forEach { context.delete($0) }
                        try? context.save()
                    }
                }
            }
            .navigationTitle("Historique")
        }
    }
}
