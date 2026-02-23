// ScreenCapture.swift — Mac screen capture with VideoToolbox HEVC hardware encode.
//
// Captures the virtual display via CGDisplayStream (loaded at runtime via dlsym
// to bypass macOS 15 SDK deprecation), wraps each IOSurface as a CVPixelBuffer,
// and feeds it into a VTCompressionSession for low-latency HEVC encoding.
// The encoded NAL units (Annex B) are broadcast over TCP to the Android receiver.

import Foundation
import Darwin
import IOSurface
import CoreImage
import QuartzCore
import VideoToolbox
import CoreMedia
import Metal
import os.lock

// MARK: - Screen Capture Errors

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case contentEnumerationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission not granted. Open System Settings > Privacy & Security > Screen Recording and enable Daylight Mirror, then restart the app."
        case .contentEnumerationFailed(let underlying):
            return "Could not access screen content (permission may be pending). Grant Screen Recording in System Settings and retry. (\(underlying.localizedDescription))"
        }
    }
}

// MARK: - CGDisplayStream dlsym types

private typealias CGDisplayStreamCreateFn = @convention(c) (
    UInt32, Int, Int, Int32, CFDictionary?, DispatchQueue,
    @escaping @convention(block) (Int32, UInt64, IOSurfaceRef?, OpaquePointer?) -> Void
) -> OpaquePointer?
private typealias CGDisplayStreamStartFn = @convention(c) (OpaquePointer) -> Int32
private typealias CGDisplayStreamStopFn = @convention(c) (OpaquePointer) -> Int32

func adaptiveBackpressureThreshold(rttMs: Double) -> Int {
    max(2, min(6, Int(120.0 / max(rttMs, 1.0))))
}

// MARK: - Screen Capture

class ScreenCapture: NSObject {
    let tcpServer: TCPServer
    let ciContext: CIContext
    let targetDisplayID: CGDirectDisplayID
    
    var imageProcessor: ImageProcessor?
    
    func setProcessing(contrast: Float, sharpen: Float) {
        imageProcessor?.contrast = contrast
        imageProcessor?.sharpen = sharpen
    }

    // CGDisplayStream runtime handles
    private var cgHandle: UnsafeMutableRawPointer?
    private var displayStream: OpaquePointer?

    // VideoToolbox encoder
    private var vtSession: VTCompressionSession?
    private var encoderFormatDesc: CMFormatDescription?

    // Frame dimensions
    var frameWidth: Int = 0
    var frameHeight: Int = 0

    var frameCount: Int = 0
    var frameSequence: UInt32 = 0
    var skippedFrames: Int = 0
    var forceNextKeyframe: Bool = false
    var lastStatTime: Date = Date()
    var convertTimeSum: Double = 0
    var compressTimeSum: Double = 0
    var statFrames: Int = 0
    var lastCompressedSize: Int = 0
    var lastInflightFrames: Int = 0
    var lastBackpressureThreshold: Int = 0
    var lastRTTMs: Double = 0
    var encoderQueueDepth: Int = 0
    let maxEncoderQueueDepth = 3

    var jitterSamples: [Double] = []
    var lastCallbackTime: Double = 0
    let jitterWindowSize = 150

    /// Callback: (fps, bandwidthMB, frameSizeKB, totalFrames, greyMs, compressMs, jitterMs, skipped)
    var onStats: ((Double, Double, Int, Int, Double, Double, Double, Int) -> Void)?

    // Synchronization lock for shared state accessed from multiple threads
    private var encoderLock = os_unfair_lock()

    let expectedWidth: Int
    let expectedHeight: Int

