import AppKit
import AVFoundation
import AVKit
import Combine
import CoreVideo
import SwiftUI
import UniformTypeIdentifiers

@main
struct RunningDataOverlayApp: App {
    private var defaultWindowSize: CGSize {
        let availableScreenSize = NSScreen.main?.visibleFrame.size
            ?? CGSize(width: 1_572, height: 720)
        return OverlayDesign.defaultWindowSize(forAvailableScreenSize: availableScreenSize)
    }

    var body: some Scene {
        WindowGroup("Run Overlay") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)
    }
}

private struct ContentView: View {
    @StateObject private var playback = PlaybackController()
    @State private var videoImports: [VideoImport] = []
    @State private var fitImports: [FitImport] = []
    @State private var timelineOffsets: [UUID: Double] = [:]
    @State private var timelineTime = 0.0
    @State private var isTimelineScrubbing = false
    @State private var alignmentStatus: String?
    @State private var sidebarTab = SidebarTab.materials
    @State private var overlayComponents: [OverlayComponentInstance] = []
    @State private var selectedOverlayID: UUID?
    @State private var importError: String?
    @State private var complementaryImport: ComplementaryImport?
    @State private var isExportSheetPresented = false
    @State private var exportsCompleteDataLayer = false
    @State private var exportResolution = OverlayExportResolution.fullHD
    @State private var exportFrameRate = OverlayExportFrameRate.fps30
    @State private var isExporting = false
    @State private var exportProgress = 0.0
    @State private var exportStatus: ExportStatus?
    @State private var exportTask: Task<Void, Never>?

