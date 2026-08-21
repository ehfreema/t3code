import Foundation
import Observation

enum FeatureRunTarget: Equatable {
    case iosApp
    case website
}

enum FeatureRunActivity: Equatable {
    case idle
    case preparing(FeatureRunTarget)
    case buildingIOS
    case launchingIOS
    case startingWebsite
    case failed(FeatureRunTarget)

    var target: FeatureRunTarget? {
        switch self {
        case .idle:
            nil
        case let .preparing(target), let .failed(target):
            target
        case .buildingIOS, .launchingIOS:
            .iosApp
        case .startingWebsite:
            .website
        }
    }

    var isBusy: Bool {
        switch self {
        case .preparing, .buildingIOS, .launchingIOS, .startingWebsite:
            true
        case .idle, .failed:
            false
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var compactLabel: String {
        switch self {
        case .idle: "Run"
        case .preparing: "Prepare"
        case .buildingIOS: "Build"
        case .launchingIOS: "Launch"
        case .startingWebsite: "Website"
        case .failed: "Failed"
        }
    }

    var compactIcon: String {
        switch self {
        case .idle: "play.fill"
        case .preparing: "shippingbox"
        case .buildingIOS: "hammer.fill"
        case .launchingIOS: "iphone.gen3"
        case .startingWebsite: "safari"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: "Run"
        case .preparing(.iosApp): "Preparing iPhone app"
        case .preparing(.website): "Preparing website"
        case .buildingIOS: "Building iPhone app"
        case .launchingIOS: "Launching iPhone app"
        case .startingWebsite: "Starting website"
        case .failed(.iosApp): "iPhone app run failed"
        case .failed(.website): "Website run failed"
        }
    }
}

@MainActor
@Observable
final class FeatureRunSession {
    var activity = FeatureRunActivity.idle
    var phase: String?
    var message: String?
    @ObservationIgnored var task: Task<Void, Never>?
}
