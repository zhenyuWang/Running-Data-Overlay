import Foundation

struct FitActivity {
    let startDate: Date?
    let endDate: Date?
    let totalDistanceMeters: Double?
    let averageSpeedMetersPerSecond: Double?
    let averageHeartRate: Int?
    let averageCadence: Int?
    let averageStrideLengthMeters: Double?
    let gpsPoints: [FitGPSPoint]
    let averageTemperatureCelsius: Double?
    let samples: [FitDataPoint]

    var weatherSummary: String {
        guard let averageTemperatureCelsius else {
            return "FIT 未记录天气信息"
        }
        return String(format: "平均温度 %.0f°C", averageTemperatureCelsius)
    }

    func sample(at elapsedSeconds: Double) -> FitDataPoint? {
        guard let startDate else {
            return samples.last
        }

        let targetDate = startDate.addingTimeInterval(max(0, elapsedSeconds))
        var lowerBound = 0
        var upperBound = samples.count

        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            if samples[midpoint].timestamp <= targetDate {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }

        return lowerBound > 0 ? samples[lowerBound - 1] : samples.first
    }

    func strideLength(at elapsedSeconds: Double) -> Double? {
        guard let sample = sample(at: elapsedSeconds),
              let speed = sample.speedMetersPerSecond,
              let cadence = sample.cadence,
              speed > 0,
              cadence > 0 else {
            return averageStrideLengthMeters
        }
        return speed * 60 / Double(cadence)
    }
}

struct FitDataPoint {
    let timestamp: Date
    let distanceMeters: Double?
    let speedMetersPerSecond: Double?
    let heartRate: Int?
    let cadence: Int?
    let latitude: Double?
    let longitude: Double?
    let temperatureCelsius: Double?
}

struct FitGPSPoint {
    let latitude: Double
    let longitude: Double
    let timestamp: Date?
}

enum FitParserError: LocalizedError {
    case invalidHeader
    case truncatedFile

    var errorDescription: String? {
        switch self {
        case .invalidHeader:
            return "FIT 文件头无效。"
        case .truncatedFile:
            return "FIT 文件不完整。"
        }
    }
}

enum FitParser {
    static func parse(url: URL) throws -> FitActivity {
        let bytes = Array(try Data(contentsOf: url, options: .mappedIfSafe))
        guard bytes.count >= 12,
              bytes[8] == 0x2E,
              bytes[9] == 0x46,
              bytes[10] == 0x49,
              bytes[11] == 0x54 else {
            throw FitParserError.invalidHeader
        }

        let headerSize = Int(bytes[0])
        let dataSize = Int(readFitUnsigned(bytes, at: 4, count: 4, architecture: .little))
        let dataEnd = headerSize + dataSize
        guard headerSize >= 12, dataEnd <= bytes.count else {
            throw FitParserError.truncatedFile
        }

        var parser = FitBinaryParser(bytes: bytes, dataStart: headerSize, dataEnd: dataEnd)
        return try parser.parseActivity()
    }
}

private struct FitBinaryParser {
    let bytes: [UInt8]
    let dataEnd: Int
    var index: Int
    var definitions: [UInt8: FitMessageDefinition] = [:]
    var lastTimestamp: UInt32?
    var records: [FitRecord] = []
    var session: FitSession?

    init(bytes: [UInt8], dataStart: Int, dataEnd: Int) {
        self.bytes = bytes
        index = dataStart
        self.dataEnd = dataEnd
    }

    mutating func parseActivity() throws -> FitActivity {
        while index < dataEnd {
            let header = try readByte()
            if header & 0x80 != 0 {
                let localMessageType = (header >> 5) & 0x03
                let compressedTimestampOffset = header & 0x1F
                try parseDataMessage(
                    localMessageType: localMessageType,
                    compressedTimestampOffset: compressedTimestampOffset
                )
            } else if header & 0x40 != 0 {
                try parseDefinitionMessage(localMessageType: header & 0x0F, hasDeveloperFields: header & 0x20 != 0)
            } else {
                try parseDataMessage(localMessageType: header & 0x0F, compressedTimestampOffset: nil)
            }
        }

        return makeActivity()
    }

