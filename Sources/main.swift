// Daylight Mirror — ScreenCaptureKit + WebSocket for low-latency screen mirroring.
// Captures a Mac display via ScreenCaptureKit, converts to greyscale via CIFilter (GPU),
// JPEG-encodes with CIContext (GPU), streams via WebSocket. Daylight DC-1 over USB.
//
// Pipeline: ScreenCaptureKit BGRA → CIColorControls desaturate → greyscale JPEG → WebSocket
// Greyscale JPEG: ~180KB/frame at q0.8 → ~5MB/s bandwidth (fits USB 2.0 easily).
// Raw greyscale was pixel-perfect but 1.2MB/frame × 30fps = 36MB/s overwhelmed USB.

import Foundation
import ScreenCaptureKit
import CoreImage
import CoreMedia
import Network

// MARK: - Configuration

let PORT: UInt16 = 8888
let JPEG_QUALITY: CGFloat = 0.8
let TARGET_FPS: Int = 30

// MARK: - WebSocket Server (NWListener based, no dependencies)

class WebSocketServer {
    let listener: NWListener
    var connections: [NWConnection] = []
    let queue = DispatchQueue(label: "ws-server")
    let lock = NSLock()

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("WebSocket server on ws://localhost:\(PORT)")
            case .failed(let err):
                print("Server failed: \(err)")
            default: break
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("Client connected")
                case .failed, .cancelled:
                    self.lock.lock()
                    self.connections.removeAll { $0 === conn }
                    self.lock.unlock()
                    print("Client disconnected")
                default: break
                }
            }
            conn.start(queue: self.queue)
            self.lock.lock()
            self.connections.append(conn)
            self.lock.unlock()

            self.receiveLoop(conn)
        }

        listener.start(queue: queue)
    }

    func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] content, context, isComplete, error in
            if error != nil { return }
            self?.receiveLoop(conn)
        }
    }

    func broadcast(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame",
                                                   metadata: [metadata])
        lock.lock()
        let conns = connections
        lock.unlock()

        for conn in conns {
            conn.send(content: data, contentContext: context, isComplete: true,
                      completion: .contentProcessed { error in
                if error != nil {
                    // Connection dead, will be cleaned up by state handler
                }
            })
        }
    }
}

// MARK: - HTTP Server for the viewer page (separate from WebSocket)

class HTTPServer {
    let listener: NWListener
    let queue = DispatchQueue(label: "http-server")
    let htmlPage: Data

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

        // Greyscale JPEG viewer. Uses createImageBitmap for off-main-thread decode.
        // requestAnimationFrame loop renders only the latest frame (drops stale ones).
        let html = """
        <!DOCTYPE html><html>
        <head><meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
        <style>*{margin:0;padding:0;overflow:hidden}
        body{background:#000;width:100vw;height:100vh;touch-action:none}
        canvas{width:100vw;height:100vh;display:block;image-rendering:pixelated}</style></head>
        <body><canvas id="c"></canvas><script>
        const canvas=document.getElementById('c');
        const ctx=canvas.getContext('2d');
        canvas.width=\(1280);canvas.height=\(960);

        const ws=new WebSocket('ws://localhost:\(PORT)');
        ws.binaryType='arraybuffer';

        let latestFrame=null;
        let pending=false;

        ws.onmessage=async(e)=>{
          // Decode JPEG off main thread, store as latest frame (drop old ones)
          const blob=new Blob([e.data],{type:'image/jpeg'});
          const bmp=await createImageBitmap(blob);
          if(latestFrame)latestFrame.close();
          latestFrame=bmp;
          if(!pending){pending=true;requestAnimationFrame(render);}
        };

        function render(){
          if(latestFrame){
            ctx.drawImage(latestFrame,0,0,canvas.width,canvas.height);
            latestFrame.close();
            latestFrame=null;
          }
          pending=false;
        }

        document.body.addEventListener('click',()=>{
          document.documentElement.requestFullscreen().catch(()=>{});
        });
        </script></body></html>
        """
        htmlPage = Data(html.utf8)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                print("HTTP server on http://localhost:\(self.listener.port!.rawValue)")
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self!.queue)
            self?.handleConnection(conn)
        }

        listener.start(queue: queue)
    }

    func handleConnection(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self = self, let data = data else {
                conn.cancel()
                return
            }

            let request = String(data: data, encoding: .utf8) ?? ""
            if request.contains("GET") {
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(self.htmlPage.count)\r\nConnection: close\r\n\r\n"
                var responseData = Data(response.utf8)
                responseData.append(self.htmlPage)
                conn.send(content: responseData, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            } else {
                conn.cancel()
            }
        }
    }
}

