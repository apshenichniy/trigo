import AppKit
import Carbon

extension DesktopLaunchReason {
  /// AppKit supplies the launch Apple event with didFinishLaunching. Login/service launches
  /// and an explicit command-line background launch must not create a library window.
  public static func resolve(
    arguments: [String],
    appleEvent: NSAppleEventDescriptor?,
    isDefaultLaunch: Bool? = nil
  ) -> Self {
    if arguments.contains("--background") { return .background }
    if let event = appleEvent, event.eventID == kAEOpenApplication {
      let reason = event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
      if reason == keyAELaunchedAsLogInItem || reason == keyAELaunchedAsServiceItem {
        return .background
      }
    }
    return isDefaultLaunch == false ? .background : .explicit
  }
}
