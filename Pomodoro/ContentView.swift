import SwiftUI
import Combine
import UserNotifications
import AudioToolbox
import UIKit

// MARK: - Alarm sound options (SystemSoundID)

enum AlarmSound: String, CaseIterable, Identifiable {
    case alarm1 = "Alarm 1"
    case alarm2 = "Alarm 2"
    case alert1 = "Alert 1"
    case alert2 = "Alert 2"

    var id: String { rawValue }

    // Prototype-friendly system sounds
    var soundID: SystemSoundID {
        switch self {
        case .alarm1: return 1005
        case .alarm2: return 1007
        case .alert1: return 1013
        case .alert2: return 1022
        }
    }
}

final class FeedbackManager {
    static let shared = FeedbackManager()
    private init() {}

    func play(sound: AlarmSound) {
        AudioServicesPlaySystemSound(sound.soundID)
    }

    func haptic() {
        let gen = UIImpactFeedbackGenerator(style: .heavy)
        gen.prepare()
        gen.impactOccurred()
    }
}

// MARK: - Pomodoro

enum PomodoroPhase: String {
    case focus = "Focus"
    case `break` = "Break"
}

final class PomodoroViewModel: ObservableObject {

    // MARK: - UserDefaults keys
    private enum Keys {
        static let focusMinutes = "settings.focusMinutes"
        static let breakMinutes = "settings.breakMinutes"
        static let phase = "settings.phase"
        static let alarmOn = "settings.alarmOn"
        static let hapticOn = "settings.hapticOn"
        static let alarmSound = "settings.alarmSound"
    }

    // MARK: - Config (persisted)
    @Published var focusMinutes: Int = 25
    @Published var breakMinutes: Int = 5

    @Published var alarmOn: Bool = true
    @Published var hapticOn: Bool = false
    @Published var selectedAlarm: AlarmSound = .alarm2

    // MARK: - State
    @Published private(set) var phase: PomodoroPhase = .focus
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var remainingSeconds: Int = 25 * 60
    @Published private(set) var totalSeconds: Int = 25 * 60
    @Published private(set) var hasStarted: Bool = false
    @Published private(set) var isFinishingFeedback: Bool = false

    private var endTime: Date? = nil
    private var ticker: Timer? = nil
    private let notifId = "pomodoro.timer.done"

    // feedback sequence (3 seconds)
    private var finishingTimer: Timer? = nil
    private var finishingFireCount: Int = 0

    init() {
        requestNotificationPermission()
        loadSettings()
        reset(to: phase)
        startTicker()
    }

    deinit {
        ticker?.invalidate()
        stopFinishingFeedback()
    }

    // MARK: - Persistence

    private func loadSettings() {
        let ud = UserDefaults.standard

        let f = ud.integer(forKey: Keys.focusMinutes)
        let b = ud.integer(forKey: Keys.breakMinutes)
        if f > 0 { focusMinutes = f }
        if b > 0 { breakMinutes = b }

        if let p = ud.string(forKey: Keys.phase),
           let loaded = PomodoroPhase(rawValue: p) {
            phase = loaded
        }

        if ud.object(forKey: Keys.alarmOn) != nil { alarmOn = ud.bool(forKey: Keys.alarmOn) }
        if ud.object(forKey: Keys.hapticOn) != nil { hapticOn = ud.bool(forKey: Keys.hapticOn) }

        if let s = ud.string(forKey: Keys.alarmSound),
           let sound = AlarmSound(rawValue: s) {
            selectedAlarm = sound
        }
    }

    private func saveSettings() {
        let ud = UserDefaults.standard
        ud.set(focusMinutes, forKey: Keys.focusMinutes)
        ud.set(breakMinutes, forKey: Keys.breakMinutes)
        ud.set(phase.rawValue, forKey: Keys.phase)
        ud.set(alarmOn, forKey: Keys.alarmOn)
        ud.set(hapticOn, forKey: Keys.hapticOn)
        ud.set(selectedAlarm.rawValue, forKey: Keys.alarmSound)
    }

    // MARK: - Public Actions

    func toggleStartPause() {
        stopFinishingFeedback()
        isRunning ? pause() : start()
    }

    func start() {
        stopFinishingFeedback()
        guard !isRunning else { return }
        isRunning = true
        if !hasStarted { hasStarted = true }

        if endTime == nil {
            endTime = Date().addingTimeInterval(TimeInterval(remainingSeconds))
        }

        scheduleSilentNotification(in: remainingSeconds, phase: phase)
        tick()
    }

    func pause() {
        stopFinishingFeedback()
        guard isRunning else { return }
        isRunning = false
        endTime = nil
        cancelNotification()
    }

