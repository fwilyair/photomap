import UIKit
import CoreVideo

// DEPRECATED: This file is no longer used in V4 (Background Synthesis).
// Please remove this file and its reference from your Xcode project.
@available(*, deprecated, message: "Use BackgroundVideoSynthesizer instead")
class FrameCaptureUtility {
    // Empty implementation to satisfy build
    static func captureView(_ view: UIView, size: CGSize) -> CVPixelBuffer? {
        return nil
    }
}
