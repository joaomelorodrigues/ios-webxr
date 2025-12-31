import ARKit
import SceneKit
import SwiftUI
import VideoToolbox
import WebKit

struct ContentView: View {
    // Default starting URL
    @State private var urlString: String = "https://pmndrs.github.io/xr/examples/stage/"
    // The URL actually being displayed by the AR view
    @State private var currentURL: URL? = URL(string: "https://pmndrs.github.io/xr/examples/stage/")
    
    var body: some View {
        ZStack(alignment: .top) {
            // AR Web View Background
            if let targetURL = currentURL {
                ARWebView(url: targetURL)
                    .edgesIgnoringSafeArea(.all)
            }
            
            // Address Bar Overlay
            VStack {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .foregroundColor(.secondary)
                    
                    TextField("https://...", text: $urlString)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .submitLabel(.go)
                        .onSubmit {
                            loadURL()
                        }
                    
                    Button(action: {
                        loadURL()
                    }) {
                        Text("Go")
                            .bold()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                }
                .padding()
                .background(.regularMaterial) // Glassy background
                .cornerRadius(16)
                .padding(.horizontal)
                // Add top padding to account for safe area (Dynamic Island/Notch)
                .padding(.top, 50)
                
                Spacer()
            }
        }
        .statusBar(hidden: true)
    }
    
    private func loadURL() {
        // Dismiss keyboard
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        
        var cleanString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Basic convenience: Add https if missing
        if !cleanString.lowercased().hasPrefix("http") {
            cleanString = "https://" + cleanString
            urlString = cleanString // Update UI
        }
        
        if let newURL = URL(string: cleanString) {
            currentURL = newURL
        }
    }
}

