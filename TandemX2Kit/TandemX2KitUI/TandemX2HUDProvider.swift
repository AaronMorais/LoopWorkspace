import LoopKit
import LoopKitUI
import UIKit

final class TandemX2HUDProvider: NSObject, HUDProvider {
    private let pumpManager: TandemX2PumpManager
    private var reservoirView: ReservoirVolumeHUDView?
    var visible = false

    init(pumpManager: TandemX2PumpManager, bluetoothProvider: BluetoothProvider, colorPalette: LoopUIColorPalette, allowedInsulinTypes: [InsulinType]) {
        self.pumpManager = pumpManager
        super.init()
        pumpManager.addStatusObserver(self, queue: .main)
    }

    var managerIdentifier: String { TandemX2PumpManager.pluginIdentifier }

    func createHUDView() -> BaseHUDView? {
        let view = ReservoirVolumeHUDView.instantiate()
        reservoirView = view
        update(view)
        return view
    }

    func didTapOnHUDView(_ view: BaseHUDView, allowDebugFeatures: Bool) -> HUDTapAction? {
        nil
    }

    var hudViewRawState: HUDViewRawState {
        var raw: HUDViewRawState = [:]
        raw["reservoir"] = pumpManager.uiSnapshot.reservoirUnits
        raw["date"] = pumpManager.uiSnapshot.lastSync
        return raw
    }

    static func createHUDView(rawValue: HUDProvider.HUDViewRawState) -> BaseHUDView? {
        guard let volume = rawValue["reservoir"] as? Double else { return nil }
        let view = ReservoirVolumeHUDView.instantiate()
        let date = rawValue["date"] as? Date ?? Date()
        view.level = min(1, max(0, volume / TandemX2Rates.reservoirCapacity))
        view.setReservoirVolume(volume: volume, at: date)
        return view
    }

    private func update(_ view: ReservoirVolumeHUDView) {
        let volume = pumpManager.uiSnapshot.reservoirUnits ?? 0
        view.level = min(1, max(0, volume / TandemX2Rates.reservoirCapacity))
        view.setReservoirVolume(volume: volume, at: pumpManager.uiSnapshot.lastSync ?? Date())
    }
}

extension TandemX2HUDProvider: PumpManagerStatusObserver {
    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {
        guard let reservoirView else { return }
        update(reservoirView)
    }
}
