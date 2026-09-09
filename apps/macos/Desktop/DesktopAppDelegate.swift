import AppKit
import Combine
import SwiftUI
import TrigoNative

@MainActor private final class RecordingStatusPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

@MainActor private final class RecordingHostingView<Content: View>: NSHostingView<Content> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Native presentation adapter. Production and #72's fixture executable share this implementation.
@MainActor
public final class DesktopAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
  NSMenuDelegate
{
  public let shell: DesktopShell?
  private let appName: String
  private let startupFailure: RecordingNotice?
  private let login: DesktopLoginModel?
  private let reader: DesktopReader
  private var shortcut: GlobalRecordingShortcut?
  private var observations: [AnyCancellable] = []
  private var statusItem: NSStatusItem?
  private let statusMenu = NSMenu()
  private var menuIsTracking = false
  private var libraryWindow: NSWindow?
  private var libraryToolbar: AnyObject?
  private var settingsWindow: NSWindow?
  private var recordingPanel: NSPanel?
  private var recordingRevealSequence = -1
  private var notificationPanel: NSPanel?
  private var notificationID: UUID?
  private var notificationTask: Task<Void, Never>?
  private lazy var libraryLifecycle = DesktopLibraryLifecycle(
    setDockPresence: { NSApp.setActivationPolicy($0 ? .regular : .accessory) },
    create: { [weak self] in self?.createLibrary() },
    reveal: { [weak self] in
      if self?.libraryWindow?.isMiniaturized == true { self?.libraryWindow?.deminiaturize(nil) }
      self?.libraryWindow?.makeKeyAndOrderFront(nil)
    },
    activate: { NSApp.activate(ignoringOtherApps: true) }
  )

  public static func installed() -> DesktopAppDelegate {
    do {
      let composition = try DesktopComposition.installed()
      return DesktopAppDelegate(
        composition: composition,
        login: composition.services == nil ? nil : DesktopLoginModel(service: SystemLoginService()),
        reader: .live(
          model: LibraryModel(
            preferences: UserDefaults(suiteName: composition.namespace.preferences)!,
            makeSession: { try await composition.makeLibrarySession() }
          )
        )
      )
    } catch {
      return DesktopAppDelegate(
        failure: .init(
          title: "Cannot start this copy of Trigo",
          message:
            "The app identity or local configuration is invalid. Rebuild the intended Trigo variant and reopen it. No archive or credentials were opened."
        )
      )
    }
  }

  /// A fixture cannot use the installed initializer's defaults, register the live shortcut,
  /// or select SMAppService. Login behavior and reader content are explicitly injected too.
  public convenience init(
    fixture: DesktopComposition,
    loginService: any DesktopLoginService,
    reader: DesktopReader,
    makeShortcut: ((DesktopShell) -> GlobalRecordingShortcut)? = nil
  ) throws {
    guard fixture.isFixture else { throw NamespaceError.fixtureRequiresAdapters }
    guard Bundle.main.bundleIdentifier == fixture.namespace.fixtureIdentifier else {
      throw NamespaceError.unsupportedBundle
    }
    self.init(composition: fixture, login: DesktopLoginModel(service: loginService), reader: reader)
    if let makeShortcut, let shell {
      let shortcut = makeShortcut(shell)
      guard shortcut.isFixture else { throw NamespaceError.fixtureRequiresAdapters }
      self.shortcut = shortcut
    }
  }

  private init(composition: DesktopComposition, login: DesktopLoginModel?, reader: DesktopReader) {
    self.shell = DesktopShell(composition: composition)
    self.appName = composition.appName
    self.startupFailure = composition.startupFailure
    self.login = login
    self.reader = reader
    super.init()
    shell?.openLibrary = { [weak self] in self?.showLibrary() }
    shell?.openSettings = { [weak self] in self?.showSettings() }
  }

  private init(failure: RecordingNotice) {
    shell = nil
    appName = "Trigo"
    startupFailure = failure
    login = nil
    reader = .unavailable
    super.init()
  }

  public func applicationWillFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }

  public func applicationDidFinishLaunching(_ notification: Notification) {
    installApplicationMenu()
    statusMenu.delegate = self
    statusMenu.autoenablesItems = false
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem?.menu = statusMenu
    statusItem?.button?.setAccessibilityIdentifier("trigo-status-item")
    observations.append(
      NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
        .sink { [weak self] _ in
          Task { @MainActor in self?.clampRecordingWindows() }
        }
    )
    if let shell {
      if !shell.composition.isFixture, shell.composition.services != nil {
        let shortcut = GlobalRecordingShortcut(
          preferences: UserDefaults(suiteName: shell.composition.namespace.preferences)!
        ) { [weak shell] in
          shell?.startOrReveal(from: .keyboard)
        }
        self.shortcut = shortcut
      }
      shortcut?.register()
      observations.append(
        shell.objectWillChange.sink { [weak self] in
          Task { @MainActor in self?.updatePresentation() }
        }
      )
    }
    updatePresentation()
    let reason = DesktopLaunchReason.resolve(
      arguments: ProcessInfo.processInfo.arguments,
      appleEvent: NSAppleEventManager.shared().currentAppleEvent,
      isDefaultLaunch: notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool
    )
    if let shell { shell.launch(reason) } else if reason == .explicit { showLibrary() }
  }

  public func applicationDidBecomeActive(_ notification: Notification) { login?.refresh() }

  public func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    showLibrary()
    return false
  }

  public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let shell else { return .terminateNow }
    let result = shell.requestQuit(
      confirmFinish: { [weak self] in self?.confirmFinishAndQuit() ?? false },
      reply: { [weak self, weak sender] safe in
        if safe { self?.shortcut?.unregister() }
        sender?.reply(toApplicationShouldTerminate: safe)
      }
    )
    switch result {
    case .now: return .terminateNow
    case .later: return .terminateLater
    case .cancel: return .terminateCancel
    }
  }

  public func applicationWillTerminate(_ notification: Notification) {
    notificationTask?.cancel()
    shortcut?.unregister()
  }

  private func confirmFinishAndQuit() -> Bool {
    let alert = NSAlert()
    alert.messageText = "Finish recording and quit \(appName)?"
    alert.informativeText = "Trigo will stay open until the recording has finished safely."
    alert.addButton(withTitle: "Finish and quit")
    alert.addButton(withTitle: "Keep Trigo open")
    alert.buttons[0].setAccessibilityIdentifier("quit-finish-and-quit")
    alert.buttons[1].setAccessibilityIdentifier("quit-keep-open")
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertFirstButtonReturn
  }

  @objc private func showLibrary() { reader.willOpen(); libraryLifecycle.open() }

  private func createLibrary() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = appName
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unifiedCompact
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.contentMinSize = NSSize(width: 800, height: 590)
    window.collectionBehavior.insert(.fullScreenPrimary)
    window.setAccessibilityIdentifier("library-window")
    if let shell, startupFailure == nil {
      libraryToolbar = reader.configureWindow(window, shell)
      window.contentView = NSHostingView(
        rootView: reader.makeContent(shell)
          .defaultAppStorage(UserDefaults(suiteName: shell.composition.namespace.preferences)!)
          .accessibilityIdentifier("library-host")
      )
    } else {
      window.contentView = NSHostingView(rootView: startupView)
    }
    window.contentView?.setAccessibilityLabel("Call archive")
    window.delegate = self
    restoreFrame(window, name: "library")
    libraryWindow = window
  }

  @objc private func showSettings() {
    guard let shell, let login, startupFailure == nil else { showLibrary(); return }
    if settingsWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 620, height: 660),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
      )
      window.title = "\(appName) Settings"
      window.isReleasedWhenClosed = false
      window.isRestorable = false
      window.contentMinSize = NSSize(width: 580, height: 520)
      window.contentView = NSHostingView(
        rootView: DesktopSettingsView(shell: shell, login: login, shortcut: shortcut)
          .defaultAppStorage(UserDefaults(suiteName: shell.composition.namespace.preferences)!)
      )
      window.setAccessibilityIdentifier("settings-window")
      restoreFrame(window, name: "settings")
      settingsWindow = window
    }
    login.refresh()
    settingsWindow?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func restoreFrame(_ window: NSWindow, name: String) {
    let identity = shell?.composition.namespace.preferences ?? "invalid"
    let key = "\(identity).\(name)"
    window.setFrameAutosaveName(key)
    if !window.setFrameUsingName(key) { window.center() }
  }

  private var startupView: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(startupFailure?.title ?? "Cannot start Trigo").font(.title2.weight(.semibold))
      Text(startupFailure?.message ?? "Reopen the intended app variant.").textSelection(.enabled)
      Button("Quit This Copy") { NSApp.terminate(nil) }.accessibilityIdentifier("startup-quit")
    }
    .padding(32).frame(maxWidth: 580, alignment: .leading)
    .accessibilityIdentifier("startup-failure")
  }

  public func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    if window === libraryWindow {
      reader.didClose()
      libraryToolbar = nil
      libraryWindow = nil
      libraryLifecycle.closed()
    } else if window === recordingPanel {
      shell?.hideRecording()
    }
  }

  private func updatePresentation() {
    let state = shell?.recording
    if let button = statusItem?.button {
      let title = startupFailure?.title ?? state?.statusTitle ?? "Cannot start Trigo"
      let needsAttention =
        startupFailure != nil || state?.phase == .recoveryRequired
        || state?.phase == .error || state?.phase == .interrupted
      let symbol =
        state?.phase == .recording
        ? "record.circle.fill"
        : needsAttention
          ? "exclamationmark.circle"
          : state?.phase == .starting || state?.phase == .stopping ? "ellipsis.circle" : "waveform"
      button.image = NSImage(
        systemSymbolName: symbol,
        accessibilityDescription: "\(appName): \(title)"
      )
      button.contentTintColor =
        state?.phase == .recording ? .systemRed : needsAttention ? .systemOrange : nil
      button.toolTip = "\(appName) — \(title)"
      button.setAccessibilityLabel("\(appName): \(title)")
    }
    if !menuIsTracking { rebuildStatusMenu() }
    if shell?.recordingVisible == true {
      showRecordingPanel()
    } else {
      recordingPanel?.orderOut(nil)
    }
    updateRecordingNotification()
  }

  private func showRecordingPanel() {
    guard let shell, startupFailure == nil else { return }
    if recordingPanel == nil {
      let panel = makeStatusPanel(size: NSSize(width: 192, height: 44))
      panel.title = "\(appName) Recording"
      panel.isMovableByWindowBackground = true
      panel.contentView = RecordingHostingView(rootView: RecordingPanel(shell: shell))
      panel.setAccessibilityIdentifier("recording-window")
      panel.delegate = self
      restoreFrame(panel, name: "recording")
      // A frame saved by the earlier, larger panel cannot change the accepted strip.
      panel.setContentSize(NSSize(width: 192, height: 44))
      recordingPanel = panel
    }
    clampRecordingWindows()
    if recordingPanel?.isVisible != true || recordingRevealSequence != shell.recordingRevealSequence
    {
      recordingPanel?.orderFrontRegardless()
      recordingRevealSequence = shell.recordingRevealSequence
    }
  }

  private func makeStatusPanel(size: NSSize) -> RecordingStatusPanel {
    let panel = RecordingStatusPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isRestorable = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    // This always-available surface is a floating utility window, not a modal dialog.
    panel.setAccessibilitySubrole(.floatingWindow)
    return panel
  }

  private func clampRecordingWindows() {
    let screens = NSScreen.screens.map(\.visibleFrame)
    for panel in [recordingPanel, notificationPanel].compactMap({ $0 }) {
      let frame = RecordingPanelPlacement.clamp(panel.frame, to: screens)
      if frame != panel.frame { panel.setFrame(frame, display: true) }
    }
  }

  private func updateRecordingNotification() {
    guard let shell, let notification = shell.recordingNotification else {
      notificationPanel?.orderOut(nil)
      notificationTask?.cancel()
      notificationTask = nil
      notificationID = nil
      return
    }
    guard notification.id != notificationID else { return }
    notificationTask?.cancel()
    notificationID = notification.id
    let panel = notificationPanel ?? makeStatusPanel(size: NSSize(width: 310, height: 90))
    let content = RecordingHostingView(
      rootView: RecordingNotificationView(notification: notification) { [weak shell] in
        shell?.dismissRecordingNotification(notification.id)
      }
    )
    panel.contentView = content
    panel.setContentSize(NSSize(width: 310, height: max(68, content.fittingSize.height)))
    panel.setAccessibilityIdentifier("recording-notification")
    panel.title = notification.notice.title
    if let anchor = recordingPanel?.frame {
      panel.setFrameOrigin(NSPoint(x: anchor.midX - panel.frame.width / 2, y: anchor.maxY + 8))
    } else {
      panel.center()
    }
    notificationPanel = panel
    clampRecordingWindows()
    panel.orderFrontRegardless()
    NSAccessibility.post(
      element: NSApp!,
      notification: .announcementRequested,
      userInfo: [
        .announcement: "\(notification.notice.title). \(notification.notice.message)",
        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
      ]
    )
    notificationTask = Task { [weak shell] in
      try? await Task.sleep(for: .seconds(notification.isSaved ? 5 : 8))
      guard !Task.isCancelled else { return }
      shell?.dismissRecordingNotification(notification.id)
    }
  }

  public func menuWillOpen(_ menu: NSMenu) {
    guard menu === statusMenu else { return }
    shell?.menuWillOpen()
    rebuildStatusMenu()
    menuIsTracking = true
  }

  public func menuDidClose(_ menu: NSMenu) {
    guard menu === statusMenu else { return }
    menuIsTracking = false
    // Keep the source snapshot through the selected menu action's delivery.
    Task { @MainActor [weak self] in self?.updatePresentation() }
  }

  private func rebuildStatusMenu() {
    statusMenu.removeAllItems()
    let heading = NSMenuItem(
      title: startupFailure?.title ?? shell?.recording.statusTitle ?? "Cannot start Trigo",
      action: nil,
      keyEquivalent: ""
    )
    heading.isEnabled = false
    heading.setAccessibilityIdentifier("menu-recording-status")
    statusMenu.addItem(heading)
    if let shell, startupFailure == nil {
      let state = shell.recording
      if let source = state.source, state.phase != .idle && state.phase != .setupRequired {
        let item = NSMenuItem(title: source.applicationName, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.toolTip = state.sourceDescription
        item.setAccessibilityIdentifier("menu-recording-source")
        statusMenu.addItem(item)
      }
      if state.phase == .recording && state.microphoneState == .unavailable {
        let item = NSMenuItem(
          title: "Microphone unavailable; application audio continues",
          action: nil,
          keyEquivalent: ""
        )
        item.isEnabled = false
        item.toolTip = state.microphoneUnavailableReason
        item.setAccessibilityIdentifier("menu-microphone-unavailable")
        statusMenu.addItem(item)
      }
      if ![.starting, .recording, .stopping].contains(state.phase) {
        let start = item("Start Recording", #selector(startFromMenu), id: "menu-start-recording")
        start.isEnabled = state.canStart && !shell.isQuitting && state.permissions.ready
        statusMenu.addItem(start)
      }
      if state.phase != .idle && state.phase != .setupRequired {
        statusMenu.addItem(
          item("Show Recording Controls", #selector(showRecording), id: "menu-show-recording")
        )
      }
      if state.canStop {
        statusMenu.addItem(
          item(
            state.phase == .starting ? "Cancel Start" : "Finish Recording",
            #selector(finish),
            id: "menu-finish-recording"
          )
        )
      }
      if state.phase == .recording {
        let microphone = item(
          state.microphoneEnabled ? "Mute Microphone Recording" : "Unmute Microphone Recording",
          #selector(toggleMicrophone),
          id: "menu-microphone"
        )
        microphone.isEnabled = !state.microphoneChanging && state.microphoneState != .unavailable
        statusMenu.addItem(microphone)
      }
      if state.canRetryRecovery {
        statusMenu.addItem(
          item(state.recoveryActionTitle, #selector(retryRecovery), id: "menu-retry-recovery")
        )
      }
    }
    statusMenu.addItem(.separator())
    statusMenu.addItem(item("Open Library", #selector(showLibrary), id: "menu-open-library"))
    statusMenu.addItem(item("Settings…", #selector(showSettings), id: "menu-settings"))
    statusMenu.addItem(.separator())
    statusMenu.addItem(item("Quit \(appName)", #selector(quit), id: "menu-quit"))
  }

  private func item(
    _ title: String,
    _ action: Selector,
    key: String = "",
    id: String? = nil
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = self
    if let id { item.setAccessibilityIdentifier(id) }
    return item
  }

  @objc private func startFromMenu() { shell?.startOrReveal(from: .menu) }
  @objc private func showRecording() { shell?.showRecording() }
  @objc private func finish() { Task { await shell?.finish() } }
  @objc private func toggleMicrophone() { Task { await shell?.toggleMicrophone() } }
  @objc private func retryRecovery() { Task { await shell?.retryRecovery() } }
  @objc private func quit() { NSApp.terminate(nil) }

  private func installApplicationMenu() {
    let main = NSMenu()
    let application = NSMenuItem()
    application.submenu = NSMenu(title: appName)
    application.submenu?.addItem(item("Settings…", #selector(showSettings), key: ","))
    application.submenu?.addItem(.separator())
    application.submenu?.addItem(item("Quit \(appName)", #selector(quit), key: "q"))
    main.addItem(application)
    let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    file.submenu = NSMenu(title: "File")
    file.submenu?.addItem(item("Open Library", #selector(showLibrary), key: "l"))
    file.submenu?
      .addItem(
        NSMenuItem(
          title: "Close Window",
          action: #selector(NSWindow.performClose(_:)),
          keyEquivalent: "w"
        )
      )
    main.addItem(file)
    let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    edit.submenu = NSMenu(title: "Edit")
    for (title, action, key) in [
      ("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"),
      ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"),
      ("Select All", #selector(NSText.selectAll(_:)), "a"),
    ] { edit.submenu?.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key)) }
    main.addItem(edit)
    let window = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    window.submenu = NSMenu(title: "Window")
    window.submenu?
      .addItem(
        NSMenuItem(
          title: "Minimize",
          action: #selector(NSWindow.miniaturize(_:)),
          keyEquivalent: "m"
        )
      )
    let fullscreen = NSMenuItem(
      title: "Enter Full Screen",
      action: #selector(NSWindow.toggleFullScreen(_:)),
      keyEquivalent: "f"
    )
    fullscreen.keyEquivalentModifierMask = [.control, .command]
    window.submenu?.addItem(fullscreen)
    main.addItem(window)
    NSApp.mainMenu = main
    NSApp.windowsMenu = window.submenu
  }
}