    var body: some View {
        content
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    exportStatus = nil
                    isExportSheetPresented = true
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .help("导出透明数据层")
            }
        }
        .sheet(isPresented: $isExportSheetPresented) {
            ExportOverlaySheet(
                exportRange: exportRange,
                exportsCompleteDataLayer: $exportsCompleteDataLayer,
                exportResolution: $exportResolution,
                exportFrameRate: $exportFrameRate,
                isExporting: isExporting,
                exportProgress: exportProgress,
                exportStatus: exportStatus,
                export: startExport,
                cancelExport: cancelExport
            )
        }
        .alert("无法导入文件", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .alert(
            complementaryImport?.title ?? "",
            isPresented: Binding(
                get: { complementaryImport != nil },
                set: { if !$0 { complementaryImport = nil } }
            ),
            presenting: complementaryImport
        ) { importType in
            Button("稍后", role: .cancel) {}
            Button(importType.actionTitle) {
                complementaryImport = nil
                switch importType {
                case .video:
                    importVideo()
                case .workoutFile:
                    importFITFile()
                }
            }
        } message: { importType in
            Text(importType.message)
        }
        .onDisappear {
            playback.pause()
        }
        .onChange(of: playback.currentTime) { _, currentTime in
            guard !isTimelineScrubbing,
                  let currentVideo = videoImports.first(where: { $0.url == playback.videoURL }) else {
                return
            }

                timelineTime = timelineOffsets[currentVideo.id, default: 0] + currentTime
        }
    }

    private var content: some View {
        HStack(spacing: 0) {
            library
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .padding(16)

            Divider()

            VStack(spacing: 20) {
                ZStack {
                    PlayerView(player: playback.player)
                    OverlayCanvas(
                        overlays: $overlayComponents,
                        selectedOverlayID: $selectedOverlayID,
                        activity: fitImports.last?.activity,
                        activityTime: timelineTime - fitTimelineOffset
                    )
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)

                if !videoImports.isEmpty || !fitImports.isEmpty {
                    TimelineEditor(
                        videos: videoImports,
                        fitFiles: fitImports,
                        playback: playback,
                        offsets: $timelineOffsets,
                        timelineTime: $timelineTime,
                        alignmentStatus: alignmentStatus,
                        autoAlign: autoAlignUsingFileDates,
                        previewTimeline: { timelineTime = $0 },
                        setTimelineScrubbing: setTimelineScrubbing,
                        seekTimeline: seekTimeline
                    )
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            Group {
                if let selectedOverlayBinding {
                    OverlayInspector(
                        overlay: selectedOverlayBinding,
                        addComponent: { addComponent($0) },
                        delete: { removeSelectedOverlay() }
                    )
                } else {
                    OverlayAddPanel(addComponent: { addComponent($0) })
                }
            }
                .frame(width: 280)
                .frame(maxHeight: .infinity)
                .padding(16)
        }
    }

    private var library: some View {
        VStack(spacing: 16) {
            Picker("工作区", selection: $sidebarTab) {
                ForEach(SidebarTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch sidebarTab {
            case .materials:
                materialsSidebar
            case .components:
                componentsSidebar
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var materialsSidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Button(action: importVideo) {
                    Label("导入视频", systemImage: "video.badge.plus")
                }
                Button(action: importFITFile) {
                    Label("导入运动文件", systemImage: "figure.run")
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MaterialSection(title: "视频", systemImage: "video") {
                        if videoImports.isEmpty {
                            EmptyMaterialRow(text: "尚未导入视频")
                        } else {
                            ForEach(videoImports) { video in
                                AssetRow(
                                    title: video.url.lastPathComponent,
                                    subtitle: "视频",
                                    systemImage: "video.fill",
                                    isSelected: playback.videoURL == video.url,
                                    onSelect: { playback.loadVideo(url: video.url) },
                                    onDelete: { removeVideo(video) }
                                )
                            }
                        }
                    } footer: {
                        Button(action: importVideo) {
                            Label("导入视频", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                    }

                    Divider()

                    MaterialSection(title: "运动文件", systemImage: "figure.run") {
                        if fitImports.isEmpty {
                            EmptyMaterialRow(text: "尚未导入运动文件")
                        } else {
                            ForEach(fitImports) { fitImport in
                                AssetRow(
                                    title: fitImport.fileName,
                                    subtitle: "FIT · \(fitImport.fileSizeDescription)",
                                    systemImage: "figure.run",
                                    onDelete: { removeFITFile(fitImport) }
                                )
                            }
                        }
                    } footer: {
                        Button(action: importFITFile) {
                            Label("导入运动文件", systemImage: "plus")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var componentsSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: addAllComponents) {
                Label("添加所有组件", systemImage: "plus.circle")
            }
            .buttonStyle(.bordered)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(OverlayComponent.allCases) { component in
                        OverlayComponentRow(
                            component: component,
                            isAdded: overlayComponents.contains { $0.component == component },
                            addComponent: { addComponent(component) }
                        )
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var selectedOverlayBinding: Binding<OverlayComponentInstance>? {
        guard let selectedOverlayID,
              let index = overlayComponents.firstIndex(where: { $0.id == selectedOverlayID }) else {
            return nil
        }

        return Binding(
            get: { overlayComponents[index] },
            set: { overlayComponents[index] = $0 }
        )
    }

    private var fitTimelineOffset: Double {
        guard let fitImport = fitImports.last else {
            return 0
        }
        return timelineOffsets[fitImport.id, default: 0]
    }

    private var exportVideo: VideoImport? {
        if let videoURL = playback.videoURL,
           let loadedVideo = videoImports.first(where: { $0.url == videoURL }) {
            return loadedVideo
        }
        return videoImports.last
    }

    private var exportRange: ExportOverlayRange? {
        guard let video = exportVideo,
              let videoDuration = video.duration,
              videoDuration > 0,
              let fitImport = fitImports.last,
              let fitDuration = fitDuration(for: fitImport) else {
            return nil
        }

        let videoStart = timelineOffsets[video.id, default: 0]
        let videoEnd = videoStart + videoDuration
        let fitStart = timelineOffsets[fitImport.id, default: 0]
        let fitEnd = fitStart + fitDuration
        let timelineStart: Double
        let timelineEnd: Double

        if exportsCompleteDataLayer {
            timelineStart = fitStart
            timelineEnd = fitEnd
        } else {
            timelineStart = max(videoStart, fitStart)
            timelineEnd = min(videoEnd, fitEnd)
        }

        guard timelineEnd > timelineStart else {
            return nil
        }

        return ExportOverlayRange(
            videoFileName: video.url.lastPathComponent,
            fitFileName: fitImport.fileName,
            resolution: video.resolution ?? CGSize(width: 1_920, height: 1_080),
            timelineStart: timelineStart,
            timelineEnd: timelineEnd,
            exportsCompleteDataLayer: exportsCompleteDataLayer
        )
    }

    private func fitDuration(for fitImport: FitImport) -> Double? {
        guard let startDate = fitImport.activity.startDate,
              let endDate = fitImport.activity.endDate else {
            return nil
        }
        let duration = endDate.timeIntervalSince(startDate)
        return duration > 0 ? duration : nil
    }

    private func startExport(_ exportRange: ExportOverlayRange) {
        guard let fitImport = fitImports.last else {
            exportStatus = .failure("未找到可用于导出的 FIT 运动数据。")
            return
        }

        let savePanel = NSSavePanel()
        savePanel.title = "导出透明数据层"
        savePanel.message = "导出包含 Alpha 通道的 HEVC 视频文件。"
        savePanel.allowedContentTypes = [.quickTimeMovie]
        let videoBaseName = (exportRange.videoFileName as NSString).deletingPathExtension
        savePanel.nameFieldStringValue = "\(videoBaseName)-overlay.mov"
        savePanel.canCreateDirectories = true

        guard savePanel.runModal() == .OK, let outputURL = savePanel.url else {
            return
        }

        let configuration = OverlayVideoExportConfiguration(
            outputURL: outputURL,
            resolution: exportRange.outputResolution(for: exportResolution),
            framesPerSecond: exportFrameRate.rawValue,
            timelineStart: exportRange.timelineStart,
            duration: exportRange.duration,
            fitTimelineOffset: fitTimelineOffset,
            activity: fitImport.activity,
            overlays: overlayComponents
        )
        isExporting = true
        exportProgress = 0
        exportStatus = nil

        exportTask = Task { @MainActor in
            do {
                try await OverlayVideoExporter.export(configuration) { progress in
                    exportProgress = progress
                }
                try Task.checkCancellation()
                exportProgress = 1
                exportStatus = .success("已导出到 \(outputURL.lastPathComponent)")
            } catch is CancellationError {
                exportStatus = .cancelled("已取消导出。")
            } catch {
                exportStatus = .failure(error.localizedDescription)
            }
            isExporting = false
            exportTask = nil
        }
    }

    private func cancelExport() {
        guard isExporting else {
            return
        }
        exportTask?.cancel()
    }

    private func importVideo() {
        let panel = NSOpenPanel()
        panel.title = "选择跑步视频"
        panel.message = "选择要用于制作数据浮层的视频文件。"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else {
            return
        }

        let imports = panel.urls.map(VideoImport.init)
        videoImports.append(contentsOf: imports)
        if let latestImport = imports.last {
            playback.loadVideo(url: latestImport.url)
        }
        for video in imports {
            loadVideoDuration(for: video)
        }
        if !imports.isEmpty, !fitImports.isEmpty {
            autoAlignUsingFileDates()
        }
        if !imports.isEmpty, fitImports.isEmpty {
            complementaryImport = .workoutFile
        }
    }

    private func importFITFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 FIT 跑步记录"
        panel.message = "选择 Garmin、Coros 等设备导出的 .fit 文件。"
        panel.allowedContentTypes = [.fit]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK else {
            return
        }

        var importedCount = 0
        var errors: [String] = []
        for url in panel.urls {
            do {
                fitImports.append(try FitImport(url: url))
                importedCount += 1
            } catch {
                errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if !errors.isEmpty {
            importError = errors.joined(separator: "\n")
        }
        if importedCount > 0, !videoImports.isEmpty {
            autoAlignUsingFileDates()
        }
        if importedCount > 0, videoImports.isEmpty {
            complementaryImport = .video
        }
    }

    private func loadVideoDuration(for video: VideoImport) {
        Task { @MainActor in
            let asset = AVURLAsset(url: video.url)
            guard let assetDuration = try? await asset.load(.duration) else {
                return
            }

            let seconds = assetDuration.seconds
            guard seconds.isFinite, seconds > 0,
                  let index = videoImports.firstIndex(where: { $0.id == video.id }) else {
                return
            }
            videoImports[index].duration = seconds

            guard let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
                  let naturalSize = try? await videoTrack.load(.naturalSize),
                  let preferredTransform = try? await videoTrack.load(.preferredTransform) else {
                return
            }
            let transformedSize = naturalSize.applying(preferredTransform)
            videoImports[index].resolution = CGSize(
                width: abs(transformedSize.width),
                height: abs(transformedSize.height)
            )
        }
    }

    private func removeVideo(_ video: VideoImport) {
        videoImports.removeAll { $0.id == video.id }
        timelineOffsets.removeValue(forKey: video.id)
        guard playback.videoURL == video.url else {
            return
        }

        if let remainingVideo = videoImports.last {
            playback.loadVideo(url: remainingVideo.url)
        } else {
            playback.unloadVideo()
        }
    }

    private func removeFITFile(_ fitImport: FitImport) {
        fitImports.removeAll { $0.id == fitImport.id }
        timelineOffsets.removeValue(forKey: fitImport.id)
    }

    private func autoAlignUsingFileDates() {
        let datedAssets = videoImports.compactMap { video in
            video.fileCreationDate.map { (video.id, $0) }
        } + fitImports.compactMap { fitImport in
            (fitImport.activity.startDate ?? fitImport.fileCreationDate).map { (fitImport.id, $0) }
        }

        guard let earliestDate = datedAssets.map(\.1).min() else {
            alignmentStatus = "缺少文件创建时间，无法自动对齐。"
            return
        }

        let largestOffset = datedAssets
            .map { $0.1.timeIntervalSince(earliestDate) }
            .max() ?? 0
        guard largestOffset <= 12 * 60 * 60 else {
            for (id, _) in datedAssets {
                timelineOffsets[id] = 0
            }
            timelineTime = 0
            alignmentStatus = "素材时间相差超过 12 小时，已从 0 开始，请手动对齐。"
            return
        }

        for (id, creationDate) in datedAssets {
            timelineOffsets[id] = max(0, creationDate.timeIntervalSince(earliestDate))
        }
        alignmentStatus = "已按视频创建时间和 FIT 运动开始时间对齐，可拖动素材微调。"
    }

    private func seekTimeline(to time: Double) {
        timelineTime = max(0, time)
        guard let video = videoImports.first(where: { video in
            let offset = timelineOffsets[video.id, default: 0]
            let duration = timelineVideoDuration(for: video)
            return duration > 0 && timelineTime >= offset && timelineTime < offset + duration
        }) else {
            playback.unloadVideo()
            return
        }

        let videoTime = timelineTime - timelineOffsets[video.id, default: 0]
        if playback.videoURL == video.url {
            playback.seek(to: videoTime)
        } else {
            playback.loadVideo(url: video.url, seekTo: videoTime)
        }
    }

    private func timelineVideoDuration(for video: VideoImport) -> Double {
        if let duration = video.duration {
            return duration
        }
        return playback.videoURL == video.url ? playback.duration : 0
    }

    private func setTimelineScrubbing(_ isScrubbing: Bool) {
        isTimelineScrubbing = isScrubbing
        playback.setScrubbing(isScrubbing)
    }

    private func addComponent(_ component: OverlayComponent) {
        if let existingOverlay = overlayComponents.first(where: { $0.component == component }) {
            selectedOverlayID = existingOverlay.id
            return
        }

        let instance = OverlayComponentInstance(component: component)
        overlayComponents.append(instance)
        selectedOverlayID = instance.id
    }

    private func addAllComponents() {
        for component in OverlayComponent.allCases {
            addComponent(component)
        }
    }

    private func removeSelectedOverlay() {
        guard let selectedOverlayID else {
            return
        }
        overlayComponents.removeAll { $0.id == selectedOverlayID }
        self.selectedOverlayID = nil
    }
}

private enum ComplementaryImport {
    case video
    case workoutFile

    var title: String {
        switch self {
        case .video:
            return "已导入运动文件"
        case .workoutFile:
            return "已导入视频"
        }
    }

    var message: String {
        switch self {
        case .video:
            return "是否现在导入视频？"
        case .workoutFile:
            return "是否现在导入运动文件？"
        }
    }

    var actionTitle: String {
        switch self {
        case .video:
            return "导入视频"
        case .workoutFile:
            return "导入运动文件"
        }
    }
}

private enum SidebarTab: CaseIterable, Identifiable {
    case materials
    case components

    var id: Self { self }

    var title: String {
        switch self {
        case .materials:
            return "素材"
        case .components:
            return "组件库"
        }
    }
}

private enum OverlayComponent: CaseIterable, Hashable, Identifiable {
    case distance
    case pace
    case heartRate
    case cadence
    case strideLength
    case gpsTrack
    case elapsedTime
    case activityDateTime
    case weather

    var id: Self { self }

    var designKind: OverlayComponentKind {
        switch self {
        case .distance: return .distance
        case .pace: return .pace
        case .heartRate: return .heartRate
        case .cadence: return .cadence
        case .strideLength: return .strideLength
        case .gpsTrack: return .gpsTrack
        case .elapsedTime: return .elapsedTime
        case .activityDateTime: return .activityDateTime
        case .weather: return .weather
        }
    }

    var title: String {
        switch self {
        case .distance:
            return "距离"
        case .pace:
            return "配速"
        case .heartRate:
            return "心率"
        case .cadence:
            return "步频"
        case .strideLength:
            return "步幅"
        case .gpsTrack:
            return "GPS 轨迹"
        case .elapsedTime:
            return "当前运动时间"
        case .activityDateTime:
            return "运动日期时间"
        case .weather:
            return "天气信息"
        }
    }

    var systemImage: String {
        switch self {
        case .distance:
            return "ruler"
        case .pace:
            return "figure.run"
        case .heartRate:
            return "heart.fill"
        case .cadence:
            return "shoe.fill"
        case .strideLength:
            return "figure.walk"
        case .gpsTrack:
            return "point.topleft.down.curvedto.point.bottomright.up"
        case .elapsedTime:
            return "stopwatch.fill"
        case .activityDateTime:
            return "calendar"
        case .weather:
            return "cloud.sun"
        }
    }

    var supportsBackground: Bool {
        switch self {
        case .pace, .heartRate, .cadence, .strideLength, .elapsedTime, .activityDateTime, .weather:
            return true
        case .distance, .gpsTrack:
            return false
        }
    }

    func value(in activity: FitActivity?) -> String {
        guard let activity else {
            return "等待 FIT 数据"
        }
        switch self {
        case .distance:
            guard let distance = activity.totalDistanceMeters else { return "FIT 未记录" }
            return String(format: "%.2f km", distance / 1_000)
        case .pace:
            guard let speed = activity.averageSpeedMetersPerSecond, speed > 0 else { return "FIT 未记录" }
            let paceSeconds = Int((1_000 / speed).rounded())
            return String(format: "%d:%02d /km", paceSeconds / 60, paceSeconds % 60)
        case .heartRate:
            guard let heartRate = activity.averageHeartRate else { return "FIT 未记录" }
            return "平均 \(heartRate) bpm"
        case .cadence:
            guard let cadence = activity.averageCadence else { return "FIT 未记录" }
            return "平均 \(cadence) spm"
        case .strideLength:
            guard let strideLength = activity.averageStrideLengthMeters else { return "FIT 未记录" }
            return String(format: "平均 %.2f m", strideLength)
        case .gpsTrack:
            return activity.gpsPoints.isEmpty ? "FIT 未记录" : "\(activity.gpsPoints.count) 个定位点"
        case .elapsedTime:
            guard let startDate = activity.startDate, let endDate = activity.endDate else { return "FIT 未记录" }
            return formattedActivityDuration(endDate.timeIntervalSince(startDate))
        case .activityDateTime:
            guard let startDate = activity.startDate else { return "FIT 未记录" }
            return formattedActivityDate(startDate)
        case .weather:
            return activity.weatherSummary
        }
    }

    func overlayValue(in activity: FitActivity?, unit: OverlayUnit, at activityTime: Double) -> String {
        guard let activity else {
            return title
        }

        let sample = activity.sample(at: activityTime)

        switch self {
        case .distance:
            guard let distance = sample?.distanceMeters ?? activity.totalDistanceMeters else { return title }
            if unit == .miles {
                return String(format: "%.2f mi", distance / 1_609.344)
            }
            return String(format: "%.2f km", distance / 1_000)
        case .pace:
            guard let speed = sample?.speedMetersPerSecond ?? activity.averageSpeedMetersPerSecond, speed > 0 else { return title }
            let multiplier = unit == .pacePerMile ? 1_609.344 : 1_000
            let paceSeconds = Int((multiplier / speed).rounded())
            return String(format: "%d:%02d %@", paceSeconds / 60, paceSeconds % 60, unit == .pacePerMile ? "/mi" : "/km")
        case .heartRate:
            guard let heartRate = sample?.heartRate ?? activity.averageHeartRate else { return title }
            return "\(heartRate) bpm"
        case .cadence:
            guard let cadence = sample?.cadence ?? activity.averageCadence else { return title }
            return "\(cadence) spm"
        case .strideLength:
            guard let strideLength = activity.strideLength(at: activityTime) else { return title }
            if unit == .feet {
                return String(format: "%.2f ft", strideLength * 3.28084)
            }
            if unit == .centimeters {
                return String(format: "%.0f cm", strideLength * 100)
            }
            return String(format: "%.2f m", strideLength)
        case .gpsTrack:
            guard let latitude = sample?.latitude, let longitude = sample?.longitude else { return title }
            return String(format: "%.4f, %.4f", latitude, longitude)
        case .elapsedTime:
            return formattedActivityDuration(elapsedTime(in: activity, at: activityTime))
        case .activityDateTime:
            guard let startDate = activity.startDate else { return title }
            return formattedActivityDate(startDate.addingTimeInterval(max(0, activityTime)))
        case .weather:
            if let temperature = sample?.temperatureCelsius {
                return String(format: "%.0f°C", temperature)
            }
            return activity.weatherSummary
        }
    }

    func overlayDisplayValue(in activity: FitActivity?, unit: OverlayUnit, at activityTime: Double) -> OverlayDisplayValue {
        guard let activity else {
            return OverlayDisplayValue(value: title, unit: "")
        }

        let sample = activity.sample(at: activityTime)
        switch self {
        case .distance:
            guard let distance = sample?.distanceMeters ?? activity.totalDistanceMeters else {
                return OverlayDisplayValue(value: title, unit: "")
            }
            if unit == .miles {
                return OverlayDisplayValue(value: String(format: "%.2f", distance / 1_609.344), unit: "mi")
            }
            return OverlayDisplayValue(value: String(format: "%.2f", distance / 1_000), unit: "km")
        case .pace:
            guard let speed = sample?.speedMetersPerSecond ?? activity.averageSpeedMetersPerSecond, speed > 0 else {
                return OverlayDisplayValue(value: title, unit: "")
            }
            let multiplier = unit == .pacePerMile ? 1_609.344 : 1_000
            let paceSeconds = Int((multiplier / speed).rounded())
            return OverlayDisplayValue(
                value: String(format: "%d:%02d", paceSeconds / 60, paceSeconds % 60),
                unit: unit == .pacePerMile ? "/mi" : "/km"
            )
        case .heartRate:
            guard let heartRate = sample?.heartRate ?? activity.averageHeartRate else {
                return OverlayDisplayValue(value: title, unit: "")
            }
            return OverlayDisplayValue(value: "\(heartRate)", unit: "bpm")
        case .cadence:
            guard let cadence = sample?.cadence ?? activity.averageCadence else {
                return OverlayDisplayValue(value: title, unit: "")
            }
            return OverlayDisplayValue(value: "\(cadence)", unit: "spm")
        case .strideLength:
            guard let strideLength = activity.strideLength(at: activityTime) else {
                return OverlayDisplayValue(value: title, unit: "")
            }
            if unit == .feet {
                return OverlayDisplayValue(value: String(format: "%.2f", strideLength * 3.28084), unit: "ft")
            }
            if unit == .centimeters {
                return OverlayDisplayValue(value: String(format: "%.0f", strideLength * 100), unit: "cm")
            }
            return OverlayDisplayValue(value: String(format: "%.2f", strideLength), unit: "m")
        case .gpsTrack:
            guard let latitude = sample?.latitude, let longitude = sample?.longitude else {
                return OverlayDisplayValue(value: title, unit: "")
            }
            return OverlayDisplayValue(value: String(format: "%.4f, %.4f", latitude, longitude), unit: "")
        case .elapsedTime:
            return OverlayDisplayValue(
                value: formattedActivityDuration(elapsedTime(in: activity, at: activityTime)),
                unit: ""
            )
        case .activityDateTime:
            guard let startDate = activity.startDate else {
                return OverlayDisplayValue(value: title, unit: "")
            }
            return OverlayDisplayValue(value: formattedActivityDate(startDate.addingTimeInterval(max(0, activityTime))), unit: "")
        case .weather:
            if let temperature = sample?.temperatureCelsius {
                return OverlayDisplayValue(value: String(format: "%.0f", temperature), unit: "°C")
            }
            return OverlayDisplayValue(value: activity.weatherSummary, unit: "")
        }
    }

    func dateTimeDisplayValue(in activity: FitActivity?, at activityTime: Double) -> OverlayDateTimeDisplay {
        guard let startDate = activity?.startDate else {
            return OverlayDateTimeDisplay(time: title, date: "")
        }
        let currentDate = startDate.addingTimeInterval(max(0, activityTime))
        return OverlayDateTimeDisplay(
            time: formattedActivityTime(currentDate),
            date: formattedActivityDay(currentDate)
        )
    }

    private func elapsedTime(in activity: FitActivity, at activityTime: Double) -> Double {
        let elapsed = max(0, activityTime)
        guard let startDate = activity.startDate, let endDate = activity.endDate else {
            return elapsed
        }
        return min(elapsed, max(0, endDate.timeIntervalSince(startDate)))
    }
}

private struct OverlayComponentRow: View {
    let component: OverlayComponent
    let isAdded: Bool
    let addComponent: () -> Void

    var body: some View {
        Button(action: addComponent) {
            HStack(spacing: 10) {
                Image(systemName: component.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(Color.accentColor)
                Text(component.title)
                Spacer()
                if isAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isAdded ? Color.accentColor.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(isAdded ? "选择 \(component.title) 组件" : "添加 \(component.title) 组件")
    }
}

private struct OverlayTextStyle {
    var fontSize = 14.0
    var hexColor = "#FFFFFF"
}

private extension Color {
    init(hexColor: String) {
        let rawValue = hexColor.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = rawValue.hasPrefix("#") ? String(rawValue.dropFirst()) : rawValue
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else {
            self = .white
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }

    var hexColorString: String {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else {
            return "#FFFFFF"
        }
        return String(
            format: "#%02X%02X%02X",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded())
        )
    }
}

private struct OverlayDisplayValue {
    let value: String
    let unit: String
}

private struct DistanceOverlayDisplay {
    let startDistance: Double
    let currentDistance: Double
    let endDistance: Double
    let unit: String
    let progress: Double
    let kilometerTickProgresses: [Double]

    init(
        activity: FitActivity?,
        activityTime: Double,
        unit: OverlayUnit,
        configuration: DistanceOverlayConfiguration
    ) {
        let calculation = DistanceProgressCalculation(
            startDistance: configuration.startDistance,
            configuredEndDistance: configuration.endDistance,
            usesActivityEndDistance: configuration.usesActivityEndDistance,
            activityEndDistanceMeters: activity?.totalDistanceMeters,
            currentDistanceMeters: activity?.sample(at: activityTime)?.distanceMeters,
            unit: unit == .miles ? .miles : .kilometers
        )
        startDistance = calculation.startDistance
        currentDistance = calculation.currentDistance
        endDistance = calculation.endDistance
        self.unit = calculation.unit
        progress = calculation.progress
        kilometerTickProgresses = calculation.kilometerTickProgresses
    }
}

private struct OverlayDateTimeDisplay {
    let time: String
    let date: String
}

private enum WeatherCondition: String, CaseIterable, Identifiable {
    case sunny
    case partlyCloudy
    case cloudy
    case rainy
    case snowy
    case foggy
    case thunderstorm
    case thundershowers

    var id: Self { self }

    var title: String {
        switch self {
        case .sunny: return "晴"
        case .partlyCloudy: return "多云"
        case .cloudy: return "阴"
        case .rainy: return "雨"
        case .snowy: return "雪"
        case .foggy: return "雾"
        case .thunderstorm: return "雷雨"
        case .thundershowers: return "雷阵雨"
        }
    }

    var systemImage: String {
        switch self {
        case .sunny: return "sun.max.fill"
        case .partlyCloudy: return "cloud.sun.fill"
        case .cloudy: return "cloud.fill"
        case .rainy: return "cloud.rain.fill"
        case .snowy: return "cloud.snow.fill"
        case .foggy: return "cloud.fog.fill"
        case .thunderstorm: return "cloud.bolt.rain.fill"
        case .thundershowers: return "cloud.bolt.rain.fill"
        }
    }
}

private enum WindDirection: String, CaseIterable, Identifiable {
    case calm
    case north
    case northeast
    case east
    case southeast
    case south
    case southwest
    case west
    case northwest

    var id: Self { self }

    var title: String {
        switch self {
        case .calm: return "无风"
        case .north: return "北风"
        case .northeast: return "东北风"
        case .east: return "东风"
        case .southeast: return "东南风"
        case .south: return "南风"
        case .southwest: return "西南风"
        case .west: return "西风"
        case .northwest: return "西北风"
        }
    }
}

private struct ManualWeather {
    var condition: WeatherCondition = .sunny
    var windDirection: WindDirection = .calm
    var windSpeedKilometersPerHour = 0.0
    var temperatureCelsius = 20.0
    var humidityPercent = 50.0
}

private struct DistanceOverlayConfiguration {
    var startDistance = 0.0
    var endDistance = 10.0
    var usesActivityEndDistance = true
    var showsStartDistance = true
    var showsCurrentDistance = true
    var showsEndDistance = true
    var showsScale = true
    var lineWidth = OverlayDesign.distanceLineWidth
    var lineHexColor = OverlayDesign.distanceLineHexColor
    var progressHexColor = OverlayDesign.distanceProgressHexColor
    var length = OverlayDesign.distanceLength
    var startValueStyle = OverlayTextStyle(
        fontSize: OverlayDesign.distanceEndpointFontSize,
        hexColor: OverlayDesign.distanceLineHexColor
    )
    var currentValueStyle = OverlayTextStyle(
        fontSize: OverlayDesign.distanceCurrentFontSize,
        hexColor: OverlayDesign.distanceProgressHexColor
    )
    var endValueStyle = OverlayTextStyle(
        fontSize: OverlayDesign.distanceEndpointFontSize,
        hexColor: OverlayDesign.distanceLineHexColor
    )
}

private struct OverlayPosition {
    var horizontal: Double
    var vertical: Double

    static func defaultPosition(for component: OverlayComponent) -> Self {
        let position = OverlayDesign.defaultPosition(for: component.designKind)
        return Self(horizontal: position.horizontal, vertical: position.vertical)
    }
}

private struct OverlayComponentInstance: Identifiable {
    let id = UUID()
    let component: OverlayComponent
    var showsIcon = true
    var showsBackground = false
    var iconStyle = OverlayTextStyle()
    var valueStyle = OverlayTextStyle()
    var unitStyle = OverlayTextStyle()
    var humidityIconStyle = OverlayTextStyle()
    var humidityValueStyle = OverlayTextStyle()
    var windIconStyle = OverlayTextStyle()
    var windValueStyle = OverlayTextStyle()
    var weather = ManualWeather()
    var distance = DistanceOverlayConfiguration()
    var position: OverlayPosition
    var unit: OverlayUnit

    init(component: OverlayComponent) {
        self.component = component
        unit = OverlayUnit.defaultUnit(for: component)
        position = OverlayPosition.defaultPosition(for: component)
        showsIcon = OverlayDesign.showsIconByDefault(for: component.designKind)
        if component == .weather {
            iconStyle.hexColor = OverlayDesign.weatherIconHexColor
        }
    }
}

private enum OverlayUnit: String, CaseIterable, Identifiable {
    case automatic
    case kilometers
    case miles
    case pacePerKilometer
    case pacePerMile
    case beatsPerMinute
    case stepsPerMinute
    case centimeters
    case meters
    case feet
    case elapsedTime
    case dateTime
    case coordinates
    case weather

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: return "自动"
        case .kilometers: return "公里"
        case .miles: return "英里"
        case .pacePerKilometer: return "/km"
        case .pacePerMile: return "/mi"
        case .beatsPerMinute: return "bpm"
        case .stepsPerMinute: return "spm"
        case .centimeters: return "厘米"
        case .meters: return "米"
        case .feet: return "英尺"
        case .elapsedTime: return "时:分:秒"
        case .dateTime: return "年月日时分秒"
        case .coordinates: return "经纬度"
        case .weather: return "天气"
        }
    }

    static func defaultUnit(for component: OverlayComponent) -> OverlayUnit {
        switch component {
        case .distance: return .kilometers
        case .pace: return .pacePerKilometer
        case .heartRate: return .beatsPerMinute
        case .cadence: return .stepsPerMinute
        case .strideLength: return .centimeters
        case .gpsTrack: return .coordinates
        case .elapsedTime: return .elapsedTime
        case .activityDateTime: return .dateTime
        case .weather: return .weather
        }
    }

    static func options(for component: OverlayComponent) -> [OverlayUnit] {
        switch component {
        case .distance: return [.kilometers, .miles]
        case .pace: return [.pacePerKilometer, .pacePerMile]
        case .heartRate: return [.beatsPerMinute]
        case .cadence: return [.stepsPerMinute]
        case .strideLength: return [.centimeters, .meters, .feet]
        case .gpsTrack: return [.coordinates]
        case .elapsedTime: return [.elapsedTime]
        case .activityDateTime: return [.dateTime]
        case .weather: return [.weather]
        }
    }
}

private struct OverlayCanvas: View {
    @Binding var overlays: [OverlayComponentInstance]
    @Binding var selectedOverlayID: UUID?
    let activity: FitActivity?
    let activityTime: Double
    @State private var dragStartPositions: [UUID: OverlayPosition] = [:]

    var body: some View {
        GeometryReader { geometry in
            let componentScale = OverlayDesign.componentScale(forCanvasSize: geometry.size)

            ZStack(alignment: .topLeading) {
                ForEach(overlays.indices, id: \.self) { index in
                    let overlay = overlays[index]
                    overlayContent(for: overlay, renderScale: componentScale)
                        .contentShape(Rectangle())
                        .position(
                            x: geometry.size.width * overlay.position.horizontal,
                            y: geometry.size.height * overlay.position.vertical
                        )
                        .onTapGesture {
                            selectedOverlayID = overlay.id
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let overlayID = overlay.id
                                    selectedOverlayID = overlayID
                                    let startPosition = dragStartPositions[overlayID] ?? overlay.position
                                    dragStartPositions[overlayID] = startPosition
                                    overlays[index].position = OverlayPosition(
                                        horizontal: min(max(
                                            startPosition.horizontal + Double(value.translation.width / max(geometry.size.width, 1)),
                                            0
                                        ), 1),
                                        vertical: min(max(
                                            startPosition.vertical + Double(value.translation.height / max(geometry.size.height, 1)),
                                            0
                                        ), 1)
                                    )
                                }
                                .onEnded { _ in
                                    dragStartPositions.removeValue(forKey: overlay.id)
                                }
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(!overlays.isEmpty)
    }

    @ViewBuilder
    private func overlayContent(
        for overlay: OverlayComponentInstance,
        renderScale: CGFloat
    ) -> some View {
        if overlay.component == .distance {
            DistanceProgressOverlay(
                overlay: overlay,
                display: DistanceOverlayDisplay(
                    activity: activity,
                    activityTime: activityTime,
                    unit: overlay.unit,
                    configuration: overlay.distance
                ),
                isSelected: selectedOverlayID == overlay.id,
                renderScale: renderScale
            )
        } else if overlay.component == .gpsTrack,
           let activity,
           activity.gpsPoints.count > 1 {
            GPSRouteOverlay(
                activity: activity,
                activityTime: activityTime,
                renderScale: renderScale
            )
        } else if overlay.component == .activityDateTime {
            OverlayDateTimeBadge(
                overlay: overlay,
                display: overlay.component.dateTimeDisplayValue(in: activity, at: activityTime),
                isSelected: selectedOverlayID == overlay.id,
                renderScale: renderScale
            )
        } else if overlay.component == .weather {
            ManualWeatherBadge(
                overlay: overlay,
                isSelected: selectedOverlayID == overlay.id,
                renderScale: renderScale
            )
        } else {
            OverlayBadge(
                overlay: overlay,
                display: overlay.component.overlayDisplayValue(in: activity, unit: overlay.unit, at: activityTime),
                isSelected: selectedOverlayID == overlay.id,
                renderScale: renderScale
            )
        }
    }
}

private struct DistanceProgressOverlay: View {
    let overlay: OverlayComponentInstance
    let display: DistanceOverlayDisplay
    let isSelected: Bool
    let renderScale: CGFloat

    private var configuration: DistanceOverlayConfiguration {
        overlay.distance
    }

    private var length: CGFloat {
        max(120, configuration.length) * renderScale
    }

    private var lineWidth: CGFloat {
        max(1, configuration.lineWidth) * renderScale
    }

    private var progressWidth: CGFloat {
        length * display.progress
    }

    private var markerSize: CGFloat {
        max(10 * renderScale, lineWidth * 2.4)
    }

    private var markerPosition: CGFloat {
        min(max(progressWidth, markerSize / 2), length - markerSize / 2)
    }

    private var trackHeight: CGFloat {
        max(16 * renderScale, markerSize)
    }

    private var currentLabelWidth: CGFloat {
        let estimatedWidth = CGFloat(formattedDistance(display.currentDistance).count)
            * configuration.currentValueStyle.fontSize * renderScale * 0.62
        return min(length, max(60 * renderScale, estimatedWidth))
    }

    private func formattedDistance(_ distance: Double) -> String {
        String(format: "%.2f %@", distance, display.unit)
    }

    var body: some View {
        VStack(spacing: 5 * renderScale) {
            HStack(spacing: 8 * renderScale) {
                if configuration.showsStartDistance {
                    Text(formattedDistance(display.startDistance))
                        .monospacedDigit()
                        .lineLimit(1)
                        .font(.system(
                            size: configuration.startValueStyle.fontSize * renderScale,
                            weight: .semibold,
                            design: .rounded
                        ))
                        .foregroundStyle(Color(hexColor: configuration.startValueStyle.hexColor))
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if configuration.showsEndDistance {
                    Text(formattedDistance(display.endDistance))
                        .monospacedDigit()
                        .lineLimit(1)
                        .font(.system(
                            size: configuration.endValueStyle.fontSize * renderScale,
                            weight: .semibold,
                            design: .rounded
                        ))
                        .foregroundStyle(Color(hexColor: configuration.endValueStyle.hexColor))
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: length, height: max(
                configuration.showsStartDistance ? configuration.startValueStyle.fontSize * renderScale : 0,
                configuration.showsEndDistance ? configuration.endValueStyle.fontSize * renderScale : 0
            ))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(hexColor: configuration.lineHexColor))
                    .frame(width: length, height: lineWidth)

                if progressWidth > 0 {
                    Capsule()
                        .fill(Color(hexColor: configuration.progressHexColor))
                        .frame(width: progressWidth, height: lineWidth)
                }

                if configuration.showsScale {
                    DistanceScaleShape(
                        progressValues: display.kilometerTickProgresses.filter { $0 <= display.progress },
                        tickHalfHeight: 4 * renderScale
                    )
                        .stroke(
                            Color(hexColor: configuration.progressHexColor),
                            style: StrokeStyle(
                                lineWidth: max(renderScale, lineWidth * 0.35),
                                lineCap: .round
                            )
                        )

                    DistanceScaleShape(
                        progressValues: display.kilometerTickProgresses.filter { $0 > display.progress },
                        tickHalfHeight: 4 * renderScale
                    )
                        .stroke(
                            Color(hexColor: configuration.lineHexColor),
                            style: StrokeStyle(
                                lineWidth: max(renderScale, lineWidth * 0.35),
                                lineCap: .round
                            )
                        )
                }

                Circle()
                    .fill(Color(hexColor: configuration.progressHexColor))
                    .frame(width: markerSize, height: markerSize)
                    .shadow(color: .black.opacity(0.45), radius: renderScale)
                    .position(x: markerPosition, y: trackHeight / 2)
            }
            .frame(width: length, height: trackHeight)

            ZStack {
                if configuration.showsCurrentDistance {
                    Text(formattedDistance(display.currentDistance))
                        .monospacedDigit()
                        .lineLimit(1)
                        .font(.system(
                            size: configuration.currentValueStyle.fontSize * renderScale,
                            weight: .semibold,
                            design: .rounded
                        ))
                        .foregroundStyle(Color(hexColor: configuration.currentValueStyle.hexColor))
                        .minimumScaleFactor(0.5)
                        .frame(width: currentLabelWidth)
                        .position(
                            x: markerPosition,
                            y: configuration.currentValueStyle.fontSize * renderScale / 2
                        )
                }
            }
            .frame(
                width: length,
                height: configuration.showsCurrentDistance
                    ? configuration.currentValueStyle.fontSize * renderScale
                    : 0
            )
        }
        .padding(6 * renderScale)
        .overlay {
            RoundedRectangle(cornerRadius: 4 * renderScale)
                .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2 * renderScale)
        }
        .contentShape(Rectangle())
    }
}

private struct DistanceScaleShape: Shape {
    let progressValues: [Double]
    let tickHalfHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for progress in progressValues {
            let x = rect.minX + rect.width * min(max(progress, 0), 1)
            path.move(to: CGPoint(x: x, y: rect.midY - tickHalfHeight))
            path.addLine(to: CGPoint(x: x, y: rect.midY + tickHalfHeight))
        }
        return path
    }
}

private struct GPSRouteOverlay: View {
    let activity: FitActivity
    let activityTime: Double
    let renderScale: CGFloat
    private let routeColor = Color(hexColor: OverlayDesign.gpsRouteHexColor)

    private var gpsRenderScale: CGFloat {
        OverlayDesign.gpsRenderScale(forComponentScale: renderScale)
    }

    private var renderedSize: CGSize {
        OverlayDesign.gpsRenderedSize(forComponentScale: renderScale)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = GPSRouteLayout(
                points: activity.gpsPoints,
                startDate: activity.startDate,
                activityTime: activityTime,
                size: geometry.size,
                padding: Double(10 * gpsRenderScale)
            )

            ZStack {
                GPSRouteShape(points: layout.points)
                    .stroke(
                        routeColor,
                        style: StrokeStyle(
                            lineWidth: 3 * gpsRenderScale,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )

                if let currentPosition = layout.currentPosition {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 13 * gpsRenderScale, weight: .bold))
                        .foregroundStyle(.red)
                        .rotationEffect(.degrees(layout.headingDegrees ?? 0))
                        .position(currentPosition)
                }
            }
        }
        .frame(
            width: renderedSize.width,
            height: renderedSize.height
        )
        .contentShape(Rectangle())
    }
}

private struct GPSRouteShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        guard let firstPoint = points.first else {
            return Path()
        }

        var path = Path()
        path.move(to: firstPoint)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }
}

private struct GPSRouteLayout {
    let points: [CGPoint]
    let currentPosition: CGPoint?
    let headingDegrees: Double?

    init(
        points gpsPoints: [FitGPSPoint],
        startDate: Date?,
        activityTime: Double,
        size: CGSize,
        padding: Double = 10
    ) {
        guard gpsPoints.count > 1 else {
            points = []
            currentPosition = nil
            headingDegrees = nil
            return
        }

        let latitudeSum = gpsPoints.map { $0.latitude }.reduce(0.0, +)
        let meanLatitudeRadians = latitudeSum / Double(gpsPoints.count) * Double.pi / 180
        let projectedPoints: [(x: Double, y: Double)] = gpsPoints.map { point in
            (
                x: point.longitude * cos(meanLatitudeRadians),
                y: point.latitude
            )
        }

        let horizontalValues = projectedPoints.map { $0.x }
        let verticalValues = projectedPoints.map { $0.y }
        let minimumX = horizontalValues.min() ?? 0
        let maximumX = horizontalValues.max() ?? 0
        let minimumY = verticalValues.min() ?? 0
        let maximumY = verticalValues.max() ?? 0
        let horizontalRange = max(maximumX - minimumX, 0.000_001)
        let verticalRange = max(maximumY - minimumY, 0.000_001)
        let scale = min(
            max(Double(size.width) - padding * 2, 1) / horizontalRange,
            max(Double(size.height) - padding * 2, 1) / verticalRange
        )
        let midpointX = (minimumX + maximumX) / 2
        let midpointY = (minimumY + maximumY) / 2

        points = projectedPoints.map { point in
            let x = Double(size.width) / 2 + (point.x - midpointX) * scale
            let y = Double(size.height) / 2 - (point.y - midpointY) * scale
            return CGPoint(x: x, y: y)
        }

        let currentIndex: Int
        if let startDate {
            let targetDate = startDate.addingTimeInterval(max(0, activityTime))
            currentIndex = gpsPoints.lastIndex {
                guard let timestamp = $0.timestamp else {
                    return false
                }
                return timestamp <= targetDate
            } ?? 0
        } else {
            currentIndex = points.count - 1
        }

        currentPosition = points[currentIndex]
        if currentIndex > 0 {
            let previous = points[currentIndex - 1]
            let current = points[currentIndex]
            headingDegrees = atan2(current.x - previous.x, previous.y - current.y) * 180 / .pi
        } else if points.count > 1 {
            let next = points[1]
            let current = points[0]
            headingDegrees = atan2(next.x - current.x, current.y - next.y) * 180 / .pi
        } else {
            headingDegrees = nil
        }
    }
}

private struct OverlayBadge: View {
    let overlay: OverlayComponentInstance
    let display: OverlayDisplayValue
    let isSelected: Bool
    let renderScale: CGFloat

    private var iconColumnWidth: CGFloat {
        OverlayDesign.iconColumnWidth(fontSize: overlay.iconStyle.fontSize) * renderScale
    }

    private var backgroundColor: Color {
        overlay.showsBackground ? .black.opacity(OverlayDesign.badgeBackgroundOpacity) : .clear
    }

    private var iconRotation: Angle {
        .degrees(OverlayDesign.iconRotationDegrees(for: overlay.component.designKind))
    }

    private var iconScale: CGFloat {
        OverlayDesign.iconScale(for: overlay.component.designKind)
    }

    private var reservesThreeDigitValueWidth: Bool {
        OverlayDesign.reservesThreeDigitValueWidth(for: overlay.component.designKind)
    }

    private var fixedMetricContentWidth: CGFloat? {
        OverlayDesign.fixedMetricContentWidth(
            for: overlay.component.designKind,
            iconFontSize: overlay.iconStyle.fontSize,
            valueFontSize: overlay.valueStyle.fontSize,
            unitFontSize: overlay.unitStyle.fontSize
        ).map { $0 * renderScale }
    }

    private var valueUnitSpacing: CGFloat {
        OverlayDesign.valueUnitSpacing(for: overlay.component.designKind) * renderScale
    }

    private var fixedValueUnitContentWidth: CGFloat? {
        OverlayDesign.fixedValueUnitContentWidth(
            for: overlay.component.designKind,
            valueFontSize: overlay.valueStyle.fontSize,
            unitFontSize: overlay.unitStyle.fontSize
        ).map { $0 * renderScale }
    }

    var body: some View {
        HStack(spacing: OverlayDesign.badgeContentSpacing * renderScale) {
            if overlay.showsIcon {
                Image(systemName: overlay.component.systemImage)
                    .font(.system(
                        size: overlay.iconStyle.fontSize * renderScale * iconScale,
                        weight: .semibold,
                        design: .rounded
                    ))
                    .foregroundStyle(Color(hexColor: overlay.iconStyle.hexColor))
                    .rotationEffect(iconRotation)
                    .frame(
                        width: iconColumnWidth,
                        height: overlay.iconStyle.fontSize * renderScale
                    )
            }
            HStack(spacing: valueUnitSpacing) {
                ZStack(alignment: .leading) {
                    if reservesThreeDigitValueWidth {
                        Text("000")
                            .monospacedDigit()
                            .lineLimit(1)
                            .font(.system(
                                size: overlay.valueStyle.fontSize * renderScale,
                                weight: .semibold,
                                design: .rounded
                            ))
                            .hidden()
                    }
                    Text(display.value)
                        .monospacedDigit()
                        .lineLimit(1)
                        .font(.system(
                            size: overlay.valueStyle.fontSize * renderScale,
                            weight: .semibold,
                            design: .rounded
                        ))
                        .foregroundStyle(Color(hexColor: overlay.valueStyle.hexColor))
                }
                .fixedSize(horizontal: true, vertical: false)
                if !display.unit.isEmpty {
                    Text(display.unit)
                        .monospacedDigit()
                        .lineLimit(1)
                        .font(.system(
                            size: overlay.unitStyle.fontSize * renderScale,
                            weight: .semibold,
                            design: .rounded
                        ))
                        .foregroundStyle(Color(hexColor: overlay.unitStyle.hexColor))
                }
            }
            .frame(minWidth: fixedValueUnitContentWidth, alignment: .leading)
        }
        .frame(minWidth: fixedMetricContentWidth, alignment: .leading)
        .padding(.horizontal, OverlayDesign.badgeHorizontalPadding * renderScale)
        .padding(.vertical, OverlayDesign.badgeVerticalPadding * renderScale)
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: OverlayDesign.badgeCornerRadius * renderScale)
                .stroke(
                    isSelected ? Color.accentColor : .clear,
                    lineWidth: 2 * renderScale
                )
        }
        .clipShape(RoundedRectangle(
            cornerRadius: OverlayDesign.badgeCornerRadius * renderScale
        ))
    }
}

private struct OverlayDateTimeBadge: View {
    let overlay: OverlayComponentInstance
    let display: OverlayDateTimeDisplay
    let isSelected: Bool
    let renderScale: CGFloat

    private var backgroundColor: Color {
        overlay.showsBackground ? .black.opacity(OverlayDesign.badgeBackgroundOpacity) : .clear
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2 * renderScale) {
            Text(display.time)
                .monospacedDigit()
                .font(.system(
                    size: overlay.valueStyle.fontSize * renderScale,
                    weight: .semibold,
                    design: .rounded
                ))
                .foregroundStyle(Color(hexColor: overlay.valueStyle.hexColor))
            if !display.date.isEmpty {
                Text(display.date)
                    .monospacedDigit()
                    .font(.system(
                        size: overlay.unitStyle.fontSize * renderScale,
                        weight: .semibold,
                        design: .rounded
                    ))
                    .foregroundStyle(Color(hexColor: overlay.unitStyle.hexColor))
            }
        }
        .padding(.horizontal, OverlayDesign.badgeHorizontalPadding * renderScale)
        .padding(.vertical, OverlayDesign.badgeVerticalPadding * renderScale)
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: OverlayDesign.badgeCornerRadius * renderScale)
                .stroke(
                    isSelected ? Color.accentColor : .clear,
                    lineWidth: 2 * renderScale
                )
        }
        .clipShape(RoundedRectangle(
            cornerRadius: OverlayDesign.badgeCornerRadius * renderScale
        ))
    }
}

private struct ManualWeatherBadge: View {
    let overlay: OverlayComponentInstance
    let isSelected: Bool
    let renderScale: CGFloat

    private var backgroundColor: Color {
        overlay.showsBackground ? .black.opacity(OverlayDesign.badgeBackgroundOpacity) : .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2 * renderScale) {
            HStack(spacing: OverlayDesign.badgeContentSpacing * renderScale) {
                if overlay.showsIcon {
                    Image(systemName: overlay.weather.condition.systemImage)
                        .font(.system(
                            size: overlay.iconStyle.fontSize * renderScale,
                            weight: .semibold
                        ))
                        .foregroundStyle(Color(hexColor: overlay.iconStyle.hexColor))
                }
                Text(String(format: "%.0f°C", overlay.weather.temperatureCelsius))
                    .monospacedDigit()
                    .font(.system(
                        size: overlay.valueStyle.fontSize * renderScale,
                        weight: .semibold,
                        design: .rounded
                    ))
                    .foregroundStyle(Color(hexColor: overlay.valueStyle.hexColor))
                Image(systemName: "humidity.fill")
                    .font(.system(
                        size: overlay.humidityIconStyle.fontSize * renderScale,
                        weight: .medium
                    ))
                    .foregroundStyle(Color(hexColor: overlay.humidityIconStyle.hexColor))
                Text(String(format: "%.0f%%", overlay.weather.humidityPercent))
                    .monospacedDigit()
                    .font(.system(
                        size: overlay.humidityValueStyle.fontSize * renderScale,
                        weight: .medium,
                        design: .rounded
                    ))
                    .foregroundStyle(Color(hexColor: overlay.humidityValueStyle.hexColor))
            }
            HStack(spacing: OverlayDesign.badgeContentSpacing * renderScale) {
                Image(systemName: "wind")
                    .font(.system(
                        size: overlay.windIconStyle.fontSize * renderScale,
                        weight: .medium
                    ))
                    .foregroundStyle(Color(hexColor: overlay.windIconStyle.hexColor))
                Text(
                    String(
                        format: "%@ %.1f km/h",
                        overlay.weather.windDirection.title,
                        overlay.weather.windSpeedKilometersPerHour
                    )
                )
                .monospacedDigit()
                .font(.system(
                    size: overlay.windValueStyle.fontSize * renderScale,
                    weight: .medium,
                    design: .rounded
                ))
                .foregroundStyle(Color(hexColor: overlay.windValueStyle.hexColor))
            }
        }
        .padding(.horizontal, OverlayDesign.badgeHorizontalPadding * renderScale)
        .padding(.vertical, OverlayDesign.badgeVerticalPadding * renderScale)
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: OverlayDesign.badgeCornerRadius * renderScale)
                .stroke(
                    isSelected ? Color.accentColor : .clear,
                    lineWidth: 2 * renderScale
                )
        }
        .clipShape(RoundedRectangle(
            cornerRadius: OverlayDesign.badgeCornerRadius * renderScale
        ))
    }
}

private struct OverlayAddPanel: View {
    let addComponent: (OverlayComponent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OverlayComponentAddMenu(addComponent: addComponent)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct OverlayComponentAddMenu: View {
    let addComponent: (OverlayComponent) -> Void
    var isCompact = false

    var body: some View {
        Menu {
            Button {
                for component in OverlayComponent.allCases {
                    addComponent(component)
                }
            } label: {
                Label("添加所有组件", systemImage: "plus.circle")
            }

            Divider()

            ForEach(OverlayComponent.allCases) { component in
                Button {
                    addComponent(component)
                } label: {
                    Label(component.title, systemImage: component.systemImage)
                }
            }
        } label: {
            if isCompact {
                Image(systemName: "plus")
            } else {
                Label("添加浮层", systemImage: "plus")
            }
        }
        .help("添加浮层")
    }
}

private struct OverlayInspector: View {
    @Binding var overlay: OverlayComponentInstance
    let addComponent: (OverlayComponent) -> Void
    let delete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label(overlay.component.title, systemImage: overlay.component.systemImage)
                        .font(.headline)
                    Spacer()
                    OverlayComponentAddMenu(addComponent: addComponent, isCompact: true)
                    Button(role: .destructive, action: delete) {
                        Image(systemName: "trash")
                    }
                    .foregroundStyle(.red)
                    .help("删除该组件")
                }

                OverlayPositionEditor(position: $overlay.position)

                if overlay.component.supportsBackground {
                    Toggle("显示半透明背景", isOn: $overlay.showsBackground)
                }

                if overlay.component == .distance {
                    DistanceOverlayEditor(
                        configuration: $overlay.distance,
                        unit: $overlay.unit
                    )
                } else if overlay.component == .activityDateTime {
                    OverlayTextStyleEditor(title: "时间", style: $overlay.valueStyle)
                    OverlayTextStyleEditor(title: "日期", style: $overlay.unitStyle)
                } else if overlay.component == .weather {
                    ManualWeatherEditor(weather: $overlay.weather)
                    Toggle("显示图标", isOn: $overlay.showsIcon)
                    OverlayTextStyleEditor(title: "天气图标", style: $overlay.iconStyle)
                    OverlayTextStyleEditor(title: "温度", style: $overlay.valueStyle)
                    OverlayTextStyleEditor(title: "湿度图标", style: $overlay.humidityIconStyle)
                    OverlayTextStyleEditor(title: "湿度", style: $overlay.humidityValueStyle)
                    OverlayTextStyleEditor(title: "风力图标", style: $overlay.windIconStyle)
                    OverlayTextStyleEditor(title: "风向和风速", style: $overlay.windValueStyle)
                } else {
                    Toggle("显示图标", isOn: $overlay.showsIcon)

                    OverlayTextStyleEditor(title: "图标", style: $overlay.iconStyle)
                    OverlayTextStyleEditor(title: "数值", style: $overlay.valueStyle)
                    OverlayTextStyleEditor(title: "单位", style: $overlay.unitStyle)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("数据单位")
                        Picker("单位", selection: $overlay.unit) {
                            ForEach(OverlayUnit.options(for: overlay.component)) { unit in
                                Text(unit.title).tag(unit)
                            }
                        }
                        .labelsHidden()
                    }
                }

                Spacer()
            }
        }
    }
}