    /// Long-press stop: fully stop and return to phase initial time (show settings again)
    func stopAndReset() {
        stopFinishingFeedback()
        isRunning = false
        endTime = nil
        cancelNotification()

        let total = (phase == .focus ? focusMinutes : breakMinutes) * 60
        totalSeconds = total
        remainingSeconds = total
        hasStarted = false
    }

    func reset(to newPhase: PomodoroPhase? = nil) {
        stopFinishingFeedback()
        isRunning = false
        endTime = nil
        cancelNotification()

        if let p = newPhase { phase = p }

        let total = (phase == .focus ? focusMinutes : breakMinutes) * 60
        totalSeconds = total
        remainingSeconds = total
        hasStarted = false

        saveSettings()
    }

    func applyDurations() {
        if !hasStarted && !isRunning && !isFinishingFeedback {
            let total = (phase == .focus ? focusMinutes : breakMinutes) * 60
            totalSeconds = total
            remainingSeconds = total
        }
        saveSettings()
    }

    func applyFeedbackSettings() {
        saveSettings()
    }

    // MARK: - Ticker

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let ticker { RunLoop.main.add(ticker, forMode: .common) }
    }

    private func tick() {
        guard isRunning else { return }

        if endTime == nil {
            endTime = Date().addingTimeInterval(TimeInterval(remainingSeconds))
            return
        }

        guard let end = endTime else { return }

        let secs = Int(ceil(end.timeIntervalSinceNow))
        let newRemaining = max(0, secs)

        if newRemaining != remainingSeconds {
            remainingSeconds = newRemaining
        }

        if remainingSeconds == 0 {
            onTimerFinished()
        }
    }

    private func onTimerFinished() {
        // Stop ticking state
        isRunning = false
        endTime = nil
        cancelNotification()

        // Show 00:00 for a moment
        remainingSeconds = 0

        // Fire finishing feedback for ~3s
        startFinishingFeedback()

        // After feedback, auto-switch phase
        let nextPhase: PomodoroPhase = (phase == .focus) ? .break : .focus

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            self.stopFinishingFeedback()

            self.phase = nextPhase
            let total = (self.phase == .focus ? self.focusMinutes : self.breakMinutes) * 60
            self.totalSeconds = total
            self.remainingSeconds = total
            self.hasStarted = false
            self.saveSettings()
        }
    }

    // MARK: - Finishing Feedback (3 seconds)

    private func startFinishingFeedback() {
        stopFinishingFeedback()

        // If user turned everything off, do nothing
        guard alarmOn || hapticOn else { return }

        isFinishingFeedback = true
        finishingFireCount = 0

        // 3 seconds total / 0.6 interval ≈ 5 times
        finishingTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] t in
            guard let self else { return }

            self.finishingFireCount += 1

            if self.alarmOn {
                FeedbackManager.shared.play(sound: self.selectedAlarm)
            }
            if self.hapticOn {
                FeedbackManager.shared.haptic()
            }

            if self.finishingFireCount >= 5 {
                t.invalidate()
                self.finishingTimer = nil
            }
        }

        if let finishingTimer {
            RunLoop.main.add(finishingTimer, forMode: .common)
        }
    }

    private func stopFinishingFeedback() {
        finishingTimer?.invalidate()
        finishingTimer = nil
        finishingFireCount = 0
        isFinishingFeedback = false
    }

    // MARK: - Notifications (silent fallback)

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    private func scheduleSilentNotification(in seconds: Int, phase: PomodoroPhase) {
        guard seconds > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Pomodoro"
        content.body = (phase == .focus)
            ? "Focus finished. Time for a break."
            : "Break finished. Back to focus."
        content.sound = nil

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
        let request = UNNotificationRequest(identifier: notifId, content: content, trigger: trigger)

        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notifId])
        UNUserNotificationCenter.current().add(request)
    }

    private func cancelNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notifId])
    }
}

// MARK: - Minimal UI Components

