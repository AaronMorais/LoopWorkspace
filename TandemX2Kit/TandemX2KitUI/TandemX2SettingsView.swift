import Combine
import LoopKit
import LoopKitUI
import SwiftUI

struct TandemX2SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Pump", value: model.pumpManager.uiSnapshot.pumpName.isEmpty ? "t:slim X2" : model.pumpManager.uiSnapshot.pumpName)
                LabeledContent("Link", value: model.pumpManager.linkDescription)
                if let reservoir = model.pumpManager.uiSnapshot.reservoirUnits {
                    LabeledContent("Reservoir", value: String(format: "%.0f U", reservoir))
                }
                if let battery = model.pumpManager.uiSnapshot.batteryFraction {
                    LabeledContent("Battery", value: String(format: "%.0f%%", battery * 100))
                }
                if model.pumpManager.uiSnapshot.hasBasalReading {
                    LabeledContent("Basal now", value: String(format: "%.3f U/hr", model.pumpManager.uiSnapshot.currentBasalUnitsPerHour))
                }
            }
            Section {
                Text("t:slim X2 remote control is bolus-only. Loop will not change the basal rate. Match Loop's basal schedule to the profile saved on the pump, and keep Control-IQ off while Loop is allowed to bolus.")
            }
            if !model.pumpManager.uiSnapshot.isMobi {
                Section {
                    Toggle("Allow automatic boluses", isOn: Binding(
                        get: { model.automaticBolus },
                        set: { model.automaticBolus = $0 }
                    ))
                    Text("When this is on, Loop may bolus if the pump is already delivering the basal Loop asked for. Loop still cannot reduce basal. Leave this off until you have confirmed boluses on the pump with saline or under your own judgment.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Insulin") {
                Picker("Insulin type", selection: Binding(
                    get: { model.insulinType },
                    set: { model.insulinType = $0 }
                )) {
                    Text("Not set").tag(Optional<InsulinType>.none)
                    ForEach(model.allowedInsulinTypes, id: \.self) { type in
                        Text(type.brandName).tag(Optional(type))
                    }
                }
            }
            if model.pumpManager.uiSnapshot.deliveryIsUncertain {
                Section {
                    Text("A bolus may have been delivered, but Loop did not get a final amount. Check the pump history. Do not bolus again until this is cleared.")
                    Button("I checked the pump and insulin is not moving") {
                        model.pumpManager.clearUncertaintyAfterPumpCheck()
                    }
                }
            }
            Section {
                Button("Delete pump", role: .destructive) {
                    model.pumpManager.prepareForDeactivation { _ in }
                }
            }
        }
        .navigationTitle("t:slim X2")
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            model.objectWillChange.send()
        }
    }
}

final class SettingsModel: ObservableObject {
    let pumpManager: TandemX2PumpManager
    let allowedInsulinTypes: [InsulinType]

    var automaticBolus: Bool {
        get { pumpManager.uiSnapshot.allowsAutomaticBolus }
        set { pumpManager.setAllowsAutomaticBolus(newValue) }
    }

    var insulinType: InsulinType? {
        get { pumpManager.uiSnapshot.insulinType }
        set { pumpManager.setInsulinType(newValue) }
    }

    init(pumpManager: TandemX2PumpManager, allowedInsulinTypes: [InsulinType]) {
        self.pumpManager = pumpManager
        self.allowedInsulinTypes = allowedInsulinTypes
    }
}
