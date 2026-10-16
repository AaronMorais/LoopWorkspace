import LoopKitUI
import TandemX2Kit

class TandemX2KitPlugin: NSObject, PumpManagerUIPlugin {
    var pumpManagerType: PumpManagerUI.Type? {
        TandemX2PumpManager.self
    }

    var cgmManagerType: CGMManagerUI.Type? {
        nil
    }

    override init() {
        super.init()
    }
}
