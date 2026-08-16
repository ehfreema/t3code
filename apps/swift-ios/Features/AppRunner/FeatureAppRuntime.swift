import SwiftUI
import UIKit

public enum FeatureAppRuntimeAvailability: Equatable, Sendable {
    case embedded
    case unavailable
}

public struct FeatureAppRuntimeActions: Sendable {
    public var availability: @MainActor @Sendable () -> FeatureAppRuntimeAvailability
    public var run: @MainActor @Sendable (FeatureIOSAppManifest, URL) async throws -> Void

    public init(
        availability: @escaping @MainActor @Sendable () -> FeatureAppRuntimeAvailability,
        run: @escaping @MainActor @Sendable (FeatureIOSAppManifest, URL) async throws -> Void
    ) {
        self.availability = availability
        self.run = run
    }

    public static let embedded = FeatureAppRuntimeActions(
        availability: {
            FeatureLiveContainerBridge.isEmbedded ? .embedded : .unavailable
        },
        run: { manifest, artifactURL in
            guard FeatureLiveContainerBridge.isEmbedded else {
                throw FeatureAppRuntimeError.runtimeUnavailable
            }
            try await FeatureLiveContainerBridge.run(
                manifest: manifest,
                artifactURL: artifactURL
            )
        }
    )
}

private enum FeatureLiveContainerBridge {
    static var isEmbedded: Bool {
        Bundle.main.object(forInfoDictionaryKey: "T3EmbeddedLiveContainerRuntime") as? Bool == true
    }

    @MainActor
    static func run(
        manifest: FeatureIOSAppManifest,
        artifactURL: URL
    ) async throws {
        let requestID = UUID().uuidString
        let route = try FeatureLiveContainerRoute.run(
            manifest: manifest,
            artifactURL: artifactURL,
            requestID: requestID
        )

        try await withCheckedThrowingContinuation { continuation in
            let waiter = FeatureLiveContainerRequestWaiter(
                requestID: requestID,
                continuation: continuation
            )
            waiter.start()
            NotificationCenter.default.post(
                name: Notification.Name("T3CodeEmbeddedLiveContainerRoute"),
                object: route
            )
        }
    }
}

@MainActor
private final class FeatureLiveContainerRequestWaiter: @unchecked Sendable {
    private let requestID: String
    private var continuation: CheckedContinuation<Void, any Error>?
    private var observer: NSObjectProtocol?
    private var timeoutTask: Task<Void, Never>?

    init(
        requestID: String,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        self.requestID = requestID
        self.continuation = continuation
    }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("T3CodeEmbeddedLiveContainerResult"),
            object: nil,
            queue: .main
        ) { [self] notification in
            let responseID = notification.userInfo?["request-id"] as? String
            let error = notification.userInfo?["error"] as? String
            Task { @MainActor [self] in
                self.receive(requestID: responseID, error: error)
            }
        }
        // The runtime can be suspended (e.g. while the user approves the certificate
        // export in SideStore) or killed; never leave the caller hanging forever.
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 240_000_000_000)
            guard let self else { return }
            self.receive(
                requestID: self.requestID,
                error: "The iPhone app runtime did not respond within 4 minutes. Please try again."
            )
        }
    }

    private func receive(requestID responseID: String?, error: String?) {
        guard responseID == requestID, let continuation else { return }
        finish()
        if let message = error {
            continuation.resume(throwing: FeatureAppRuntimeError.runtimeFailed(message))
        } else {
            continuation.resume()
        }
    }

    private func finish() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation = nil
    }
}

public enum FeatureAppRuntimeError: LocalizedError, Equatable, Sendable {
    case invalidRoute
    case runtimeUnavailable
    case runtimeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRoute:
            "T3 Code could not create the app runtime route."
        case .runtimeUnavailable:
            "Install T3 Code Live to run iPhone apps on this device."
        case let .runtimeFailed(message):
            message
        }
    }
}

enum FeatureLiveContainerRoute {
    static func run(
        manifest: FeatureIOSAppManifest,
        artifactURL: URL,
        requestID: String
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = "t3code-livecontainer"
        components.host = "run"
        components.queryItems = [
            URLQueryItem(name: "url", value: artifactURL.absoluteString),
            URLQueryItem(name: "bundle-name", value: manifest.liveContainerBundleName),
            URLQueryItem(name: "request-id", value: requestID),
        ]
        guard let url = components.url else { throw FeatureAppRuntimeError.invalidRoute }
        return url
    }
}

private struct FeatureAppRuntimeEnvironmentKey: EnvironmentKey {
    typealias Value = FeatureAppRuntimeActions
    static let defaultValue = FeatureAppRuntimeActions.embedded
}

public extension EnvironmentValues {
    var featureAppRuntime: FeatureAppRuntimeActions {
        get { self[FeatureAppRuntimeEnvironmentKey.self] }
        set { self[FeatureAppRuntimeEnvironmentKey.self] = newValue }
    }
}