private struct DistanceOverlayEditor: View {
    @Binding var configuration: DistanceOverlayConfiguration
    @Binding var unit: OverlayUnit

    private static let distanceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 0
        formatter.maximum = 100_000
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let lineWidthFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 1
        formatter.maximum = 16
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private static let lengthFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 120
        formatter.maximum = 1_200
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("距离范围")
                    .font(.subheadline.weight(.semibold))

                Picker("单位", selection: $unit) {
                    ForEach(OverlayUnit.options(for: .distance)) { option in
                        Text(option.title).tag(option)
                    }
                }

                HStack {
                    Text("开始距离")
                    Spacer()
                    TextField("0.00", value: $configuration.startDistance, formatter: Self.distanceFormatter)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                    Text(unit.title)
                        .foregroundStyle(.secondary)
                }

                Toggle("结束距离跟随 FIT", isOn: $configuration.usesActivityEndDistance)

                HStack {
                    Text("结束距离")
                    Spacer()
                    TextField("10.00", value: $configuration.endDistance, formatter: Self.distanceFormatter)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .disabled(configuration.usesActivityEndDistance)
                    Text(unit.title)
                        .foregroundStyle(.secondary)
                }
                .opacity(configuration.usesActivityEndDistance ? 0.5 : 1)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("显示内容")
                    .font(.subheadline.weight(.semibold))
                Toggle("开始距离", isOn: $configuration.showsStartDistance)
                Toggle("当前距离", isOn: $configuration.showsCurrentDistance)
                Toggle("结束距离", isOn: $configuration.showsEndDistance)
                Toggle("显示每公里刻度", isOn: $configuration.showsScale)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("线条")
                    .font(.subheadline.weight(.semibold))

