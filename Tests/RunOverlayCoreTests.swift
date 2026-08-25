import CoreGraphics
import Foundation
import Testing
@testable import RunOverlayCore

@Suite("FIT activity behavior")
struct FitActivityTests {
    private let startDate = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("FIT epoch is converted from 1989-12-31 UTC")
    func fitEpochConversion() {
        #expect(fitDate(0) == Date(timeIntervalSince1970: 631_065_600))
        #expect(fitDate(1) == Date(timeIntervalSince1970: 631_065_601))
    }

    @Test("Timeline sampling selects the latest sample at or before the target")
    func timelineSampling() {
        let activity = makeActivity(samples: [
            sample(offset: 0, heartRate: 120),
            sample(offset: 10, heartRate: 130),
            sample(offset: 20, heartRate: 140)
        ])

        #expect(activity.sample(at: -5)?.heartRate == 120)
        #expect(activity.sample(at: 0)?.heartRate == 120)
        #expect(activity.sample(at: 15)?.heartRate == 130)
        #expect(activity.sample(at: 20)?.heartRate == 140)
        #expect(activity.sample(at: 200)?.heartRate == 140)
    }

    @Test("Stride length uses current speed and cadence")
    func strideLengthFromSample() {
        let activity = makeActivity(samples: [
            sample(offset: 0, speed: 3, cadence: 180)
        ], averageStrideLength: 0.92)

        #expect(activity.strideLength(at: 0) == 1)
    }

    @Test("Stride length falls back to the activity average when sample data is incomplete")
    func strideLengthFallback() {
        let activity = makeActivity(samples: [
            sample(offset: 0, speed: 3, cadence: nil)
        ], averageStrideLength: 0.92)

        #expect(activity.strideLength(at: 0) == 0.92)
    }

    @Test("Invalid and truncated FIT files report parser errors")
    func parserErrors() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let invalidURL = temporaryDirectory.appendingPathComponent("invalid.fit")
        try Data(repeating: 0, count: 12).write(to: invalidURL)
        #expect(throws: FitParserError.invalidHeader) {
            try FitParser.parse(url: invalidURL)
        }

        var truncatedHeader = [UInt8](repeating: 0, count: 12)
        truncatedHeader[0] = 12
        truncatedHeader[4] = 100
        truncatedHeader[8...11] = [0x2E, 0x46, 0x49, 0x54]
        let truncatedURL = temporaryDirectory.appendingPathComponent("truncated.fit")
        try Data(truncatedHeader).write(to: truncatedURL)
        #expect(throws: FitParserError.truncatedFile) {
            try FitParser.parse(url: truncatedURL)
        }
    }

    @Test("Movement timer excludes paused intervals")
    func movementTimer() {
        let activity = FitActivity(
            startDate: startDate,
            endDate: startDate.addingTimeInterval(120),
            totalDistanceMeters: nil,
            averageSpeedMetersPerSecond: nil,
            averageHeartRate: nil,
            averageCadence: nil,
            averageStrideLengthMeters: nil,
            gpsPoints: [],
            averageTemperatureCelsius: nil,
            samples: [],
            totalTimerTimeSeconds: 90,
            timerIntervals: [
                FitTimerInterval(
                    startDate: startDate,
                    endDate: startDate.addingTimeInterval(60)
                ),
                FitTimerInterval(
                    startDate: startDate.addingTimeInterval(90),
                    endDate: startDate.addingTimeInterval(120)
                )
            ]
        )

        #expect(activity.timerElapsedTime(at: 45) == 45)
        #expect(activity.timerElapsedTime(at: 75) == 60)
        #expect(activity.timerElapsedTime(at: 100) == 70)
        #expect(activity.timerElapsedTime(at: 120) == 90)
        #expect(activity.timerResumeDates == [startDate.addingTimeInterval(90)])
        #expect(activity.isTimerRunning(at: 45))
        #expect(!activity.isTimerRunning(at: 75))
        #expect(activity.isTimerRunning(at: 100))
        #expect(!activity.isTimerRunning(at: 120))
    }

    private func sample(
        offset: TimeInterval,
        heartRate: Int? = nil,
        speed: Double? = nil,
        cadence: Int? = nil
    ) -> FitDataPoint {
        FitDataPoint(
            timestamp: startDate.addingTimeInterval(offset),
            distanceMeters: nil,
            speedMetersPerSecond: speed,
            heartRate: heartRate,
            cadence: cadence,
            latitude: nil,
            longitude: nil,
            temperatureCelsius: nil
        )
    }

    private func makeActivity(
        samples: [FitDataPoint],
        averageStrideLength: Double? = nil
    ) -> FitActivity {
        FitActivity(
            startDate: startDate,
            endDate: startDate.addingTimeInterval(60),
            totalDistanceMeters: nil,
            averageSpeedMetersPerSecond: nil,
            averageHeartRate: nil,
            averageCadence: nil,
            averageStrideLengthMeters: averageStrideLength,
            gpsPoints: [],
            averageTemperatureCelsius: nil,
            samples: samples
        )
    }
}

