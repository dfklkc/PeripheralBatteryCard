import Foundation

/// 合并有共同硬件标识的来源，并为已识别的设备保留有限期的上次电量。
public final class BatteryAggregator {
    private struct Reading {
        let level: Int?
        let subBatteries: [SubBattery]
        let observedAt: Date
        let serial: String?

        init?(_ device: PeripheralDevice) {
            guard device.effectiveBatteryLevel != nil else { return nil }
            level = device.batteryLevel
            subBatteries = device.subBatteries
            observedAt = device.batteryReadingAt ?? device.lastUpdated
            serial = PeripheralDevice.normalizedSerial(device.serialNumber)
        }
    }

    private var sleepCache: [String: Reading] = [:]
    private var ambiguousLegacyIDs = Set<String>()
    private let cacheTTL: TimeInterval

    public init(cacheTTL: TimeInterval = 1800) {
        self.cacheTTL = cacheTTL
    }

    public func aggregate(
        results: [ProviderResult], now: Date = Date(), freshFor: TimeInterval = 120
    ) -> (devices: [PeripheralDevice], diagnostics: [DiagnosticEntry]) {
        let allDevices = results.flatMap(\.devices)
        let receivers = allDevices.filter { $0.source == .vendorHID && slot(in: $0.id) != nil }
        var merged: [PeripheralDevice] = []

        // Resolve the records carrying the most hardware information before considering records with gaps.
        for incoming in allDevices.sorted(by: moreIdentifying) {
            if incoming.source == .usbInventory && receivers.contains(where: { sameHardware($0, incoming) }) {
                continue
            }
            let matches = merged.indices.filter { isSameDevice(merged[$0], incoming) }
            if matches.count == 1, let index = matches.first {
                merged[index] = merge(merged[index], incoming, now: now, freshFor: freshFor)
            } else {
                merged.append(incoming)
            }
        }

        assignDeviceIDs(&merged)
        let cacheKeyCounts = merged.compactMap(cacheKey).reduce(into: [String: Int]()) { counts, key in
            counts[key, default: 0] += 1
        }
        sleepCache = sleepCache.filter { key, reading in
            let age = now.timeIntervalSince(reading.observedAt)
            return cacheKeyCounts[key] == 1 && age >= 0 && age <= cacheTTL
        }
        for index in merged.indices {
            let key = cacheKey(merged[index]).flatMap { cacheKeyCounts[$0] == 1 ? $0 : nil }
            applyBatteryReading(to: &merged[index], cacheKey: key, now: now, freshFor: freshFor)
        }

        merged.sort { lhs, rhs in
            if lhs.isExternal != rhs.isExternal { return lhs.isExternal && !rhs.isExternal }
            let lhsHasLevel = lhs.effectiveBatteryLevel != nil
            let rhsHasLevel = rhs.effectiveBatteryLevel != nil
            if lhsHasLevel != rhsHasLevel { return lhsHasLevel }
            if lhs.requiresInputMonitoring != rhs.requiresInputMonitoring { return lhs.requiresInputMonitoring }
            let comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
        return (merged, results.flatMap(\.diagnostics))
    }

    private func moreIdentifying(_ lhs: PeripheralDevice, _ rhs: PeripheralDevice) -> Bool {
        func evidence(_ device: PeripheralDevice) -> Int {
            let hasAddress = PeripheralDevice.normalizedBluetoothAddress(device.bluetoothAddress) != nil
            let hasSerial = PeripheralDevice.normalizedSerial(device.serialNumber) != nil
            return (hasAddress ? 4 : 0) + (hasSerial ? 2 : 0) + (device.physicalLocationID != nil ? 1 : 0)
        }
        let lhsEvidence = evidence(lhs)
        let rhsEvidence = evidence(rhs)
        if lhsEvidence != rhsEvidence { return lhsEvidence > rhsEvidence }
        if lhs.source.priority != rhs.source.priority { return lhs.source.priority > rhs.source.priority }
        return lhs.id < rhs.id
    }

    private func isSameDevice(_ a: PeripheralDevice, _ b: PeripheralDevice) -> Bool {
        guard slot(in: a.id) == slot(in: b.id) else { return false }
        return sameHardware(a, b) || (a.id == b.id && stableProviderID(a) && stableProviderID(b))
    }

    private func sameHardware(_ a: PeripheralDevice, _ b: PeripheralDevice) -> Bool {
        let serialA = PeripheralDevice.normalizedSerial(a.serialNumber)
        let serialB = PeripheralDevice.normalizedSerial(b.serialNumber)
        if let serialA, let serialB, serialA != serialB { return false }
        if let addressA = PeripheralDevice.normalizedBluetoothAddress(a.bluetoothAddress),
           let addressB = PeripheralDevice.normalizedBluetoothAddress(b.bluetoothAddress) {
            return addressA == addressB
        }
        guard let vendor = a.vendorID, vendor == b.vendorID,
              let product = a.productID, product == b.productID else { return false }
        if let locationA = a.physicalLocationID, let locationB = b.physicalLocationID {
            return locationA == locationB
        }
        return serialA != nil && serialA == serialB
    }

    private func stableProviderID(_ device: PeripheralDevice) -> Bool {
        if device.id == "internal-battery" { return !device.isExternal }
        if device.source == .coreBluetoothBAS && device.id.hasPrefix("ble-") {
            return UUID(uuidString: String(device.id.dropFirst(4))) != nil
        }
        return false
    }

    private func slot(in id: String) -> String? {
        guard let separator = id.range(of: "-slot", options: .backwards) else { return nil }
        let suffix = id[separator.upperBound...]
        return suffix.isEmpty || !suffix.allSatisfy(\.isNumber) ? nil : String(suffix)
    }

    private func merge(
        _ first: PeripheralDevice, _ second: PeripheralDevice, now: Date, freshFor: TimeInterval
    ) -> PeripheralDevice {
        let firstIsPrimary = first.source.priority >= second.source.priority
        var primary = firstIsPrimary ? first : second
        let secondary = firstIsPrimary ? second : first
        primary.legacyIDs = Array(Set((primary.legacyIDs ?? []) + (secondary.legacyIDs ?? []) + [secondary.id]))
        primary.isConnected = primary.isConnected || secondary.isConnected
        if primary.voltageMillivolts == nil { primary.voltageMillivolts = secondary.voltageMillivolts }
        if primary.category == .other { primary.category = secondary.category }
        if primary.transport == .unknown { primary.transport = secondary.transport }
        if primary.vendorID == nil { primary.vendorID = secondary.vendorID }
        if primary.productID == nil { primary.productID = secondary.productID }
        if primary.serialNumber == nil { primary.serialNumber = secondary.serialNumber }
        if primary.bluetoothAddress == nil { primary.bluetoothAddress = secondary.bluetoothAddress }
        if primary.physicalLocationID == nil { primary.physicalLocationID = secondary.physicalLocationID }

        let primaryQuality = readingQuality(primary, now: now, freshFor: freshFor)
        let secondaryQuality = readingQuality(secondary, now: now, freshFor: freshFor)
        let preferNewerStaleReading = primaryQuality == 1 && secondaryQuality == 1
            && (secondary.batteryReadingAt ?? secondary.lastUpdated) > (primary.batteryReadingAt ?? primary.lastUpdated)
        if secondaryQuality > primaryQuality || preferNewerStaleReading {
            primary.batteryLevel = secondary.batteryLevel
            primary.subBatteries = secondary.subBatteries
            primary.batteryReadingAt = secondary.batteryReadingAt ?? secondary.lastUpdated
            primary.batteryReadingIsStale = secondary.batteryReadingIsStale
            primary.lastUpdated = secondary.lastUpdated
            primary.chargingState = secondary.chargingState
            primary.source = secondary.source
            primary.sourceDetail = secondary.sourceDetail
            primary.statusHint = secondary.statusHint
        } else if primaryQuality == 2, secondaryQuality == 2,
                  secondary.subBatteries.count > primary.subBatteries.count {
            primary.subBatteries = secondary.subBatteries
            let observedAt = min(primary.batteryReadingAt ?? primary.lastUpdated,
                                 secondary.batteryReadingAt ?? secondary.lastUpdated)
            primary.batteryReadingAt = observedAt
            primary.lastUpdated = observedAt
        }
        primary.requiresInputMonitoring = max(primaryQuality, secondaryQuality) == 0
            && (primary.requiresInputMonitoring || secondary.requiresInputMonitoring)
        return primary
    }

    private func readingQuality(_ device: PeripheralDevice, now: Date, freshFor: TimeInterval) -> Int {
        guard let reading = Reading(device) else { return 0 }
        let age = now.timeIntervalSince(reading.observedAt)
        guard age >= 0 && age <= cacheTTL else { return 0 }
        return age <= freshFor && !device.hasStaleBatteryReading && device.chargingState != .sleeping ? 2 : 1
    }

    private func assignDeviceIDs(_ devices: inout [PeripheralDevice]) {
        for index in devices.indices {
            let device = devices[index]
            guard PeripheralDevice.normalizedBluetoothAddress(device.bluetoothAddress) == nil,
                  PeripheralDevice.normalizedSerial(device.serialNumber) == nil,
                  let vendor = device.vendorID, let product = device.productID,
                  let location = device.physicalLocationID else { continue }
            let model = String(format: "hid-%04x-%04x", vendor, product)
            let slotSuffix = slot(in: device.id).map { "-slot\($0)" } ?? ""
            devices[index].id = "\(model)-location-\(String(location, radix: 16))\(slotSuffix)"
            devices[index].legacyIDs = (device.legacyIDs ?? []) + [device.id]
        }

        let conflicting = Dictionary(grouping: devices.indices, by: { devices[$0].id }).values.filter { $0.count > 1 }
        for indices in conflicting {
            for (offset, index) in indices.enumerated() {
                let device = devices[index]
                ambiguousLegacyIDs.insert(device.id)
                let location = device.physicalLocationID.map { "-location-\(String($0, radix: 16))" } ?? ""
                let suffix = "\(location)-\(device.source.rawValue)-\(offset + 1)"
                devices[index].id += suffix
            }
        }

        let canonicalIDs = Set(devices.map(\.id))
        let legacyOwners = devices.flatMap { Set($0.legacyIDs ?? []) }.reduce(into: [String: Int]()) { counts, id in
            counts[id, default: 0] += 1
        }
        ambiguousLegacyIDs.formUnion(legacyOwners.filter { $0.value > 1 }.keys)
        for index in devices.indices {
            let unique = Set(devices[index].legacyIDs ?? []).filter {
                legacyOwners[$0] == 1 && !canonicalIDs.contains($0) && !ambiguousLegacyIDs.contains($0)
            }.sorted()
            devices[index].legacyIDs = unique.isEmpty ? nil : unique
        }
    }

    private func cacheKey(_ device: PeripheralDevice) -> String? {
        if let group = device.diagnosticGroupKey {
            return group + (slot(in: device.id).map { "-slot\($0)" } ?? "")
        }
        return stableProviderID(device) ? device.id : nil
    }

    private func applyBatteryReading(
        to device: inout PeripheralDevice, cacheKey: String?, now: Date, freshFor: TimeInterval
    ) {
        let reading = Reading(device)
        let quality = readingQuality(device, now: now, freshFor: freshFor)
        if !device.isConnected || device.requiresInputMonitoring {
            if let cacheKey { sleepCache.removeValue(forKey: cacheKey) }
            return
        }
        if let cacheKey, let cachedSerial = sleepCache[cacheKey]?.serial,
           let serial = PeripheralDevice.normalizedSerial(device.serialNumber), cachedSerial != serial {
            sleepCache.removeValue(forKey: cacheKey)
        }
        let cached = cacheKey.flatMap { sleepCache[$0] }
        if let cacheKey, let reading, quality > 0, cached.map({ reading.observedAt > $0.observedAt }) ?? true {
            sleepCache[cacheKey] = reading
        }
        if quality == 2 { return }

        let lastKnown = [quality == 1 ? reading : nil, cached].compactMap { $0 }.max { $0.observedAt < $1.observedAt }
        if let lastKnown {
            device.batteryLevel = lastKnown.level
            device.subBatteries = lastKnown.subBatteries
            device.batteryReadingAt = lastKnown.observedAt
            device.lastUpdated = lastKnown.observedAt
            device.batteryReadingIsStale = true
            if device.chargingState == .sleeping {
                device.statusHint = "休眠中 · 上次电量"
            } else if device.statusHint == nil || device.source == .usbInventory {
                device.statusHint = "上次电量"
            }
            return
        }
        if reading != nil {
            device.batteryLevel = nil
            device.subBatteries = []
            device.batteryReadingIsStale = true
            device.statusHint = device.statusHint ?? "电量未更新"
        }
    }
}
