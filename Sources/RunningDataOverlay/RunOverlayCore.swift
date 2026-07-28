import CoreGraphics
import Foundation

enum OverlayComponentKind: CaseIterable, Hashable, Sendable {
    case distance
    case pace
    case heartRate
    case cadence
    case strideLength
    case gpsTrack
    case elapsedTime
    case activityDateTime
    case weather
}

struct OverlayPositionSpec: Equatable, Sendable {
    let horizontal: Double
    let vertical: Double
}

enum OverlayDesign {
    static let defaultWindowWidthRatio: CGFloat = 0.70
    static let canvasReferenceSize = CGSize(width: 1_064, height: 598)
    static let badgeContentSpacing: CGFloat = 7
    static let metricValueUnitSpacing: CGFloat = badgeContentSpacing / 2
    static let badgeHorizontalPadding: CGFloat = 10
    static let badgeVerticalPadding: CGFloat = 6
    static let badgeCornerRadius: CGFloat = 5
    static let badgeBackgroundOpacity = 0.5

    static let distanceLength = 650.0
    static let distanceLineWidth = 4.0
    static let distanceLineHexColor = "#FFFFFF"
    static let distanceProgressHexColor = "#30D158"
    static let distanceEndpointFontSize = 16.0
    static let distanceCurrentFontSize = 18.0

    static let gpsRouteHexColor = "#63E677"
    static let gpsDefaultScale: CGFloat = 0.70
    static let gpsBaseSize = CGSize(width: 150, height: 190)
    static let weatherIconHexColor = "#FFFFFF"

    static func defaultWindowSize(forAvailableScreenSize screenSize: CGSize) -> CGSize {
        CGSize(
            width: max(1, (screenSize.width * defaultWindowWidthRatio).rounded()),
            height: max(1, screenSize.height)
        )
    }

    static func componentScale(forCanvasSize canvasSize: CGSize) -> CGFloat {
        max(
            0.01,
            min(
                canvasSize.width / canvasReferenceSize.width,
                canvasSize.height / canvasReferenceSize.height
            )
        )
    }

    static func gpsRenderScale(forComponentScale componentScale: CGFloat) -> CGFloat {
        componentScale * gpsDefaultScale
    }

    static func gpsRenderedSize(forComponentScale componentScale: CGFloat) -> CGSize {
        let scale = gpsRenderScale(forComponentScale: componentScale)
        return CGSize(
            width: gpsBaseSize.width * scale,
            height: gpsBaseSize.height * scale
        )
    }

    static func defaultPosition(for component: OverlayComponentKind) -> OverlayPositionSpec {
        switch component {
        case .distance:
            return OverlayPositionSpec(
                horizontal: 0.50,
                vertical: 0.07 + 10 / Double(canvasReferenceSize.height)
            )
        case .pace: return OverlayPositionSpec(horizontal: 0.06, vertical: 0.756)
        case .heartRate: return OverlayPositionSpec(horizontal: 0.06, vertical: 0.802)
        case .cadence: return OverlayPositionSpec(horizontal: 0.06, vertical: 0.848)
        case .strideLength: return OverlayPositionSpec(horizontal: 0.06, vertical: 0.894)
        case .gpsTrack: return OverlayPositionSpec(horizontal: 0.936, vertical: 0.25)
        case .elapsedTime: return OverlayPositionSpec(horizontal: 0.052, vertical: 0.94)
        case .activityDateTime: return OverlayPositionSpec(horizontal: 0.94, vertical: 0.922)
        case .weather: return OverlayPositionSpec(horizontal: 0.928, vertical: 0.841)
        }
    }

    static func showsIconByDefault(for component: OverlayComponentKind) -> Bool {
        component != .distance && component != .activityDateTime
    }

    static func iconScale(for component: OverlayComponentKind) -> CGFloat {
        switch component {
        case .pace: return 1.15
        case .cadence: return 0.84
        case .strideLength: return 1.30
        case .distance, .heartRate, .gpsTrack, .elapsedTime, .activityDateTime, .weather: return 1
        }
    }

