import Carbon
import Foundation

/// Runs in the admitted host GUI session, outside the isolated XCTest runner.
func sourceID(_ source: TISInputSource) throws -> String {
  guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
    throw KeyboardError.unavailable
  }
  return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

func currentSource() throws -> TISInputSource {
  guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
    throw KeyboardError.unavailable
  }
  return source
}

func enabledSource(_ identifier: String) -> TISInputSource? {
  let query = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
  guard let sources = TISCreateInputSourceList(query, false)?.takeRetainedValue() else {
    return nil
  }
  return (sources as! [TISInputSource]).first
}

enum KeyboardError: Error {
  case unavailable, unsupportedArguments, selectionFailed
}

do {
  let arguments = Array(CommandLine.arguments.dropFirst())
  switch arguments.first {
  case "current" where arguments.count == 1:
    print(try sourceID(currentSource()))
  case "fixture" where arguments.count == 1:
    guard
      let source = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
        .compactMap(enabledSource).first
    else {
      fputs("Native UI tests require an already enabled ABC or U.S. keyboard layout.\n", stderr)
      exit(1)
    }
    print(try sourceID(source))
  case "select" where arguments.count == 2:
    guard let source = enabledSource(arguments[1]), TISSelectInputSource(source) == noErr,
      try sourceID(currentSource()) == arguments[1]
    else { throw KeyboardError.selectionFailed }
    print(arguments[1])
  default:
    throw KeyboardError.unsupportedArguments
  }
} catch {
  fputs("Native UI keyboard input source: \(error)\n", stderr)
  exit(1)
}