@Suite("Overlay design contract")
struct OverlayDesignTests {
    @Test("Default window fills screen height and uses 70 percent width")
    func defaultWindowSize() {
        let size = OverlayDesign.defaultWindowSize(
            forAvailableScreenSize: CGSize(width: 1_440, height: 900)
        )

        #expect(size == CGSize(width: 1_008, height: 900))
        #expect(OverlayDesign.defaultWindowWidthRatio == 0.70)
    }

    @Test("Component scale follows the limiting canvas dimension")
    func componentScale() {
        #expect(OverlayDesign.componentScale(
            forCanvasSize: OverlayDesign.canvasReferenceSize
        ) == 1)
        #expect(OverlayDesign.componentScale(
            forCanvasSize: CGSize(width: 2_128, height: 1_196)
        ) == 2)
        #expect(OverlayDesign.componentScale(
            forCanvasSize: CGSize(width: 2_128, height: 598)
        ) == 1)
        #expect(OverlayDesign.componentScale(forCanvasSize: .zero) == 0.01)
    }

    @Test("All component default positions remain stable")
    func defaultPositions() {
        let expected: [OverlayComponentKind: OverlayPositionSpec] = [
            .distance: OverlayPositionSpec(
                horizontal: 0.50,
                vertical: 0.07 + 10 / Double(OverlayDesign.canvasReferenceSize.height)
            ),
            .pace: OverlayPositionSpec(horizontal: 0.06, vertical: 0.756),
            .heartRate: OverlayPositionSpec(horizontal: 0.06, vertical: 0.802),
            .cadence: OverlayPositionSpec(horizontal: 0.06, vertical: 0.848),
            .strideLength: OverlayPositionSpec(horizontal: 0.06, vertical: 0.894),
            .gpsTrack: OverlayPositionSpec(horizontal: 0.936, vertical: 0.25),
            .elapsedTime: OverlayPositionSpec(horizontal: 0.052, vertical: 0.94),
            .activityDateTime: OverlayPositionSpec(horizontal: 0.94, vertical: 0.922),
            .weather: OverlayPositionSpec(horizontal: 0.928, vertical: 0.841)
        ]

        #expect(expected.count == OverlayComponentKind.allCases.count)
        for component in OverlayComponentKind.allCases {
            #expect(OverlayDesign.defaultPosition(for: component) == expected[component])
        }
    }

    @Test("Distance offset and lower-left component spacing remain exact")
    func defaultPositionSpacing() {
        let distance = OverlayDesign.defaultPosition(for: .distance)
        let distanceOffsetPixels = (distance.vertical - 0.07)
            * Double(OverlayDesign.canvasReferenceSize.height)
        #expect(abs(distanceOffsetPixels - 10) < 0.000_001)

        let lowerLeftComponents: [OverlayComponentKind] = [
            .pace, .heartRate, .cadence, .strideLength, .elapsedTime
        ]
        let verticalPositions = lowerLeftComponents.map {
            OverlayDesign.defaultPosition(for: $0).vertical
        }
        for pair in zip(verticalPositions, verticalPositions.dropFirst()) {
            #expect(abs((pair.1 - pair.0) - 0.046) < 0.000_001)
        }
        #expect(verticalPositions.last == 0.94)
    }

    @Test("Distance, GPS, weather, and badge style defaults remain stable")
    func styleDefaults() {
        #expect(OverlayDesign.distanceLength == 650)
        #expect(OverlayDesign.distanceLineWidth == 4)
        #expect(OverlayDesign.distanceLineHexColor == "#FFFFFF")
        #expect(OverlayDesign.distanceProgressHexColor == "#30D158")
        #expect(OverlayDesign.distanceEndpointFontSize == 16)
        #expect(OverlayDesign.distanceCurrentFontSize == 18)
        #expect(OverlayDesign.gpsRouteHexColor == "#63E677")
        #expect(OverlayDesign.gpsDefaultScale == 0.70)
        #expect(OverlayDesign.gpsBaseSize == CGSize(width: 150, height: 190))
        #expect(OverlayDesign.gpsRenderedSize(forComponentScale: 1) == CGSize(width: 105, height: 133))
        #expect(OverlayDesign.weatherIconHexColor == "#FFFFFF")
        #expect(OverlayDesign.badgeBackgroundOpacity == 0.5)
        #expect(OverlayDesign.canvasReferenceSize == CGSize(width: 1_064, height: 598))
    }

    @Test("Metric icon scale, cadence angle, and spacing remain stable")
    func metricVisualRules() {
        #expect(OverlayDesign.iconScale(for: .pace) == 1.15)
        #expect(OverlayDesign.iconScale(for: .heartRate) == 1)
        #expect(OverlayDesign.iconScale(for: .cadence) == 0.84)
        #expect(OverlayDesign.iconScale(for: .strideLength) == 1.30)
        #expect(OverlayDesign.iconRotationDegrees(for: .cadence) == 30)
        #expect(OverlayDesign.badgeContentSpacing == 7)
        #expect(OverlayDesign.valueUnitSpacing(for: .pace) == 3.5)
        #expect(OverlayDesign.valueUnitSpacing(for: .heartRate) == 3.5)
        #expect(OverlayDesign.valueUnitSpacing(for: .weather) == 7)
    }

    @Test("Heart rate, cadence, and stride reserve three digit value width")
    func fixedThreeDigitColumns() {
        #expect(!OverlayDesign.reservesThreeDigitValueWidth(for: .pace))
        #expect(OverlayDesign.reservesThreeDigitValueWidth(for: .heartRate))
        #expect(OverlayDesign.reservesThreeDigitValueWidth(for: .cadence))
        #expect(OverlayDesign.reservesThreeDigitValueWidth(for: .strideLength))
    }

    @Test("Metric width calculations scale with configured font sizes")
    func metricWidthCalculations() {
        #expect(OverlayDesign.iconColumnWidth(fontSize: 14) == 28)
        #expect(OverlayDesign.iconColumnWidth(fontSize: 32) == 40)
        #expect(OverlayDesign.metricValueWidthAllowance(for: .pace, fontSize: 14) == 42)
        #expect(OverlayDesign.metricValueWidthAllowance(for: .weather, fontSize: 14) == nil)
        let metricContentWidth = OverlayDesign.fixedMetricContentWidth(
            for: .pace,
            iconFontSize: 14,
            valueFontSize: 14,
            unitFontSize: 14
        )
        let valueUnitWidth = OverlayDesign.fixedValueUnitContentWidth(
            for: .strideLength,
            valueFontSize: 14,
            unitFontSize: 14
        )
        #expect(abs((metricContentWidth ?? 0) - 114.8) < 0.000_1)
        #expect(abs((valueUnitWidth ?? 0) - 76.3) < 0.000_1)
    }

    @Test("Icon visibility defaults remain stable")
    func iconVisibility() {
        #expect(!OverlayDesign.showsIconByDefault(for: .distance))
        #expect(!OverlayDesign.showsIconByDefault(for: .activityDateTime))
        #expect(OverlayDesign.showsIconByDefault(for: .pace))
        #expect(OverlayDesign.showsIconByDefault(for: .weather))
    }
}