                HStack {
                    Text("线宽")
                    Slider(value: $configuration.lineWidth, in: 1...16, step: 0.5)
                    TextField("4", value: $configuration.lineWidth, formatter: Self.lineWidthFormatter)
                        .frame(width: 48)
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    Text("组件长度")
                    Slider(value: $configuration.length, in: 120...1_200, step: 10)
                    TextField("650", value: $configuration.length, formatter: Self.lengthFormatter)
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                }

                OverlayColorEditor(title: "线条颜色", hexColor: $configuration.lineHexColor)
                OverlayColorEditor(title: "进度条颜色", hexColor: $configuration.progressHexColor)
            }

            if configuration.showsStartDistance {
                OverlayTextStyleEditor(title: "开始距离数值", style: $configuration.startValueStyle)
            }
            if configuration.showsCurrentDistance {
                OverlayTextStyleEditor(title: "当前距离数值", style: $configuration.currentValueStyle)
            }
            if configuration.showsEndDistance {
                OverlayTextStyleEditor(title: "结束距离数值", style: $configuration.endValueStyle)
            }
        }
    }
}

private struct ManualWeatherEditor: View {
    @Binding var weather: ManualWeather

    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = -99
        formatter.maximum = 999
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("天气信息")
                .font(.subheadline.weight(.semibold))

