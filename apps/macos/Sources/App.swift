import SwiftUI
import TrigoNative

@main struct TrigoApp: App {
  private let variant: AppVariant
  private let namespace: AppNamespace
  @StateObject private var connectionModel: ConnectionViewModel

  init() {
    let variant: AppVariant =
      Bundle.main.bundleIdentifier == AppVariant.dev.bundleIdentifier ? .dev : .personal
    let namespace = try! AppNamespace.installed()
    self.variant = variant
    self.namespace = namespace
    _connectionModel = StateObject(
      wrappedValue: ConnectionViewModel(
        connection: ServerConnection.live(namespace: namespace, variant: variant)))
  }

  var body: some Scene {
    WindowGroup {
      ConnectionView(appName: variant.appName, model: connectionModel)
        .defaultAppStorage(UserDefaults(suiteName: namespace.preferences)!)
    }
  }
}

@MainActor
private final class ConnectionViewModel: ObservableObject {
  @Published var serverURL = ""
  @Published var token = ""
  @Published private(set) var snapshot = ConnectionSnapshot(
    binding: nil, health: .setupRequired, lastAttemptIssue: nil)
  @Published private(set) var isConnecting = false
  private let connection: ServerConnection
  private var didRestore = false

  init(connection: ServerConnection) { self.connection = connection }

  func restore() async {
    guard !didRestore else { return }
    didRestore = true
    isConnecting = true
    snapshot = await connection.restore()
    if let savedURL = snapshot.binding?.serverURL.absoluteString { serverURL = savedURL }
    isConnecting = false
  }

  func connect() async {
    guard !isConnecting else { return }
    isConnecting = true
    let candidateToken = token
    token = ""
    snapshot = await connection.connect(serverURL: serverURL, token: candidateToken)
    isConnecting = false
  }
}

private struct ConnectionView: View {
  let appName: String
  @ObservedObject var model: ConnectionViewModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 6) {
          Text(appName).font(.largeTitle.bold())
          Text("Your personal call archive").font(.title3).foregroundStyle(.secondary)
        }

        GroupBox("Archive connection") {
          VStack(alignment: .leading, spacing: 14) {
            TextField("https://your-trigo-server.example", text: $model.serverURL)
              .textFieldStyle(.roundedBorder)
              .accessibilityLabel("Server URL")
              .accessibilityIdentifier("server-url")
            SecureField("Owner token", text: $model.token)
              .textFieldStyle(.roundedBorder)
              .accessibilityLabel("Owner token")
              .accessibilityIdentifier("owner-token")
            HStack {
              Button(model.snapshot.binding == nil ? "Connect" : "Validate and save") {
                Task { await model.connect() }
              }
              .keyboardShortcut(.defaultAction)
              .disabled(model.isConnecting || model.serverURL.isEmpty || model.token.isEmpty)
              .accessibilityIdentifier("connect-button")
              if model.isConnecting { ProgressView().controlSize(.small) }
            }
          }
          .padding(.top, 8)
        }

        connectionStatus
        recordingStatus
      }
      .padding(32)
      .frame(maxWidth: 680, alignment: .leading)
    }
    .frame(minWidth: 560, minHeight: 540)
    .task { await model.restore() }
  }

  @ViewBuilder private var connectionStatus: some View {
    GroupBox("Connection status") {
      VStack(alignment: .leading, spacing: 10) {
        switch model.snapshot.health {
        case .setupRequired:
          statusLine(symbol: "link.badge.plus", title: "Setup required", color: .orange)
          Text("Connect once to establish this Mac's archive identity.")
            .foregroundStyle(.secondary)
        case .checking:
          statusLine(symbol: "arrow.triangle.2.circlepath", title: "Checking server", color: .blue)
        case .connected(let status):
          statusLine(symbol: "checkmark.circle.fill", title: "Authenticated", color: .green)
          archiveDetails(status: status)
        case .blocked(let issue):
          statusLine(symbol: "exclamationmark.triangle.fill", title: issue.title, color: .orange)
          Text(issue.recoverySuggestion).foregroundStyle(.secondary)
          boundArchiveDetails
        case .recoveryRequired(let issue):
          statusLine(symbol: "exclamationmark.octagon.fill", title: issue.title, color: .red)
          Text(issue.recoverySuggestion).foregroundStyle(.secondary)
        }

        if let issue = model.snapshot.lastAttemptIssue {
          Divider()
          Label("New settings were not saved", systemImage: "arrow.uturn.backward.circle")
            .font(.headline)
          Text(issue.title + ". " + issue.recoverySuggestion).foregroundStyle(.secondary)
        }
      }
      .padding(.top, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("connection-status")
    }
  }

  @ViewBuilder private var recordingStatus: some View {
    GroupBox("Local recording") {
      switch model.snapshot.recordingEligibility {
      case .requiresSetup:
        Label("Connect before the first recording", systemImage: "record.circle")
          .foregroundStyle(.secondary)
      case .eligible:
        VStack(alignment: .leading, spacing: 6) {
          Label("Archive binding ready", systemImage: "checkmark.shield.fill")
            .foregroundStyle(.green)
          Text("Local recording stays eligible if the server or token later becomes unavailable.")
            .foregroundStyle(.secondary)
        }
      case .unavailableUntilRecovery:
        Label("Recover connection metadata before recording", systemImage: "wrench.and.screwdriver")
          .foregroundStyle(.red)
      }
    }
  }

  private func statusLine(symbol: String, title: String, color: Color) -> some View {
    Label(title, systemImage: symbol).font(.headline).foregroundStyle(color)
  }

  @ViewBuilder private func archiveDetails(status: ServerStatus) -> some View {
    boundArchiveDetails
    if status.readiness.callOperations == .unavailable {
      Label("Call operations are not available on this server yet.", systemImage: "icloud.slash")
        .foregroundStyle(.secondary)
    }
    ForEach(status.errors) { notice in
      Text(notice.message).font(.callout).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var boundArchiveDetails: some View {
    if let binding = model.snapshot.binding {
      LabeledContent("Archive", value: binding.archiveId)
        .fontDesign(.monospaced)
        .textSelection(.enabled)
        .accessibilityIdentifier("archive-id")
      LabeledContent("Server", value: binding.serverURL.absoluteString)
        .textSelection(.enabled)
      LabeledContent("Stage", value: binding.stage.rawValue)
    }
  }
}