    private mutating func parseDefinitionMessage(localMessageType: UInt8, hasDeveloperFields: Bool) throws {
        _ = try readByte()
        guard let architecture = FitArchitecture(rawValue: try readByte()) else {
            throw FitParserError.invalidHeader
        }
        let globalMessageNumber = try readUnsigned(count: 2, architecture: architecture)
        let fieldCount = Int(try readByte())

        var fields: [FitFieldDefinition] = []
        for _ in 0..<fieldCount {
            fields.append(
                FitFieldDefinition(
                    number: try readByte(),
                    size: Int(try readByte()),
                    baseType: try readByte()
                )
            )
        }

        var developerFieldSizes: [Int] = []
        if hasDeveloperFields {
            let developerFieldCount = Int(try readByte())
            for _ in 0..<developerFieldCount {
                _ = try readByte()
                developerFieldSizes.append(Int(try readByte()))
                _ = try readByte()
            }
        }

        definitions[localMessageType] = FitMessageDefinition(
            globalMessageNumber: globalMessageNumber,
            fields: fields,
            developerFieldSizes: developerFieldSizes,
            architecture: architecture
        )
    }

    private mutating func parseDataMessage(
        localMessageType: UInt8,
        compressedTimestampOffset: UInt8?
    ) throws {
        guard let definition = definitions[localMessageType] else {
            throw FitParserError.truncatedFile
        }

        let payload = try readBytes(count: definition.payloadSize)
        var cursor = 0
        var values: [UInt8: Double] = [:]
        for field in definition.fields {
            let fieldBytes = Array(payload[cursor..<(cursor + field.size)])
            cursor += field.size
            if let value = decodeNumericValue(fieldBytes, baseType: field.baseType, architecture: definition.architecture) {
                values[field.number] = value
            }
        }

        let timestamp: UInt32?
        if let rawTimestamp = values[253] {
            timestamp = UInt32(rawTimestamp)
        } else if let compressedTimestampOffset, let lastTimestamp {
            var resolvedTimestamp = (lastTimestamp & ~UInt32(0x1F)) | UInt32(compressedTimestampOffset)
            if resolvedTimestamp < lastTimestamp {
                resolvedTimestamp += 0x20
            }
            timestamp = resolvedTimestamp
        } else {
            timestamp = nil
        }

        if let timestamp {
            lastTimestamp = timestamp
        }

        switch definition.globalMessageNumber {
        case 20:
            records.append(FitRecord(values: values, timestamp: timestamp))
        case 18:
            session = FitSession(values: values, timestamp: timestamp)
        default:
            break
        }
    }

    private func makeActivity() -> FitActivity {
        let sessionStart = session?.startTimestamp.map(fitDate)
        let recordDates = records.compactMap { $0.timestamp.map(fitDate) }
        let startDate = sessionStart ?? recordDates.min()
        let endDate = session?.timestamp.map(fitDate) ?? recordDates.max()

        let totalDistance = session?.totalDistanceMeters ?? records.compactMap(\.distanceMeters).max()
        let averageSpeed = session?.averageSpeedMetersPerSecond ?? average(records.compactMap(\.speedMetersPerSecond))
        let averageHeartRate = session?.averageHeartRate ?? average(records.compactMap(\.heartRate)).map { Int($0.rounded()) }
        let averageCadence = session?.averageCadence ?? average(records.compactMap(\.cadence)).map { Int($0.rounded()) }

        let gpsPoints = records.compactMap { record -> FitGPSPoint? in
            guard let latitude = record.latitude, let longitude = record.longitude else {
                return nil
            }
            return FitGPSPoint(latitude: latitude, longitude: longitude, timestamp: record.timestamp.map(fitDate))
        }

        let samples = records.compactMap { record -> FitDataPoint? in
            guard let timestamp = record.timestamp else {
                return nil
            }
            return FitDataPoint(
                timestamp: fitDate(timestamp),
                distanceMeters: record.distanceMeters,
                speedMetersPerSecond: record.speedMetersPerSecond,
                heartRate: record.heartRate,
                cadence: record.cadence,
                latitude: record.latitude,
                longitude: record.longitude,
                temperatureCelsius: record.temperatureCelsius
            )
        }

        return FitActivity(
            startDate: startDate,
            endDate: endDate,
            totalDistanceMeters: totalDistance,
            averageSpeedMetersPerSecond: averageSpeed,
            averageHeartRate: averageHeartRate,
            averageCadence: averageCadence,
            averageStrideLengthMeters: calculateAverageStrideLength(),
            gpsPoints: gpsPoints,
            averageTemperatureCelsius: average(records.compactMap(\.temperatureCelsius)),
            samples: samples
        )
    }

    private func calculateAverageStrideLength() -> Double? {
        var totalDistance = 0.0
        var totalCycles = 0.0
        for (previous, current) in zip(records, records.dropFirst()) {
            guard let previousDistance = previous.distanceMeters,
                  let currentDistance = current.distanceMeters,
                  let previousTimestamp = previous.timestamp,
                  let currentTimestamp = current.timestamp,
                  let cadence = current.cadence else {
                continue
            }

            let distanceDelta = currentDistance - previousDistance
            let duration = Double(currentTimestamp - previousTimestamp)
            guard distanceDelta >= 0, distanceDelta <= 20, duration > 0, duration <= 10, cadence > 0 else {
                continue
            }

            totalDistance += distanceDelta
            totalCycles += Double(cadence) * duration / 60
        }

        guard totalCycles > 0 else {
            return nil
        }
        return totalDistance / totalCycles
    }

