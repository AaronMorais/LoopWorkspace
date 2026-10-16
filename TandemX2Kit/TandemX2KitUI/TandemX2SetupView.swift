import Combine
import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

final class TandemX2SetupViewController: UIViewController, PumpManagerOnboarding, CompletionNotifying {
    var pumpManagerOnboardingDelegate: PumpManagerOnboardingDelegate?
    var completionDelegate: CompletionDelegate?

    private let pumpManager: TandemX2PumpManager
    private var hosting: UIHostingController<TandemX2SetupView>?

    init(settings: PumpManagerSetupSettings) {
        pumpManager = TandemX2PumpManager(settings: settings)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "t:slim X2"
        let root = TandemX2SetupView(pumpManager: pumpManager) { [weak self] in
            self?.finish()
        }
        let hosting = UIHostingController(rootView: root)
        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        self.hosting = hosting
        pumpManager.startScanning()
    }

    private func finish() {
        pumpManagerOnboardingDelegate?.pumpManagerOnboarding(didCreatePumpManager: pumpManager)
        pumpManagerOnboardingDelegate?.pumpManagerOnboarding(didOnboardPumpManager: pumpManager)
        completionDelegate?.completionNotifyingDidComplete(self)
    }
}

struct TandemX2SetupView: View {
    @ObservedObject private var model: SetupModel
    let onFinished: () -> Void

    init(pumpManager: TandemX2PumpManager, onFinished: @escaping () -> Void) {
        model = SetupModel(pumpManager: pumpManager)
        self.onFinished = onFinished
    }

    var body: some View {
        Form {
            Section {
                Text("This build talks to a t:slim X2 with the same Bluetooth protocol as Tandem's mobile bolus feature. It is experimental, not a Tandem product, and not a medical device.")
                Text("The pump can take a remote bolus. Current t:slim X2 firmware cannot take a remote temporary basal or a remote suspend, so Loop cannot lower insulin on its own. Leave closed loop off unless you turn on automatic boluses later and accept that limitation.")
                Text("Turn off Control-IQ before dosing from Loop. Loop and Control-IQ must not both deliver insulin.")
            }
            Section("Pairing code") {
                TextField("6-digit code from the pump", text: $model.code)
                    .keyboardType(.numberPad)
                Button(model.scanning ? "Scanning…" : "Scan again") {
                    model.pumpManager.startScanning()
                }
            }
            Section("Pumps") {
                if model.pumpManager.discovered.isEmpty {
                    Text(model.pumpManager.linkDescription)
                }
                ForEach(model.pumpManager.discovered) { pump in
                    Button("\(pump.name)  \(pump.rssi) dBm") {
                        model.connect(pump)
                    }
                }
            }
            if model.pumpManager.paired {
                Section {
                    Button("Continue") { onFinished() }
                }
            }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            model.objectWillChange.send()
        }
    }
}

private final class SetupModel: ObservableObject {
    let pumpManager: TandemX2PumpManager
    @Published var code = ""
    var scanning: Bool { pumpManager.linkDescription == "Scanning" }

    init(pumpManager: TandemX2PumpManager) {
        self.pumpManager = pumpManager
    }

    func connect(_ pump: TandemDiscoveredPump) {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return }
        pumpManager.connect(id: pump.id, name: pump.name, pairingCode: digits)
    }
}
