// Added for LocalAIPortal: exposes the pixel size a loaded model generates.

import Foundation

@available(iOS 16.2, macOS 13.1, *)
public extension StableDiffusionPipeline {
    /// Output size in pixels (width, height). Loads the Unet if needed.
    var outputPixelSize: (width: Int, height: Int) {
        let shape = unet.latentSampleShape
        return (shape[3] * 8, shape[2] * 8)
    }
}

@available(iOS 17.0, macOS 14.0, *)
public extension StableDiffusionXLPipeline {
    /// Output size in pixels (width, height). Loads the Unet if needed.
    var outputPixelSize: (width: Int, height: Int) {
        let shape = unet.latentSampleShape
        return (shape[3] * 8, shape[2] * 8)
    }
}
