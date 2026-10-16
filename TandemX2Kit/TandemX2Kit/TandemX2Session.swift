import Foundation
import CoreBluetooth
import TandemAuth
import TandemBLE
import TandemMessages

struct TandemDiscoveredPump: Identifiable, Equatable {
    var id: UUID
    var name: String
    var rssi: Int
}

struct TandemStatusReading {
    var reservoirUnits: Double?
    var batteryFraction: Double?
    var currentBasalUnitsPerHour: Double?
    var profileBasalUnitsPerHour: Double?
    var bolusActive = false
    var activeBolusID = 0
    var lastBolusID = 0
    var lastBolusDeliveredUnits = 0.0
    var lastBolusPumpTime: UInt32 = 0
    var pumpTime: UInt32 = 0
    var loadingActive = false
    var maxBolusUnits: Double?
    var readAt = Date()
}

enum TandemBolusResult {
    case delivered(Double, id: Int)
    case rejected(String)
    case uncertain(id: Int, reason: String)
}

/// BLE session for a t:slim X2 or Mobi. Insulin commands go through TandemKit's signed,
/// write-policy-gated path. The session never reports a bolus as delivered unless the pump's
/// own last-bolus record confirms it.
@MainActor
final class TandemX2Session: NSObject, PumpBLEClientDelegate {
    let client: PumpBLEClient

    private(set) var discovered: [TandemDiscoveredPump] = []
    private(set) var isPaired = false
    private(set) var connectionState: PumpBLEClient.State = .unknown
    private(set) var isMobi = false
    private(set) var pumpName = ""

    var onChange: (() -> Void)?
    var onPaired: (() -> Void)?

    private var coordinator: PairingCoordinator?
    private var authKey: [UInt8] = []
    private var derivedSecret: [UInt8] = []
    private var pairingCode: String?
    private var deliveryInProgress = false
    private var cancelRequested = false
    private var currentBolusID = 0
    private var readyWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var peripherals: [UUID: CBPeripheral] = [:]

    override init() {
        client = PumpBLEClient(restoreIdentifier: "org.loopkit.TandemX2Kit")
        super.init()
        client.delegate = self
    }

    func setIdentity(name: String) {
        pumpName = name
        let lowered = name.lowercased()
        isMobi = lowered.contains("mobi")
        let model: PumpModel = isMobi ? .mobi : .tslim
        let family: PumpBLEClient.PumpFamily = isMobi ? .mobi : .tslim
        client.setPumpFamily(family)
        client.setDeviceContext(model: model, apiVersion: nil, trusted: true)
    }

    func restoreDerivedSecret(_ data: Data) {
        derivedSecret = [UInt8](data)
    }

    func derivedSecretData() -> Data? {
        derivedSecret.isEmpty ? nil : Data(derivedSecret)
    }

    func startScan() {
        discovered = []
        client.startScan()
        onChange?()
    }

    func stopScan() {
        client.stopScan()
    }

    func connect(_ id: UUID, name: String) {
        setIdentity(name: name)
        guard let peripheral = peripherals[id] else { return }
        client.connect(peripheral)
    }

    func connectKnown(id: UUID, name: String) {
        setIdentity(name: name)
        client.connectKnownPeripheral(identifier: id)
    }

    func disconnect() {
        coordinator = nil
        isPaired = false
        authKey = []
        failWaiters(TandemX2Message.text("Disconnected."))
        client.disconnect()
    }

    func beginPairing(code: String) {
        pairingCode = code
        coordinator = nil
        isPaired = false
    }

