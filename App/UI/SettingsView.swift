import ServiceManagement
import SwiftUI
import Translation

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Translation", systemImage: "character.bubble") { TranslationSettings() }
            Tab("Appearance", systemImage: "textformat") { AppearanceSettings() }
            Tab("Shortcuts", systemImage: "command") { ShortcutSettings() }
            Tab("About", systemImage: "info.circle") { AboutView() }
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
            Section("Languages") {
                Picker("Translate from", selection: $model.settings.sourceLanguage) {
                    ForEach(Languages.sources, id: \.self) { Text(Languages.name($0)).tag($0) }
                }
                Picker("Translate to", selection: $model.settings.targetLanguage) {
                    ForEach(Languages.targets, id: \.self) { Text(Languages.name($0)).tag($0) }
                }
            }
            Section {
                Picker("Display", selection: $model.settings.renderMode) {
                    ForEach(RenderMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(model.settings.renderMode.detail).font(.caption).foregroundStyle(.secondary)
                if model.settings.renderMode == .adaptive {
                    LabeledContent("Rewrite after stillness") {
                        Slider(value: $model.settings.settleDelay, in: 0.2...2, step: 0.1) {
                            EmptyView()
                        } minimumValueLabel: { Text("Sooner").font(.caption) } maximumValueLabel: { Text("Later").font(.caption) }
                    }
                }
            } header: {
                Text("Rendering")
            }
            Section {
                LabeledContent("Screen checks") {
                    Picker("", selection: $model.settings.framesPerSecond) {
                        Text("Saver (4 fps)").tag(4.0)
                        Text("Normal (8 fps)").tag(8.0)
                        Text("Fast (15 fps)").tag(15.0)
                    }
                    .labelsHidden()
                }
                Text("Text is read again only when the screen changes. A still screen uses almost no power.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            } header: {
                Text("Performance")
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
            Section("Translation engine") {
                Picker("Engine", selection: $model.settings.engine) {
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
                        Label("Available · on device", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                }
            }
            Section {
                LanguagePacksView(target: model.settings.targetLanguage) {
                    Task { await model.languagePacksChanged() }
                }
            } header: {
                Text("Apple Translation language packs")
            } footer: {
                Text("Language packs are stored on this Mac and translate quickly, even offline.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: $model.settings.glossary)
                    .font(.body.monospaced())
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .overlay(alignment: .topLeading) {
                        if model.settings.glossary.isEmpty {
                            Text("勇者 = Hero\nポーション = Potion").foregroundStyle(.tertiary).font(.body.monospaced())
                                .padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
            } header: {
                Text("Glossary")
            } footer: {
                Text("One \"original = translation\" per line. Apple Intelligence uses these exactly, and text recognition uses them as hints.")
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

    private var sources: [String] { Languages.sources.dropFirst().filter { $0 != target } }

    var body: some View {
        ForEach(sources, id: \.self) { source in
            LabeledContent {
                switch status[source] {
                case .installed?:
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon)
                case .supported?:
                    Button("Download") {
                        downloading = TranslationSession.Configuration(source: Locale.Language(identifier: source),
                                                                       target: Locale.Language(identifier: target))
                    }
                    .disabled(downloading != nil)
                case nil:
                    ProgressView().controlSize(.small)
                default:
                    Text("Not supported").foregroundStyle(.secondary)
                }
            } label: {
                Text(verbatim: "\(Languages.name(source)) → \(Languages.name(target))")
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
            Section("Text") {
                Picker("Font", selection: $model.settings.fontStyle) {
                    ForEach(FontStyleChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Colour, weight and size are matched to the original text.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Quick boxes") {
                LabeledContent("Opacity") {
                    Slider(value: $model.settings.boxOpacity, in: 0.6...1)
                }
            }
            Section {
                Toggle("Erase from textured backgrounds with AI", isOn: $model.settings.useInpaintingModel)
                    .disabled(!model.inpaintingAvailable)
                LabeledContent("Inpainting model") {
                    if model.inpaintingAvailable {
                        Label("MI-GAN · Core ML (GPU)", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    } else {
                        Label("Not installed", systemImage: "xmark.circle").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Erasing the original")
            } footer: {
                Text("Flat and gradient backgrounds are filled from their surroundings. On photos and artwork, an on-device inpainting model redraws the background.")
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
                Text("These work in any app.").font(.caption).foregroundStyle(.secondary)
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
            Text("Translates the screen in place, wherever you put a lens.")
                .foregroundStyle(.secondary)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .font(.caption).foregroundStyle(.tertiary)
            Divider().frame(width: 260).padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 6) {
                Label("Recognition and translation happen entirely on this Mac", systemImage: "lock.shield")
                Label("Vision · Translation · Apple Intelligence · Core ML", systemImage: "apple.intelligence")
                Label("Inpainting: MI-GAN (Picsart AI Research, MIT)", systemImage: "paintbrush")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
