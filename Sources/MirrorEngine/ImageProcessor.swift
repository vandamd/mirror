import CoreImage
import IOSurface
import CoreVideo
import Metal

class ImageProcessor {
    let ciContext: CIContext
    
    private var bufferPool: CVPixelBufferPool?
    private var poolWidth: Int = 0
    private var poolHeight: Int = 0
    
    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("ImageProcessor: Metal not available")
            return nil
        }
        self.ciContext = CIContext(mtlDevice: device, options: [.useSoftwareRenderer: false])
        print("ImageProcessor: CIContext ready (grayscale pipeline)")
    }
    
    private func getOrCreatePool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pool = bufferPool, poolWidth == width, poolHeight == height {
            return pool
        }
        
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferPoolAllocationThresholdKey as String: 5
        ]
        
        var newPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            nil,
            poolAttributes as CFDictionary,
            pixelBufferAttributes as CFDictionary,
            &newPool
        )
        
        guard status == kCVReturnSuccess, let pool = newPool else { return nil }
        
        bufferPool = pool
        poolWidth = width
        poolHeight = height
        return pool
    }
    
    func processCI(surface: IOSurface) -> CVPixelBuffer? {
        let ciImage = CIImage(ioSurface: surface)
        
        var processed = ciImage
        
        // 1. Grayscale (BT.601 luminance: 0.114R + 0.587G + 0.301B)
        processed = processed.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0
        ])
        
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        
        guard let pool = getOrCreatePool(width: width, height: height) else { return nil }
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }
        
        ciContext.render(processed, to: pb)
        return pb
    }
}
