import Foundation

enum TandemX2Message: LocalizedError {
    case text(String)

    var errorDescription: String? {
        switch self {
        case .text(let message):
            return message
        }
    }
}

enum TandemBasalCommand: Equatable {
    case noChange
    case unsupported(String)
    case setPercent(Int, minutes: Int)
    case stop
}

/// Decides whether a Loop temp-basal request can be sent.
///
/// t:slim X2 firmware does not accept remote temp basals. Reporting success when the pump is
/// already delivering the requested rate lets Loop's model match the pump. A different rate is
/// refused so Loop does not record insulin that was never delivered.
enum TandemBasalPolicy {
    static let rateTolerance = 0.03

    static func command(
        isMobi: Bool,
        requestedUnitsPerHour: Double,
        duration: TimeInterval,
        currentUnitsPerHour: Double,
        profileUnitsPerHour: Double
    ) -> TandemBasalCommand {
        if duration <= 0 {
            if abs(currentUnitsPerHour - profileUnitsPerHour) <= rateTolerance {
                return .noChange
            }
            if isMobi {
                return .stop
            }
            return .unsupported("t:slim X2 cannot stop a temporary basal from Loop. Cancel it on the pump.")
        }

        if abs(requestedUnitsPerHour - currentUnitsPerHour) <= rateTolerance {
            return .noChange
        }

        guard isMobi else {
            return .unsupported("t:slim X2 firmware accepts remote boluses only. It cannot change the basal rate from Loop, so closed-loop basal adjustments stay off.")
        }

        guard profileUnitsPerHour >= 0.05 else {
            return .unsupported("The pump's profile basal is too low to set a percent temporary rate.")
        }

        let minutes = Int((duration / 60.0).rounded())
        guard (15...4_320).contains(minutes) else {
            return .unsupported("Temporary basal duration must be 15 minutes to 72 hours on a Tandem pump.")
        }

        let percent = Int((requestedUnitsPerHour / profileUnitsPerHour * 100.0).rounded(.down))
        guard (0...250).contains(percent) else {
            return .unsupported("That basal rate is outside the 0–250% temporary rate the pump accepts.")
        }
        return .setPercent(percent, minutes: minutes)
    }

    /// Control-IQ (or an existing temp) is already changing basal when delivery differs from the profile.
    static func controlIQLikelyActive(currentUnitsPerHour: Double, profileUnitsPerHour: Double, hasReading: Bool) -> Bool {
        guard hasReading, profileUnitsPerHour > 0 else { return false }
        return abs(currentUnitsPerHour - profileUnitsPerHour) > rateTolerance
    }

    static func allowAutomaticBolus(isMobi: Bool, userEnabledOnX2: Bool, controlIQLikelyActive: Bool) -> Bool {
        if controlIQLikelyActive { return false }
        if isMobi { return true }
        return userEnabledOnX2
    }
}

enum TandemX2Rates {
    static let reservoirCapacity = 300.0
    static let maxBasalEntries = 16
    static let minimumBasalEntryDuration: TimeInterval = 30 * 60

    static let basalRates: [Double] = stride(from: 0.0, through: 15.0, by: 0.001).map { ($0 * 1000).rounded() / 1000 }
    static let bolusVolumes: [Double] = stride(from: 0.05, through: 25.0, by: 0.05).map { ($0 * 20).rounded() / 20 }

    static func bolusMilliunits(from units: Double) -> UInt32? {
        guard units.isFinite, units >= 0.05 else { return nil }
        let rounded = (units * 20).rounded(.down) / 20
        let milliunits = UInt32((rounded * 1000).rounded())
        guard milliunits >= 50 else { return nil }
        return milliunits
    }
}
