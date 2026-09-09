import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

struct DailyUseAcceptanceTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TRIGO_DAILY_USE_INVOCATION"] != nil))
  @MainActor func executesOnlyTheExplicitPreparedAcceptanceInvocation() async throws {
    let file = try requiredDailyUse(
      ProcessInfo.processInfo.environment["TRIGO_DAILY_USE_INVOCATION"],
      "Use the explicit daily-use acceptance command."
    )
    let invocation = try JSONDecoder()
      .decode(
        DailyUseInvocation.self,
        from: Data(contentsOf: URL(fileURLWithPath: file))
      )
    try invocation.validate()
    let lease = try ExclusiveFileLease(file: invocation.folder.appending(path: ".execution.lock"))
    defer { withExtendedLifetime(lease) {} }
    let context = try await DailyUseAcceptanceContext.make(invocation)
    if invocation.action == "prepare" {
      try await context.prepare()
    } else {
      try await context.run()
    }
  }
}

@MainActor struct DailyUseAcceptanceContext {
  let invocation: DailyUseInvocation
  let template: DailyUseTemplate
  let apiURL: URL
  let archiveID: String
  let token: String
  let statusClient: HTTPSStatusClient
  let connection: ServerConnection

  static func make(_ invocation: DailyUseInvocation) async throws -> Self {
    let template = try DailyUseTemplate(folder: invocation.folder)
    let policy: ServerTransportPolicy
    let apiURL: URL
    let token: String
    if invocation.local {
      let worktree = String(Contract.hash(Data(invocation.root.utf8)).prefix(12))
      let local = try LocalDevelopmentConfiguration.load(
        url: URL(fileURLWithPath: invocation.configuration),
        worktree: worktree,
        variant: .dev
      )
      policy = .localDevelopment(local)
      apiURL = local.serverURL
      token = local.ownerToken
    } else {
      policy = .httpsOnly
      apiURL = try requiredDailyUse(
        invocation.apiURL.flatMap(URL.init(string:)),
        "The Dev URL is invalid."
      )
      token = try requiredDailyUse(
        ProcessInfo.processInfo.environment["TRIGO_ASR_OPERATOR_TOKEN"],
        "The operator token is missing."
      )
    }
    let statusClient = HTTPSStatusClient(timeout: 15, transportPolicy: policy)
    let status = try await statusClient.fetch(serverURL: apiURL, token: token)
    try requireDailyUse(status.stage == .dev, "The server does not identify as Dev.")
    if invocation.action == "run" {
      try requireDailyUse(
        status.readiness.transcription == (invocation.local ? .notVerified : .ready)
          && status.readiness.callOperations == .ready,
        "The server is not ready for the integrated call path."
      )
    }
    let connection = ServerConnection(
      expectedStage: .dev,
      metadataStore: FileConnectionMetadataStore(
        url: invocation.folder.appending(path: "connection.json"),
        transportPolicy: policy
      ),
      credentialStore: DailyUseCredentials(),
      statusClient: statusClient,
      transportPolicy: policy
    )
    let paired = await connection.connect(serverURL: apiURL.absoluteString, token: token)
    try requireDailyUse(
      paired.binding?.archiveId == status.archiveId && paired.binding?.serverURL == apiURL,
      "The native connection did not bind to the admitted Dev archive."
    )
    return .init(
      invocation: invocation,
      template: template,
      apiURL: apiURL,
      archiveID: status.archiveId,
      token: token,
      statusClient: statusClient,
      connection: connection
    )
  }