// MARK: - Screen Capture

class ScreenCapture: NSObject, SCStreamOutput {
    let wsServer: WebSocketServer
    let ciContext: CIContext
    var stream: SCStream?
    var frameCount: Int = 0
    var lastStatTime: Date = Date()
    var encodeTimeSum: Double = 0
    var statFrames: Int = 0

    init(wsServer: WebSocketServer) {
        self.wsServer = wsServer
        // GPU-accelerated CIContext — reused across all frames
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Find the virtual "Daylight" display (1280x960 non-HiDPI mirror)
        guard let display = content.displays.first(where: {
            $0.width == 1280 || $0.width == 1600
        }) ?? content.displays.first else {
            print("No display found!")
            return
        }

        print("Capturing display: \(display.width)x\(display.height) (ID: \(display.displayID))")

        let config = SCStreamConfiguration()
        config.width = Int(display.width)
        config.height = Int(display.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(TARGET_FPS))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = true

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        stream = SCStream(filter: filter, configuration: config, delegate: nil)

        let captureQueue = DispatchQueue(label: "capture", qos: .userInteractive)
        try stream!.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream!.startCapture()

        lastStatTime = Date()
        print("Capture started at \(TARGET_FPS)fps — greyscale JPEG")
    }

    // SCStreamOutput delegate — called for each captured frame
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let t0 = CACurrentMediaTime()

        // GPU pipeline: BGRA → desaturate (greyscale) → JPEG encode
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let grayImage = ciImage.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
        guard let jpegData = ciContext.jpegRepresentation(
            of: grayImage,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: JPEG_QUALITY]
        ) else { return }

        let t1 = CACurrentMediaTime()

        wsServer.broadcast(jpegData)

        frameCount += 1
        statFrames += 1
        encodeTimeSum += (t1 - t0) * 1000

        // Stats every 5 seconds
        let now = Date()
        if now.timeIntervalSince(lastStatTime) >= 5.0 {
            let fps = Double(statFrames) / now.timeIntervalSince(lastStatTime)
            let avgEncode = statFrames > 0 ? encodeTimeSum / Double(statFrames) : 0
            let bw = Double(jpegData.count) * fps / 1024 / 1024
            print(String(format: "FPS: %.1f | encode: %.1fms | frame: %dKB | ~%.1fMB/s | total: %d",
                         fps, avgEncode, jpegData.count / 1024, bw, frameCount))
            statFrames = 0
            encodeTimeSum = 0
            lastStatTime = now
        }
    }
}

// MARK: - Main

setbuf(stdout, nil)

let wsServer = try WebSocketServer(port: PORT)
wsServer.start()

let httpServer = try HTTPServer(port: PORT + 1)
httpServer.start()

let capture = ScreenCapture(wsServer: wsServer)

Task {
    do {
        try await capture.start()
    } catch {
        print("Capture error: \(error)")
    }
}

print("Daylight Mirror v3 — greyscale JPEG, rAF frame dropping")
print("HTML page: http://localhost:\(PORT + 1)")
print("WebSocket: ws://localhost:\(PORT)")

RunLoop.main.run()