@Suite("Distance overlay calculations")
struct DistanceOverlayTests {
    @Test("Progress and scale marks are calculated at every kilometer")
    func kilometerProgressAndTicks() {
        let result = DistanceProgressCalculation(
            startDistance: 2,
            configuredEndDistance: 6,
            usesActivityEndDistance: false,
            activityEndDistanceMeters: nil,
            currentDistanceMeters: 4_000,
            unit: .kilometers
        )

        #expect(result.startDistance == 2)
        #expect(result.currentDistance == 4)
        #expect(result.endDistance == 6)
        #expect(result.unit == "km")
        #expect(result.progress == 0.5)
        #expect(result.kilometerTickProgresses == [0, 0.25, 0.5, 0.75, 1])
    }

    @Test("Activity distance can define the endpoint and progress is clamped")
    func activityEndpointAndClamping() {
        let result = DistanceProgressCalculation(
            startDistance: 0,
            configuredEndDistance: 10,
            usesActivityEndDistance: true,
            activityEndDistanceMeters: 22_330,
            currentDistanceMeters: 30_000,
            unit: .kilometers
        )

        #expect(abs(result.endDistance - 22.33) < 0.000_1)
        #expect(result.progress == 1)
    }

    @Test("Mile display still places scale marks at physical kilometer intervals")
    func mileScaleMarks() {
        let result = DistanceProgressCalculation(
            startDistance: 0,
            configuredEndDistance: 1,
            usesActivityEndDistance: false,
            activityEndDistanceMeters: nil,
            currentDistanceMeters: 804.672,
            unit: .miles
        )

        #expect(result.unit == "mi")
        #expect(result.progress == 0.5)
        #expect(result.kilometerTickProgresses.count == 2)
        #expect(result.kilometerTickProgresses[0] == 0)
        #expect(abs(result.kilometerTickProgresses[1] - 0.621_371) < 0.000_001)
    }
}