struct ARWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView(frame: .zero)
        arView.automaticallyUpdatesLighting = true

        let webConfig = WKWebViewConfiguration()
        webConfig.allowsInlineMediaPlayback = true

        let contentController = webConfig.userContentController
        contentController.add(context.coordinator, name: "initAR")
        contentController.add(context.coordinator, name: "requestSession")
        contentController.add(context.coordinator, name: "stopAR")

        // 1. Better Error Handling Injection
        let errorScript = WKUserScript(
            source: """
                    window.onerror = function(message, source, lineno, colno, error) {
                        window.webkit.messageHandlers.initAR.postMessage({
                            "callback": "console_error_bridge",
                            "error_message": message
                        });
                    };
                """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        contentController.addUserScript(errorScript)

        // 2. Load Polyfill
        if let url = Bundle.module.url(forResource: "webxr-polyfill", withExtension: "js"),
            let polyfillSource = try? String(contentsOf: url)
        {
            let userScript = WKUserScript(
                source: polyfillSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            contentController.addUserScript(userScript)
        }

        let webView = WKWebView(frame: .zero, configuration: webConfig)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        webView.translatesAutoresizingMaskIntoConstraints = false
        arView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: arView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: arView.bottomAnchor),
        ])

        context.coordinator.webView = webView
        context.coordinator.arView = arView

        webView.navigationDelegate = context.coordinator
        arView.session.delegate = context.coordinator

        // We trigger the initial load in updateUIView to avoid duplication
        
        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        guard let webView = context.coordinator.webView else { return }
        
        // Load the URL if it differs from the current one or if the webview is empty
        if webView.url?.absoluteString != url.absoluteString {
            webView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    class Coordinator: NSObject, WKNavigationDelegate, ARSessionDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        weak var arView: ARSCNView?
        var dataCallbackName: String?
        var isSessionRunning = false

        // Reuse CIContext for performance (creating this every frame is expensive)
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        // Cache the sRGB color space
        let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

        // Throttling for image sending to maintain FPS
        var frameCounter = 0
        let frameSkip = 15
        
        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }

            if let errorMsg = body["error_message"] as? String {
                print("⚠️ JS Error: \(errorMsg)")
                return
            }

            switch message.name {
            case "initAR":
                if let callback = body["callback"] as? String {
                    replyToJS(callback: callback, data: "ios-ar-device-id")
                }
            case "requestSession":
                if let options = body["options"] as? [String: Any],
                    let callbackName = body["data_callback"] as? String
                {
                    self.dataCallbackName = callbackName
                    self.startARSession(options: options)
                    if let responseCallback = body["callback"] as? String {
                        replyToJS(
                            callback: responseCallback,
                            data: ["cameraAccess": true, "worldAccess": true, "webXRAccess": true])
                    }
                }
            case "stopAR":
                isSessionRunning = false
                arView?.session.pause()
            default: break
            }
        }

        func startARSession(options: [String: Any]) {
            let config = ARWorldTrackingConfiguration()
            config.planeDetection = [.horizontal, .vertical]
            arView?.session.run(config, options: [.resetTracking, .removeExistingAnchors])
            isSessionRunning = true
        }

        nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
            MainActor.assumeIsolated {
                guard isSessionRunning,
                    let webView = self.webView,
                    let callbackName = self.dataCallbackName
                else { return }

                // Throttle image processing
                frameCounter += 1
                let shouldSendImage = (frameCounter % frameSkip == 0)

                let orientation: UIInterfaceOrientation = .portrait
                let viewportSize = webView.bounds.size

                let viewMatrix = frame.camera.viewMatrix(for: orientation)
                let cameraTransform = viewMatrix.inverse
                let projMatrix = frame.camera.projectionMatrix(
                    for: orientation,
                    viewportSize: viewportSize,
                    zNear: 0.01,
                    zFar: 1000
                )

                // IMPORTANT: Calculate dimensions based on rotation
                // ARKit buffers are usually landscape. Since we rotate to .right (Portrait),
                // we must swap width and height for the JS payload.
                let rawWidth = CVPixelBufferGetWidth(frame.capturedImage)
                let rawHeight = CVPixelBufferGetHeight(frame.capturedImage)

                // Assuming we rotate 90 degrees (see convertPixelBufferToBase64)
                let finalWidth = rawHeight
                let finalHeight = rawWidth

                var payload: [String: Any] = [
                    "timestamp": frame.timestamp * 1000,
                    "light_intensity": frame.lightEstimate?.ambientIntensity ?? 1000,
                    "camera_transform": toArray(cameraTransform),
                    "camera_view": toArray(viewMatrix),
                    "projection_camera": toArray(projMatrix),
                    "worldMappingStatus": "ar_worldmapping_not_available",
                    "objects": [],
                    "newObjects": [],
                    "removedObjects": [],
                ]

                // --- IMAGE PROCESSING START ---
                if shouldSendImage {
                    let pixelBuffer = frame.capturedImage
                    // Convert CVPixelBuffer to JPEG Base64 with forced sRGB
                    if let base64String = convertPixelBufferToBase64(pixelBuffer, quality: 0.6) {
                        payload["video_data"] = base64String
                        // Send the swapped dimensions so WebGL textures aren't skewed
                        payload["video_width"] = finalWidth
                        payload["video_height"] = finalHeight
                    }
                }
                // --- IMAGE PROCESSING END ---

                if let jsonData = try? JSONSerialization.data(withJSONObject: payload),
                    let jsonString = String(data: jsonData, encoding: .utf8)
                {
                    let js = """
                        try {
                            \(callbackName)(\(jsonString));
                        } catch(e) {
                            console.error("ARKit Polyfill Error:", e.message);
                        }
                        """
                    webView.evaluateJavaScript(js, completionHandler: nil)
                }
            }
        }

        // Helper: Convert CVPixelBuffer to JPEG Base64
        private func convertPixelBufferToBase64(_ pixelBuffer: CVPixelBuffer, quality: CGFloat)
            -> String?
        {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

            // Create a CGImage using the explicit sRGB color space to fix "Dark" images
            guard
                let cgImage = ciContext.createCGImage(
                    ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: sRGBColorSpace)
            else {
                return nil
            }

            // Convert to UIImage then JPEG Data
            // orientation: .right handles the 90 degree rotation from Camera Sensor -> UI
            let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)

            guard let jpegData = uiImage.jpegData(compressionQuality: quality) else { return nil }

            return jpegData.base64EncodedString()
        }

        private func toArray(_ m: simd_float4x4) -> [Float] {
            return [
                m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
                m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
                m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
                m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w,
            ]
        }

        private func replyToJS(callback: String, data: Any) {
            guard let webView = webView else { return }
            if let str = data as? String {
                webView.evaluateJavaScript("\(callback)('\(str)')")
            } else if let dict = data as? [String: Any],
                let jsonData = try? JSONSerialization.data(withJSONObject: dict),
                let jsonString = String(data: jsonData, encoding: .utf8)
            {
                webView.evaluateJavaScript("\(callback)(\(jsonString))")
            }
        }
    }
}
