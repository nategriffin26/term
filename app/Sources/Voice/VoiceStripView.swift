import UIKit

/// What dictation is doing, as the Smart Keys bar shows it.
enum VoiceState: Equatable, Sendable {
  case idle
  /// The microphone is on and recording.
  case listening(HeardLevels)
  /// Not listening; `pending` recordings are still being transcribed.
  case transcribing(pending: Int)
  /// Not listening; `queued` recordings wait behind a failure.
  case failed(queued: Int, problem: VoiceProblem)
  /// Not listening: the microphone did not start, or stopped by itself.
  case microphoneUnavailable
}

/// The input levels of the recording so far, each 0 (silence) to 1 (loud
/// speech), one per 50 ms; they arrive two at a time, every 100 ms.
struct HeardLevels: Equatable, Sendable {
  /// The latest, oldest first.
  var recent: [Float] = []
  /// Levels since listening started, so the strip knows how many are new
  /// even when the latest repeat earlier ones.
  var total = 0

  static let recentCount = 40

  mutating func add(_ levels: [Float]) {
    recent.append(contentsOf: levels)
    if recent.count > Self.recentCount { recent.removeFirst(recent.count - Self.recentCount) }
    total += levels.count
  }
}

/// What the strip says for a moment after a recording.
enum VoiceNote: Equatable, Sendable {
  /// The text went to the clipboard: its terminal shows another session now.
  case copied
  /// The recording held no speech, so nothing was sent or typed.
  case noSpeech
}

/// The mic key and the free middle of the Smart Keys bar, as one (Trace,
/// the direction the user picked). Listening lights the mic key like a
/// locked modifier and scrolls a trace of the voice through the middle in
/// the text colour (`LevelTape`); transcribing flattens it to dots with a
/// light passing across; a failure shows its glyph and the queued count in
/// the error colour; a note ("Copied", "No speech") shows its glyph and
/// words in the text colour for a moment. Tapping a failure retries, or
/// opens Settings › Voice when it is fixed there; the close button discards
/// the queue after a confirmation.
@MainActor
final class VoiceStripView: UIView {
  var state = VoiceState.idle { didSet { if state != oldValue { update(from: oldValue) } } }
  /// Said in the middle over whatever else it shows.
  var note: VoiceNote? { didSet { if note != oldValue { showMarks() } } }
  var micWidth: CGFloat = 40 { didSet { setNeedsLayout() } }
  var onMic: (() -> Void)?
  var onRetry: (() -> Void)?
  var onOpenSettings: (() -> Void)?
  var onDiscard: (() -> Void)?

  private let mic = KeyCap()
  /// The free middle: taps on a failure land here.
  private let status = UIControl()
  private let trace = UIView()
  private let fade = CAGradientLayer()
  private var bars: [CALayer] = []
  private var xs: [CGFloat] = [], hs: [CGFloat] = [], alphas: [CGFloat] = []
  private let icon = UIImageView()
  private let count = UILabel()
  private let discard = UIButton(type: .system)
  private var traceAlpha: CGFloat = 0
  private var markAlpha: CGFloat = 0

  private var link: CADisplayLink?
  private var clock: CFTimeInterval = 0
  private var tape = LevelTape()

  private static let barCount = 26
  private static let pitch = CGFloat(LevelTape.barSeconds * LevelTape.speed)
  private static let barWidth: CGFloat = 2

