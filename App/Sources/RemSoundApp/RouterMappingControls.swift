import AppKit
import CoreFoundation
import RemSoundCore
import RemSoundRuntime

@MainActor
final class RouterMappingControls: NSObject {
    static let settingKey = "automaticRouterPortOpening"
    let view = NSStackView()
    let checkbox = NSButton(checkboxWithTitle: "Automatically open my router for incoming connections (UPnP)", target: nil, action: nil)
    let status = ServerStatusTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 64))
    var keyViews: [NSView] { [checkbox, status] }
    private(set) var enabled = false
    private let configuration: RuntimeConfiguration
    private let allowed: () -> Bool, clock: () -> TimeInterval
    private let makeBackend: () -> RouterMappingBackend
    private let schedule: (@escaping () -> Void) -> () -> Void
    private let watchWake: (@escaping () -> Void) -> () -> Void
    private var request: UUID?, acknowledgedRequest: UUID?
    private var observed: SessionNetworkBinding?, acknowledged: SessionNetworkBinding?, applied: SessionNetworkBinding?
    private var running = false, closed = false
    private var driverGeneration: UUID?, cancelTick: (() -> Void)?, cancelWake: (() -> Void)?
    private var saveError: String?
    private lazy var owner = RouterPortMapping(permitted: { [weak self] in self?.eligible == true }, clock: clock, makeBackend: makeBackend)
    private var eligible: Bool {
        !closed && enabled && allowed() && running && request != nil && request == acknowledgedRequest &&
        observed != nil && observed == acknowledged && observed!.port > 0
    }
    init(configuration: RuntimeConfiguration, allowed: (() -> Bool)? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         makeBackend: (() -> RouterMappingBackend)? = nil,
         schedule: ((@escaping () -> Void) -> () -> Void)? = nil,
         watchWake: ((@escaping () -> Void) -> () -> Void)? = nil) {
        // Isolated opt-in fixtures must inject every native resource boundary.
        precondition(allowed == nil || !configuration.isIsolated || (makeBackend != nil && schedule != nil && watchWake != nil))
        self.configuration = configuration; self.allowed = allowed ?? { !configuration.isIsolated }; self.clock = clock
        self.makeBackend = makeBackend ?? { RouterMappingServiceBackend(service: RouterMappingService(configuration: configuration)) }
        self.schedule = schedule ?? Self.scheduleTick; self.watchWake = watchWake ?? Self.observeWake
        if let number = configuration.settings.object(forKey: Self.settingKey) as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() { enabled = number.boolValue }
        super.init()
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 4
        checkbox.target = self; checkbox.action = #selector(choiceChanged)
        checkbox.setAccessibilityHelp("Computer-wide and off by default. Opens only the live RemSound audio port, using compatible UPnP, NAT-PMP or PCP. This choice is separate from profiles. Router results cannot guarantee Internet reachability.")
        status.setAccessibilityLabel("Router port mapping status")
        let scroll = NSScrollView(); scroll.documentView = status; scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addArrangedSubview(checkbox); view.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 64).isActive = true
        owner.onChange = { [weak self] _ in
            guard let self else { return }
            self.saveError = nil
            if self.owner.isBlocked { self.stopDrivers() }
            self.render()
        }
        render()
    }
    deinit { MainActor.assumeIsolated { stopDrivers(); owner.shutdown() } }
    @objc func choiceChanged() {
        guard !closed else { render(); return }
        let proposed = checkbox.state == .on
        guard proposed != enabled else { return }
        guard configuration.settings.setValues([Self.settingKey: proposed]) else {
            saveError = "Could not save the router choice. The previous choice and mapping remain in effect."
            render()
            if let window = status.window { window.makeFirstResponder(status) }
            return
        }
        enabled = proposed; saveError = nil; reconcile()
    }
    func beginStart(_ request: UUID) {
        guard !closed else { return }
        invalidate(); self.request = request
    }
    func observe(running: Bool, binding: SessionNetworkBinding?) {
        guard !closed else { return }
        self.running = running; observed = running ? binding : nil; reconcile()
    }
    func acknowledge(_ request: UUID, binding: SessionNetworkBinding?) {
        guard !closed, self.request == request else { return }
        acknowledgedRequest = request; acknowledged = binding; reconcile()
    }
    func invalidate() {
        request = nil; acknowledgedRequest = nil; acknowledged = nil; observed = nil; running = false
        reconcile()
    }
    private func reconcile() {
        guard eligible, let binding = observed else {
            applied = nil; stopDrivers(); owner.setEnabled(false); render(); return
        }
        if applied != binding {
            // A fresh socket on the same port must retire the previous mapping.
            applied = binding; stopDrivers(); owner.setEnabled(false); owner.setEnabled(true, port: binding.port)
        }
        if !owner.isBlocked { startDrivers() }
        render()
    }
    private func startDrivers() {
        guard driverGeneration == nil, eligible, !owner.isBlocked else { return }
        let generation = UUID(); driverGeneration = generation
        let tick = schedule { [weak self] in
            guard let self, self.driverGeneration == generation else { return }
            guard self.eligible else { self.reconcile(); return }
            self.owner.tick()
        }
        guard driverGeneration == generation, eligible, !owner.isBlocked else { tick(); return }
        cancelTick = tick
        let wake = watchWake { [weak self] in
            guard let self, self.driverGeneration == generation else { return }
            guard self.eligible else { self.reconcile(); return }
            self.owner.refresh()
        }
        guard driverGeneration == generation, eligible, !owner.isBlocked else { wake(); return }
        cancelWake = wake
    }
    private func stopDrivers() {
        driverGeneration = nil
        let tick = cancelTick, wake = cancelWake; cancelTick = nil; cancelWake = nil
        tick?(); wake?()
    }
    private static func scheduleTick(_ callback: @escaping () -> Void) -> () -> Void {
        let timer = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { callback() } }
        RunLoop.main.add(timer, forMode: .common); return { timer.invalidate() }
    }
    private static func observeWake(_ callback: @escaping () -> Void) -> () -> Void {
        let center = NSWorkspace.shared.notificationCenter
        let observer = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { callback() }
        }
        return { center.removeObserver(observer) }
    }
    private func render() {
        checkbox.state = enabled ? .on : .off; checkbox.isEnabled = !closed
        let text: String
        if let saveError { text = saveError }
        else if owner.isBlocked { text = "The router mapping did not close properly. " + (owner.state.lastError ?? "Further mapping is blocked.") }
        else if closed { text = "Router mapping is stopping or stopped." }
        else if !enabled { text = "Automatic router port opening is off." }
        else if !allowed() { text = "Router mapping is unavailable in isolated configuration." }
        else if !eligible { text = "Router opening is enabled. Waiting for an acknowledged running RemSound audio socket." }
        else {
            switch owner.state.status {
            case .disabled: text = "Router mapping is waiting for previous cleanup."
            case .searching: text = "Checking a compatible router for UPnP, NAT-PMP or PCP."
            case .mapped: text = "Router mapping reported: \(owner.state.externalAddress ?? "unknown address") port \(owner.state.externalPort ?? 0). Internet reachability is not confirmed."
            case .noRouterFound: text = "No compatible router answered. Automatic retry follows the router deadline."
            case .cgnatDetected: text = "Carrier-grade NAT detected. This router mapping cannot establish a public incoming route."
            case .mappingFailed: text = "Router mapping failed. " + (owner.state.lastError ?? "No mapping was confirmed.")
            }
        }
        status.update(text)
    }
    func shutdown(_ completion: @escaping (Result<Void, Error>) -> Void) {
        closed = true; invalidate(); owner.shutdown(completion); render()
    }
    func shutdown() { closed = true; invalidate(); owner.shutdown(); render() }
}
