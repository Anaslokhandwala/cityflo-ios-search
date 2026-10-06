import Foundation
import os

/// Routes `URLSession` requests for `SimulatedBackend.host` to the in-process backend.
/// Because this sits *under* URLSession, cancelling the Swift task that awaits
/// `URLSession.data(for:)` cancels the URLSessionTask, which calls `stopLoading()` here. That is the
/// same path a real request takes, so cancellation is tested end to end, not mocked.
///
/// Concurrency: URLProtocol isn't Sendable, so `self` crosses into the loading task in an
/// `UncheckedSendableBox`. That's sound here because the only mutable state, `inFlight`, is behind a
/// lock, and URLSession allows `client` callbacks from any thread for custom protocols.
final class SimulatedCityfloProtocol: URLProtocol {
    private let inFlight = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host() == SimulatedBackend.host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let request = self.request
        let protocolBox = UncheckedSendableBox(value: self)
        let task = Task {
            guard let response = await SimulatedBackend.shared.handle(request), !Task.isCancelled else { return }
            protocolBox.value.deliver(response, for: request)
        }
        inFlight.withLock { $0 = task }
    }

    override func stopLoading() {
        inFlight.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    private func deliver(_ response: SimulatedResponse, for request: URLRequest) {
        guard let url = request.url,
              let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}
