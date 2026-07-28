import Foundation

@main
struct FitParserSmokeTest {
    static func main() throws {
        guard fitDate(0) == Date(timeIntervalSince1970: 631_065_600) else {
            throw SmokeTestError.invalidFitEpochConversion
        }

        let fileURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let activity = try FitParser.parse(url: fileURL)

        guard let distance = activity.totalDistanceMeters, distance > 0,
              !activity.gpsPoints.isEmpty,
              !activity.samples.isEmpty,
              activity.averageHeartRate != nil,
              activity.averageCadence != nil,
              activity.startDate != nil else {
            throw SmokeTestError.expectedActivityDataMissing
        }

        let temperatures = activity.samples.compactMap(\.temperatureCelsius)
        let temperatureSummary: String
        if let first = temperatures.first, let last = temperatures.last, let average = activity.averageTemperatureCelsius {
            temperatureSummary = String(
                format: "temperature: %.0f C start, %.0f C end, %.1f C average (%d samples)",
                first,
                last,
                average,
                temperatures.count
            )
        } else {
            temperatureSummary = "temperature: not recorded"
        }

        print("FIT parsed: \(Int(distance)) m, \(activity.gpsPoints.count) GPS points; \(temperatureSummary)")
    }
}

private enum SmokeTestError: LocalizedError {
    case expectedActivityDataMissing
    case invalidFitEpochConversion

    var errorDescription: String? {
        switch self {
        case .expectedActivityDataMissing:
            return "测试 FIT 文件缺少预期的跑步数据。"
        case .invalidFitEpochConversion:
            return "FIT 时间戳基准转换错误。"
        }
    }
}