@Suite("Timeline coordinate mapping")
struct TimelineLayoutTests {
    @Test("Ruler, clip start, and playhead line share one timeline coordinate")
    func coordinateAlignment() {
        let time = 125.0
        let pixelsPerSecond = 0.4
        let timelineX = TimelineLayout.timelineX(
            time: time,
            pixelsPerSecond: pixelsPerSecond
        )
        let clipX = TimelineLayout.trackLeadingInset + TimelineLayout.clipOffsetX(
            startTime: time,
            pixelsPerSecond: pixelsPerSecond
        )
        let playheadX = TimelineLayout.playheadLineX(
            time: time,
            pixelsPerSecond: pixelsPerSecond
        )

        #expect(timelineX == clipX)
        #expect(timelineX == playheadX)
        #expect(TimelineLayout.clipWidth(
            duration: 60,
            pixelsPerSecond: pixelsPerSecond
        ) == 24)
    }

    @Test("Video range includes its exact start and excludes its end")
    func videoRangeBoundaries() {
        #expect(!TimelineLayout.contains(time: 9.999, start: 10, duration: 60))
        #expect(TimelineLayout.contains(time: 10, start: 10, duration: 60))
        #expect(TimelineLayout.contains(time: 69.999, start: 10, duration: 60))
        #expect(!TimelineLayout.contains(time: 70, start: 10, duration: 60))
        #expect(TimelineLayout.mediaTime(timelineTime: 10, start: 10) == 0)
    }

    @Test("Visible provisional clips and playback hit testing use the same duration")
    func provisionalDuration() {
        #expect(TimelineLayout.videoDuration(
            importedDuration: nil,
            loadedDuration: nil
        ) == 60)
        #expect(TimelineLayout.videoDuration(
            importedDuration: nil,
            loadedDuration: 90
        ) == 90)
        #expect(TimelineLayout.videoDuration(
            importedDuration: 120,
            loadedDuration: 90
        ) == 120)
    }

    @Test("Playhead drag conversion is exact and clamped")
    func playheadDragConversion() {
        #expect(TimelineLayout.draggedTime(
            startTime: 10,
            translation: 20,
            pixelsPerSecond: 2,
            totalDuration: 100
        ) == 20)
        #expect(TimelineLayout.draggedTime(
            startTime: 10,
            translation: -40,
            pixelsPerSecond: 2,
            totalDuration: 100
        ) == 0)
        #expect(TimelineLayout.draggedTime(
            startTime: 90,
            translation: 40,
            pixelsPerSecond: 2,
            totalDuration: 100
        ) == 100)
    }
}

