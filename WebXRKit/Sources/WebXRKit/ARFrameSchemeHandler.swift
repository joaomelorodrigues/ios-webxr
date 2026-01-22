import Foundation
import WebKit

/// Thread-safe storage for the latest AR camera frame.
/// Uses a lock to allow writes from any thread and reads from the main thread.
/// Marked @unchecked Sendable because we manually synchronize access with NSLock.
final class ARFrameStorage: @unchecked Sendable {
    static let shared = ARFrameStorage()
    
    private let lock = NSLock()
    private var _data: Data?
    private var _width: Int = 0
    private var _height: Int = 0
    
    private init() {}
    
    var data: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _data
    }
    
    var width: Int {
        lock.lock()
        defer { lock.unlock() }
        return _width
    }
    
    var height: Int {
        lock.lock()
        defer { lock.unlock() }
        return _height
    }
    
    func update(data: Data, width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        _data = data
        _width = width
        _height = height
    }
}

/// A custom URL scheme handler that serves AR camera frames as raw JPEG binary.
/// This eliminates the need for Base64 encoding, reducing CPU overhead and memory usage.
///
/// Usage: JS can fetch frames via `webxr-frame://frame?t=<timestamp>`
/// The timestamp query param is used to bust caches and trigger new requests.
class ARFrameSchemeHandler: NSObject, WKURLSchemeHandler {
    
    /// The custom URL scheme this handler responds to.
    static let scheme = "webxr-frame"
    
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        
        // Serve the latest frame data
        if url.host == "frame" {
            serveFrame(urlSchemeTask)
        } else if url.host == "metadata" {
            serveMetadata(urlSchemeTask)
        } else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
        }
    }
    
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Nothing to clean up - frame data is already in memory
    }
    
    private func serveFrame(_ task: WKURLSchemeTask) {
        let storage = ARFrameStorage.shared
        guard let data = storage.data else {
            // No frame available yet - return empty response
            let response = HTTPURLResponse(
                url: task.request.url!,
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            task.didReceive(response)
            task.didFinish()
            return
        }
        
        let response = HTTPURLResponse(
            url: task.request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "image/jpeg",
                "Content-Length": "\(data.count)",
                "Cache-Control": "no-store",
                "Access-Control-Allow-Origin": "*"
            ]
        )!
        
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
    
    private func serveMetadata(_ task: WKURLSchemeTask) {
        let storage = ARFrameStorage.shared
        let metadata: [String: Any] = [
            "width": storage.width,
            "height": storage.height,
            "available": storage.data != nil
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: metadata) else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        
        let response = HTTPURLResponse(
            url: task.request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json",
                "Cache-Control": "no-store"
            ]
        )!
        
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