            Picker("天气", selection: $weather.condition) {
                ForEach(WeatherCondition.allCases) { condition in
                    Label(condition.title, systemImage: condition.systemImage)
                        .tag(condition)
                }
            }

            Picker("风向", selection: $weather.windDirection) {
                ForEach(WindDirection.allCases) { direction in
                    Text(direction.title).tag(direction)
                }
            }

            HStack {
                Text("风速")
                TextField("km/h", value: $weather.windSpeedKilometersPerHour, formatter: Self.decimalFormatter)
                    .multilineTextAlignment(.trailing)
                Text("km/h")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("温度")
                TextField("°C", value: $weather.temperatureCelsius, formatter: Self.decimalFormatter)
                    .multilineTextAlignment(.trailing)
                Text("°C")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("湿度")
                TextField("%", value: $weather.humidityPercent, formatter: Self.decimalFormatter)
                    .multilineTextAlignment(.trailing)
                Text("%")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct OverlayColorEditor: View {
    let title: String
    @Binding var hexColor: String

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hexColor: hexColor) },
            set: { hexColor = $0.hexColorString }
        )
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            ColorPicker(title, selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
            TextField("#RRGGBB", text: $hexColor)
                .frame(width: 88)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct OverlayPositionEditor: View {
    @Binding var position: OverlayPosition

    private static let percentageFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 0
        formatter.maximum = 100
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private func percentageBinding(_ keyPath: WritableKeyPath<OverlayPosition, Double>) -> Binding<Double> {
        Binding(
            get: { position[keyPath: keyPath] * 100 },
            set: { position[keyPath: keyPath] = min(max($0 / 100, 0), 1) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("位置")
                .font(.subheadline.weight(.semibold))

            HStack {
                Text("水平")
                Slider(value: $position.horizontal, in: 0...1, step: 0.01)
                TextField("0", value: percentageBinding(\.horizontal), formatter: Self.percentageFormatter)
                    .frame(width: 48)
                    .multilineTextAlignment(.trailing)
                Text("%")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("垂直")
                Slider(value: $position.vertical, in: 0...1, step: 0.01)
                TextField("0", value: percentageBinding(\.vertical), formatter: Self.percentageFormatter)
                    .frame(width: 48)
                    .multilineTextAlignment(.trailing)
                Text("%")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct OverlayTextStyleEditor: View {
    let title: String
    @Binding var style: OverlayTextStyle

    private static let fontSizeFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 8
        formatter.maximum = 96
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hexColor: style.hexColor) },
            set: { style.hexColor = $0.hexColorString }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            HStack {
                Text("字号")
                Slider(value: $style.fontSize, in: 8...96, step: 1)
                TextField("22", value: $style.fontSize, formatter: Self.fontSizeFormatter)
                    .frame(width: 48)
                    .multilineTextAlignment(.trailing)
            }

            HStack {
                Text("颜色")
                ColorPicker("颜色", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
                TextField("#RRGGBB", text: $style.hexColor)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct AssetRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var isSelected = false
    var onSelect: (() -> Void)?
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { onSelect?() }) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(Color.accentColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(onSelect == nil)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除 \(title)")
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct MaterialSection<Content: View, Footer: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
            footer
        }
    }
}

private struct EmptyMaterialRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }
}

private struct ExportOverlayRange {
    let videoFileName: String
    let fitFileName: String
    let resolution: CGSize
    let timelineStart: Double
    let timelineEnd: Double
    let exportsCompleteDataLayer: Bool

    var duration: Double {
        timelineEnd - timelineStart
    }

    var sourceResolutionDescription: String {
        String(format: "%.0f × %.0f", resolution.width, resolution.height)
    }

    func outputResolution(for preset: OverlayExportResolution) -> CGSize {
        preset.resolution(matching: resolution)
    }

    func outputResolutionDescription(for preset: OverlayExportResolution) -> String {
        let outputResolution = outputResolution(for: preset)
        return String(format: "%.0f × %.0f", outputResolution.width, outputResolution.height)
    }

    var durationDescription: String {
        formattedExportDuration(duration)
    }

    var timelineRangeDescription: String {
        "\(formattedExportDuration(timelineStart)) - \(formattedExportDuration(timelineEnd))"
    }

    func estimatedFileSizeDescription(
        resolution preset: OverlayExportResolution,
        frameRate: OverlayExportFrameRate
    ) -> String {
        let outputResolution = outputResolution(for: preset)
        let width = max(2, Int(outputResolution.width.rounded()) / 2 * 2)
        let height = max(2, Int(outputResolution.height.rounded()) / 2 * 2)
        let estimatedBytes = OverlayVideoEncoding.estimatedFileSize(
            width: width,
            height: height,
            framesPerSecond: frameRate.rawValue,
            duration: duration
        )
        return ByteCountFormatter.string(fromByteCount: estimatedBytes, countStyle: .file)
    }
}

private struct ExportOverlaySheet: View {
    let exportRange: ExportOverlayRange?
    @Binding var exportsCompleteDataLayer: Bool
    @Binding var exportResolution: OverlayExportResolution
    @Binding var exportFrameRate: OverlayExportFrameRate
    let isExporting: Bool
    let exportProgress: Double
    let exportStatus: ExportStatus?
    let export: (ExportOverlayRange) -> Void
    let cancelExport: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("导出透明数据层", systemImage: "square.and.arrow.up")
                    .font(.headline)
                Spacer()
                Button(action: dismiss.callAsFunction) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("关闭")
                .disabled(isExporting)
            }

            Toggle("导出完整数据层", isOn: $exportsCompleteDataLayer)
                .disabled(isExporting)

            VStack(alignment: .leading, spacing: 8) {
                Text("分辨率")
                    .font(.subheadline.weight(.semibold))
                Picker("分辨率", selection: $exportResolution) {
                    ForEach(OverlayExportResolution.allCases) { resolution in
                        Text(resolution.title).tag(resolution)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isExporting)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("帧率")
                    .font(.subheadline.weight(.semibold))
                Picker("帧率", selection: $exportFrameRate) {
                    ForEach(OverlayExportFrameRate.allCases) { frameRate in
                        Text(frameRate.title).tag(frameRate)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(isExporting)
            }

            if let exportRange {
                Text(
                    exportRange.exportsCompleteDataLayer
                        ? "导出 FIT 对应的完整数据层。"
                        : "仅导出视频素材与 FIT 数据重叠的部分。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                ExportInfoRow(title: "源视频分辨率", value: exportRange.sourceResolutionDescription)
                ExportInfoRow(
                    title: "导出分辨率",
                    value: exportRange.outputResolutionDescription(for: exportResolution)
                )
                ExportInfoRow(title: "导出帧率", value: exportFrameRate.title)
                ExportInfoRow(title: "时长", value: exportRange.durationDescription)
                ExportInfoRow(title: "时间线范围", value: exportRange.timelineRangeDescription)
                ExportInfoRow(
                    title: "预计大小",
                    value: exportRange.estimatedFileSizeDescription(
                        resolution: exportResolution,
                        frameRate: exportFrameRate
                    )
                )
                ExportInfoRow(title: "视频素材", value: exportRange.videoFileName)
                ExportInfoRow(title: "运动文件", value: exportRange.fitFileName)

                Text("预计大小基于针对透明数据层优化的 HEVC Alpha 码率，实际结果会随图层复杂度变化。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("暂时无法计算导出范围")
                        .font(.subheadline.weight(.semibold))
                    Text("请导入包含有效时长的视频和 FIT 运动文件，并在时间线上让两者重叠；或者勾选“导出完整数据层”以导出 FIT 的完整范围。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if isExporting {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView(value: exportProgress) {
                        Text("正在导出透明数据层")
                    } currentValueLabel: {
                        Text("\(Int((exportProgress * 100).rounded()))%")
                    }

                    Button(role: .cancel, action: cancelExport) {
                        Label("取消导出", systemImage: "xmark.circle")
                    }
                }
            } else if let exportStatus {
                Text(exportStatus.message)
                    .font(.caption)
                    .foregroundStyle(exportStatus.color)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                if case .success = exportStatus {
                    Button(action: dismiss.callAsFunction) {
                        Label("关闭", systemImage: "xmark")
                    }
                } else {
                    Button {
                        if let exportRange {
                            export(exportRange)
                        }
                    } label: {
                        Label("导出浮层", systemImage: "square.and.arrow.up")
                    }
                    .disabled(exportRange == nil || isExporting)
                }
            }
        }
        .padding(20)
        .frame(width: 440, alignment: .topLeading)
        .frame(minHeight: 300, alignment: .topLeading)
    }
}

private struct ExportInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }
}

private enum ExportStatus {
    case success(String)
    case cancelled(String)
    case failure(String)

    var message: String {
        switch self {
        case let .success(message), let .cancelled(message), let .failure(message):
            return message
        }
    }

    var color: Color {
        switch self {
        case .success:
            return .green
        case .cancelled:
            return .secondary
        case .failure:
            return .red
        }
    }
}

private struct OverlayVideoExportConfiguration {
    let outputURL: URL
    let resolution: CGSize
    let framesPerSecond: Int32
    let timelineStart: Double
    let duration: Double
    let fitTimelineOffset: Double
    let activity: FitActivity
    let overlays: [OverlayComponentInstance]

    var outputWidth: Int {
        max(2, Int(resolution.width.rounded()) / 2 * 2)
    }

    var outputHeight: Int {
        max(2, Int(resolution.height.rounded()) / 2 * 2)
    }
}

private enum OverlayVideoExporter {
    private enum ExportError: LocalizedError {
        case unsupportedCodec
        case couldNotStartWriting
        case missingPixelBufferPool
        case couldNotCreatePixelBuffer
        case couldNotCreateGraphicsContext
        case couldNotRenderFrame
        case couldNotAppendFrame
        case writingFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedCodec:
                return "此设备不支持 HEVC Alpha 透明视频导出。"
            case .couldNotStartWriting:
                return "无法开始写入透明视频。"
            case .missingPixelBufferPool:
                return "无法创建视频像素缓冲区。"
            case .couldNotCreatePixelBuffer:
                return "无法创建导出帧。"
            case .couldNotCreateGraphicsContext:
                return "无法创建透明图层绘制上下文。"
            case .couldNotRenderFrame:
                return "无法渲染浮层画面。"
            case .couldNotAppendFrame:
                return "无法写入视频帧。"
            case .writingFailed:
                return "透明视频写入失败。"
            }
        }
    }

    @MainActor
    static func export(
        _ configuration: OverlayVideoExportConfiguration,
        progress: @escaping (Double) -> Void
    ) async throws {
        let fileManager = FileManager.default
        try Task.checkCancellation()
        let temporaryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }

        let writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mov)
        var didCompleteExport = false
        defer {
            if !didCompleteExport {
                if writer.status == .writing {
                    writer.cancelWriting()
                }
                if fileManager.fileExists(atPath: temporaryURL.path) {
                    try? fileManager.removeItem(at: temporaryURL)
                }
            }
        }
        let averageBitRate = OverlayVideoEncoding.averageBitRate(
            width: configuration.outputWidth,
            height: configuration.outputHeight,
            framesPerSecond: configuration.framesPerSecond
        )
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: configuration.outputWidth,
            AVVideoHeightKey: configuration.outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: averageBitRate,
                AVVideoExpectedSourceFrameRateKey: Int(configuration.framesPerSecond),
                AVVideoMaxKeyFrameIntervalKey: Int(
                    configuration.framesPerSecond * OverlayVideoEncoding.keyFrameIntervalSeconds
                ),
                AVVideoAllowFrameReorderingKey: true
            ]
        ]
        guard writer.canApply(outputSettings: outputSettings, forMediaType: .video) else {
            throw ExportError.unsupportedCodec
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: configuration.outputWidth,
            kCVPixelBufferHeightKey as String: configuration.outputHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: pixelBufferAttributes
        )
        guard writer.canAdd(input) else {
            throw ExportError.couldNotStartWriting
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? ExportError.couldNotStartWriting
        }
        writer.startSession(atSourceTime: .zero)

        guard let pixelBufferPool = pixelBufferAdaptor.pixelBufferPool else {
            throw ExportError.missingPixelBufferPool
        }

        let framesPerSecond = configuration.framesPerSecond
        let frameCount = max(1, Int(ceil(configuration.duration * Double(framesPerSecond))))
        let hasTimelineDrivenOverlays = configuration.overlays.contains { overlay in
            overlay.component != .weather
        }
        let progressUpdateInterval = max(1, frameCount / 1_000)
        var cachedRenderKey: Int?
        var cachedPixelBuffer: CVPixelBuffer?

        for frameIndex in 0..<frameCount {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            let frameTime = Double(frameIndex) / Double(framesPerSecond)
            let activityTime = configuration.timelineStart + frameTime - configuration.fitTimelineOffset
            let renderKey = hasTimelineDrivenOverlays ? Int(floor(max(0, activityTime))) : 0
            let pixelBuffer: CVPixelBuffer
            if cachedRenderKey == renderKey, let cachedPixelBuffer {
                pixelBuffer = cachedPixelBuffer
            } else {
                pixelBuffer = try autoreleasepool {
                    let frameImage = try renderOverlay(
                        overlays: configuration.overlays,
                        activity: configuration.activity,
                        activityTime: activityTime,
                        width: configuration.outputWidth,
                        height: configuration.outputHeight
                    )
                    return try makePixelBuffer(
                        from: frameImage,
                        pool: pixelBufferPool,
                        width: configuration.outputWidth,
                        height: configuration.outputHeight
                    )
                }
                cachedRenderKey = renderKey
                cachedPixelBuffer = pixelBuffer
            }
            let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: framesPerSecond)
            guard pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                throw writer.error ?? ExportError.couldNotAppendFrame
            }
            if frameIndex.isMultiple(of: progressUpdateInterval) || frameIndex == frameCount - 1 {
                progress(Double(frameIndex + 1) / Double(frameCount))
            }
            await Task.yield()
        }

        input.markAsFinished()
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else {
            throw writer.error ?? ExportError.writingFailed
        }
        if fileManager.fileExists(atPath: configuration.outputURL.path) {
            try fileManager.removeItem(at: configuration.outputURL)
        }
        try fileManager.copyItem(at: temporaryURL, to: configuration.outputURL)
        try fileManager.removeItem(at: temporaryURL)
        didCompleteExport = true
    }

    @MainActor
    private static func renderOverlay(
        overlays: [OverlayComponentInstance],
        activity: FitActivity,
        activityTime: Double,
        width: Int,
        height: Int
    ) throws -> CGImage {
        let overlay = OverlayCanvas(
            overlays: .constant(overlays),
            selectedOverlayID: .constant(nil),
            activity: activity,
            activityTime: max(0, activityTime)
        )
        .frame(width: CGFloat(width), height: CGFloat(height))
        let renderer = ImageRenderer(content: overlay)
        renderer.proposedSize = ProposedViewSize(width: CGFloat(width), height: CGFloat(height))
        renderer.scale = 1
        renderer.isOpaque = false
        guard let image = renderer.cgImage else {
            throw ExportError.couldNotRenderFrame
        }
        return image
    }

    private static func makePixelBuffer(
        from image: CGImage,
        pool: CVPixelBufferPool,
        width: Int,
        height: Int
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else {
            throw ExportError.couldNotCreatePixelBuffer
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(
                  data: baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else {
            throw ExportError.couldNotCreateGraphicsContext
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }
}

private struct VideoImport: Identifiable {
    let id = UUID()
    let url: URL
    let fileCreationDate: Date?
    var duration: Double?
    var resolution: CGSize?

    init(url: URL) {
        self.url = url
        fileCreationDate = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.player = player
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        if playerView.player !== player {
            playerView.player = player
        }
    }
}

private struct TimelineScrollWheelZoom: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.onScroll = onScroll
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.view = view
        context.coordinator.onScroll = onScroll
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        weak var view: NSView?
        var onScroll: ((CGFloat) -> Void)?
        private var monitor: Any?

        func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      let view = self.view,
                      let window = view.window,
                      event.window === window else {
                    return event
                }

                let location = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(location) else {
                    return event
                }

                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
                guard delta != 0 else {
                    return event
                }

                self.onScroll?(delta)
                return nil
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}

private struct TimelineEditor: View {
    let videos: [VideoImport]
    let fitFiles: [FitImport]
    @ObservedObject var playback: PlaybackController
    @Binding var offsets: [UUID: Double]
    @Binding var timelineTime: Double
    let alignmentStatus: String?
    let autoAlign: () -> Void
    let previewTimeline: (Double) -> Void
    let setTimelineScrubbing: (Bool) -> Void
    let seekTimeline: (Double) -> Void

    @State private var zoomScale = 1.0
    @State private var timelineScrollOffset = 0.0
    private let trackLeadingInset = 76.0
    private let trackTrailingInset = 72.0

    private var totalDuration: Double {
        let videoEnd = videos.map { offsets[$0.id, default: 0] + videoDuration(for: $0) }.max() ?? 0
        let workoutEnd = fitFiles.map { offsets[$0.id, default: 0] + workoutDuration(for: $0) }.max() ?? 0
        return max(3_600, videoEnd, workoutEnd)
    }

    private func pixelsPerSecond(for availableWidth: Double) -> Double {
        max(availableWidth - trackLeadingInset, 1) / totalDuration * zoomScale
    }

    private func videoClips(pixelsPerSecond: Double) -> [TimelineClip] {
        videos.map { video in
            TimelineClip(
                id: video.id,
                title: video.url.lastPathComponent,
                duration: videoDuration(for: video),
                kind: .video,
                onSelect: { playback.loadVideo(url: video.url) }
            )
        }
    }

    private func workoutClips(pixelsPerSecond: Double) -> [TimelineClip] {
        fitFiles.map { fitFile in
            TimelineClip(
                id: fitFile.id,
                title: fitFile.fileName,
                duration: workoutDuration(for: fitFile),
                kind: .workout,
                onSelect: {}
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlaybackControls(playback: playback)
                .opacity(playback.videoURL == nil ? 0 : 1)
                .allowsHitTesting(playback.videoURL != nil)

            HStack {
                if let alignmentStatus {
                    Text(alignmentStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(action: autoAlign) {
                    Label("自动对齐", systemImage: "wand.and.stars")
                }
                .disabled(videos.isEmpty || fitFiles.isEmpty)
                .help("按文件创建时间生成初始对齐位置")
            }

            GeometryReader { geometry in
                let pixelsPerSecond = pixelsPerSecond(for: geometry.size.width)
                let timelineWidth = totalDuration * pixelsPerSecond
                let timelineContentWidth = trackLeadingInset + timelineWidth + trackTrailingInset
                let maximumScrollOffset = max(0, timelineContentWidth - geometry.size.width)
                let visibleScrollOffset = min(max(timelineScrollOffset, 0), maximumScrollOffset)

                VStack(spacing: 4) {
                    ZStack(alignment: .topLeading) {
                        ZStack(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 8) {
                                TimelineRuler(
                                    totalDuration: totalDuration,
                                    timelineWidth: timelineWidth,
                                    pixelsPerSecond: pixelsPerSecond
                                )
                                TimelineTrack(
                                    title: "视频",
                                    systemImage: "video.fill",
                                    clips: videoClips(pixelsPerSecond: pixelsPerSecond),
                                    offsets: $offsets,
                                    width: timelineWidth,
                                    pixelsPerSecond: pixelsPerSecond
                                )
                                TimelineTrack(
                                    title: "运动",
                                    systemImage: "figure.run",
                                    clips: workoutClips(pixelsPerSecond: pixelsPerSecond),
                                    offsets: $offsets,
                                    width: timelineWidth,
                                    pixelsPerSecond: pixelsPerSecond
                                )
                            }

                            TimelinePlayhead(
                                time: $timelineTime,
                                totalDuration: totalDuration,
                                pixelsPerSecond: pixelsPerSecond,
                                trackLeadingInset: trackLeadingInset,
                                preview: previewTimeline,
                                setScrubbing: setTimelineScrubbing,
                                seek: seekTimeline
                            )
                                .offset(x: trackLeadingInset + timelineTime * pixelsPerSecond)
                        }
                        .coordinateSpace(name: "timeline")
                        .padding(.vertical, 4)
                        .frame(width: timelineContentWidth, alignment: .leading)
                        .offset(x: -visibleScrollOffset)
                    }
                    .frame(width: geometry.size.width, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                    .background(
                        TimelineScrollWheelZoom { delta in
                            let step = delta / 10
                            let nextScale = zoomScale * pow(1.08, Double(step))
                            zoomScale = min(max(nextScale, 0.5), 8)
                        }
                    )

                    TimelineHorizontalScrollbar(
                        viewportWidth: geometry.size.width,
                        contentWidth: timelineContentWidth,
                        offset: $timelineScrollOffset
                    )
                    .frame(width: geometry.size.width, height: 10)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            .frame(height: 164)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func videoDuration(for video: VideoImport) -> Double {
        if let duration = video.duration {
            return duration
        }
        return playback.videoURL == video.url && playback.duration > 0 ? playback.duration : 60
    }

    private func workoutDuration(for fitFile: FitImport) -> Double {
        guard let startDate = fitFile.activity.startDate, let endDate = fitFile.activity.endDate else {
            return 60
        }
        return max(1, endDate.timeIntervalSince(startDate))
    }
}

private struct TimelineHorizontalScrollbar: View {
    let viewportWidth: Double
    let contentWidth: Double
    @Binding var offset: Double
    @State private var dragOrigin: Double?

    private var maximumOffset: Double {
        max(0, contentWidth - viewportWidth)
    }

    var body: some View {
        GeometryReader { geometry in
            let trackWidth = Double(geometry.size.width)
            let thumbWidth = min(trackWidth, max(28, trackWidth * viewportWidth / max(contentWidth, 1)))
            let usableTrackWidth = max(0, trackWidth - thumbWidth)
            let visibleOffset = min(max(offset, 0), maximumOffset)
            let thumbX = maximumOffset > 0 ? visibleOffset / maximumOffset * usableTrackWidth : 0

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                    .frame(height: 6)
                Capsule()
                    .fill(Color.secondary.opacity(maximumOffset > 0 ? 0.8 : 0.3))
                    .frame(width: thumbWidth, height: 6)
                    .offset(x: thumbX)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragOrigin == nil {
                            dragOrigin = visibleOffset
                        }
                        let offsetPerPoint = maximumOffset / max(usableTrackWidth, 1)
                        offset = min(max(0, (dragOrigin ?? 0) + Double(value.translation.width) * offsetPerPoint), maximumOffset)
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                    }
            )
        }
        .opacity(maximumOffset > 0 ? 1 : 0.35)
    }
}

private struct PlaybackControls: View {
    @ObservedObject var playback: PlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button(action: playback.togglePlayback) {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                }
                .help(playback.isPlaying ? "暂停" : "播放")

                Text(playback.currentTimeDisplay)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Spacer()

                Button(action: playback.toggleMute) {
                    Image(systemName: playback.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .help(playback.isMuted ? "取消静音" : "静音")

                Slider(value: $playback.volume, in: 0...1)
                    .frame(width: 100)
                    .help("音量")
            }
            .buttonStyle(.borderless)

        }
    }
}

private enum TimelineClipKind {
    case video
    case workout

    var color: Color {
        switch self {
        case .video:
            return .blue
        case .workout:
            return .green
        }
    }
}

private struct TimelineClip: Identifiable {
    let id: UUID
    let title: String
    let duration: Double
    let kind: TimelineClipKind
    let onSelect: () -> Void
}

private struct TimelineRuler: View {
    let totalDuration: Double
    let timelineWidth: Double
    let pixelsPerSecond: Double

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: 76 + timelineWidth, height: 22)
            ForEach(0...Int(ceil(totalDuration / 60)), id: \.self) { minute in
                VStack(alignment: .leading, spacing: 2) {
                    if minute.isMultiple(of: 10) {
                        Text("\(minute) 分")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Color.clear.frame(height: 12)
                    }
                    Rectangle()
                        .fill(Color.secondary.opacity(minute.isMultiple(of: 10) ? 0.7 : 0.3))
                        .frame(width: 1, height: minute.isMultiple(of: 10) ? 8 : 4)
                }
                .offset(x: 76 + Double(minute) * 60 * pixelsPerSecond)
            }
        }
    }
}

private struct TimelineTrack: View {
    let title: String
    let systemImage: String
    let clips: [TimelineClip]
    @Binding var offsets: [UUID: Double]
    let width: Double
    let pixelsPerSecond: Double

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .frame(width: 68, alignment: .leading)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: width, height: 48)

                ForEach(clips) { clip in
                    TimelineClipView(
                        clip: clip,
                        offsetSeconds: Binding(
                            get: { offsets[clip.id, default: 0] },
                            set: { offsets[clip.id] = $0 }
                        ),
                        pixelsPerSecond: pixelsPerSecond
                    )
                }
            }
            .frame(width: width, height: 48, alignment: .leading)
        }
    }
}