    static func iconRotationDegrees(for component: OverlayComponentKind) -> Double {
        component == .cadence ? 30 : 0
    }

    static func reservesThreeDigitValueWidth(for component: OverlayComponentKind) -> Bool {
        component == .heartRate || component == .cadence || component == .strideLength
    }

    static func iconColumnWidth(fontSize: CGFloat) -> CGFloat {
        max(28, fontSize * 1.25)
    }

    static func metricValueWidthAllowance(
        for component: OverlayComponentKind,
        fontSize: CGFloat
    ) -> CGFloat? {
        guard isMetricBadge(component) else {
            return nil
        }
        return max(42, fontSize * 3)
    }

    static func fixedMetricContentWidth(
        for component: OverlayComponentKind,
        iconFontSize: CGFloat,
        valueFontSize: CGFloat,
        unitFontSize: CGFloat
    ) -> CGFloat? {
        guard let valueAllowance = metricValueWidthAllowance(for: component, fontSize: valueFontSize) else {
            return nil
        }
        let unitAllowance = max(30, unitFontSize * 2.2)
        return iconColumnWidth(fontSize: iconFontSize)
            + badgeContentSpacing * 2
            + valueAllowance
            + unitAllowance
    }

    static func fixedValueUnitContentWidth(
        for component: OverlayComponentKind,
        valueFontSize: CGFloat,
        unitFontSize: CGFloat
    ) -> CGFloat? {
        guard let valueAllowance = metricValueWidthAllowance(for: component, fontSize: valueFontSize) else {
            return nil
        }
        let unitAllowance = max(30, unitFontSize * 2.2)
        return valueAllowance + valueUnitSpacing(for: component) + unitAllowance
    }

    static func valueUnitSpacing(for component: OverlayComponentKind) -> CGFloat {
        isMetricBadge(component) ? metricValueUnitSpacing : badgeContentSpacing
    }

    private static func isMetricBadge(_ component: OverlayComponentKind) -> Bool {
        component == .pace
            || component == .heartRate
            || component == .cadence
            || component == .strideLength
    }
}

enum DistanceDisplayUnit: Sendable {
    case kilometers
    case miles

    var metersPerUnit: Double {
        switch self {
        case .kilometers: return 1_000
        case .miles: return 1_609.344
        }
    }

    var label: String {
        switch self {
        case .kilometers: return "km"
        case .miles: return "mi"
        }
    }
}

struct DistanceProgressCalculation: Equatable, Sendable {
    let startDistance: Double
    let currentDistance: Double
    let endDistance: Double
    let unit: String
    let progress: Double
    let kilometerTickProgresses: [Double]

    init(
        startDistance: Double,
        configuredEndDistance: Double,
        usesActivityEndDistance: Bool,
        activityEndDistanceMeters: Double?,
        currentDistanceMeters: Double?,
        unit displayUnit: DistanceDisplayUnit
    ) {
        let divisor = displayUnit.metersPerUnit
        let start = max(0, startDistance)
        let activityEnd = activityEndDistanceMeters.map { $0 / divisor }
        let configuredEnd = max(start, configuredEndDistance)
        let end = usesActivityEndDistance
            ? max(start, activityEnd ?? configuredEnd)
            : configuredEnd
        let current = max(0, currentDistanceMeters.map { $0 / divisor } ?? start)

        self.startDistance = start
        currentDistance = current
        endDistance = end
        unit = displayUnit.label
        if end > start {
            progress = min(max((current - start) / (end - start), 0), 1)
        } else {
            progress = current >= end ? 1 : 0
        }

        let startMeters = start * divisor
        let endMeters = end * divisor
        if endMeters > startMeters {
            let firstKilometer = Int(ceil(startMeters / 1_000))
            let lastKilometer = Int(floor(endMeters / 1_000))
            if firstKilometer <= lastKilometer {
                kilometerTickProgresses = (firstKilometer...lastKilometer).map { kilometer in
                    (Double(kilometer) * 1_000 - startMeters) / (endMeters - startMeters)
                }
            } else {
                kilometerTickProgresses = []
            }
        } else {
            kilometerTickProgresses = []
        }
    }
}

