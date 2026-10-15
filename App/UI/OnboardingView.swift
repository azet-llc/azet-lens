import Combine
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    @State private var permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let intelligence = IntelligenceTranslator()

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                AppGlyph(size: 76)
                    .shadow(color: .orange.opacity(0.35), radius: 18, y: 8)
                Text("뭐여? 이제 바로 읽혀요")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("화면의 원하는 곳에 영역을 걸어 두면, 글자를 지우고\n그 자리에 번역을 자연스럽게 다시 써 드려요.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 34)
            .padding(.bottom, 24)

            VStack(spacing: 10) {
                StepCard(number: 1, title: "화면 기록 권한", done: model.hasScreenPermission,
                         detail: model.hasScreenPermission ? "허용됨. 영역 안의 글자만 읽고, 아무것도 저장하거나 보내지 않아요."
                             : "선택한 영역의 글자를 읽으려면 필요해요. 허용한 뒤 앱을 다시 열어야 할 수 있어요.") {
                    if !model.hasScreenPermission {
                        Button("허용하기") { model.requestPermission() }.buttonStyle(.glassProminent)
                    }
                }
                StepCard(number: 2, title: "번역 언어", done: true,
                         detail: intelligence.isAvailable ? "Apple Intelligence로 문맥을 살려 번역해요. 더 빠른 번역은 설정 › 번역에서 언어 팩을 받으세요."
                             : "Apple 번역을 사용해요. 설정 › 번역에서 언어 팩을 받아 주세요.") {
                    LanguageBar(source: $model.settings.sourceLanguage, target: $model.settings.targetLanguage)
                        .frame(width: 230)
                }
                StepCard(number: 3, title: "영역 고르기", done: !model.regions.isEmpty,
                         detail: "어디서든 \(HotKeys.addRegion.display)를 누르거나 메뉴 막대의 말풍선을 누르세요. 창을 클릭하면 창을 따라다녀요.") {
                    Button("지금 해 보기") {
                        finish()
                        Task { await model.addRegion() }
                    }
                    .buttonStyle(.glass)
                    .disabled(!model.hasScreenPermission)
                }
            }
            .padding(.horizontal, 28)

            HStack {
                Text("모든 처리는 이 Mac 안에서만 이루어져요.")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("시작하기") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
            .padding(28)
        }
        .frame(width: 600)
        .onReceive(permissionTimer) { _ in model.recheckPermission() }
    }

    private func finish() {
        model.settings.hasCompletedOnboarding = true
        close()
    }
}

private struct StepCard<Accessory: View>: View {
    let number: Int
    let title: String
    let done: Bool
    let detail: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green.opacity(0.18) : Color.accentColor.opacity(0.15))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(.green)
                } else {
                    Text("\(number)").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 30, height: 30)
            .animation(.spring(duration: 0.3), value: done)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