private struct TimelineClipView: View {
    let clip: TimelineClip
    @Binding var offsetSeconds: Double
    @State private var dragOrigin: Double?
    let pixelsPerSecond: Double

    var body: some View {
        Label(clip.title, systemImage: clip.kind == .video ? "video.fill" : "figure.run")
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(width: clipWidth, height: 36, alignment: .leading)
            .background(clip.kind.color.opacity(0.75))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .offset(x: offsetSeconds * pixelsPerSecond + 4)
            .onTapGesture(perform: clip.onSelect)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if dragOrigin == nil {
                            dragOrigin = offsetSeconds
                        }
                        offsetSeconds = max(0, (dragOrigin ?? 0) + Double(value.translation.width) / pixelsPerSecond)
                    }
                    .onEnded { _ in
                        dragOrigin = nil
                    }
            )
            .help("拖动以调整相对时间位置")
    }

    private var clipWidth: Double {
        max(clip.duration * pixelsPerSecond, 48)
    }
}

private struct TimelinePlayhead: View {
    @Binding var time: Double
    let totalDuration: Double
    let pixelsPerSecond: Double
    let trackLeadingInset: CGFloat
    let preview: (Double) -> Void
    let setScrubbing: (Bool) -> Void
    let seek: (Double) -> Void
    @State private var isDragging = false
    @State private var dragStartLocationX: CGFloat?
    @State private var dragStartTime: Double?

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.red)
                .frame(width: 10, height: 10)
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: 140)
        }
        .frame(width: 18)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragStartLocationX = value.location.x
                        dragStartTime = time
                        setScrubbing(true)
                    }
                    let translation = value.location.x - (dragStartLocationX ?? value.location.x)
                    let target = min(
                        max(0, (dragStartTime ?? time) + Double(translation) / pixelsPerSecond),
                        totalDuration
                    )
                    preview(target)
                }
                .onEnded { _ in
                    isDragging = false
                    dragStartLocationX = nil
                    dragStartTime = nil
                    seek(time)
                    setScrubbing(false)
                }
        )
        .help("拖动播放指针以查看该时刻素材")
    }
}

