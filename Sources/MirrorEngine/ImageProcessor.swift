import CoreImage
import IOSurface
import CoreVideo
import Metal

class ImageProcessor {
    let ciContext: CIContext
    
    var contrast: Float = 1.0
    var sharpen: Float = 0.0
    
    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("ImageProcessor: Metal not available")
            return nil
        }
        self.ciContext = CIContext(mtlDevice: device, options: [.useSoftwareRenderer: false])
        print("ImageProcessor: CIContext ready (grayscale pipeline)")
    }
    
    func processCI(surface: IOSurface) -> CVPixelBuffer? {
        let ciImage = CIImage(ioSurface: surface)
        
        var processed = ciImage
        
        // 1. Grayscale (BT.601 luminance: 0.114R + 0.587G + 0.301B)
        processed = processed.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0
        ])
        
        // 2. Contrast enhancement
        if contrast != 1.0 {
            processed = processed.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: NSNumber(value: contrast)
            ])
        }
        
        // 3. Sharpen (unsharp mask)
        if sharpen > 0 {
            processed = processed.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: NSNumber(value: sharpen * 0.5)
            ])
        }
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            IOSurfaceGetWidth(surface),
            IOSurfaceGetHeight(surface),
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }
        
        ciContext.render(processed, to: pb)
        return pb
    }
}