    private mutating func readByte() throws -> UInt8 {
        guard index < dataEnd else {
            throw FitParserError.truncatedFile
        }
        defer { index += 1 }
        return bytes[index]
    }

    private mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, index + count <= dataEnd else {
            throw FitParserError.truncatedFile
        }
        defer { index += count }
        return Array(bytes[index..<(index + count)])
    }

    private mutating func readUnsigned(count: Int, architecture: FitArchitecture) throws -> UInt16 {
        let value = try readBytes(count: count)
        return UInt16(readFitUnsigned(value, at: 0, count: count, architecture: architecture))
    }
}

private struct FitRecord {
    let timestamp: UInt32?
    let distanceMeters: Double?
    let speedMetersPerSecond: Double?
    let heartRate: Int?
    let cadence: Int?
    let latitude: Double?
    let longitude: Double?
    let temperatureCelsius: Double?

    init(values: [UInt8: Double], timestamp: UInt32?) {
        self.timestamp = timestamp
        distanceMeters = values[5].map { $0 / 100 }
        speedMetersPerSecond = values[6].map { $0 / 1_000 }
        heartRate = values[3].map { Int($0) }
        cadence = values[4].map { Int($0) * 2 }
        latitude = values[0].map { $0 * 180 / 2_147_483_648 }
        longitude = values[1].map { $0 * 180 / 2_147_483_648 }
        temperatureCelsius = values[13]
    }
}

private struct FitSession {
    let timestamp: UInt32?
    let startTimestamp: UInt32?
    let totalDistanceMeters: Double?
    let averageSpeedMetersPerSecond: Double?
    let averageHeartRate: Int?
    let averageCadence: Int?

    init(values: [UInt8: Double], timestamp: UInt32?) {
        self.timestamp = timestamp
        startTimestamp = values[2].map(UInt32.init)
        totalDistanceMeters = values[9].map { $0 / 100 }
        averageSpeedMetersPerSecond = values[14].map { $0 / 1_000 }
        averageHeartRate = values[16].map { Int($0) }
        averageCadence = values[18].map { Int($0) * 2 }
    }
}

private struct FitMessageDefinition {
    let globalMessageNumber: UInt16
    let fields: [FitFieldDefinition]
    let developerFieldSizes: [Int]
    let architecture: FitArchitecture

    var payloadSize: Int {
        fields.reduce(0) { $0 + $1.size } + developerFieldSizes.reduce(0, +)
    }
}

private struct FitFieldDefinition {
    let number: UInt8
    let size: Int
    let baseType: UInt8
}

private enum FitArchitecture: UInt8 {
    case little = 0
    case big = 1
}

private func decodeNumericValue(_ bytes: [UInt8], baseType: UInt8, architecture: FitArchitecture) -> Double? {
    let type = baseType & 0x1F
    let unsigned = readFitUnsigned(bytes, at: 0, count: bytes.count, architecture: architecture)

    switch type {
    case 0, 2:
        guard unsigned != 0xFF else { return nil }
        return Double(unsigned)
    case 1:
        guard unsigned != 0x7F else { return nil }
        return Double(Int8(bitPattern: UInt8(unsigned)))
    case 3:
        guard unsigned != 0x7FFF else { return nil }
        return Double(Int16(bitPattern: UInt16(unsigned)))
    case 4:
        guard unsigned != 0xFFFF else { return nil }
        return Double(unsigned)
    case 5:
        guard unsigned != 0x7FFF_FFFF else { return nil }
        return Double(Int32(bitPattern: UInt32(unsigned)))
    case 6:
        guard unsigned != 0xFFFF_FFFF else { return nil }
        return Double(unsigned)
    default:
        return nil
    }
}

private func readFitUnsigned(_ bytes: [UInt8], at index: Int, count: Int, architecture: FitArchitecture) -> UInt64 {
    let range = bytes[index..<(index + count)]
    switch architecture {
    case .little:
        return range.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
    case .big:
        return range.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

func fitDate(_ timestamp: UInt32) -> Date {
    Date(timeIntervalSince1970: TimeInterval(timestamp) + 631_065_600)
}

private func average<T: BinaryInteger>(_ values: [T]) -> Double? {
    guard !values.isEmpty else { return nil }
    return Double(values.reduce(0, +)) / Double(values.count)
}

private func average(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
}