@MainActor
private final class PlaybackController: ObservableObject {
    let player = AVPlayer()

    @Published private(set) var videoURL: URL?
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isMuted = false
    @Published var volume = 1.0 {
        didSet {
            player.volume = Float(volume)
        }
    }

    private var isScrubbing = false
    private var timeObserver: Any?

    init() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                self?.updateCurrentTime(seconds)
            }
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    var timeDisplay: String {
        "\(formatTime(currentTime)) / \(formatTime(duration))"
    }

    var currentTimeDisplay: String {
        formatTime(currentTime)
    }

    func loadVideo(url: URL) {
        loadVideo(url: url, seekTo: 0)
    }

    func loadVideo(url: URL, seekTo initialTime: Double) {
        pause()
        videoURL = url
        currentTime = max(0, initialTime)
        duration = 0

        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.seek(
            to: CMTime(seconds: currentTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )

        Task { [weak self] in
            guard let loadedDuration = try? await item.asset.load(.duration) else {
                return
            }

            let seconds = loadedDuration.seconds
            guard seconds.isFinite, seconds >= 0 else {
                return
            }
            guard self?.videoURL == url else {
                return
            }
            self?.duration = seconds
        }
    }

    func unloadVideo() {
        pause()
        videoURL = nil
        currentTime = 0
        duration = 0
        player.replaceCurrentItem(with: nil)
    }

    func togglePlayback() {
        if isPlaying {
            pause()
            return
        }

        if duration > 0, currentTime >= duration {
            seek(to: 0)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: Double) {
        let target = min(max(seconds, 0), duration)
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func setScrubbing(_ isScrubbing: Bool) {
        self.isScrubbing = isScrubbing
    }

    func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
    }

    private func updateCurrentTime(_ seconds: Double) {
        guard !isScrubbing else {
            return
        }

        currentTime = max(0, seconds)
        if duration > 0, currentTime >= duration {
            isPlaying = false
        }
    }

    private func formatTime(_ time: Double) -> String {
        guard time.isFinite else {
            return "00:00"
        }

        let totalSeconds = Int(time.rounded(.down))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

private struct FitImport: Identifiable {
    let id = UUID()
    let fileName: String
    let fileSizeDescription: String
    let fileCreationDate: Date?
    let activity: FitActivity

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 12,
              data[8] == 0x2E,
              data[9] == 0x46,
              data[10] == 0x49,
              data[11] == 0x54 else {
            throw FitImportError.invalidFile
        }

        fileName = url.lastPathComponent
        fileSizeDescription = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        fileCreationDate = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        activity = try FitParser.parse(url: url)
    }
}

private enum FitImportError: LocalizedError {
    case invalidFile

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "所选文件不是有效的 FIT 运动记录。"
        }
    }
}

private extension UTType {
    static let fit = UTType(filenameExtension: "fit")!
}
