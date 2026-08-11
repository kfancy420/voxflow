import AppKit
import os

/// Small floating, always-on-top "pill" HUD shown while dictating. Never
/// activates the app or steals key focus — insertion targets whatever app is
/// frontmost, so this window must remain non-activating at all times.
@MainActor
final class HUDController {
    private static let logger = os.Logger(subsystem: "com.voxflow.app", category: "HUDController")

    private static let pillSize = NSSize(width: 220, height: 56)
    private static let bottomMargin: CGFloat = 80

    private let panel: NSPanel
    private let waveformView: WaveformView
    private let statusLabel: NSTextField
    private let spinner: NSProgressIndicator

    private var levelObserver: NSObjectProtocol?
    private var currentState: FlowState = .idle

    init() {
        let contentRect = NSRect(origin: .zero, size: Self.pillSize)

        let panel = NSPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0

        let effectView = NSVisualEffectView(frame: contentRect)
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 14
        effectView.layer?.masksToBounds = true
        effectView.autoresizingMask = [.width, .height]

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isHidden = true

        let waveform = WaveformView(frame: NSRect(x: 16, y: 8, width: Self.pillSize.width - 32, height: 40))
        waveform.translatesAutoresizingMaskIntoConstraints = false

        effectView.addSubview(waveform)
        effectView.addSubview(spinner)
        effectView.addSubview(label)

        NSLayoutConstraint.activate([
            waveform.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 16),
            waveform.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -16),
            waveform.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 8),
            waveform.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -8),

            label.centerXAnchor.constraint(equalTo: effectView.centerXAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),

            spinner.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -8),
            spinner.centerYAnchor.constraint(equalTo: effectView.centerYAnchor),
        ])

        panel.contentView = effectView

        self.panel = panel
        self.waveformView = waveform
        self.statusLabel = label
        self.spinner = spinner

        levelObserver = NotificationCenter.default.addObserver(
            forName: .voxFlowAudioLevel, object: nil, queue: .main
        ) { [weak self] note in
            // Delivered on the main queue (see `queue: .main`), but the block
            // itself is nonisolated as far as the compiler is concerned.
            MainActor.assumeIsolated {
                guard let self, let level = note.userInfo?["level"] as? Float else { return }
                self.waveformView.push(level: level)
            }
        }

        applyState(.idle)
        Self.logger.info("HUDController initialized")
    }

    deinit {
        if let levelObserver {
            NotificationCenter.default.removeObserver(levelObserver)
        }
    }

    // MARK: - Public API (SPEC)

    func show() {
        positionOnMainScreen()
        applyState(currentState)
        panel.orderFrontRegardless()
        waveformView.isRunning = (currentState == .recording)
        fade(to: 1.0)
    }

    func update(state: FlowState) {
        currentState = state
        applyState(state)
        waveformView.isRunning = (state == .recording)
    }

    func hide() {
        waveformView.isRunning = false
        fade(to: 0.0) { [weak self] in
            MainActor.assumeIsolated {
                self?.panel.orderOut(nil)
            }
        }
    }

    // MARK: - Private

    private func applyState(_ state: FlowState) {
        switch state {
        case .idle:
            statusLabel.stringValue = ""
            spinner.isHidden = true
            spinner.stopAnimation(nil)
            waveformView.isHidden = false
        case .recording:
            statusLabel.stringValue = ""
            spinner.isHidden = true
            spinner.stopAnimation(nil)
            waveformView.isHidden = false
        case .transcribing:
            statusLabel.stringValue = "Transcribing…"
            spinner.isHidden = false
            spinner.startAnimation(nil)
            waveformView.isHidden = true
        case .cleaning:
            statusLabel.stringValue = "Polishing…"
            spinner.isHidden = false
            spinner.startAnimation(nil)
            waveformView.isHidden = true
        case .inserting:
            statusLabel.stringValue = "Inserting…"
            spinner.isHidden = false
            spinner.startAnimation(nil)
            waveformView.isHidden = true
        case .error(let message):
            statusLabel.stringValue = message.isEmpty ? "Error" : message
            spinner.isHidden = true
            spinner.stopAnimation(nil)
            waveformView.isHidden = true
        }
    }

    private func positionOnMainScreen() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.midX - Self.pillSize.width / 2
        let y = frame.minY + Self.bottomMargin
        panel.setFrame(NSRect(x: x, y: y, width: Self.pillSize.width, height: Self.pillSize.height), display: true)
    }

    private func fade(to alpha: CGFloat, completion: (() -> Void)? = nil) {
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ context in
            MainActor.assumeIsolated {
                context.duration = 0.15
                panel.animator().alphaValue = alpha
            }
        }, completionHandler: completion)
    }
}

/// Lightweight live waveform view: keeps a ring buffer of recent audio
/// levels (0...1) and draws them as vertical rounded bars, refreshed at a
/// steady rate via a Timer (no CADisplayLink on macOS pre-14.0 AppKit paths).
private final class WaveformView: NSView {
    private static let barCount = 24

    private var levels: [Float] = Array(repeating: 0, count: WaveformView.barCount)
    private var timer: Timer?

    var isRunning: Bool = false {
        didSet {
            guard isRunning != oldValue else { return }
            if isRunning {
                startTimer()
            } else {
                stopTimer()
                levels = Array(repeating: 0, count: Self.barCount)
                needsDisplay = true
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    deinit {
        timer?.invalidate()
    }

    func push(level: Float) {
        levels.removeFirst()
        levels.append(min(max(level, 0), 1))
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop below, so this always fires on
            // the main thread.
            MainActor.assumeIsolated {
                self?.needsDisplay = true
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isRunning else { return }
        NSColor.clear.setFill()
        dirtyRect.fill()

        let barCount = Self.barCount
        let spacing: CGFloat = 3
        let totalSpacing = spacing * CGFloat(barCount - 1)
        let barWidth = max(1, (bounds.width - totalSpacing) / CGFloat(barCount))
        let minHeight: CGFloat = 3
        let maxHeight = bounds.height

        NSColor.white.withAlphaComponent(0.9).setFill()

        for (index, level) in levels.enumerated() {
            let height = max(minHeight, CGFloat(level) * maxHeight)
            let x = CGFloat(index) * (barWidth + spacing)
            let y = (bounds.height - height) / 2
            let barRect = NSRect(x: x, y: y, width: barWidth, height: height)
            let path = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            path.fill()
        }
    }
}
