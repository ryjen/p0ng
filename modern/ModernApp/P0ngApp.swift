import SwiftUI
import PongCore

@main
struct P0ngApp: App {
    var body: some Scene {
        WindowGroup { PongHomeView() }
    }
}

private enum Retro {
    static let foreground = Color(red: 0.93, green: 0.97, blue: 0.94)
    static let background = Color(red: 0.04, green: 0.06, blue: 0.07)
    static let accent = Color(red: 0.42, green: 0.92, blue: 0.75)
}

struct PongHomeView: View {
    @StateObject private var model = PongViewModel()
    @AppStorage("p0ng.soundEnabled") private var soundEnabled = true
    @AppStorage("p0ng.hapticsEnabled") private var hapticsEnabled = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("p0ng").accessibilityIdentifier("pong.title").font(.system(size: 34, weight: .black, design: .monospaced))
                Spacer()
                if model.screen != .menu {
                    Button("Exit") { model.leave() }
                        .buttonStyle(.bordered)
                }
            }
            .foregroundStyle(Retro.accent)

            switch model.screen {
            case .menu:
                VStack(spacing: 18) {
                    Text("RETRO PADDLES · MODERN NETWORKING")
                        .font(.caption.monospaced()).foregroundStyle(Retro.foreground)
                    menuButton("Play against computer", action: model.playSolo)
                    menuButton("Host nearby match", action: model.host)
                    menuButton("Join nearby match", action: model.browse)
                    Toggle("Sound effects", isOn: $soundEnabled)
                        .frame(maxWidth: 340)
                    Toggle("Haptic feedback", isOn: $hapticsEnabled)
                        .frame(maxWidth: 340)
                }
                .frame(maxHeight: .infinity)
            case .hosting:
                waiting("Hosting · Waiting for a player")
            case .connecting:
                waiting("Connecting · Waiting for host")
            case .browsing:
                VStack(spacing: 18) {
                    Text("Nearby hosts").font(.title3.monospaced())
                    if model.peers.isEmpty {
                        Text("Searching on your local network…")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.peers) { peer in
                        menuButton(peer.displayName) { model.join(peer) }
                    }
                }
                .frame(maxHeight: .infinity)
            case .playing:
                VStack(spacing: 12) {
                    HStack {
                        Text("\(model.state.leftScore)")
                        Spacer()
                        Text(model.roleLabel)
                            .font(.caption2.monospaced()).foregroundStyle(Retro.accent)
                        Spacer()
                        Text("\(model.state.rightScore)")
                    }
                    .font(.title.monospacedDigit().bold())
                    CourtView(snapshot: model.state, playingRight: model.isGuest) {
                        model.movePaddle(y: $0, finished: $1)
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    if model.state.phase == .finished {
                        Text("\(model.state.leftScore > model.state.rightScore ? "LEFT" : "RIGHT") WINS")
                            .font(.title2.monospaced().bold())
                        menuButton("Play again") {
                            if model.isGuest { model.browse() }
                            else if model.roleLabel.hasPrefix("Host") { model.host() }
                            else { model.playSolo() }
                        }
                    } else if model.state.phase == .serving {
                        Text("SERVE IN \(Int(ceil(model.state.serveRemaining)))")
                            .font(.headline.monospaced())
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Retro.background)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active: model.setInteractive(true)
            case .inactive: model.setInteractive(false)
            case .background:
                model.setInteractive(false)
                if model.screen != .menu { model.leave() }
            @unknown default: model.setInteractive(false)
            }
        }
        .foregroundStyle(Retro.foreground)
        // One SwiftUI alert destination: invitation approval takes precedence
        // over a concurrent network error, instead of competing modifiers.
        .alert(model.invitation != nil ? "Join request" : "Network",
               isPresented: Binding(
                get: { model.invitation != nil || model.message != nil },
                set: { presented in
                    guard !presented else { return }
                    if model.invitation != nil { model.dismissInvitationIfPending() }
                    else { model.message = nil }
                }
               )) {
            if model.invitation != nil {
                Button("Decline", role: .cancel) { model.respondToInvitation(false) }
                Button("Allow") { model.respondToInvitation(true) }
            } else {
                if model.canRetryDiscovery {
                    Button("Retry") { model.retryDiscovery() }
                }
                Button("OK", role: .cancel) { model.message = nil }
            }
        } message: {
            if let peer = model.invitation {
                Text("Allow \(peer) to join your match?")
            } else {
                Text(model.message ?? "")
            }
        }
    }

    private func menuButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.headline.monospaced())
                .frame(maxWidth: 340).padding(14)
                .background(Retro.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Retro.accent, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func waiting(_ text: String) -> some View {
        VStack(spacing: 18) {
            ProgressView().tint(Retro.accent)
            Text(text).font(.headline.monospaced())
            Text("Both devices need Wi-Fi or Bluetooth enabled and local network permission.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity)
    }
}

struct CourtView: View {
    let snapshot: PongSnapshot
    let playingRight: Bool
    let move: (Double, Bool) -> Void

    @GestureState private var fingerDown = false
    @State private var pendingPosition: Double?

    private var localPaddle: Double {
        playingRight ? snapshot.rightPaddleY : snapshot.leftPaddleY
    }

    private func releaseIfNeeded() {
        guard let pendingPosition else { return }
        self.pendingPosition = nil
        move(pendingPosition, true)
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let sx = size.width, sy = size.height
                let line = Path { path in
                    path.move(to: CGPoint(x: sx / 2, y: 0))
                    path.addLine(to: CGPoint(x: sx / 2, y: sy))
                }
                context.stroke(line, with: .color(.gray.opacity(0.5)),
                               style: StrokeStyle(lineWidth: 2, dash: [8, 8]))
                for (x, y) in [
                    (PongGame.paddleInset, snapshot.leftPaddleY),
                    (1 - PongGame.paddleInset, snapshot.rightPaddleY)
                ] {
                    let rect = CGRect(x: (x - PongGame.paddleWidth / 2) * sx,
                                      y: (y - PongGame.paddleHeight / 2) * sy,
                                      width: PongGame.paddleWidth * sx,
                                      height: PongGame.paddleHeight * sy)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.white))
                }
                let ball = CGRect(x: (snapshot.ballX - PongGame.ballRadius) * sx,
                                  y: (snapshot.ballY - PongGame.ballRadius) * sy,
                                  width: PongGame.ballRadius * 2 * sx,
                                  height: PongGame.ballRadius * 2 * sy)
                context.fill(Path(ellipseIn: ball), with: .color(.white))
            }
            .background(.black)
            .border(.white.opacity(0.8), width: 2)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($fingerDown) { _, active, _ in active = true }
                .onChanged { v in
                    let y = Double(v.location.y / max(geo.size.height, 1))
                    pendingPosition = y
                    move(y, false)
                }
                .onEnded { _ in releaseIfNeeded() })
            .onChange(of: fingerDown) { oldValue, newValue in
                if oldValue && !newValue { releaseIfNeeded() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(playingRight ? "Right paddle" : "Left paddle")
            .accessibilityValue("\(Int((localPaddle * 100).rounded())) percent court height")
            .accessibilityHint("Drag vertically, or swipe up and down with VoiceOver to adjust")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: move(min(1 - PongGame.paddleHeight / 2, localPaddle + 0.06), true)
                case .decrement: move(max(PongGame.paddleHeight / 2, localPaddle - 0.06), true)
                @unknown default: break
                }
            }
        }
    }
}
