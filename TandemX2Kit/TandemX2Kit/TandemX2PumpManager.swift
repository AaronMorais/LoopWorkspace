import Foundation
import HealthKit
import LoopKit
import LoopKitUI
import os.log
import TandemBLE

private let tandemLog = Logger(subsystem: "org.loopkit.TandemX2Kit", category: "PumpManager")

public final class TandemX2PumpManager: NSObject, PumpManager, PumpManagerUI {
    public static let pluginIdentifier = "TandemX2"
    public static let localizedTitle = "t:slim X2"

    public var localizedTitle: String { Self.localizedTitle }

    public static var onboardingMaximumBasalScheduleEntryCount: Int { TandemX2Rates.maxBasalEntries }
    public static var onboardingSupportedBasalRates: [Double] { TandemX2Rates.basalRates }
    public static var onboardingSupportedBolusVolumes: [Double] { TandemX2Rates.bolusVolumes }
    public static var onboardingSupportedMaximumBolusVolumes: [Double] { TandemX2Rates.bolusVolumes }

    public let pumpReservoirCapacity = TandemX2Rates.reservoirCapacity
    public var supportedBasalRates: [Double] { TandemX2Rates.basalRates }
    public var supportedBolusVolumes: [Double] { TandemX2Rates.bolusVolumes }
    public var supportedMaximumBolusVolumes: [Double] { TandemX2Rates.bolusVolumes }
    public var maximumBasalScheduleEntryCount: Int { TandemX2Rates.maxBasalEntries }
    public var minimumBasalScheduleEntryDuration: TimeInterval { TandemX2Rates.minimumBasalEntryDuration }
    public var pumpRecordsBasalProfileStartEvents: Bool { false }

    public var delegateQueue: DispatchQueue! {
        get { delegateQueueStorage }
        set { if let newValue { delegateQueueStorage = newValue } }
    }

    public weak var pumpManagerDelegate: PumpManagerDelegate?

    public var isOnboarded: Bool { state.peripheralID != nil }
    public var lastSync: Date? { state.lastSync }
    public var status: PumpManagerStatus { lockedStatus.value }

    public override var debugDescription: String {
        "TandemX2PumpManager(name: \(state.pumpName), onboarded: \(isOnboarded), uncertain: \(state.deliveryIsUncertain))"
    }

    let session: TandemX2Session = MainActor.assumeIsolated { TandemX2Session() }
    private var delegateQueueStorage = DispatchQueue(label: "org.loopkit.TandemX2Kit.delegate")
    private let lockedStatus: Locked<PumpManagerStatus>
    private var state: State
    private var observers: [UUID: Observer] = [:]
    private var heartbeatTimer: Timer?
    private var pollTimer: Timer?
    private var reportedBolusIDs: Set<Int> = []

    public init?(rawState: RawStateValue) {
        guard let restored = State(rawState: rawState) else { return nil }
        state = restored
        lockedStatus = Locked(restored.status)
        super.init()
        attachSession()
        let id = state.peripheralID
        let name = state.pumpName
        let secret = id.flatMap { TandemX2CredentialStore.loadDerivedSecret(account: $0.uuidString) }
        Task { @MainActor in
            if let secret {
                self.session.restoreDerivedSecret(secret)
            }
            if let id {
                self.session.connectKnown(id: id, name: name)
            }
        }
        startPolling()
    }

    init(settings: PumpManagerSetupSettings) {
        var initial = State()
        initial.basalSchedule = settings.basalSchedule
        initial.maxBasal = settings.maxBasalRateUnitsPerHour
        initial.maxBolus = settings.maxBolusUnits
        state = initial
        lockedStatus = Locked(initial.status)
        super.init()
        attachSession()
    }

    private(set) var discovered: [TandemDiscoveredPump] = []
    private(set) var linkDescription = "Not connected"
    private(set) var paired = false

