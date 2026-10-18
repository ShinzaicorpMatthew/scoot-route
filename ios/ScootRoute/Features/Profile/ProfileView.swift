import SwiftUI
import PhotosUI

/// Profil trottinette et livreur (stocké uniquement sur l'iPhone).
struct ProfileView: View {
    @Environment(AppModel.self) private var model
    @State private var batteryShot: PhotosPickerItem?
    @State private var readingBattery = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    TextField("Modèle (ex. Dualtron Mini)", text: $model.vehicle.modelName)
                    HStack {
                        Text("Tension nominale")
                        Spacer()
                        TextField("ex. 52", value: $model.vehicle.nominalVoltage, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Text("V").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Capacité")
                        Spacer()
                        TextField("ex. 13", value: $model.vehicle.capacityAh, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Text("Ah").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Énergie batterie")
                        Spacer()
                        TextField("inconnue", value: $model.vehicle.batteryWh, format: .number)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Text("Wh").foregroundStyle(.secondary)
                    }
                    Picker("Mode de conduite", selection: $model.vehicle.ridingMode) {
                        ForEach(RidingMode.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Freinage régénératif", isOn: $model.vehicle.hasRegenerativeBraking)
                } header: {
                    Text("Trottinette")
                } footer: {
                    Text("Tension (V) et capacité (Ah) figurent sur l'étiquette de la batterie ou la fiche technique de votre modèle : l'énergie en Wh est calculée automatiquement (V × Ah).")
                }
                .onChange(of: model.vehicle.nominalVoltage) { _, _ in updateEnergy() }
                .onChange(of: model.vehicle.capacityAh) { _, _ in updateEnergy() }

                Section {
                    PhotosPicker(selection: $batteryShot, matching: .screenshots) {
                        Label("Lire ma batterie sur une capture de l'app de la trottinette", systemImage: "battery.75percent")
                    }
                    if readingBattery { HStack { ProgressView(); Text("Lecture…") } }
                    if let message = model.batteryMessage {
                        Text(message).font(.footnote)
                    }
                    if let date = model.vehicle.lastBatteryReadingDate {
                        Text("Dernière lecture : \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Niveau de batterie depuis l'app Dualtron")
                } footer: {
                    Text("Ouvrez l'app de votre trottinette, faites une capture de l'écran qui affiche la batterie (pourcentage ou tension), puis choisissez-la ici. Plus rapide : tapotez le dos de l'iPhone sur cet écran, le même raccourci que pour les offres enregistre le niveau.")
                }
                .onChange(of: batteryShot) { _, item in
                    guard let item else { return }
                    Task {
                        readingBattery = true
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            await model.readBatteryScreenshot(data)
                        }
                        readingBattery = false
                        batteryShot = nil
                    }
                }

                Section {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Batterie restante")
                            Spacer()
                            Text("\(Int(model.vehicle.batteryPercent)) %").monospacedDigit()
                        }
                        Slider(value: $model.vehicle.batteryPercent, in: 0...100, step: 1)
                    }
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Vitesse de croisière")
                            Spacer()
                            Text("\(Int(model.vehicle.cruiseSpeedKmh)) km/h").monospacedDigit()
                        }
                        Slider(value: $model.vehicle.cruiseSpeedKmh, in: 10...25, step: 1)
                    }
                } header: {
                    Text("Avant de partir")
                } footer: {
                    Text("La vitesse des trottinettes est limitée à 25 km/h en France.")
                }

                Section {
                    Stepper("Livreur : \(Int(model.vehicle.riderMassKg)) kg", value: $model.vehicle.riderMassKg, in: 35...150, step: 1)
                    Stepper("Trottinette : \(Int(model.vehicle.scooterMassKg)) kg", value: $model.vehicle.scooterMassKg, in: 8...40, step: 1)
                    Stepper("Chargement : \(Int(model.vehicle.cargoMassKg)) kg", value: $model.vehicle.cargoMassKg, in: 0...30, step: 1)
                } header: {
                    Text("Poids transporté (facultatif)")
                } footer: {
                    Text("Le poids total influe sur la consommation en montée.")
                }

                Section("Estimation de consommation") {
                    let flat = BatteryEstimator.estimate(distanceM: 1000, durationS: 1000 / (model.vehicle.cruiseSpeedKmh / 3.6),
                                                         ascentM: 0, descentM: 0, vehicle: model.vehicle)
                    LabeledContent("Sur le plat", value: String(format: "%.1f Wh/km", flat.energyWh))
                    let range = flat.energyWh > 0 ? model.vehicle.effectiveBatteryWh * model.vehicle.batteryPercent / 100 / flat.energyWh : 0
                    LabeledContent("Autonomie restante (plat)", value: "≈ \(Int(range)) km")
                    if model.vehicle.calibrationSamples > 0 {
                        LabeledContent("Ajustement appris", value: String(format: "× %.2f (%d trajets)", model.vehicle.calibrationFactor, model.vehicle.calibrationSamples))
                        Button("Réinitialiser l'apprentissage", role: .destructive) {
                            model.vehicle.calibrationFactor = 1
                            model.vehicle.calibrationSamples = 0
                        }
                    } else {
                        Text("Approximation théorique. Saisissez la batterie restante à la fin de vos trajets pour l'ajuster.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Profil")
        }
    }

    private func updateEnergy() {
        if let v = model.vehicle.nominalVoltage, let ah = model.vehicle.capacityAh, v > 0, ah > 0 {
            model.vehicle.batteryWh = (v * ah).rounded()
        }
    }
}
