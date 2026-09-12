import SwiftUI
import UIKit

/// Marks the embedded (T3 Code Live) hosting context. Navigation-bar transitions
/// glitch when the product UI is hosted inside a UIViewControllerRepresentable,
/// so views use this to pin inline bars and skip transition animations.
struct T3CodeEmbeddedEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

/// True when this process is the LiveContainer host. iLoader may re-sign with a
/// different bundle identifier, so detect the runtime by the ObjC class only the
/// Live build links instead of the bundle identifier.
var isT3CodeLiveRuntime: Bool {
    NSClassFromString("LCUtils") != nil
}

extension EnvironmentValues {
    var t3CodeEmbedded: Bool {
        get { self[T3CodeEmbeddedEnvironmentKey.self] }
        set { self[T3CodeEmbeddedEnvironmentKey.self] = newValue }
    }
}

/// Composition root used by the sideload-only LiveContainer host.
public struct T3CodeEmbeddedRoot: View {
    @State private var model: FeatureRootModel

    public init() {
        let client = NativeFeatureClient()
        let model = FeatureRootModel(client: client)
        _model = State(initialValue: model)
        PlatformCloudDeliveryCoordinator.shared.install(
            controller: client.t3ConnectController
        )
        PlatformBackgroundRefreshCoordinator.shared.install { [weak model] in
            guard let model else { return false }
            return await model.refreshInBackground()
        }
        PlatformBackgroundRefreshCoordinator.shared.register()
        PlatformNotificationService.shared.installDelegate()
    }

    public var body: some View {
        RootView {
            PlatformRootView(model: model)
        }
        .environment(\.t3CodeEmbedded, true)
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name("T3CodeEmbeddedOpenURL")
            )
        ) { notification in
            guard let url = notification.object as? URL,
                  let route = try? PlatformDeepLinkParser.parse(url) else {
                return
            }
            NotificationCenter.default.post(
                name: .platformRouteReceived,
                object: nil,
                userInfo: ["route": route]
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name("T3CodeEmbeddedDeviceToken")
            )
        ) { notification in
            guard let token = notification.object as? Data else { return }
            PlatformNotificationService.shared.didRegisterForRemoteNotifications(
                deviceToken: token
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name("T3CodeEmbeddedDeviceTokenError")
            )
        ) { notification in
            guard let error = notification.object as? Error else { return }
            PlatformNotificationService.shared.didFailToRegisterForRemoteNotifications(error)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name("T3CodeEmbeddedRemoteNotification")
            )
        ) { notification in
            guard let userInfo = notification.object as? [AnyHashable: Any],
                  let route = PlatformNotificationPayload.route(from: userInfo) else {
                return
            }
            PlatformRouteMailbox.shared.put(route)
            NotificationCenter.default.post(
                name: .platformRouteReceived,
                object: nil,
                userInfo: ["route": route]
            )
        }
    }
}

@_cdecl("T3CodeCreateRootViewController")
public func T3CodeCreateRootViewController() -> UInt {
    MainActor.assumeIsolated {
        let controller = UIHostingController(rootView: T3CodeEmbeddedRoot())
        return UInt(bitPattern: Unmanaged.passRetained(controller).toOpaque())
    }
}