  func loadPlan() throws -> (DailyUsePlan, Data) {
    let file = invocation.folder.appending(path: "plan.json")
    try requireDailyUse(
      (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16_384
        && file.resolvingSymlinksInPath() == file,
      "The prepared plan is missing, too large or not isolated."
    )
    let bytes = try Data(contentsOf: file)
    if invocation.action == "run" {
      try requireDailyUse(
        Contract.hash(bytes) == invocation.planSHA256,
        "The admitted plan changed."
      )
    }
    let plan = try JSONDecoder().decode(DailyUsePlan.self, from: bytes)
    try plan.validate(
      invocation: invocation,
      apiURL: apiURL,
      archiveID: archiveID,
      template: template
    )
    return (plan, bytes)
  }

  func prepare() async throws {
    let planFile = invocation.folder.appending(path: "plan.json")
    if FileManager.default.fileExists(atPath: planFile.path) {
      let (plan, bytes) = try loadPlan()
      try writeResult(
        plan: plan,
        planBytes: bytes,
        fields: ["prepared": true, "recoveredPlan": true]
      )
      return
    }
    try requireDailyUse(
      !FileManager.default.fileExists(atPath: invocation.archive.path),
      "An incomplete local preparation is retained; it cannot be overwritten."
    )
    let session = try CaptureArchiveSession.allocate(
      root: invocation.archive,
      archiveID: archiveID,
      source: .init(
        applicationName: "Trigo synthetic first-use (\(invocation.profile))",
        bundleID: "test.trigo.daily-use-acceptance",
        processID: 24,
        windowID: 24,
        windowTitle: nil,
        processLaunchDate: Date()
      ),
      microphone: .init(id: "synthetic-native-template", name: "Synthetic Samantha source"),
      startedAt: Date().addingTimeInterval(-Double(invocation.durationMs) / 1000)
    )
    try await session.prepare()
    let repository = try LocalRepository(root: invocation.archive, archiveID: archiveID)
    let writer = try RecoverableMediaMaster(
      directory: session.mediaDirectory,
      identity: session.mediaMasterIdentity
    )
    for second in 0..<(invocation.durationMs / 1000) {
      try repository.commitMediaProgress(
        writer.append(
          interleaved: template.samples(second: second, durationMs: invocation.durationMs),
          microphoneIntervals: [
            .init(startMs: second * 1000, endMs: (second + 1) * 1000, state: .recorded)
          ],
          applicationIntervals: [
            .init(startMs: second * 1000, endMs: (second + 1) * 1000, state: .recorded)
          ]
        )
      )
      if (second + 1) % 600 == 0 {
        print(
          "Prepared \(second + 1)/\(invocation.durationMs / 1000) seconds of synthetic native media."
        )
      }
    }
    let master = try writer.finish()
    let upload = try await repository.ensureMasterUpload(session)
    let registration = try await repository.masterUploadRegistration(callID: session.callID)
    let plan = DailyUsePlan(
      schemaVersion: 1,
      kind: "synthetic-native-daily-use-v1",
      profile: invocation.profile,
      source: invocation.source,
      configurationSHA256: invocation.configurationSHA256,
      apiURL: apiURL.absoluteString,
      archiveID: archiveID,
      callID: session.callID,
      masterID: session.masterID,
      microphoneTrackID: session.microphoneTrackID,
      applicationTrackID: session.applicationTrackID,
      manifestID: session.audioManifestID,
      uploadID: upload.uploadID,
      finalizeOperationID: upload.finalizeOperationID,
      transcriptionOperationID: synchronizationIdentity(
        "trigo-initial-transcription:\(archiveID):\(session.callID)"
      ),
      revisionID: synchronizationIdentity("trigo-initial-revision:\(archiveID):\(session.callID)"),
      durationMs: invocation.durationMs,
      byteLength: Int(master.cursor.stableBytes),
      templateSHA256: template.sha256,
      templateMetadataSHA256: template.metadataSHA256,
      masterSHA256: master.sha256,
      sourceStatesSHA256: Contract.hash(Data(repeating: 0, count: invocation.durationMs / 2)),
      registrationSHA256: Contract.hash(try Contract.encode(registration)),
      maximumProviderSubmissions: invocation.providerSubmissions,
      preparedAt: dailyUseTimestamp()
    )
    try plan.validate(
      invocation: invocation,
      apiURL: apiURL,
      archiveID: archiveID,
      template: template
    )
    try requireDailyUse(
      try repository.captureCompletion(callID: session.callID) == nil
        && repository.verifiedMasterReceipt(callID: session.callID) == nil
        && repository.masterUploadParts(callID: session.callID).isEmpty,
      "Preparation unexpectedly changed remote-upload or stopped-call state."
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let bytes = try encoder.encode(plan)
    try writeDailyUseBytes(bytes, to: planFile)
    try writeResult(plan: plan, planBytes: bytes, fields: ["prepared": true])
  }

  func run() async throws {
    let (plan, planBytes) = try loadPlan()
    let repository = try LocalRepository(root: invocation.archive, archiveID: archiveID)
    let session = try requiredDailyUse(
      try await repository.captureSession(callID: plan.callID),
      "The prepared native session is missing."
    )
    try requireDailyUse(
      session.masterID == plan.masterID && session.archiveID == plan.archiveID
        && session.microphoneTrackID == plan.microphoneTrackID
        && session.applicationTrackID == plan.applicationTrackID
        && session.audioManifestID == plan.manifestID
        && session.source.bundleID == "test.trigo.daily-use-acceptance",
      "The native session is outside the admitted synthetic call."
    )
    let completed = invocation.folder.appending(path: "completed.json")
    if FileManager.default.fileExists(atPath: completed.path) {
      let result = try requiredDailyUse(
        try JSONSerialization.jsonObject(with: Data(contentsOf: completed)) as? [String: Any],
        "The retained completion receipt is invalid."
      )
      let saved = try await repository.isCallSavedOnMacAndServer(callID: plan.callID)
      try requireDailyUse(
        result["planSHA256"] as? String == Contract.hash(planBytes)
          && result["passed"] as? Bool == true
          && saved,
        "The completed plan no longer has its verified retained local state."
      )
      try writeResult(
        plan: plan,
        planBytes: planBytes,
        fields: ["recoveredExistingAcceptance": true, "originalReceipt": completed.path]
      )
      return
    }
    let runFolder = invocation.folder.appending(
      path: "run-\(invocation.invocationId)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
      at: runFolder,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let journal = try DailyUseJournal(file: runFolder.appending(path: "stages.jsonl"))
    try await journal.record(.init(event: "run_admitted"))
    let uploads = MasterUploadCoordinator(
      repository: repository,
      transport: DailyUseAdmittedUpload(
        underlying: .init(connection: connection, archiveID: archiveID),
        plan: plan,
        journal: journal
      )
    )
    let wasStopped = try repository.captureCompletion(callID: plan.callID) != nil
    let priorParts = try repository.masterUploadParts(callID: plan.callID)
    let freshMeasurement = !wasStopped && priorParts.isEmpty
    var roundTrips: [Double] = []
    for _ in 0..<5 {
      let began = ProcessInfo.processInfo.systemUptime
      let status = try await statusClient.fetch(serverURL: apiURL, token: token)
      try requireDailyUse(
        status.archiveId == archiveID && status.stage == .dev,
        "Dev binding changed."
      )
      roundTrips.append((ProcessInfo.processInfo.systemUptime - began) * 1000)
    }
    var uploadMbps = 0.0
    var finishRequestedAt: Double?
    if try repository.verifiedMasterReceipt(callID: plan.callID) == nil {
      let writer = try RecoverableMediaMaster(
        reopening: session.mediaDirectory,
        expectedIdentity: session.mediaMasterIdentity,
        confirmed: repository.confirmedMediaCursor(callID: plan.callID)
      )
      let master = try writer.finish()
      try requireDailyUse(
        master.sha256 == plan.masterSHA256 && master.cursor.stableBytes == plan.byteLength
          && master.durationMs == plan.durationMs,
        "The full durable native master differs from the prepared media."
      )
      let uploadStart = ProcessInfo.processInfo.systemUptime
      if !wasStopped {
        let fullParts = plan.byteLength / MediaMasterProfile.maximumRequestBytes
        for _ in 0...(fullParts / 4 + 1) {
          let acknowledged = try repository.masterUploadParts(callID: plan.callID)
            .filter { $0.receipt != nil }.count
          if acknowledged == fullParts { break }
          let report = try await uploads.runPass(retryAfterCorrection: false)
          try requireDailyUse(
            report.failures[plan.callID] == nil && report.uploadedParts > 0,
            "Pre-Finish upload failed or stopped progressing; the same plan is retained."
          )
        }
        let acknowledged = try repository.masterUploadParts(callID: plan.callID)
          .filter { $0.receipt != nil }
        try requireDailyUse(
          acknowledged.count == fullParts,
          "Pre-Finish full parts are incomplete."
        )
        let sent =
          acknowledged.reduce(0) { $0 + $1.descriptor.byteLength }
          - priorParts.filter { $0.receipt != nil }.reduce(0) { $0 + $1.descriptor.byteLength }
        uploadMbps =
          Double(sent * 8) / (ProcessInfo.processInfo.systemUptime - uploadStart) / 1_000_000
        try await journal.record(
          .init(event: "full_parts_uploaded_while_capture_active", byteLength: sent)
        )
        finishRequestedAt = ProcessInfo.processInfo.systemUptime
        try await journal.record(.init(event: "finish_requested"))
        _ = try await session.complete(media: master, interruptionReason: nil)
      }
    }
    let afterFinishStart = finishRequestedAt ?? ProcessInfo.processInfo.systemUptime
    for _ in 0..<3 {
      if try repository.verifiedMasterReceipt(callID: plan.callID) != nil { break }
      let report = try await uploads.runPass(retryAfterCorrection: false)
      try requireDailyUse(
        report.failures[plan.callID] == nil,
        "Final upload/finalization needs recovery; the same plan is retained."
      )
    }
    // A previous invocation can have committed its receipt before completing local cleanup.
    _ = try await uploads.runPass(retryAfterCorrection: false)
    let receipt = try requiredDailyUse(
      try repository.verifiedMasterReceipt(callID: plan.callID),
      "The verified storage receipt is missing."
    )
    try requireDailyUse(
      receipt.value.masterSHA256 == plan.masterSHA256 && receipt.value.byteLength == plan.byteLength
        && receipt.value.durationMs == plan.durationMs
        && receipt.value.sourceStatesSHA256 == plan.sourceStatesSHA256
        && !FileManager.default.fileExists(
          atPath: session.mediaDirectory.appending(path: "master.caf").path
        ),
      "Verified storage or normal local cleanup is incomplete."
    )
    try writeDailyUseBytes(
      receipt.storedBytes,
      to: runFolder.appending(path: "master-receipt.json")
    )
    let storedAt = ProcessInfo.processInfo.systemUptime
    try await journal.record(.init(event: "verified_local_cleanup_complete"))
    let transport = DailyUseAdmittedSync(
      underlying: .init(connection: connection, archiveID: archiveID),
      plan: plan,
      journal: journal
    )
    let synchronization = CanonicalSyncCoordinator(
      repository: repository,
      transport: transport,
      language: { "en" }
    )
    let deadline = ProcessInfo.processInfo.systemUptime + 900
    while !(try await repository.isCallSavedOnMacAndServer(callID: plan.callID)) {
      let report = try await synchronization.runPass(retryAfterCorrection: false)
      try requireDailyUse(report.catalogFailure == nil, "The canonical catalog is unavailable.")
      if let failure = report.failures[plan.callID], failure.retry != .retryable {
        throw DailyUseAcceptanceFailure(
          description: "The admitted call needs correction: \(failure.code)."
        )
      }
      if try await repository.isCallSavedOnMacAndServer(callID: plan.callID) { break }
      try requireDailyUse(
        ProcessInfo.processInfo.systemUptime < deadline,
        "The admitted call did not reach Ready within 15 minutes. Its IDs and evidence are retained."
      )
      try await Task.sleep(for: .seconds(2))
    }
    let readyAt = ProcessInfo.processInfo.systemUptime
    try await journal.record(.init(event: "ready_saved_on_mac_and_server"))
    let operation = try requiredDailyUse(
      try repository.automaticTranscription(callID: plan.callID)?.operation,
      "The initial automatic operation is missing."
    )
    let proof = try await verifyDailyUseResult(
      context: self,
      plan: plan,
      repository: repository,
      transport: transport,
      synchronization: synchronization,
      runFolder: runFolder,
      operation: operation
    )
    let readyMilliseconds = (readyAt - afterFinishStart) * 1000
    let conditions =
      freshMeasurement && uploadMbps >= 10
      && roundTrips.allSatisfy { $0 <= 100 } && operation.attemptCount == 1
    let latencyPassed = conditions && readyMilliseconds <= 300_000
    let passed = invocation.profile != "one-hour" || latencyPassed
    let fields: [String: Any] = [
      "hostedAcceptancePassed": !invocation.local && passed,
      "localRehearsalPassed": invocation.local,
      "evidenceDirectory": runFolder.path,
      "sourceKind": "accelerated-native-synthetic-media",
      "freshLatencyMeasurement": freshMeasurement,
      "preFinishUploadMbps": uploadMbps,
      "warmStatusRoundTripsMs": roundTrips,
      "finishToStoredMs": (storedAt - afterFinishStart) * 1000,
      "finishToReadyMs": readyMilliseconds,
      "latencyConditionsSatisfied": conditions,
      "qualifiedOneHourLatencyPassed": latencyPassed,
      "operationId": operation.operationId,
      "attemptCount": operation.attemptCount,
      "proof": proof,
    ]
    try writeResult(plan: plan, planBytes: planBytes, fields: fields, passed: passed)
    if passed {
      try writeDailyUseBytes(
        Data(contentsOf: URL(fileURLWithPath: invocation.resultPath)),
        to: completed
      )
    }
    try requireDailyUse(
      passed,
      "The hosted path completed, but the qualified one-hour latency gate did not pass. Read the retained measurements."
    )
  }

  func writeResult(
    plan: DailyUsePlan,
    planBytes: Data,
    fields: [String: Any],
    passed: Bool = true
  ) throws {
    var result: [String: Any] = [
      "schemaVersion": 1, "invocationId": invocation.invocationId,
      "action": invocation.action, "profile": invocation.profile, "passed": passed,
      "callId": plan.callID, "planSHA256": Contract.hash(planBytes), "durationMs": plan.durationMs,
      "maximumProviderSubmissions": plan.maximumProviderSubmissions,
      "sourceRevision": invocation.source.revision, "recordedAt": dailyUseTimestamp(),
    ]
    result.merge(fields) { _, new in new }
    try writeDailyUseJSON(result, to: URL(fileURLWithPath: invocation.resultPath))
  }
}
