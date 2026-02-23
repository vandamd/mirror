import CoreImage
import IOSurface
import CoreVideo
import Metal

class ImageProcessor {
    let ciContext: CIContext
    
    var contrast: Float = 1.3
    var sharpen: Float = 1.0
    
    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("ImageProcessor: Metal not available")
            return nil
        }
        self.ciContext = CIContext(mtlDevice: device, options: [.useSoftwareRenderer: false])
        print("ImageProcessor: CIContext ready")
    }
    
    func processCI(surface: IOSurface) -> CVPixelBuffer? {
        let ciImage = CIImage(ioSurface: surface)
        
        var processed = ciImage
        
        if contrast != 1.0 {
            processed = processed.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: NSNumber(value: contrast)
            ])
        }
        
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
