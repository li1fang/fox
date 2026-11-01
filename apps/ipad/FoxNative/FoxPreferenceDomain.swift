import Foundation

/// UI automation must never write the user's ordinary preference domain.
enum FoxPreferenceDomain {
    private static let uiSuiteName = "com.whipa.fox.ui-testing.preferences"

    static var isUITesting: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["FOX_UI_TESTING"] == "1"
        #else
        return false
        #endif
    }

    static var current: UserDefaults {
        resolve(isUITesting: isUITesting, production: .standard, testSuiteName: uiSuiteName)
    }

    static func resolve(isUITesting: Bool, production: UserDefaults, testSuiteName: String) -> UserDefaults {
        guard isUITesting else { return production }
        guard let isolated = UserDefaults(suiteName: testSuiteName) else {
            preconditionFailure("Unable to create the isolated UI test preference domain")
        }
        return isolated
    }

    static func resetIfRequested(isUITesting: Bool, arguments: [String], testSuiteName: String) {
        guard isUITesting, arguments.contains("--ui-testing-reset") else { return }
        let isolated = resolve(isUITesting: true, production: .standard, testSuiteName: testSuiteName)
        isolated.removePersistentDomain(forName: testSuiteName)
    }

    static func prepareForLaunch() {
        resetIfRequested(isUITesting: isUITesting, arguments: ProcessInfo.processInfo.arguments, testSuiteName: uiSuiteName)
    }
}
