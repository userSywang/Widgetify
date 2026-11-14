import AppKit
import SwiftUI

private final class LiveWaterImage: ObservableObject {
    weak var source: NSView?
    @Published var image: NSImage?
    private var timer: Timer?
    init(_ source: NSView?) { self.source = source }
    func start() {
        stop(); capture()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.capture() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func stop() { timer?.invalidate(); timer = nil }
    private func capture() {
        guard let source, source.bounds.width > 0, source.bounds.height > 0,
              let bitmap = source.bitmapImageRepForCachingDisplay(in: source.bounds) else { return }
        source.cacheDisplay(in: source.bounds, to: bitmap)
        let image = NSImage(size: source.bounds.size); image.addRepresentation(bitmap); self.image = image
    }
    deinit { timer?.invalidate() }
}
private final class WaterActions {
    weak var target: NSObject?
    init(_ target: NSObject) { self.target = target }
    func perform(_ selector: String, value: Any? = nil) { _ = target?.perform(NSSelectorFromString(selector), with: value) }
}
private struct NativeWaterThumbnail: View {
    @StateObject private var live: LiveWaterImage
    let size: CGFloat
    let accent: Color
    init(source: NSView?, size: CGFloat, accent: Color) { _live = StateObject(wrappedValue: LiveWaterImage(source)); self.size = size; self.accent = accent }
    var body: some View {
        Group {
            if let image = live.image { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
            else { Image(systemName: "drop.fill").font(.system(size: size * 0.42, weight: .medium)).foregroundColor(accent).frame(width: size, height: size).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: size * 0.24)) }
        }.frame(width: size, height: size).allowsHitTesting(false).accessibilityHidden(true)
            .onAppear { live.start() }.onDisappear { live.stop() }
    }
}
private struct WaterReminderView: View {
    let config: NSDictionary
    let theme: NSDictionary
    let source: NSView?
    let actions: WaterActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var compact: Bool { (config["style"] as? NSNumber)?.intValue == 1 }
    var preview: Bool { (config["preview"] as? NSNumber)?.boolValue ?? false }
    var accent: Color { Color(nsColor: theme["accent"] as? NSColor ?? .systemBlue) }
    var ink: Color { Color(nsColor: theme["base"] as? NSColor ?? .labelColor) }
    var duration: Double { (config["duration"] as? NSNumber)?.doubleValue ?? 10 }
    var expires: Date { Date(timeIntervalSince1970: (config["expires"] as? NSNumber)?.doubleValue ?? 0) }
    var interval: Int { (config["intervalMinutes"] as? NSNumber)?.intValue ?? 45 }
    var body: some View {
        VStack(spacing: compact ? 10 : 14) {
            if !compact {
                HStack {
                    Label(preview ? "提醒预览" : "喝水提醒", systemImage: "drop").font(.system(size: 11, weight: .medium)).foregroundColor(ink.opacity(0.56))
                    Spacer(); closeButton
                }
            }
            HStack(spacing: compact ? 14 : 18) {
                NativeWaterThumbnail(source: source, size: compact ? 66 : 86, accent: accent)
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 15 : 19, style: .continuous))
                VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                    Text("该喝水啦").font(.system(size: compact ? 17 : 22, weight: .semibold, design: .rounded)).foregroundColor(ink)
                    Text("放松一下，喝口水再继续。").font(.system(size: 12)).foregroundColor(ink.opacity(0.64)).fixedSize(horizontal: false, vertical: true)
                    if compact { reminderClock.font(.system(size: 10)).foregroundColor(ink.opacity(0.42)) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if compact { closeButton }
            }
            if !compact {
                HStack {
                    Text("每隔 \(interval) 分钟").font(.system(size: 11)).foregroundColor(ink.opacity(0.42))
                    Spacer(); reminderClock.font(.system(size: 11)).foregroundColor(ink.opacity(0.42))
                }
                HStack(spacing: 10) {
                    if preview {
                        Text("预览不计入饮水记录").font(.system(size: 10)).foregroundColor(ink.opacity(0.42)).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Button { actions.perform("snooze:") } label: { Text("10 分钟后提醒").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity).frame(height: 34).foregroundColor(ink.opacity(0.72)).background(ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous)) }
                    }
                    Button { actions.perform("dismiss:") } label: { Text(preview ? "关闭预览" : "知道了").font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 34).foregroundColor(.white).background(accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous)) }
                }.buttonStyle(.plain)
            }
        }.padding(compact ? 17 : 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if duration > 0 {
                TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 0.05)) { timeline in
                    GeometryReader { geometry in
                        Rectangle().fill(accent.opacity(0.55)).frame(width: geometry.size.width * max(0, min(1, expires.timeIntervalSince(timeline.date) / duration)), height: 2)
                    }.frame(height: 2)
                }
            }
        }
    }
    var closeButton: some View {
        Button { actions.perform("dismiss:") } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundColor(ink.opacity(0.48)).frame(width: 21, height: 21).background(ink.opacity(0.06), in: Circle()) }.buttonStyle(.plain).help("关闭提醒").accessibilityLabel("关闭提醒")
    }
    var reminderClock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Text(duration > 0 ? "\(max(0, Int(ceil(expires.timeIntervalSince(timeline.date))))) 秒后关闭" : "手动关闭")
                .monospacedDigit()
        }
    }
}
private struct WaterSettingsView: View {
    let identifier: String
    let actions: WaterActions
    @State var enabled: Bool
    @State var interval: Int
    @State var style: Int
    @State var duration: Int
    @State var position: Int
    @State var sound: Bool
    @State private var custom = false
    @State private var next: Date?
    @State private var notice = ""
    private let presets = [15, 30, 45, 60, 90, 120]
    init(config: NSDictionary, target: NSObject) {
        identifier = config["identifier"] as? String ?? ""
        actions = WaterActions(target)
        _enabled = State(initialValue: (config["enabled"] as? NSNumber)?.boolValue ?? false)
        let minutes = (config["intervalMinutes"] as? NSNumber)?.intValue ?? 45
        _interval = State(initialValue: minutes)
        _custom = State(initialValue: ![15,30,45,60,90,120].contains(minutes))
        _style = State(initialValue: (config["style"] as? NSNumber)?.intValue ?? 0)
        _duration = State(initialValue: (config["duration"] as? NSNumber)?.intValue ?? 10)
        _position = State(initialValue: (config["position"] as? NSNumber)?.intValue ?? 0)
        _sound = State(initialValue: (config["sound"] as? NSNumber)?.boolValue ?? true)
        let timestamp = (config["nextReminderAt"] as? NSNumber)?.doubleValue ?? 0
        _next = State(initialValue: timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil)
    }
    var config: NSDictionary { ["enabled":enabled, "intervalMinutes":interval, "style":style, "duration":duration, "position":position, "sound":sound, "scheduleVersion":2] as NSDictionary }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("提醒") {
                    Toggle("间隔提醒", isOn: $enabled).toggleStyle(.switch).controlSize(.small)
                    Divider().opacity(0.5)
                    HStack {
                        Text("提醒间隔")
                        Spacer()
                        Picker("提醒间隔", selection: Binding(get: { custom ? 0 : interval }, set: { value in if value == 0 { custom = true } else { custom = false; interval = value } })) {
                            ForEach(presets, id: \.self) { Text("每 \($0) 分钟").tag($0) }
                            Text("自定义…").tag(0)
                        }.labelsHidden().fixedSize()
                    }
                    if custom {
                        Divider().opacity(0.5)
                        HStack { Text("自定义间隔"); Spacer(); TextField("分钟", value: $interval, formatter: minuteFormatter).frame(width: 48).multilineTextAlignment(.trailing); Text("分钟").foregroundColor(.secondary); Stepper("调整间隔", value: $interval, in: 1...240).labelsHidden().fixedSize() }
                    }
                }
                if enabled {
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        HStack(spacing: 6) {
                            Image(systemName: "clock").font(.system(size: 10))
                            if let next, next > timeline.date { Text("下次提醒 \(next.formatted(date: .omitted, time: .shortened))") }
                            else { Text("每隔 \(interval) 分钟提醒一次") }
                        }.font(.system(size: 11)).foregroundColor(.secondary)
                    }.padding(.horizontal, 2).padding(.top, -8)
                }
                section("弹窗") {
                    row("样式") { Picker("弹窗样式", selection: $style) { Text("组件卡片").tag(0); Text("轻提示").tag(1) }.labelsHidden().fixedSize() }
                    Divider().opacity(0.5)
                    row("停留时间") { Picker("停留时间", selection: $duration) { Text("5 秒").tag(5); Text("10 秒").tag(10); Text("20 秒").tag(20); Text("30 秒").tag(30); Text("手动关闭").tag(0) }.labelsHidden().fixedSize() }
                    Divider().opacity(0.5)
                    row("显示位置") { Picker("显示位置", selection: $position) { Text("组件旁边").tag(0); Text("屏幕右上角").tag(1) }.labelsHidden().fixedSize() }
                    Divider().opacity(0.5)
                    Toggle("提醒声音", isOn: $sound).toggleStyle(.switch).controlSize(.small)
                }
                Button { actions.perform("previewWaterConfiguration:", value: config); notice = "预览不会增加饮水记录或改变提醒时间。" } label: {
                    HStack { Image(systemName: "play.circle"); Text("预览提醒"); Spacer(); Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary) }.padding(.horizontal, 11).frame(height: 34).contentShape(Rectangle())
                }.buttonStyle(.plain).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                Text(notice.isEmpty ? "更改自动保存。提醒在软件运行时生效，睡眠期间不补发积压提醒。" : notice).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 12)).padding(16)
        }
        .onChange(of: enabled) { _ in save() }.onChange(of: interval) { _ in save() }
        .onChange(of: style) { _ in save() }.onChange(of: duration) { _ in save() }
        .onChange(of: position) { _ in save() }.onChange(of: sound) { _ in save() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            if let saved = UserDefaults.standard.dictionary(forKey: "custom.component.\(identifier).water"), let value = saved["nextReminderAt"] as? Double { next = Date(timeIntervalSince1970: value) }
        }
    }
    var minuteFormatter: NumberFormatter { let f = NumberFormatter(); f.minimum = 1; f.maximum = 240; f.allowsFloats = false; return f }
    func save() {
        guard (1...240).contains(interval) else { notice = "间隔可设置为 1–240 分钟。"; return }
        actions.perform("waterConfigurationChanged:", value: config); notice = ""
    }
    func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary).padding(.horizontal, 2)
            VStack(spacing: 10, content: content).padding(11).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        }
    }
    func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View { HStack { Text(title); Spacer(); control() } }
}
@_cdecl("WidgetifyCreateWaterSettings")
public func createWaterSettings(_ configuration: UnsafeMutableRawPointer, _ target: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let config = Unmanaged<NSDictionary>.fromOpaque(configuration).takeUnretainedValue()
    let object = Unmanaged<NSObject>.fromOpaque(target).takeUnretainedValue()
    let view = NSHostingView(rootView: WaterSettingsView(config: config, target: object))
    view.frame = NSRect(x: 0, y: 0, width: 328, height: 470)
    return Unmanaged.passRetained(view).toOpaque()
}
@_cdecl("WidgetifyCreateWaterReminder")
public func createWaterReminder(_ source: UnsafeMutableRawPointer?, _ configuration: UnsafeMutableRawPointer, _ context: UnsafeMutableRawPointer, _ target: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer {
    let view = source.map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
    let config = Unmanaged<NSDictionary>.fromOpaque(configuration).takeUnretainedValue()
    let theme = Unmanaged<NSDictionary>.fromOpaque(context).takeUnretainedValue()
    let object = Unmanaged<NSObject>.fromOpaque(target).takeUnretainedValue()
    let root = WaterReminderView(config: config, theme: theme, source: view, actions: WaterActions(object))
    return Unmanaged.passRetained(NSHostingView(rootView: root)).toOpaque()
}
