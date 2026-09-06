import SwiftUI
import TrigoNative

struct ConnectionView: View {
  let appName: String
  @ObservedObject var model: RecordingCoordinator
  @State private var serverURL = ""
  @State private var token = ""
  private var snapshot: ConnectionSnapshot { model.connectionSnapshot }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 6) {
          Text(appName).font(.largeTitle.bold())
          Text("Your personal call archive").font(.title3).foregroundStyle(.secondary)
        }

        GroupBox("Archive connection") {
          VStack(alignment: .leading, spacing: 14) {
            TextField("https://your-trigo-server.example", text: $serverURL)
              .textFieldStyle(.roundedBorder)
              .accessibilityLabel("Server URL")
              .accessibilityIdentifier("server-url")
            SecureField("Owner token", text: $token)
              .textFieldStyle(.roundedBorder)
              .accessibilityLabel("Owner token")
              .accessibilityIdentifier("owner-token")
            HStack {
              Button(snapshot.binding == nil ? "Connect" : "Validate and save") {
                let candidateToken = token
                token = ""
                Task { await model.connect(serverURL: serverURL, token: candidateToken) }
              }
              .keyboardShortcut(.defaultAction)
              .disabled(model.isConnecting || serverURL.isEmpty || token.isEmpty)
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
    .onChange(of: snapshot.binding?.serverURL, initial: true) { _, value in
      if let value, serverURL.isEmpty { serverURL = value.absoluteString }
    }
  }

  @ViewBuilder private var connectionStatus: some View {
    GroupBox("Connection status") {
      VStack(alignment: .leading, spacing: 10) {
        switch snapshot.health {
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

        if let issue = snapshot.lastAttemptIssue {
          Divider()
          Label("New settings were not saved", systemImage: "arrow.uturn.backward.circle")
            .font(.headline)
          Text(issue.title + ". " + issue.recoverySuggestion).foregroundStyle(.secondary)
        }
        if snapshot.binding != nil || snapshot.recordingEligibility == .unavailableUntilRecovery {
          Button("Retry saved connection") {
            Task { await model.restore() }
          }
          .disabled(model.isConnecting)
          .accessibilityIdentifier("retry-connection-button")
        }
      }
      .padding(.top, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("connection-status")
    }
  }

  @ViewBuilder private var recordingStatus: some View {
    GroupBox("Local recording") {
      switch snapshot.recordingEligibility {
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
    if let binding = snapshot.binding {
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
