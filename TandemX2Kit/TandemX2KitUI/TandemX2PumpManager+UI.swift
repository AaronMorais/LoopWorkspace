import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

extension TandemX2PumpManager {
    public static var onboardingImage: UIImage? { nil }
    public var smallImage: UIImage? { nil }

    public static func setupViewController(
        initialSettings settings: PumpManagerSetupSettings,
        bluetoothProvider: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool,
        prefersToSkipUserInteraction: Bool,
        allowedInsulinTypes: [InsulinType]
    ) -> SetupUIResult<PumpManagerViewController, PumpManagerUI> {
        .userInteractionRequired(TandemX2SetupViewController(settings: settings))
    }

    public func settingsViewController(
        bluetoothProvider: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool,
        allowedInsulinTypes: [InsulinType]
    ) -> PumpManagerViewController {
        let model = SettingsModel(pumpManager: self, allowedInsulinTypes: allowedInsulinTypes)
        let hosting = DismissibleHostingController(
            content: TandemX2SettingsView(model: model),
            isModalInPresentation: false,
            colorPalette: colorPalette
        )
        let navigation = PumpManagerSettingsNavigationViewController(rootViewController: hosting)
        navigation.navigationBar.prefersLargeTitles = true
        return navigation
    }

    public func deliveryUncertaintyRecoveryViewController(colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool) -> (UIViewController & CompletionNotifying) {
        TandemX2UncertaintyViewController(pumpManager: self)
    }

    public func hudProvider(bluetoothProvider: BluetoothProvider, colorPalette: LoopUIColorPalette, allowedInsulinTypes: [InsulinType]) -> HUDProvider? {
        TandemX2HUDProvider(pumpManager: self, bluetoothProvider: bluetoothProvider, colorPalette: colorPalette, allowedInsulinTypes: allowedInsulinTypes)
    }

    public static func createHUDView(rawValue: HUDProvider.HUDViewRawState) -> BaseHUDView? {
        TandemX2HUDProvider.createHUDView(rawValue: rawValue)
    }

    public var pumpStatusHighlight: DeviceStatusHighlight? {
        if uiSnapshot.deliveryIsUncertain {
            return PumpStatusHighlight(
                localizedMessage: "Bolus not confirmed. Check the pump before dosing again.",
                imageName: "exclamationmark.triangle.fill",
                state: .critical
            )
        }
        if !uiSnapshot.isMobi {
            return PumpStatusHighlight(
                localizedMessage: "t:slim X2 can bolus from Loop. It cannot change basal.",
                imageName: "drop.fill",
                state: .warning
            )
        }
        if TandemBasalPolicy.controlIQLikelyActive(
            currentUnitsPerHour: uiSnapshot.currentBasalUnitsPerHour,
            profileUnitsPerHour: uiSnapshot.profileBasalUnitsPerHour,
            hasReading: uiSnapshot.hasBasalReading
        ) {
            return PumpStatusHighlight(
                localizedMessage: "Pump basal does not match its profile. Turn Control-IQ off before Loop doses.",
                imageName: "exclamationmark.triangle.fill",
                state: .warning
            )
        }
        return nil
    }

    public var pumpLifecycleProgress: DeviceLifecycleProgress? { nil }
    public var pumpStatusBadge: DeviceStatusBadge? { nil }
}

final class TandemX2UncertaintyViewController: UIViewController, CompletionNotifying {
    weak var completionDelegate: CompletionDelegate?
    private let pumpManager: TandemX2PumpManager

    init(pumpManager: TandemX2PumpManager) {
        self.pumpManager = pumpManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let text = UILabel()
        text.numberOfLines = 0
        text.text = "Loop lost the reply for a bolus. Look at the pump. If insulin is not being delivered, you can clear this warning. If the pump shows a bolus Loop does not know about, add it as a manual dose after clearing."
        let button = UIButton(type: .system)
        button.setTitle("The pump is not delivering that bolus", for: .normal)
        button.addTarget(self, action: #selector(clear), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [text, button])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    @objc private func clear() {
        pumpManager.clearUncertaintyAfterPumpCheck()
        completionDelegate?.completionNotifyingDidComplete(self)
    }
}