    private func attachSession() {
        MainActor.assumeIsolated {
            self.session.onChange = { [weak self] in
                Task { await self?.captureSessionSnapshot() }
            }
            self.session.onPaired = { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.finishPairing(
                        secret: self.session.derivedSecretData(),
                        name: self.session.pumpName,
                        isMobi: self.session.isMobi,
                        discovered: self.session.discovered
                    )
                }
            }
        }
    }

    private func captureSessionSnapshot() async {
        let snapshot = await MainActor.run { () -> (pumps: [TandemDiscoveredPump], paired: Bool, text: String) in
            (
                self.session.discovered,
                self.session.isPaired,
                Self.describe(self.session.connectionState, paired: self.session.isPaired)
            )
        }
        discovered = snapshot.pumps
        paired = snapshot.paired
        linkDescription = snapshot.text
        publishStatus()
    }

    private static func describe(_ state: PumpBLEClient.State, paired: Bool) -> String {
        switch state {
        case .ready: return paired ? "Connected" : "Finishing pairing"
        case .scanning: return "Scanning"
        case .connecting, .discovering: return "Connecting"
        case .reconnectExhausted: return "Pairing failed. Forget the pump in Bluetooth settings and try again."
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission is needed"
        default: return "Not connected"
        }
    }

    func startScanning() {
        Task { @MainActor in
            self.session.startScan()
        }
    }

    func connect(id: UUID, name: String, pairingCode: String) {
        rememberDiscoveredPump(TandemDiscoveredPump(id: id, name: name, rssi: 0))
        Task { @MainActor in
            self.session.beginPairing(code: pairingCode)
            self.session.connect(id, name: name)
        }
    }

    private func finishPairing(secret: Data?, name: String, isMobi: Bool, discovered: [TandemDiscoveredPump]) {
        guard let secret else { return }
        if state.peripheralID == nil, let match = discovered.first(where: { $0.name == name }) ?? discovered.first {
            state.peripheralID = match.id
        }
        guard let id = state.peripheralID else { return }
        TandemX2CredentialStore.saveDerivedSecret(secret, account: id.uuidString)
        state.pumpName = name
        state.isMobi = isMobi
        state.lastSync = Date()
        paired = true
        persistAndPublish()
        Task { await self.refresh(reportEvents: true) }
    }

    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    public func getSoundBaseURL() -> URL? { nil }
    public func getSounds() -> [Alert.Sound] { [] }

    public func addStatusObserver(_ observer: PumpManagerStatusObserver, queue: DispatchQueue) {
        observers[UUID()] = Observer(observer: observer, queue: queue)
    }

    public func removeStatusObserver(_ observer: PumpManagerStatusObserver) {
        observers = observers.filter { $0.value.observer !== observer }
    }

    public func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        Task {
            await refresh(reportEvents: true)
            completion?(state.lastSync)
        }
    }

    public func setMustProvideBLEHeartbeat(_ mustProvideBLEHeartbeat: Bool) {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        guard mustProvideBLEHeartbeat else { return }
        let timer = Timer(timeInterval: 4.5 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.delegateQueue.async {
                self.pumpManagerDelegate?.pumpManagerBLEHeartbeatDidFire(self)
            }
            Task { await self.refresh(reportEvents: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    public func createBolusProgressReporter(reportingOn dispatchQueue: DispatchQueue) -> DoseProgressReporter? {
        nil
    }

    public func estimatedDuration(toBolus units: Double) -> TimeInterval {
        units * 60
    }

    public func enactBolus(units: Double, activationType: BolusActivationType, completion: @escaping (PumpManagerError?) -> Void) {
        let automaticAllowed = TandemBasalPolicy.allowAutomaticBolus(
            isMobi: state.isMobi,
            userEnabledOnX2: state.allowsAutomaticBolus,
            controlIQLikelyActive: TandemBasalPolicy.controlIQLikelyActive(
                currentUnitsPerHour: state.currentBasalUnitsPerHour,
                profileUnitsPerHour: state.profileBasalUnitsPerHour,
                hasReading: state.hasBasalReading
            )
        )
        if activationType.isAutomatic && !automaticAllowed {
            let message = state.isMobi
                ? "Automatic boluses are paused while the pump's delivered basal does not match its profile. Turn Control-IQ off before letting Loop dose."
                : "Automatic boluses are off. t:slim X2 cannot lower basal from Loop, so closed loop would only be able to add insulin. Turn this on in pump settings only if you understand that."
            completion(.deviceState(TandemX2Message.text(message)))
            return
        }
        if state.deliveryIsUncertain {
            completion(.uncertainDelivery)
            return
        }

        Task { @MainActor in
            let result = await self.session.deliverBolus(
                units: units,
                maxBolus: min(self.state.maxBolus, self.state.pumpMaxBolus ?? self.state.maxBolus),
                cartridgeLoading: self.state.cartridgeLoading
            )
            switch result {
            case .delivered(let delivered, let id):
                self.reportBolus(id: id, units: delivered, at: Date(), activationType: activationType)
                self.persistAndPublish()
                self.delegateQueue.async { completion(nil) }
            case .rejected(let message):
                self.delegateQueue.async { completion(.deviceState(TandemX2Message.text(message))) }
            case .uncertain(let id, let reason):
                self.state.deliveryIsUncertain = true
                self.state.uncertainBolusID = id
                self.persistAndPublish()
                tandemLog.error("Uncertain bolus \(id, privacy: .public): \(reason, privacy: .public)")
                self.delegateQueue.async { completion(.uncertainDelivery) }
            }
        }
    }

    public func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
        Task { @MainActor in
            self.session.requestCancel()
            completion(.success(nil))
        }
    }

    public func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval, completion: @escaping (PumpManagerError?) -> Void) {
        let command = TandemBasalPolicy.command(
            isMobi: state.isMobi,
            requestedUnitsPerHour: unitsPerHour,
            duration: duration,
            currentUnitsPerHour: state.currentBasalUnitsPerHour,
            profileUnitsPerHour: state.hasBasalReading ? state.profileBasalUnitsPerHour : unitsPerHour
        )
        switch command {
        case .noChange:
            completion(nil)
        case .unsupported(let message):
            completion(.deviceState(TandemX2Message.text(message)))
        case .setPercent(let percent, let minutes):
            Task { @MainActor in
                do {
                    try await self.session.setTempPercent(percent, minutes: minutes)
                    self.delegateQueue.async { completion(nil) }
                } catch {
                    self.delegateQueue.async { completion(.communication(TandemX2Message.text(error.localizedDescription))) }
                }
            }
        case .stop:
            Task { @MainActor in
                do {
                    try await self.session.stopTempRate()
                    self.delegateQueue.async { completion(nil) }
                } catch {
                    self.delegateQueue.async { completion(.communication(TandemX2Message.text(error.localizedDescription))) }
                }
            }
        }
    }

    public func suspendDelivery(completion: @escaping (Error?) -> Void) {
        guard state.isMobi else {
            completion(TandemX2Message.text("t:slim X2 cannot be suspended from Loop. Suspend insulin on the pump."))
            return
        }
        Task { @MainActor in
            do {
                try await self.session.suspend()
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    public func resumeDelivery(completion: @escaping (Error?) -> Void) {
        guard state.isMobi else {
            completion(TandemX2Message.text("t:slim X2 cannot be resumed from Loop. Resume insulin on the pump."))
            return
        }
        Task { @MainActor in
            do {
                try await self.session.resume()
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    public func syncBasalRateSchedule(items scheduleItems: [RepeatingScheduleValue<Double>], completion: @escaping (Result<BasalRateSchedule, Error>) -> Void) {
        guard let schedule = BasalRateSchedule(dailyItems: scheduleItems, timeZone: TimeZone.current) else {
            completion(.failure(TandemX2Message.text("The basal schedule is not valid.")))
            return
        }
        state.basalSchedule = schedule
        persistAndPublish()
        completion(.success(schedule))
    }

    public func syncDeliveryLimits(limits deliveryLimits: DeliveryLimits, completion: @escaping (Result<DeliveryLimits, Error>) -> Void) {
        let basalUnit = HKUnit.internationalUnit().unitDivided(by: .hour())
        state.maxBasal = deliveryLimits.maximumBasalRate?.doubleValue(for: basalUnit) ?? state.maxBasal
        state.maxBolus = deliveryLimits.maximumBolus?.doubleValue(for: .internationalUnit()) ?? state.maxBolus
        persistAndPublish()
        completion(.success(deliveryLimits))
    }

    public func prepareForDeactivation(_ completion: @escaping (Error?) -> Void) {
        if let id = state.peripheralID {
            TandemX2CredentialStore.deleteDerivedSecret(account: id.uuidString)
        }
        pollTimer?.invalidate()
        heartbeatTimer?.invalidate()
        Task { @MainActor in
            self.session.disconnect()
        }
        notifyDelegateOfDeactivation {
            completion(nil)
        }
    }

    public var rawState: RawStateValue { state.rawValue }

    func setAllowsAutomaticBolus(_ enabled: Bool) {
        state.allowsAutomaticBolus = enabled
        persistAndPublish()
    }

    func setInsulinType(_ insulinType: InsulinType?) {
        state.insulinType = insulinType
        persistAndPublish()
    }

    func clearUncertaintyAfterPumpCheck() {
        state.deliveryIsUncertain = false
        state.uncertainBolusID = 0
        persistAndPublish()
    }

    var uiSnapshot: State { state }

    // MARK: - Status

    private func startPolling() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh(reportEvents: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func refresh(reportEvents: Bool) async {
        let reading = await session.refreshStatus()
        if let reservoir = reading.reservoirUnits {
            state.reservoirUnits = reservoir
            let date = reading.readAt
            delegateQueue.async {
                self.pumpManagerDelegate?.pumpManager(self, didReadReservoirValue: reservoir, at: date) { _ in }
            }
        }
        if let battery = reading.batteryFraction {
            state.batteryFraction = battery
        }
        if let current = reading.currentBasalUnitsPerHour, let profile = reading.profileBasalUnitsPerHour {
            state.currentBasalUnitsPerHour = current
            state.profileBasalUnitsPerHour = profile
            state.hasBasalReading = true
        }
        state.cartridgeLoading = reading.loadingActive
        if let maxBolus = reading.maxBolusUnits {
            state.pumpMaxBolus = maxBolus
        }
        if reading.bolusActive {
            state.bolusState = .inProgress(DoseEntry(
                type: .bolus,
                startDate: reading.readAt,
                value: 0,
                unit: .units,
                insulinType: state.insulinType
            ))
        } else if case .inProgress = state.bolusState {
            state.bolusState = .noBolus
        }
        if reading.pumpTime > 0 {
            state.pumpTimeAnchor = reading.pumpTime
            state.pumpTimeAnchorDate = reading.readAt
        }
        if reportEvents, reading.lastBolusID > 0 {
            let date = wallDate(pumpTime: reading.lastBolusPumpTime) ?? reading.readAt
            if date.timeIntervalSinceNow > -8 * 60 * 60 {
                reportBolus(id: reading.lastBolusID, units: reading.lastBolusDeliveredUnits, at: date, activationType: .none)
            }
        }
        if state.deliveryIsUncertain, reading.lastBolusID == state.uncertainBolusID, !reading.bolusActive, reading.lastBolusID > 0 {
            state.deliveryIsUncertain = false
            state.uncertainBolusID = 0
        }
        state.lastSync = reading.readAt
        let identity = await MainActor.run { (self.session.pumpName, self.session.isMobi) }
        if !identity.0.isEmpty {
            state.pumpName = identity.0
            state.isMobi = identity.1
        }
        persistAndPublish()
    }

    private func wallDate(pumpTime: UInt32) -> Date? {
        guard let anchor = state.pumpTimeAnchor, let anchorDate = state.pumpTimeAnchorDate, pumpTime > 0 else { return nil }
        return anchorDate.addingTimeInterval(TimeInterval(Int64(pumpTime) - Int64(anchor)))
    }

    private func reportBolus(id: Int, units: Double, at date: Date, activationType: BolusActivationType) {
        guard id > 0, units > 0, reportedBolusIDs.insert(id).inserted else { return }
        let dose = DoseEntry(
            type: .bolus,
            startDate: date,
            endDate: date.addingTimeInterval(estimatedDuration(toBolus: units)),
            value: units,
            unit: .units,
            deliveredUnits: units,
            insulinType: state.insulinType,
            automatic: activationType.isAutomatic ? true : nil,
            wasProgrammedByPumpUI: activationType == .none
        )
        let event = NewPumpEvent(date: date, dose: dose, raw: Data("tandem-bolus-\(id)".utf8), title: "Bolus")
        delegateQueue.async {
            self.pumpManagerDelegate?.pumpManager(self, hasNewPumpEvents: [event], lastReconciliation: Date(), replacePendingEvents: false) { _ in }
        }
    }

    private func publishStatus() {
        let old = lockedStatus.value
        let new = state.status
        lockedStatus.value = new
        let observers = self.observers
        for entry in observers.values {
            guard let observer = entry.observer else { continue }
            entry.queue.async {
                observer.pumpManager(self, didUpdate: new, oldStatus: old)
            }
        }
    }

    private func persistAndPublish() {
        publishStatus()
        delegateQueue.async {
            self.pumpManagerDelegate?.pumpManagerDidUpdateState(self)
            self.pumpManagerDelegate?.pumpManager(self, didUpdate: self.status, oldStatus: self.status)
        }
    }

    func rememberDiscoveredPump(_ pump: TandemDiscoveredPump) {
        state.peripheralID = pump.id
        state.pumpName = pump.name
        state.isMobi = pump.name.lowercased().contains("mobi")
    }
}

private struct Observer {
    weak var observer: PumpManagerStatusObserver?
    let queue: DispatchQueue
}

struct State {
    var peripheralID: UUID?
    var pumpName = ""
    var isMobi = false
    var insulinType: InsulinType?
    var basalSchedule: BasalRateSchedule?
    var maxBasal = 1.0
    var maxBolus = 10.0
    var pumpMaxBolus: Double?
    var reservoirUnits: Double?
    var batteryFraction: Double?
    var currentBasalUnitsPerHour = 0.0
    var profileBasalUnitsPerHour = 0.0
    var hasBasalReading = false
    var cartridgeLoading = false
    var bolusState: PumpManagerStatus.BolusState = .noBolus
    var lastSync: Date?
    var deliveryIsUncertain = false
    var uncertainBolusID = 0
    var allowsAutomaticBolus = false
    var pumpTimeAnchor: UInt32?
    var pumpTimeAnchorDate: Date?

    var status: PumpManagerStatus {
        let device = HKDevice(
            name: pumpName.isEmpty ? "t:slim X2" : pumpName,
            manufacturer: "Tandem",
            model: isMobi ? "Mobi" : "t:slim X2",
            hardwareVersion: nil,
            firmwareVersion: nil,
            softwareVersion: nil,
            localIdentifier: peripheralID?.uuidString,
            udiDeviceIdentifier: nil
        )
        let basal: PumpManagerStatus.BasalDeliveryState?
        if hasBasalReading {
            basal = currentBasalUnitsPerHour <= 0.001 ? .suspended(lastSync ?? Date()) : .active(lastSync ?? Date())
        } else {
            basal = nil
        }
        return PumpManagerStatus(
            timeZone: basalSchedule?.timeZone ?? .current,
            device: device,
            pumpBatteryChargeRemaining: batteryFraction,
            basalDeliveryState: basal,
            bolusState: bolusState,
            insulinType: insulinType,
            deliveryIsUncertain: deliveryIsUncertain
        )
    }

    var rawValue: PumpManager.RawStateValue {
        var raw: [String: Any] = [
            "pumpName": pumpName,
            "isMobi": isMobi,
            "maxBasal": maxBasal,
            "maxBolus": maxBolus,
            "currentBasal": currentBasalUnitsPerHour,
            "profileBasal": profileBasalUnitsPerHour,
            "hasBasalReading": hasBasalReading,
            "deliveryIsUncertain": deliveryIsUncertain,
            "uncertainBolusID": uncertainBolusID,
            "allowsAutomaticBolus": allowsAutomaticBolus
        ]
        raw["peripheralID"] = peripheralID?.uuidString
        raw["insulinType"] = insulinType?.rawValue
        raw["reservoir"] = reservoirUnits
        raw["battery"] = batteryFraction
        raw["lastSync"] = lastSync
        raw["pumpMaxBolus"] = pumpMaxBolus
        if let schedule = basalSchedule {
            raw["schedule"] = schedule.items.map { [$0.startTime, $0.value] }
            raw["scheduleTimeZone"] = schedule.timeZone.identifier
        }
        return raw
    }

    init() {}

    init?(rawState: PumpManager.RawStateValue) {
        guard let idString = rawState["peripheralID"] as? String, let id = UUID(uuidString: idString) else {
            return nil
        }
        peripheralID = id
        pumpName = rawState["pumpName"] as? String ?? ""
        isMobi = rawState["isMobi"] as? Bool ?? false
        if let rawInsulin = rawState["insulinType"] as? Int {
            insulinType = InsulinType(rawValue: rawInsulin)
        }
        maxBasal = rawState["maxBasal"] as? Double ?? 1
        maxBolus = rawState["maxBolus"] as? Double ?? 10
        pumpMaxBolus = rawState["pumpMaxBolus"] as? Double
        reservoirUnits = rawState["reservoir"] as? Double
        batteryFraction = rawState["battery"] as? Double
        currentBasalUnitsPerHour = rawState["currentBasal"] as? Double ?? 0
        profileBasalUnitsPerHour = rawState["profileBasal"] as? Double ?? 0
        hasBasalReading = rawState["hasBasalReading"] as? Bool ?? false
        lastSync = rawState["lastSync"] as? Date
        deliveryIsUncertain = rawState["deliveryIsUncertain"] as? Bool ?? false
        uncertainBolusID = rawState["uncertainBolusID"] as? Int ?? 0
        allowsAutomaticBolus = rawState["allowsAutomaticBolus"] as? Bool ?? false
        if let rows = rawState["schedule"] as? [[Double]],
           let identifier = rawState["scheduleTimeZone"] as? String,
           let timeZone = TimeZone(identifier: identifier) {
            let items = rows.compactMap { row -> RepeatingScheduleValue<Double>? in
                guard row.count == 2 else { return nil }
                return RepeatingScheduleValue(startTime: row[0], value: row[1])
            }
            basalSchedule = BasalRateSchedule(dailyItems: items, timeZone: timeZone)
        }
    }
}

private final class Locked<Value> {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