    init(tcpServer: TCPServer, targetDisplayID: CGDirectDisplayID, width: Int, height: Int) {
        self.tcpServer = tcpServer
        self.targetDisplayID = targetDisplayID
        self.expectedWidth = width
        self.expectedHeight = height
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        super.init()
        self.imageProcessor = ImageProcessor()
        if let processor = imageProcessor {
            processor.contrast = CONTRAST_AMOUNT
            processor.sharpen = SHARPEN_AMOUNT
        }
    }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureError.permissionDenied
        }

        frameWidth = expectedWidth
        frameHeight = expectedHeight

        try setupEncoder()

        print("Capturing display: \(expectedWidth)x\(expectedHeight) pixels (ID: \(targetDisplayID))")

        guard let cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else {
            throw ScreenCaptureError.contentEnumerationFailed(
                NSError(domain: "ScreenCapture", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to dlopen CoreGraphics"]))
        }
        cgHandle = cg

        guard let createSym = dlsym(cg, "CGDisplayStreamCreateWithDispatchQueue"),
              let startSym  = dlsym(cg, "CGDisplayStreamStart"),
              let stopSym   = dlsym(cg, "CGDisplayStreamStop") else {
            throw ScreenCaptureError.contentEnumerationFailed(
                NSError(domain: "ScreenCapture", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to resolve CGDisplayStream symbols"]))
        }
        _ = stopSym

        let createFn = unsafeBitCast(createSym, to: CGDisplayStreamCreateFn.self)
        let startFn  = unsafeBitCast(startSym,  to: CGDisplayStreamStartFn.self)

        let properties: NSDictionary = [
            "kCGDisplayStreamShowCursor": kCFBooleanTrue as Any
        ]

        let captureQueue = DispatchQueue(label: "capture", qos: .userInteractive)
        let pixelFormat: Int32 = 1111970369  // kCVPixelFormatType_32BGRA

        guard let stream = createFn(
            targetDisplayID,
            frameWidth,
            frameHeight,
            pixelFormat,
            properties as CFDictionary,
            captureQueue,
            { [weak self] (status: Int32, _: UInt64, surface: IOSurfaceRef?, _: OpaquePointer?) in
                self?.handleFrame(status: status, surface: surface)
            }
        ) else {
            throw ScreenCaptureError.contentEnumerationFailed(
                NSError(domain: "ScreenCapture", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "CGDisplayStreamCreateWithDispatchQueue returned nil"]))
        }

        displayStream = stream
        let cfStream = Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(stream))
        _ = cfStream.retain()

        let result = startFn(stream)
        guard result == 0 else {
            throw ScreenCaptureError.contentEnumerationFailed(
                NSError(domain: "ScreenCapture", code: Int(result),
                        userInfo: [NSLocalizedDescriptionKey: "CGDisplayStreamStart failed with code \(result)"]))
        }

        lastStatTime = Date()
        print("Capture started at \(TARGET_FPS)fps -- CGDisplayStream + VideoToolbox HEVC")
    }

    func stop() async {
        if let stream = displayStream {
            if let cg = cgHandle, let stopSym = dlsym(cg, "CGDisplayStreamStop") {
                let stopFn = unsafeBitCast(stopSym, to: CGDisplayStreamStopFn.self)
                _ = stopFn(stream)
            }
            let cfStream = Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(stream))
            cfStream.release()
            displayStream = nil
        }
        if let cg = cgHandle {
            dlclose(cg)
            cgHandle = nil
        }
        if let session = vtSession {
            VTCompressionSessionInvalidate(session)
            vtSession = nil
        }
        encoderFormatDesc = nil
    }

    // MARK: - Encoder setup

    private func setupEncoder() throws {
        let sourcePixelFormat = kCVPixelFormatType_32BGRA

        let encoderSpec: NSDictionary = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(frameWidth),
            height: Int32(frameHeight),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: sourcePixelFormat,
                kCVPixelBufferWidthKey: frameWidth,
                kCVPixelBufferHeightKey: frameHeight,
            ] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: vtOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )
        guard status == noErr, let session = session else {
            throw ScreenCaptureError.contentEnumerationFailed(
                NSError(domain: "ScreenCapture", code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate failed: \(status)"]))
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_HEVC_Main_AutoLevel)
        let bitrate = Int(Double(frameWidth * frameHeight * TARGET_FPS) * ENCODER_BPP)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: KEYFRAME_INTERVAL as CFNumber)
        let keyframeSeconds = Double(KEYFRAME_INTERVAL) / Double(TARGET_FPS)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: keyframeSeconds as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: TARGET_FPS as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount,
                             value: 0 as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(session)
        vtSession = session
        print("VideoToolbox HEVC encoder ready: \(frameWidth)x\(frameHeight) @ \(bitrate/1_000_000)Mbps")
    }

    // MARK: - Frame callback

    private func handleFrame(status: Int32, surface: IOSurfaceRef?) {
        guard status == 0, let surface = surface else { return }

        let t0 = CACurrentMediaTime()

        if lastCallbackTime > 0 {
            let interval = (t0 - lastCallbackTime) * 1000.0
            let expectedInterval = 1000.0 / Double(TARGET_FPS)
            let jitter = abs(interval - expectedInterval)
            jitterSamples.append(jitter)
            if jitterSamples.count > jitterWindowSize {
                jitterSamples.removeFirst(jitterSamples.count - jitterWindowSize)
            }
        }
        lastCallbackTime = t0

        // Backpressure: drop frames when Android can't keep up or encoder queue is full
        let inflight = tcpServer.inflightFrames
        let isScheduledKeyframe = (frameCount % KEYFRAME_INTERVAL == 0)
        let rtt = tcpServer.latencyStats?.rttAvgMs ?? 15.0
        let adaptiveThreshold = adaptiveBackpressureThreshold(rttMs: rtt)
        lastInflightFrames = inflight
        lastBackpressureThreshold = adaptiveThreshold
        lastRTTMs = rtt

        os_unfair_lock_lock(&encoderLock)
        let currentQueueDepth = encoderQueueDepth
        os_unfair_lock_unlock(&encoderLock)
        
        if (inflight > adaptiveThreshold || currentQueueDepth >= maxEncoderQueueDepth) && !isScheduledKeyframe {
            skippedFrames += 1
            forceNextKeyframe = true
            IOSurfaceLock(surface, .readOnly, nil)
            IOSurfaceUnlock(surface, .readOnly, nil)
            frameCount += 1
            return
        }

        let isKeyframe = isScheduledKeyframe || forceNextKeyframe
        if forceNextKeyframe { forceNextKeyframe = false }

        IOSurfaceLock(surface, .readOnly, nil)
        let iosurfaceObj = unsafeBitCast(surface, to: IOSurface.self)
        
        let t1 = CACurrentMediaTime()
        let processedBuffer: CVPixelBuffer?
        if let processor = imageProcessor {
            processedBuffer = processor.processCI(surface: iosurfaceObj)
        } else {
            var pbUnmanaged: Unmanaged<CVPixelBuffer>?
            CVPixelBufferCreateWithIOSurface(nil, iosurfaceObj, nil, &pbUnmanaged)
            processedBuffer = pbUnmanaged?.takeRetainedValue()
        }
        let t2 = CACurrentMediaTime()

        guard let pixelBuffer = processedBuffer, let session = vtSession else {
            IOSurfaceUnlock(surface, .readOnly, nil)
            frameCount += 1
            return
        }

        var frameProps: CFDictionary? = nil
        if isKeyframe {
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        let presentationTime = CMTimeMake(value: Int64(frameCount), timescale: Int32(TARGET_FPS))
        os_unfair_lock_lock(&encoderLock)
        encoderQueueDepth += 1
        os_unfair_lock_unlock(&encoderLock)
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: frameProps,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )

        let t3 = CACurrentMediaTime()

        IOSurfaceUnlock(surface, .readOnly, nil)

        frameCount += 1
        statFrames += 1
        convertTimeSum += (t2 - t1) * 1000
        compressTimeSum += (t3 - t2) * 1000

        let now = Date()
        if now.timeIntervalSince(lastStatTime) >= 5.0 {
            let fps = Double(statFrames) / now.timeIntervalSince(lastStatTime)
            let avgProcess = statFrames > 0 ? convertTimeSum / Double(statFrames) : 0
            let avgCompress = statFrames > 0 ? compressTimeSum / Double(statFrames) : 0
            
            os_unfair_lock_lock(&encoderLock)
            let currentQueueDepth = encoderQueueDepth
            let currentCompressedSize = lastCompressedSize
            os_unfair_lock_unlock(&encoderLock)
            
            let bw = Double(currentCompressedSize) * fps / 1024 / 1024
            let avgJitter = jitterSamples.isEmpty ? 0.0 : jitterSamples.reduce(0, +) / Double(jitterSamples.count)

            print(String(format: "FPS: %.1f | process: %.2fms | encode: %.1fms | jitter: %.1fms | inflight: %d/%d | encQ: %d | rtt: %.1fms | frame: %dKB | ~%.1fMB/s | total: %d | skipped: %d",
                         fps, avgProcess, avgCompress, avgJitter,
                         lastInflightFrames, lastBackpressureThreshold, currentQueueDepth, lastRTTMs,
                         currentCompressedSize / 1024, bw, frameCount, skippedFrames))
            onStats?(fps, bw, currentCompressedSize / 1024, frameCount, avgProcess, avgCompress, avgJitter, skippedFrames)

            statFrames = 0
            convertTimeSum = 0
            compressTimeSum = 0
            lastStatTime = now
        }
    }

    // MARK: - VTCompressionSession output callback

    func handleEncoderOutput(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        os_unfair_lock_lock(&encoderLock)
        encoderQueueDepth = max(0, encoderQueueDepth - 1)
        os_unfair_lock_unlock(&encoderLock)
        guard status == noErr, let sampleBuffer = sampleBuffer else { return }
        guard !flags.contains(.frameDropped) else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
        var isIDR = false
        if let attachments = attachments as? [[CFString: Any]], let first = attachments.first {
            let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
            isIDR = !notSync
        }

        var annexB = Data()

        if isIDR {
            if let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                var paramCount = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    fmtDesc, parameterSetIndex: 0,
                    parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil,
                    parameterSetCountOut: &paramCount,
                    nalUnitHeaderLengthOut: nil)
                for i in 0..<paramCount {
                    var nalPtr: UnsafePointer<UInt8>? = nil
                    var nalLen = 0
                    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                        fmtDesc, parameterSetIndex: i,
                        parameterSetPointerOut: &nalPtr,
                        parameterSetSizeOut: &nalLen,
                        parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil)
                    if let nalPtr = nalPtr, nalLen > 0 {
                        annexB.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                        annexB.append(nalPtr, count: nalLen)
                    }
                }
                encoderFormatDesc = fmtDesc
            }
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>? = nil
        let blockStatus = CMBlockBufferGetDataPointer(
            dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard blockStatus == kCMBlockBufferNoErr, let dataPointer = dataPointer else { return }

        var offset = 0
        while offset < totalLength - 4 {
            let rawLen = dataPointer.advanced(by: offset).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
            let nalLen = Int(CFSwapInt32BigToHost(rawLen))
            offset += 4
            guard offset + nalLen <= totalLength else { break }
            annexB.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            dataPointer.advanced(by: offset).withMemoryRebound(to: UInt8.self, capacity: nalLen) { ptr in
                annexB.append(ptr, count: nalLen)
            }
            offset += nalLen
        }

        guard !annexB.isEmpty else { return }

        os_unfair_lock_lock(&encoderLock)
        lastCompressedSize = annexB.count
        let seq = frameSequence
        frameSequence &+= 1
        os_unfair_lock_unlock(&encoderLock)
        tcpServer.broadcast(payload: annexB, isKeyframe: isIDR, sequenceNumber: seq)
    }
}

// MARK: - C-compatible VTCompressionSession output callback

private func vtOutputCallback(
    outputCallbackRefCon: UnsafeMutableRawPointer?,
    sourceFrameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    infoFlags: VTEncodeInfoFlags,
    sampleBuffer: CMSampleBuffer?
) {
    guard let refCon = outputCallbackRefCon else { return }
    let capture = Unmanaged<ScreenCapture>.fromOpaque(refCon).takeUnretainedValue()
    capture.handleEncoderOutput(status: status, flags: infoFlags, sampleBuffer: sampleBuffer)
}