func formattedActivityDate(
    _ date: Date,
    timeZone: TimeZone = .current
) -> String {
    formattedDate(date, format: "yyyy-MM-dd HH:mm:ss", timeZone: timeZone)
}

func formattedActivityTime(
    _ date: Date,
    timeZone: TimeZone = .current
) -> String {
    formattedDate(date, format: "HH:mm:ss", timeZone: timeZone)
}

func formattedActivityDay(
    _ date: Date,
    timeZone: TimeZone = .current
) -> String {
    formattedDate(date, format: "yyyy/MM/dd", timeZone: timeZone)
}

func formattedActivityDuration(_ seconds: Double) -> String {
    guard seconds.isFinite else {
        return "00:00:00"
    }
    return formattedDuration(seconds)
}

func formattedExportDuration(_ seconds: Double) -> String {
    formattedDuration(seconds)
}

private func formattedDate(_ date: Date, format: String, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = timeZone
    formatter.dateFormat = format
    return formatter.string(from: date)
}

private func formattedDuration(_ seconds: Double) -> String {
    let finiteSeconds = seconds.isFinite ? seconds : 0
    let totalSeconds = max(0, Int(finiteSeconds.rounded(.down)))
    return String(
        format: "%02d:%02d:%02d",
        totalSeconds / 3_600,
        (totalSeconds % 3_600) / 60,
        totalSeconds % 60
    )
}

enum OverlayExportResolution: String, CaseIterable, Identifiable, Sendable {
    case source
    case fullHD
    case twoK
    case fourK

    var id: Self { self }

    var title: String {
        switch self {
        case .source: return "源视频"
        case .fullHD: return "1080p"
        case .twoK: return "2K"
        case .fourK: return "4K"
        }
    }

    private var shortEdgePixels: Double? {
        switch self {
        case .source: return nil
        case .fullHD: return 1_080
        case .twoK: return 1_440
        case .fourK: return 2_160
        }
    }

    func resolution(matching sourceResolution: CGSize) -> CGSize {
        let sourceWidth = max(1, sourceResolution.width)
        let sourceHeight = max(1, sourceResolution.height)
        guard let shortEdgePixels else {
            return CGSize(
                width: evenDimension(sourceWidth),
                height: evenDimension(sourceHeight)
            )
        }
        let scale = shortEdgePixels / min(sourceWidth, sourceHeight)
        return CGSize(
            width: evenDimension(sourceWidth * scale),
            height: evenDimension(sourceHeight * scale)
        )
    }

    private func evenDimension(_ value: Double) -> Double {
        Double(max(2, Int(value.rounded()) / 2 * 2))
    }
}

enum OverlayExportFrameRate: Int32, CaseIterable, Identifiable, Sendable {
    case fps30 = 30
    case fps60 = 60

    var id: Self { self }
    var title: String { "\(rawValue) fps" }
}

enum OverlayVideoEncoding {
    static let keyFrameIntervalSeconds: Int32 = 5

    static func averageBitRate(width: Int, height: Int, framesPerSecond: Int32) -> Int {
        let pixelCount = max(1, width * height)
        let frameRateFactor = sqrt(Double(framesPerSecond) / 30)
        return max(
            Int((1_000_000 * frameRateFactor).rounded()),
            Int((Double(pixelCount) * 0.75 * frameRateFactor).rounded())
        )
    }

    static func estimatedFileSize(
        width: Int,
        height: Int,
        framesPerSecond: Int32,
        duration: Double
    ) -> Int64 {
        let bitRate = averageBitRate(
            width: width,
            height: height,
            framesPerSecond: framesPerSecond
        )
        let videoBytes = Double(bitRate) * max(0, duration) / 8
        return Int64((videoBytes * 1.03).rounded())
    }
}
