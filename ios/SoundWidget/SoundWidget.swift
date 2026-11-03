import WidgetKit
import SwiftUI

// 앱(Dart의 WidgetService.appGroupId)과 같은 App Group이어야 상태가 공유된다
private let appGroupId = "group.com.example.eartips"
private let listeningKey = "is_listening"
// 앱(Dart의 WidgetService._tokenKey)이 만들어 저장하는 URL 검증용 비밀값. 같은 이름이어야 한다
private let tokenKey = "widget_url_token"

struct SoundEntry: TimelineEntry {
    let date: Date
    let isListening: Bool
    // 앱이 아직 비밀값을 만들지 않았으면 nil. 이 경우 URL에 붙이지 않고, 앱은 요청을 무시한다
    let token: String?
}

struct SoundProvider: TimelineProvider {
    func placeholder(in context: Context) -> SoundEntry {
        SoundEntry(date: Date(), isListening: false, token: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (SoundEntry) -> Void) {
        completion(currentEntry())
    }

    // 상태가 바뀔 때마다 앱이 HomeWidget.updateWidget으로 갱신을 요청하므로 주기 갱신은 필요 없다
    func getTimeline(in context: Context, completion: @escaping (Timeline<SoundEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> SoundEntry {
        let defaults = UserDefaults(suiteName: appGroupId)
        return SoundEntry(
            date: Date(),
            isListening: defaults?.bool(forKey: listeningKey) ?? false,
            token: defaults?.string(forKey: tokenKey)
        )
    }
}

private extension View {
    // iOS 17부터는 containerBackground를 써야 위젯 배경이 정상 표시된다
    @ViewBuilder
    func widgetBackground(_ color: Color) -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(color, for: .widget)
        } else {
            background(color)
        }
    }
}

struct SoundWidgetView: View {
    let entry: SoundEntry

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: entry.isListening ? "waveform" : "mic.fill")
                .font(.system(size: 30))
                .foregroundColor(entry.isListening ? Color(red: 0.2, green: 0.78, blue: 0.35) : .white)
            Text(entry.isListening ? "감지 중" : "감지 꺼짐")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
            Text("EarTips")
                .font(.system(size: 10))
                .foregroundColor(Color.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetBackground(Color(red: 0.102, green: 0.102, blue: 0.18))
        // 앱이 열리면서 감지 상태가 전환된다 (감지 중이면 중지, 꺼져 있으면 시작).
        // home_widget이 인식하도록 homeWidget 쿼리가 필요하다
        .widgetURL(tapURL(for: entry))
    }

    // 외부 링크와 구분되도록 앱이 만든 비밀값(token)을 붙인다. 앱이 이 값을 확인한 요청만 처리한다.
    // 비밀값은 소문자 hex라 인코딩이 필요 없다.
    private func tapURL(for entry: SoundEntry) -> URL? {
        let action = entry.isListening ? "stop" : "start"
        var url = "eartips://widget?action=\(action)&homeWidget"
        if let token = entry.token { url += "&token=\(token)" }
        return URL(string: url)
    }
}

@main
struct EarTipsWidget: Widget {
    // Dart의 WidgetService._iosWidgetKind와 같아야 한다
    let kind = "SoundWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SoundProvider()) { entry in
            SoundWidgetView(entry: entry)
        }
        .configurationDisplayName("EarTips")
        .description("탭하면 앱이 열리면서 소리 감지가 켜지거나 꺼져요.")
        .supportedFamilies([.systemSmall])
    }
}
