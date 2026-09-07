import Foundation
import TrigoContracts

@testable import TrigoNative

func captureWriter(
  root: URL,
  io: MediaMasterIO = MediaMasterIO()
) async throws
  -> CaptureMediaWriter
{
  let session = try await CaptureArchiveSession.begin(
    root: root,
    archiveID: UUID().uuidString.lowercased(),
    source: .init(
      applicationName: "Fixture",
      bundleID: "test.capture",
      processID: 123,
      windowID: 456,
      windowTitle: nil,
      processLaunchDate: Date()
    ),
    microphone: .init(id: "fixture", name: "Controlled microphone")
  )
  return try CaptureMediaWriter(session: session, io: io)
}

func finishCapture(
  _ writer: CaptureMediaWriter,
  reason: String? = nil
) throws
  -> FinalizedMediaMaster
{
  try writer.requestStop(reason: reason)
  return try writer.finish()
}

func captureIntervals(
  _ writer: CaptureMediaWriter,
  role: MediaSourceRole
) throws
  -> [CaptureInterval]
{
  let repository = try LocalRepository(
    root: writer.session.root,
    archiveID: writer.session.archiveID
  )
  return
    try
    repository.captureIntervals(
      callID: writer.session.callID,
      through: writer.master.cursor
    )[role == .microphone ? 0 : 1]
}