@Suite("Timeline date alignment")
struct TimelineAlignmentTests {
    @Test("Attached first video is calibrated to the nearby FIT resume")
    func attachedAssetDates() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let fitStart = try #require(formatter.date(from: "2026-08-05T05:46:23+08:00"))
        let videoStart = try #require(formatter.date(from: "2026-08-05T05:54:11+08:00"))
        let timerResume = try #require(formatter.date(from: "2026-08-05T05:53:21+08:00"))
        let estimate = TimelineAlignment.videoClockCorrection(
            firstVideoDate: videoStart,
            timerResumeDates: [timerResume]
        )
        let correction = estimate.correction
        let offsets = try #require(TimelineAlignment.normalizedOffsets(
            for: [fitStart, videoStart.addingTimeInterval(correction)]
        ))

        #expect(estimate.confidence == .high)
        #expect(correction == -50)
        #expect(offsets == [0, 418])
        #expect(TimelineAlignment.canAutomaticallyAlign(offsets: offsets))

        let activityTime = TimelineAlignment.activityTime(
            timelineTime: offsets[1],
            fitTimelineOffset: offsets[0]
        )
        #expect(fitStart.addingTimeInterval(activityTime) == timerResume)
        #expect(TimelineAlignment.isSequentialCameraFirstFile(
            "VID_20260805_055411_00_001.mp4"
        ))
        #expect(!TimelineAlignment.isSequentialCameraFirstFile(
            "VID_20260805_060537_00_002.mp4"
        ))
        #expect(TimelineAlignment.sequentialCameraBatchPrefix(
            "VID_20260805_060537_00_002.mp4"
        ) == "vid_20260805_")
        #expect(TimelineAlignment.sequentialCameraBatchPrefix(
            "unrelated.mp4"
        ) == nil)
    }

    @Test("Sequential camera batches keep the first-file anchor instead of the later copy time")
    func sequentialCameraBatchAnchor() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let firstFileDate = base.addingTimeInterval(90)
        let laterFileDate = base.addingTimeInterval(270)

        let alignedDate = TimelineAlignment.alignmentReferenceDate(
            fileCreationDate: laterFileDate,
            sequentialCameraBatchReferenceDate: firstFileDate
        )

        #expect(alignedDate == firstFileDate)
    }

    @Test("Distant resume dates remain valid but lower confidence")
    func distantResumeAlignmentIsConservative() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let videoStart = base.addingTimeInterval(600)
        let resume = base.addingTimeInterval(420)

        let estimate = TimelineAlignment.videoClockCorrection(
            firstVideoDate: videoStart,
            timerResumeDates: [resume]
        )

        #expect(estimate.correction == -180)
        #expect(estimate.confidence == .medium)
    }

    @Test("FIT start is used as the timeline anchor when a file is created earlier")
    func fitStartAnchor() {
        let fitStart = Date(timeIntervalSince1970: 1_700_000_000)
        let earlierVideo = fitStart.addingTimeInterval(-30)

        let offsets = TimelineAlignment.relativeOffsets(
            from: fitStart,
            for: [earlierVideo, fitStart]
        )

        #expect(offsets == [0, 0])
    }

    @Test("Automatic alignment rejects spans over twelve hours")
    func automaticAlignmentLimit() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let offsets = try #require(TimelineAlignment.normalizedOffsets(for: [
            start.addingTimeInterval(13 * 60 * 60),
            start
        ]))

        #expect(offsets == [13 * 60 * 60.0, 0])
        #expect(!TimelineAlignment.canAutomaticallyAlign(offsets: offsets))
        #expect(TimelineAlignment.normalizedOffsets(for: []) == nil)
    }
}

@Suite("Formatting and export calculations")
struct FormattingAndExportTests {
    @Test("Date and duration formatting is deterministic")
    func formatting() throws {
        let date = Date(timeIntervalSince1970: 1_722_090_613)
        let singapore = try #require(TimeZone(identifier: "Asia/Singapore"))

        #expect(formattedActivityDate(date, timeZone: singapore) == "2024-07-27 22:30:13")
        #expect(formattedActivityTime(date, timeZone: singapore) == "22:30:13")
        #expect(formattedActivityDay(date, timeZone: singapore) == "2024/07/27")
        #expect(formattedActivityDuration(3_661.9) == "01:01:01")
        #expect(formattedActivityDuration(.infinity) == "00:00:00")
        #expect(formattedExportDuration(-1) == "00:00:00")
    }

    @Test("Export resolutions preserve aspect ratio and even dimensions")
    func exportResolutions() {
        let landscape = CGSize(width: 1_920, height: 1_080)
        #expect(OverlayExportResolution.source.resolution(matching: CGSize(width: 1_919, height: 1_079)) == CGSize(width: 1_918, height: 1_078))
        #expect(OverlayExportResolution.fullHD.resolution(matching: landscape) == landscape)
        #expect(OverlayExportResolution.twoK.resolution(matching: landscape) == CGSize(width: 2_560, height: 1_440))
        #expect(OverlayExportResolution.fourK.resolution(matching: landscape) == CGSize(width: 3_840, height: 2_160))
        #expect(OverlayExportResolution.fullHD.resolution(matching: CGSize(width: 1_080, height: 1_920)) == CGSize(width: 1_080, height: 1_920))
    }

    @Test("Encoding estimates increase with frame rate, resolution, and duration")
    func encodingEstimates() {
        let fullHD30 = OverlayVideoEncoding.estimatedFileSize(
            width: 1_920,
            height: 1_080,
            framesPerSecond: 30,
            duration: 60
        )
        let fullHD60 = OverlayVideoEncoding.estimatedFileSize(
            width: 1_920,
            height: 1_080,
            framesPerSecond: 60,
            duration: 60
        )
        let fourK60 = OverlayVideoEncoding.estimatedFileSize(
            width: 3_840,
            height: 2_160,
            framesPerSecond: 60,
            duration: 60
        )

        #expect(OverlayVideoEncoding.keyFrameIntervalSeconds == 5)
        #expect(fullHD30 > 0)
        #expect(fullHD60 > fullHD30)
        #expect(fourK60 > fullHD60)
        #expect(OverlayVideoEncoding.estimatedFileSize(
            width: 1_920,
            height: 1_080,
            framesPerSecond: 30,
            duration: 120
        ) == fullHD30 * 2)
    }
}
