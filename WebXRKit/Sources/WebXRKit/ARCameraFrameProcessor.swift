import Foundation
import ARKit
import CoreImage

/// Handles the "computer vision" aspect: converting ARFrame pixel buffers
/// into web-friendly JPEG data.
///
/// Supports two modes:
/// - Binary mode (preferred): Stores raw JPEG in ARFrameSchemeHandler for URL-based access
/// - Legacy Base64 mode: Returns Base64-encoded string (slower, higher memory)
class ARCameraFrameProcessor {
    
    struct ProcessedFrame {
        /// Raw JPEG data (for binary transfer via URL scheme)
        let data: Data
        let width: Int
        let height: Int
        
        /// Legacy Base64 accessor - only compute when needed
        var base64: String {
            data.base64EncodedString()
        }
    }

    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    
    // Logic to throttle processing (processing every frame is too heavy for JS)
    private var frameCounter = 0
    private let videoFrameSkip = 4
    
    /// When true, uses the binary URL scheme (faster). When false, uses Base64 (legacy).
    var useBinaryTransfer = true

    /// Attempts to process the current frame. Returns nil if the frame should be skipped
    /// or if processing failed.
    func process(frame: ARFrame, viewportSize: CGSize, isCameraAccessRequested: Bool) -> ProcessedFrame? {
        frameCounter += 1
        
        // 1. Check if we should process this frame
        let shouldProcess = isCameraAccessRequested && (frameCounter % videoFrameSkip == 0)
        
        guard shouldProcess else { return nil }
        
        // 2. Perform Image Processing
        guard let result = convertImage(frame.capturedImage, viewportSize: viewportSize) else {
            return nil
        }
        
        // 3. If using binary transfer, update the shared frame storage
        if useBinaryTransfer {
            ARFrameStorage.shared.update(data: result.data, width: result.width, height: result.height)
        }
        
        return result
    }

    private func convertImage(_ pixelBuffer: CVPixelBuffer, viewportSize: CGSize) -> ProcessedFrame? {
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        ciImage = ciImage.oriented(.right)
        
        let imgWidth = ciImage.extent.width
        let imgHeight = ciImage.extent.height
        
        if imgWidth == 0 || imgHeight == 0 || viewportSize.width == 0 || viewportSize.height == 0 {
            return nil
        }
        
        let imageAspect = imgWidth / imgHeight
        let viewportAspect = viewportSize.width / viewportSize.height
        
        var cropRect = ciImage.extent
        
        // Center crop calculation to match WebView aspect ratio
        if imageAspect > viewportAspect {
            let newWidth = imgHeight * viewportAspect
            let xOffset = (imgWidth - newWidth) / 2.0
            cropRect = CGRect(x: xOffset, y: 0, width: newWidth, height: imgHeight)
        } else {
            let newHeight = imgWidth / viewportAspect
            let yOffset = (imgHeight - newHeight) / 2.0
            cropRect = CGRect(x: 0, y: yOffset, width: imgWidth, height: newHeight)
        }
        
        // 3. Crop to aspect ratio
        let croppedImage = ciImage.cropped(to: cropRect)
        
        // 4. Reduce resolution by 2x (Optimization for JS transmission)
        let scaledImage = croppedImage.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        
        guard let jpegData = ciContext.jpegRepresentation(
            of: scaledImage,
            colorSpace: sRGBColorSpace
        ) else {
            return nil
        }
        
        return ProcessedFrame(
            data: jpegData,
            width: Int(scaledImage.extent.width),
            height: Int(scaledImage.extent.height)
        )
    }
}