    func waitUntilPaired(timeout: TimeInterval) async throws {
        if isPaired, client.state == .ready { return }
        let id = UUID()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyWaiters[id] = continuation
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let waiter = self.readyWaiters.removeValue(forKey: id) {
                    waiter.resume(throwing: TandemX2Message.text("The pump did not finish pairing. Put it in pairing mode and try again."))
                }
            }
        }
    }

    func refreshStatus() async -> TandemStatusReading {
        var reading = TandemStatusReading()
        guard isPaired, client.state == .ready else { return reading }
        if let insulin = try? await request(InsulinStatusRequest(), as: InsulinStatusResponse.self) {
            reading.reservoirUnits = Double(insulin.currentInsulinAmount)
        }
        if let battery = try? await request(CurrentBatteryV2Request(), as: CurrentBatteryV2Response.self) {
            reading.batteryFraction = Double(battery.batteryPercent) / 100.0
        }
        if let basal = try? await request(CurrentBasalStatusRequest(), as: CurrentBasalStatusResponse.self) {
            reading.currentBasalUnitsPerHour = basal.currentBasalUnitsPerHour
            reading.profileBasalUnitsPerHour = Double(basal.profileBasalRate) / 1000.0
        }
        if let bolus = try? await request(CurrentBolusStatusRequest(), as: CurrentBolusStatusResponse.self) {
            reading.bolusActive = bolus.isActive
            reading.activeBolusID = bolus.bolusId
        }
        if let last = try? await request(LastBolusStatusV2Request(), as: LastBolusStatusV2Response.self) {
            reading.lastBolusID = last.bolusId
            reading.lastBolusDeliveredUnits = last.deliveredUnits
            reading.lastBolusPumpTime = last.timestamp
        }
        if let time = try? await request(TimeSinceResetRequest(), as: TimeSinceResetResponse.self) {
            reading.pumpTime = time.signingTimestamp
        }
        if let load = try? await request(LoadStatusRequest(), as: LoadStatusResponse.self) {
            reading.loadingActive = load.isLoadingActive
        }
        if let calc = try? await request(BolusCalcDataSnapshotRequest(), as: BolusCalcDataSnapshotResponse.self), calc.maxBolusAmount > 0 {
            reading.maxBolusUnits = Double(calc.maxBolusAmount) / 1000.0
        }
        reading.readAt = Date()
        return reading
    }

    func deliverBolus(units: Double, maxBolus: Double, cartridgeLoading: Bool) async -> TandemBolusResult {
        guard !deliveryInProgress else {
            return .rejected("A bolus is already in progress.")
        }
        guard isPaired, client.state == .ready else {
            return .rejected("The pump is not connected.")
        }
        guard !cartridgeLoading else {
            return .rejected("Finish the cartridge change on the pump before bolusing.")
        }
        guard maxBolus > 0 else {
            return .rejected("Loop has not read the pump's maximum bolus yet. Wait for the next status update.")
        }
        guard units.isFinite, units <= maxBolus else {
            return .rejected("That bolus is above the pump's maximum of \(String(format: "%.2f", maxBolus)) U.")
        }
        guard let milliunits = TandemX2Rates.bolusMilliunits(from: units) else {
            return .rejected("The smallest t:slim bolus is 0.05 U.")
        }

        deliveryInProgress = true
        cancelRequested = false
        defer {
            deliveryInProgress = false
            client.writePolicy = .readOnly
        }

        let time: TimeSinceResetResponse
        do {
            time = try await request(TimeSinceResetRequest(), as: TimeSinceResetResponse.self)
        } catch {
            return .rejected("Could not read the pump clock.")
        }

        client.writePolicy = .allowDelivery
        let permission: BolusPermissionResponse
        do {
            permission = try await request(
                BolusPermissionRequest(),
                as: BolusPermissionResponse.self,
                signed: true,
                allowDelivery: false,
                deadline: 8
            )
        } catch {
            return .rejected("The pump did not allow a bolus.")
        }
        guard permission.granted else {
            return .rejected("The pump refused the bolus (reason \(permission.nackReasonId)).")
        }

        currentBolusID = permission.bolusId
        let initiate: InitiateBolusRequest
        do {
            initiate = try InitiateBolusRequest(
                validating: milliunits,
                bolusID: permission.bolusId,
                bolusTypeBitmask: InitiateBolusRequest.bitFood2
            )
        } catch {
            return .rejected("Could not build a valid bolus command.")
        }

        let response: InitiateBolusResponse
        do {
            response = try await self.request(
                initiate,
                as: InitiateBolusResponse.self,
                signed: true,
                allowDelivery: true,
                deadline: 8
            )
        } catch {
            return .uncertain(id: permission.bolusId, reason: "The bolus was sent but the pump did not confirm it. Check the pump before dosing again.")
        }
        guard response.bolusId == permission.bolusId, response.accepted else {
            return .uncertain(id: permission.bolusId, reason: "The pump's bolus reply was not a clear acceptance. Check the pump before dosing again.")
        }

        if cancelRequested {
            try? await client.withWritePolicy(.allowDelivery) {
                _ = try self.client.send(
                    CancelBolusRequest(bolusId: permission.bolusId),
                    authenticationKey: self.authKey,
                    pumpTimeSinceReset: time.signingTimestamp,
                    allowInsulinDelivery: true
                )
            }
        }

        let deadline = Date().addingTimeInterval(min(600, max(60, units * 90)))
        var finished = false
        while Date() < deadline {
            if cancelRequested {
                try? await client.withWritePolicy(.allowDelivery) {
                    _ = try self.client.send(
                        CancelBolusRequest(bolusId: permission.bolusId),
                        authenticationKey: self.authKey,
                        pumpTimeSinceReset: time.signingTimestamp,
                        allowInsulinDelivery: true
                    )
                }
                cancelRequested = false
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard client.state == .ready else {
                return .uncertain(id: permission.bolusId, reason: "The connection dropped while insulin may have been moving. Check the pump before dosing again.")
            }
            guard let status = try? await request(CurrentBolusStatusRequest(), as: CurrentBolusStatusResponse.self) else {
                continue
            }
            if status.bolusId == permission.bolusId && !status.isActive {
                finished = true
                break
            }
            if status.bolusId != permission.bolusId && !status.isActive {
                finished = true
                break
            }
        }
        guard finished else {
            return .uncertain(id: permission.bolusId, reason: "The pump did not report that the bolus finished. Check the pump before dosing again.")
        }

        guard let last = try? await request(LastBolusStatusV2Request(), as: LastBolusStatusV2Response.self),
              last.bolusId == permission.bolusId
        else {
            return .uncertain(id: permission.bolusId, reason: "The pump finished a bolus but did not report how much was delivered.")
        }
        currentBolusID = 0
        return .delivered(last.deliveredUnits, id: permission.bolusId)
    }

    func requestCancel() {
        cancelRequested = true
    }

    func setTempPercent(_ percent: Int, minutes: Int) async throws {
        let message = try SetTempRateRequest(minutes: minutes, percent: percent)
        let response = try await deliveryRequest(message, as: SetTempRateResponse.self)
        guard response.accepted else {
            throw TandemX2Message.text("The pump rejected the temporary basal.")
        }
    }

    func stopTempRate() async throws {
        let response = try await deliveryRequest(StopTempRateRequest(), as: StopTempRateResponse.self)
        guard response.accepted else {
            throw TandemX2Message.text("The pump rejected the request to stop the temporary basal.")
        }
    }

    func suspend() async throws {
        let response = try await deliveryRequest(SuspendPumpingRequest(), as: SuspendPumpingResponse.self)
        guard response.accepted else {
            throw TandemX2Message.text("The pump rejected suspend.")
        }
    }

    func resume() async throws {
        let response = try await deliveryRequest(ResumePumpingRequest(), as: ResumePumpingResponse.self)
        guard response.accepted else {
            throw TandemX2Message.text("The pump rejected resume.")
        }
    }

    // MARK: - Requests

    private func deliveryRequest<M: Message, R: ResponseMessage>(_ message: M, as type: R.Type) async throws -> R {
        let time = try await request(TimeSinceResetRequest(), as: TimeSinceResetResponse.self)
        return try await client.withWritePolicy(.allowDelivery) {
            try await self.request(
                message,
                as: type,
                signed: true,
                allowDelivery: true,
                pumpTime: time.signingTimestamp,
                deadline: 8
            )
        }
    }

    private func request<M: Message, R: ResponseMessage>(
        _ message: M,
        as type: R.Type,
        signed: Bool = false,
        allowDelivery: Bool = false,
        pumpTime: UInt32 = 0,
        deadline: TimeInterval = 5
    ) async throws -> R {
        let frame = try await client.sendAwaitingResponse(
            message,
            authenticationKey: signed ? authKey : [],
            pumpTimeSinceReset: pumpTime,
            allowInsulinDelivery: allowDelivery,
            responseOpCode: nil,
            deadline: deadline,
            serialized: message.props.modifiesInsulinDelivery
        )
        let parsed = try ResponseParser.parse(
            frame: frame,
            characteristic: message.characteristic,
            authenticationKey: signed ? authKey : []
        )
        guard let typed = parsed.message as? R else {
            throw TandemX2Message.text("Unexpected pump response.")
        }
        return typed
    }

    private func startHandshake() {
        do {
            let coordinator: PairingCoordinator
            if derivedSecret.isEmpty {
                guard let pairingCode, pairingCode.count == 6 else { return }
                coordinator = try PairingCoordinator(pairingCode: pairingCode)
            } else {
                coordinator = PairingCoordinator(resumeDerivedSecret: derivedSecret)
            }
            coordinator.onSendRequest = { [weak self] message in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    try? self.client.send(message)
                }
            }
            coordinator.onPaired = { [weak self] key, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.authKey = key
                    if self.derivedSecret.isEmpty {
                        self.derivedSecret = coordinator.derivedSecret
                    }
                    self.isPaired = true
                    self.coordinator = nil
                    self.resumeWaiters()
                    self.onPaired?()
                    self.onChange?()
                }
            }
            coordinator.onError = { [weak self] error in
                MainActor.assumeIsolated {
                    self?.coordinator = nil
                    self?.failWaiters(error)
                    self?.onChange?()
                }
            }
            self.coordinator = coordinator
            coordinator.start()
        } catch {
            failWaiters(error)
        }
    }

    private func resumeWaiters() {
        let waiters = readyWaiters.values
        readyWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func failWaiters(_ error: Error) {
        let waiters = readyWaiters.values
        readyWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: error) }
    }

    // MARK: - PumpBLEClientDelegate

    nonisolated func pumpClient(_ client: PumpBLEClient, didChange state: PumpBLEClient.State) {
        MainActor.assumeIsolated {
            self.connectionState = state
            if state != .ready {
                self.isPaired = false
                self.authKey = []
            }
            self.onChange?()
        }
    }

    nonisolated func pumpClient(_ client: PumpBLEClient, didDiscover peripheral: CBPeripheral, rssi: Int) {
        MainActor.assumeIsolated {
            let name = peripheral.name ?? "Tandem pump"
            self.peripherals[peripheral.identifier] = peripheral
            let pump = TandemDiscoveredPump(id: peripheral.identifier, name: name, rssi: rssi)
            if let index = self.discovered.firstIndex(where: { $0.id == pump.id }) {
                self.discovered[index] = pump
            } else {
                self.discovered.append(pump)
            }
            self.onChange?()
        }
    }

    nonisolated func pumpClientDidBecomeReady(_ client: PumpBLEClient) {
        MainActor.assumeIsolated {
            self.connectionState = .ready
            self.setIdentity(name: self.pumpName.isEmpty ? "Tandem pump" : self.pumpName)
            self.startHandshake()
            self.onChange?()
        }
    }

    nonisolated func pumpClient(_ client: PumpBLEClient, didReceiveFrame frame: [UInt8], on characteristic: Characteristic) {
        MainActor.assumeIsolated {
            guard characteristic == .authorization, let coordinator = self.coordinator else { return }
            coordinator.handle(frame: frame)
        }
    }

    nonisolated func pumpClient(_ client: PumpBLEClient, didError error: Error) {
        MainActor.assumeIsolated {
            self.onChange?()
        }
    }

}