struct IconToggleButton: View {
    let systemName: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(isOn ? 0.95 : 0.55))
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(.white.opacity(isOn ? 0.16 : 0.08))
                )
                .overlay(
                    Circle().stroke(.white.opacity(isOn ? 0.28 : 0.14), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var vm = PomodoroViewModel()
    @Environment(\.scenePhase) private var scenePhase

    // Tomato gradient (warm & calm)
    private let bgTop = Color(red: 0.96, green: 0.28, blue: 0.24)
    private let bgMid = Color(red: 0.98, green: 0.36, blue: 0.22)
    private let bgBot = Color(red: 0.98, green: 0.52, blue: 0.20)

    private var progress: Double {
        guard vm.totalSeconds > 0 else { return 0 }
        return 1.0 - (Double(vm.remainingSeconds) / Double(vm.totalSeconds))
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [bgTop, bgMid, bgBot],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer()

                // Phase label (low presence)
                Text(vm.phase.rawValue.uppercased())
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.75))

                // Main timer button
                Button {
                    vm.toggleStartPause()
                } label: {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.14), lineWidth: 10)
                            .frame(width: 280, height: 280)

                        Circle()
                            .trim(from: 0, to: progress)
                            .stroke(
                                .white.opacity(0.85),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                            .frame(width: 280, height: 280)
                            .animation(.easeInOut(duration: 0.18), value: progress)

                        Circle()
                            .fill(.white.opacity(0.10))
                            .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                            .frame(width: 258, height: 258)
                            .shadow(radius: 16)

                        VStack(spacing: 10) {
                            Text(formatTime(vm.remainingSeconds))
                                .font(.system(size: 62, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.white)

                            Image(systemName: vm.isRunning ? "pause.fill" : "play.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                }
                .buttonStyle(.plain)
                // long press to stop (no hint text)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.6)
                        .onEnded { _ in vm.stopAndReset() }
                )

                Spacer()

                // SETTINGS only before start (and not during finishing feedback)
                if !vm.hasStarted && !vm.isFinishingFeedback {
                    settingsPanel
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                        .transition(.opacity)
                }
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: vm.isRunning) { _, _ in
            // Keep screen awake while running OR finishing feedback
            UIApplication.shared.isIdleTimerDisabled = (vm.isRunning || vm.isFinishingFeedback)
        }
        .onChange(of: vm.isFinishingFeedback) { _, _ in
            UIApplication.shared.isIdleTimerDisabled = (vm.isRunning || vm.isFinishingFeedback)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                UIApplication.shared.isIdleTimerDisabled = false
            } else {
                UIApplication.shared.isIdleTimerDisabled = (vm.isRunning || vm.isFinishingFeedback)
            }
        }
    }

    // MARK: - Settings Panel

    private var settingsPanel: some View {
        VStack(spacing: 16) {

            // Add breathing space to avoid "overlap/pressed" look
            HStack(spacing: 10) {
                phaseButton(.focus)
                phaseButton(.break)
            }
            .padding(.top, 4)

            VStack(spacing: 12) {
                durationRow(title: "Focus", value: $vm.focusMinutes, range: 1...120)
                durationRow(title: "Break", value: $vm.breakMinutes, range: 1...60)
            }

            // Symmetry row: bell - menu - haptic
            HStack {
                IconToggleButton(systemName: vm.alarmOn ? "bell.fill" : "bell.slash", isOn: vm.alarmOn) {
                    vm.alarmOn.toggle()
                    vm.applyFeedbackSettings()
                }

                Spacer()

                soundPickerCapsule

                Spacer()

                IconToggleButton(systemName: "waveform.path", isOn: vm.hapticOn) {
                    vm.hapticOn.toggle()
                    vm.applyFeedbackSettings()
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private var soundPickerCapsule: some View {
        // Keep the center anchored even if alarm is off (symmetry & stability)
        Group {
            if vm.alarmOn {
                Menu {
                    ForEach(AlarmSound.allCases) { s in
                        Button {
                            vm.selectedAlarm = s
                            vm.applyFeedbackSettings()
                        } label: {
                            if vm.selectedAlarm == s {
                                Label(s.rawValue, systemImage: "checkmark")
                            } else {
                                Text(s.rawValue)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note")
                        Text(vm.selectedAlarm.rawValue)
                            .lineLimit(1)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(width: 170)
                    .background(Capsule().fill(.white.opacity(0.10)))
                    .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                    Text("Sound")
                        .lineLimit(1)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(width: 170)
                .background(Capsule().fill(.white.opacity(0.06)))
                .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 1))
            }
        }
    }

    private func phaseButton(_ p: PomodoroPhase) -> some View {
        Button {
            vm.reset(to: p)
        } label: {
            Text(p.rawValue)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(vm.phase == p ? 0.95 : 0.65))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(.white.opacity(vm.phase == p ? 0.16 : 0.08))
                )
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(vm.phase == p ? 0.22 : 0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func durationRow(title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text("\(title) \(value.wrappedValue)m")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))

            Spacer()

            Stepper("", value: value, in: range)
                .labelsHidden()
                .onChange(of: value.wrappedValue) { _, _ in
                    vm.applyDurations()
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func formatTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}
