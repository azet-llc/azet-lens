import SwiftUI

struct MenuPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            header
            if let issue = model.issue {
                IssueBanner(message: issue.message) { open() }
            }
            if !model.hasScreenPermission {
                IssueBanner(message: "화면 기록 권한이 필요합니다.", action: "권한 설정") {
                    WindowPresenter.shared.showOnboarding()
                }
            }
            LanguageBar(source: $model.settings.sourceLanguage, target: $model.settings.targetLanguage)
            regionList
            addButton
            Divider().padding(.horizontal, -4)
            footer
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { model.recheckPermission() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            AppGlyph(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mwoyea").font(.headline)
                Text(statusLine).font(.caption).foregroundStyle(.secondary).contentTransition(.opacity)
            }
            Spacer()
            Button {
                Task { await model.togglePause() }
            } label: {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .help(model.isPaused ? "번역 다시 시작 (⌃⌥P)" : "모두 일시정지 (⌃⌥P)")
            .disabled(model.regions.isEmpty)
        }
    }

    private var statusLine: String {
        let active = model.regions.filter(\.isEnabled).count
        if model.isPaused { return "일시정지됨" }
        if active == 0 { return "번역 중인 영역 없음" }
        if model.isBusy { return "\(active)개 영역 · 읽는 중…" }
        return "\(active)개 영역 번역 중"
    }

    @ViewBuilder private var regionList: some View {
        if model.regions.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.and.paperclip")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("번역할 영역을 추가해 보세요")
                    .font(.callout.weight(.medium))
                Text("게임, 만화, 영상 자막, 외국어 앱 위에 영역을 걸어 두면\n그 자리에서 계속 번역됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            VStack(spacing: 6) {
                ForEach(model.regions) { region in
                    RegionRow(region: region)
                }
            }
            .id(model.sessionTick)
        }
    }

    private var addButton: some View {
        Button {
            Task { await model.addRegion() }
        } label: {
            HStack {
                Image(systemName: "plus.viewfinder")
                Text("영역 추가")
                Spacer()
                KeyCap(HotKeys.addRegion.display)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                model.toggleTranslations()
            } label: {
                Label(model.translationsVisible ? "원문 보기" : "번역 보기",
                      systemImage: model.translationsVisible ? "eye" : "eye.slash")
            }
            .help("번역을 잠시 숨기고 원문을 봅니다 (⌃⌥O)")
            Spacer()
            Button { open() } label: { Image(systemName: "gearshape") }
                .help("설정")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Mwoyea 종료")
        }
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func open() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }
}

private struct RegionRow: View {
    @Environment(AppModel.self) private var model
    let region: RegionConfig
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: dotState)
            VStack(alignment: .leading, spacing: 1) {
                Text(region.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering {
                Button {
                    Task { await model.remove(region.id) }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("영역 삭제")
                    .transition(.opacity)
            }
            Button {
                model.toggleAnchor(region.id)
            } label: {
                Image(systemName: region.anchor != nil ? "pin.fill" : "pin.slash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(region.anchor != nil ? Color.accentColor : .secondary)
            .help(region.anchor != nil ? "\(region.anchor!.appName) 창을 따라갑니다. 누르면 고정 위치로" : "화면에 고정됨. 누르면 아래 창을 따라갑니다")
            Toggle("", isOn: Binding(get: { region.isEnabled }, set: { v in Task { await model.setEnabled(region.id, v) } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(hovering ? 0.8 : 0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }

    private var dotState: StatusDot.State {
        if !region.isEnabled || model.isPaused { return .off }
        if model.error(of: region.id) != nil { return .error }
        switch model.activity(of: region.id) {
        case .idle: return .on
        case .reading, .translating: return .busy
        }
    }

    private var subtitle: String {
        if let e = model.error(of: region.id) { return e }
        let size = "\(Int(region.rect.width))×\(Int(region.rect.height))"
        if let a = region.anchor { return "\(a.appName) 창 · \(size)" }
        return "고정 영역 · \(size)"
    }
}

struct StatusDot: View {
    enum State { case on, busy, off, error }
    let state: State
    @SwiftUI.State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(color.opacity(0.5), lineWidth: 4).scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 0.8))
            .onAppear { animate() }
            .onChange(of: state) { animate() }
            .accessibilityLabel(label)
    }

    private func animate() {
        pulse = false
        guard state == .busy else { return }
        withAnimation(.easeOut(duration: 1).repeatForever(autoreverses: false)) { pulse = true }
    }

    private var color: Color {
        switch state {
        case .on: .green
        case .busy: .accentColor
        case .off: .secondary.opacity(0.5)
        case .error: .red
        }
    }

    private var label: String {
        switch state {
        case .on: "번역 중"
        case .busy: "읽는 중"
        case .off: "꺼짐"
        case .error: "오류"
        }
    }
}

struct LanguageBar: View {
    @Binding var source: String
    @Binding var target: String

    var body: some View {
        HStack(spacing: 6) {
            picker($source, Languages.sources)
            Button {
                guard source != "auto" else { return }
                (source, target) = (target, source)
            } label: {
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(source == "auto" ? "번역 방향" : "언어 바꾸기")
            picker($target, Languages.targets)
        }
    }

    private func picker(_ selection: Binding<String>, _ options: [String]) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { Text(Languages.name($0)).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity)
    }
}

struct IssueBanner: View {
    let message: String
    var action = "설정 열기"
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action, action: perform).controlSize(.small)
        }
        .padding(10)
        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption.monospaced().weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// The app mark: a speech bubble with a question, drawn in SwiftUI so it scales crisply anywhere.
struct AppGlyph: View {
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.55, blue: 0.25), Color(red: 0.93, green: 0.27, blue: 0.42)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "character.bubble.fill")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: size * 0.04, y: size * 0.02)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