  override init(frame: CGRect) {
    super.init(frame: frame)
    mic.configure(symbol: "mic")
    mic.accessibilityLabel = "Dictate"
    mic.onTap = { [weak self] in self?.onMic?() }
    addSubview(mic)
    status.addAction(UIAction { [weak self] _ in self?.statusTapped() }, for: .touchUpInside)
    addSubview(status)
    trace.isUserInteractionEnabled = false
    fade.startPoint = CGPoint(x: 0, y: 0.5)
    fade.endPoint = CGPoint(x: 1, y: 0.5)
    fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
    fade.locations = [0, 0.22, 0.9, 1]
    trace.layer.mask = fade
    status.addSubview(trace)
    for _ in 0..<Self.barCount {
      let bar = CALayer()
      // Bars sit at fractional points as they scroll: without this their
      // edges snap to whole pixels and the trace steps unevenly.
      bar.allowsEdgeAntialiasing = true
      bar.opacity = 0
      trace.layer.addSublayer(bar)
      bars.append(bar)
      xs.append(0)
      hs.append(2)
      alphas.append(0)
    }
    icon.contentMode = .center
    icon.tintColor = Chrome.UI.bad
    icon.isUserInteractionEnabled = false
    count.font = Chrome.uiMono(.caption, .medium, size: .standard)
    count.textColor = Chrome.UI.bad
    count.isUserInteractionEnabled = false
    [icon, count].forEach(status.addSubview)
    discard.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)),
                     for: .normal)
    discard.tintColor = Chrome.UI.muted
    discard.accessibilityLabel = "Discard Queued Speech"
    discard.showsMenuAsPrimaryAction = true
    discard.menu = UIMenu(children: [
      UIAction(title: "Discard Speech", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
        self?.onDiscard?()
      },
    ])
    addSubview(discard)
    update(from: .idle)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  private func statusTapped() {
    switch state {
    case .failed(_, let problem): if problem.needsSettings { onOpenSettings?() } else { onRetry?() }
    case .microphoneUnavailable: onMic?()
    default: break
    }
  }

  // MARK: - State

  private func update(from old: VoiceState) {
    if case .listening(let heard) = state {
      if case .listening = old {} else { tape = LevelTape() }
      tape.receive(heard, at: CACurrentMediaTime())
    }
    showMarks()
  }

  /// The mic key, the failure or copied mark, and what VoiceOver reads, for the state.
  private func showMarks() {
    let listening = if case .listening = state { true } else { false }
    let lit = listening ? SmartKeysBar.Modifier.armed : .off
    if mic.modifier != lit {
      mic.setSymbol(listening ? "mic.fill" : "mic")
      UIView.animate(withDuration: 0.15) { self.mic.modifier = lit }
    }
    switch state {
    case .idle:
      status.accessibilityLabel = nil
    case .listening:
      status.accessibilityLabel = "Listening"
    case .transcribing(let pending):
      status.accessibilityLabel = pending > 1 ? "Transcribing \(pending) recordings" : "Transcribing"
    case .failed(let queued, let problem):
      icon.image = UIImage(systemName: Self.symbol(for: problem),
                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
      count.text = "\(queued)"
      status.accessibilityLabel = switch problem {
      case .offline: "Offline, \(queued) waiting"
      case .badKey: "OpenRouter refused the key, \(queued) waiting"
      case .noCredit: "Out of OpenRouter credit, \(queued) waiting"
      case .modelNotFound: "Unknown model, \(queued) waiting"
      case .other(let message): "\(message), \(queued) waiting"
      }
      status.accessibilityHint = problem.needsSettings ? "Opens Voice settings" : "Retries"
    case .microphoneUnavailable:
      icon.image = UIImage(systemName: "mic.slash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
      count.text = nil
      status.accessibilityLabel = "Microphone unavailable"
      status.accessibilityHint = "Listens again"
    }
    if let note {
      let (symbol, words, spoken) = switch note {
      case .copied: ("doc.on.clipboard", "Copied", "Dictated text copied")
      case .noSpeech: ("waveform.slash", "No speech", "No speech heard")
      }
      icon.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
      count.text = words
      status.accessibilityLabel = spoken
    }
    icon.tintColor = note != nil ? Chrome.UI.fg : Chrome.UI.bad
    count.textColor = note != nil ? Chrome.UI.fg : Chrome.UI.bad
    status.isAccessibilityElement = state != .idle || note != nil
    if case .failed = state, note == nil { discard.isHidden = false } else { discard.isHidden = true }
    setNeedsLayout()
    run()
  }

  private static func symbol(for problem: VoiceProblem) -> String {
    switch problem {
    case .offline: "wifi.slash"
    case .badKey: "key"
    case .noCredit: "creditcard"
    case .modelNotFound: "questionmark.circle"
    case .other: "exclamationmark.circle"
    }
  }

  /// Speech sits high in the level range; spread its working part over 0…1.
  private static func spread(_ level: Float) -> CGFloat { CGFloat(min(max((level - 0.3) / 0.55, 0), 1)) }

  // MARK: - Drawing

  override func layoutSubviews() {
    super.layoutSubviews()
    mic.frame = CGRect(x: 0, y: 0, width: micWidth, height: bounds.height)
    status.frame = CGRect(x: micWidth, y: 0, width: max(0, bounds.width - micWidth), height: bounds.height)
    trace.frame = status.bounds.insetBy(dx: 2, dy: 0)
    fade.frame = trace.bounds
    let mid = status.bounds.midY
    count.sizeToFit()
    icon.frame = CGRect(x: 8, y: mid - 9, width: 18, height: 18)
    count.frame.origin = CGPoint(x: 29, y: mid - count.bounds.height / 2)
    discard.frame = CGRect(x: bounds.maxX - 32, y: mid - 16, width: 32, height: 32)
    draw(dt: 0)
  }

  private func run() {
    guard link == nil, window != nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      link?.invalidate()
      link = nil
    } else {
      run()
    }
  }

  @objc private func tick(_ link: CADisplayLink) {
    let dt = clock == 0 ? 1.0 / 60 : min(link.targetTimestamp - clock, 0.1)
    clock = link.targetTimestamp
    if draw(dt: dt) {
      link.invalidate()
      self.link = nil
      clock = 0
    }
  }

  /// One frame: everything eases toward the state's look. True once it has settled with nothing moving.
  @discardableResult
  private func draw(dt: CFTimeInterval) -> Bool {
    // Rates are per 60 Hz frame, as designed, and scaled to the frame's length.
    func ease(_ value: inout CGFloat, to target: CGFloat, _ rate: CGFloat) -> CGFloat {
      value += (target - value) * (1 - pow(1 - rate, CGFloat(dt * 60)))
      return value
    }
    let now = clock
    var listening = false, waiting = false, failed = false
    switch state {
    case .listening: listening = true
    case .transcribing: waiting = true
    case .failed, .microphoneUnavailable: failed = true
    case .idle: break
    }
    let w = trace.bounds.width, mid = trace.bounds.midY
    let ink = Chrome.UI.fg.resolvedColor(with: traitCollection).cgColor
    let sweep = CGFloat((now / 1.1).truncatingRemainder(dividingBy: 1)) * (w + 40) - 20
    var moving = listening || waiting
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for i in bars.indices {
      var x = w - 2 - CGFloat(i) * Self.pitch, h: CGFloat = 2, a: CGFloat = 0
      if listening {
        // Straight from the tape: a bar's place follows the clock and its height is fixed.
        let bar = tape.bar(i, at: now)
        x = w - 2 - CGFloat(bar.offset)
        if let level = bar.level { h = max(2, 24 * pow(Self.spread(level), 1.6)); a = 1 } else { a = 0.25 }
        xs[i] = x
        hs[i] = h
        alphas[i] = a
      } else if waiting {
        // Dots with a light passing across them, bold enough to read at arm's length.
        let near = exp(-pow((x - sweep) / 11, 2))
        h = 3 + 8 * near
        a = 0.6 + 0.4 * near
        _ = ease(&xs[i], to: x, 0.3)
      } else {
        _ = ease(&xs[i], to: x, 0.3)
      }
      let fh = listening ? h : ease(&hs[i], to: h, 0.25)
      let fa = listening ? a : ease(&alphas[i], to: a, 0.3)
      if abs(fa - a) > 0.01 || abs(fh - h) > 0.1 { moving = true }
      bars[i].frame = CGRect(x: xs[i] - Self.barWidth / 2, y: mid - fh / 2, width: Self.barWidth, height: fh)
      bars[i].cornerRadius = min(Self.barWidth / 2, fh / 2)
      bars[i].opacity = Float(fa)
      bars[i].backgroundColor = ink
    }
    CATransaction.commit()
    let traceTarget: CGFloat = (listening || waiting) && note == nil ? 1 : 0
    trace.alpha = ease(&traceAlpha, to: traceTarget, 0.2)
    let markTarget: CGFloat = failed || note != nil ? 1 : 0
    let mark = ease(&markAlpha, to: markTarget, 0.3)
    icon.alpha = mark
    count.alpha = mark
    discard.alpha = mark
    if abs(traceAlpha - traceTarget) > 0.01 || abs(markAlpha - markTarget) > 0.01 { moving = true }
    return !moving
  }
}
