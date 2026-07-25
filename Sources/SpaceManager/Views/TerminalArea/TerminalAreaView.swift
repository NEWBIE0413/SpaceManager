import SwiftUI

/// Right pane containing the selected terminal.
/// 탭 전환 UI는 사이드바의 워크스페이스 폴더링(WorkspaceTabRow)이 담당한다.
struct TerminalAreaView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if appState.windowKind == .workspace && !TmuxBootstrap.isTmuxAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("tmux가 설치되어 있지 않아 셸 탭만 사용할 수 있습니다 — `brew install tmux` 후 재실행")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.1))
            }
            SingleTerminalView()
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// Single terminal view for the selected session
struct SingleTerminalView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if let session = appState.selectedSession {
            SessionContentView(session: session)
                .id(session.id)
        } else if appState.windowKind == .quick {
            QuickHomeView()
        } else {
            VStack {
                Text("No terminal")
                    .foregroundColor(.secondary)
                Button("New Terminal") {
                    appState.addDefaultTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 활성 대화가 없을 때 보이는 Hermes 홈. 프롬프트는 AppState를 거쳐 PTY 환경변수로
/// 전달되며 셸 명령 문자열에는 절대 보간되지 않는다.
struct QuickHomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var prompt = ""
    @FocusState private var isPromptFocused: Bool

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text("새 대화를 시작하세요")
                    .font(.system(size: 28, weight: .semibold))
                Text("무엇을 도와드릴까요?")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .bottom, spacing: 12) {
                TextField("메시지를 입력하세요", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .lineLimit(2...7)
                    .focused($isPromptFocused)
                    .onSubmit(submit)

                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.black))
                }
                .buttonStyle(.plain)
                .disabled(trimmedPrompt.isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .shadow(color: Color.black.opacity(0.08), radius: 12, y: 4)
            )
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .onAppear { isPromptFocused = true }
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        let initialPrompt = trimmedPrompt
        guard !initialPrompt.isEmpty else { return }
        prompt = ""
        appState.addQuickSession(initialPrompt: initialPrompt)
    }
}

struct SessionContentView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        AgentTerminalView(session: session)
    }
}
