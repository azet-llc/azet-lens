import ServiceManagement
import SwiftUI
import Translation

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("일반", systemImage: "gearshape") { GeneralSettings() }
            Tab("번역", systemImage: "character.bubble") { TranslationSettings() }
            Tab("표시", systemImage: "textformat") { AppearanceSettings() }
            Tab("단축키", systemImage: "command") { ShortcutSettings() }
            Tab("정보", systemImage: "info.circle") { AboutView() }
        }
        .frame(width: 560, height: 520)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        @Bindable var model = model
        Form {
            Section("언어") {
                Picker("원문", selection: $model.settings.sourceLanguage) {
                    ForEach(Languages.sources, id: \.self) { Text(Languages.name($0)).tag($0) }
                }
                Picker("번역", selection: $model.settings.targetLanguage) {
                    ForEach(Languages.targets, id: \.self) { Text(Languages.name($0)).tag($0) }
                }
            }
            Section {
                Picker("표시 방식", selection: $model.settings.renderMode) {
                    ForEach(RenderMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(model.settings.renderMode.detail).font(.caption).foregroundStyle(.secondary)
                if model.settings.renderMode == .adaptive {
                    LabeledContent("멈춘 뒤 다시 쓰기까지") {
                        Slider(value: $model.settings.settleDelay, in: 0.2...2, step: 0.1) {
                            EmptyView()
                        } minimumValueLabel: { Text("빠르게").font(.caption) } maximumValueLabel: { Text("느긋하게").font(.caption) }
                    }
                }
            } header: {
                Text("표시")
            }
            Section {
                LabeledContent("화면 확인 빈도") {
                    Picker("", selection: $model.settings.framesPerSecond) {
                        Text("절약 (4fps)").tag(4.0)
                        Text("보통 (8fps)").tag(8.0)
                        Text("빠름 (15fps)").tag(15.0)
                    }
                    .labelsHidden()
                }
                Text("화면이 바뀔 때만 다시 읽습니다. 가만히 있는 화면은 전력을 거의 쓰지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("로그인 시 실행", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            } header: {
                Text("성능")
            }
        }
        .formStyle(.grouped)
    }
}

private struct TranslationSettings: View {
    @Environment(AppModel.self) private var model
    private let intelligence = IntelligenceTranslator()

    var body: some View {
        @Bindable var model = model
        Form {
            Section("번역 엔진") {
                Picker("엔진", selection: $model.settings.engine) {
                    ForEach(TranslationEngineChoice.allCases) { choice in
                        VStack(alignment: .leading) {
                            Text(choice.title)
                            Text(choice.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
                LabeledContent("Apple Intelligence") {
                    if let why = intelligence.unavailableReason {
                        Label(why, systemImage: "xmark.circle").foregroundStyle(.secondary)
                    } else {
                        Label("사용 가능 · 기기에서 처리", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                }
            }
            Section {
                LanguagePacksView(target: model.settings.targetLanguage) {
                    Task { await model.languagePacksChanged() }
                }
            } header: {
                Text("Apple 번역 언어 팩")
            } footer: {
                Text("언어 팩은 기기에 저장되어 오프라인에서도 빠르게 번역합니다.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: $model.settings.glossary)
                    .font(.body.monospaced())
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if model.settings.glossary.isEmpty {
                            Text("勇者 = 용사\nポーション = 포션").foregroundStyle(.tertiary).font(.body.monospaced())
                                .padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
            } header: {
                Text("용어집")
            } footer: {
                Text("한 줄에 하나씩 \"원문 = 번역\". Apple Intelligence가 이 번역을 그대로 쓰고, 화면 인식에도 힌트로 쓰입니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct LanguagePacksView: View {
    let target: String
    var onChange: () -> Void
    @State private var status: [String: LanguageAvailability.Status] = [:]
    @State private var downloading: TranslationSession.Configuration?

    private var sources: [String] { ["ja", "zh-Hans", "zh-Hant", "en", "fr", "de", "es", "ru", "vi", "th", "ko"].filter { $0 != target } }

    var body: some View {
        ForEach(sources, id: \.self) { source in
            LabeledContent {
                switch status[source] {
                case .installed?:
                    Label("설치됨", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
                case .supported?:
                    Button("내려받기") {
                        downloading = TranslationSession.Configuration(source: Locale.Language(identifier: source),
                                                                       target: Locale.Language(identifier: target))
                    }
                    .disabled(downloading != nil)
                case nil:
                    ProgressView().controlSize(.small)
                default:
                    Text("지원 안 함").foregroundStyle(.secondary)
                }
            } label: {
                Text("\(Languages.name(source)) → \(Languages.name(target))")
            }
        }
        .task(id: target) { await reload() }
        .translationTask(downloading) { session in
            // Shows the system download sheet; returns once the pack is installed or the user declines.
            try? await session.prepareTranslation()
            await MainActor.run { downloading = nil }
            await reload()
            await MainActor.run { onChange() }
        }
    }

    private func reload() async {
        let availability = LanguageAvailability()
        var next: [String: LanguageAvailability.Status] = [:]
        for s in sources {
            next[s] = await availability.status(from: Locale.Language(identifier: s), to: Locale.Language(identifier: target))
        }
        await MainActor.run { status = next }
    }
}

private struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("글자") {
                Picker("글꼴", selection: $model.settings.fontStyle) {
                    ForEach(FontStyleChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("글자 색과 굵기, 크기는 원문에서 읽어 맞춥니다.").font(.caption).foregroundStyle(.secondary)
            }
            Section("빠른 표시 상자") {
                LabeledContent("불투명도") {
                    Slider(value: $model.settings.boxOpacity, in: 0.6...1)
                }
            }
            Section {
                Toggle("무늬 있는 배경은 AI로 지우기", isOn: $model.settings.useInpaintingModel)
                    .disabled(!model.inpaintingAvailable)
                LabeledContent("인페인팅 모델") {
                    if model.inpaintingAvailable {
                        Label("MI-GAN · Core ML (GPU)", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        Label("설치되지 않음", systemImage: "xmark.circle").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("원문 지우기")
            } footer: {
                Text("단색·그라데이션 배경은 주변 색으로 채우고, 사진이나 그림 위 글자는 기기 안의 인페인팅 모델이 배경을 다시 그립니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutSettings: View {
    var body: some View {
        Form {
            Section {
                ForEach(HotKeys.all) { s in
                    LabeledContent(s.title) { KeyCap(s.display).foregroundStyle(.primary) }
                }
            } footer: {
                Text("어느 앱에 있든 동작합니다.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            AppGlyph(size: 88)
            Text("Mwoyea").font(.largeTitle.weight(.semibold))
            Text("뭐여? 화면 그 자리에서 바로 번역")
                .foregroundStyle(.secondary)
            Text("버전 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .font(.caption).foregroundStyle(.tertiary)
            Divider().frame(width: 260).padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 6) {
                Label("모든 인식과 번역은 이 Mac 안에서 처리됩니다", systemImage: "lock.shield")
                Label("Vision · Translation · Apple Intelligence · Core ML", systemImage: "apple.intelligence")
                Label("인페인팅: MI-GAN (Picsart AI Research, MIT)", systemImage: "paintbrush")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
