import Foundation

public enum RecordingPanelPlacement {
  /// Restore to the display containing most of the panel, or the nearest remaining
  /// display when its previous monitor is gone. The whole strip stays reachable.
  public static func clamp(_ frame: CGRect, to visibleScreens: [CGRect]) -> CGRect {
    let screens = visibleScreens.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
    guard let first = screens.first else { return frame }
    let valid =
      frame.origin.x.isFinite && frame.origin.y.isFinite
      && frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
    let frame =
      valid ? frame : CGRect(x: first.midX - 96, y: first.midY - 22, width: 192, height: 44)
    let screen =
      screens.max { left, right in
        let leftOverlap = frame.intersection(left)
        let rightOverlap = frame.intersection(right)
        let leftArea = leftOverlap.isNull ? 0 : leftOverlap.width * leftOverlap.height
        let rightArea = rightOverlap.isNull ? 0 : rightOverlap.width * rightOverlap.height
        if leftArea != rightArea { return leftArea < rightArea }
        return distance(frame, left) > distance(frame, right)
      } ?? first
    return CGRect(
      x: min(max(frame.minX, screen.minX), max(screen.minX, screen.maxX - frame.width)),
      y: min(max(frame.minY, screen.minY), max(screen.minY, screen.maxY - frame.height)),
      width: frame.width,
      height: frame.height
    )
  }

  private static func distance(_ frame: CGRect, _ screen: CGRect) -> Double {
    pow(frame.midX - screen.midX, 2) + pow(frame.midY - screen.midY, 2)
  }
}
