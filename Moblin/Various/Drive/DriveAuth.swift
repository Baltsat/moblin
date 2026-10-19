import AppAuth
import AppAuthCore
import Foundation

let driveIssuer = URL(string: "https://accounts.google.com")!
let driveScopes = ["https://www.googleapis.com/auth/drive", "https://www.googleapis.com/auth/youtube"]

enum DriveError: Error {
    case notSignedIn
    case retryable(String)
    case sessionGone
    case fatal(String)
}

func driveClientId() -> String {
    Bundle.main.object(forInfoDictionaryKey: "DriveClientId") as? String ?? ""
}

func driveRedirectUri() -> URL? {
    let id = driveClientId().replacing(".apps.googleusercontent.com", with: "")
    guard !id.isEmpty else {
        return nil
    }
    return URL(string: "com.googleusercontent.apps.\(id):/oauthredirect")
}

final class DriveAuth: NSObject, OIDAuthStateChangeDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let keychain = Keychain(streamId: "drive", server: "drive.google.com", logPrefix: "drive: auth")
    private var authState: OIDAuthState?

    override init() {
        super.init()
        guard let encoded = keychain.load(),
              let data = Data(base64Encoded: encoded),
              let state = try? NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data)
        else {
            return
        }
        state.stateChangeDelegate = self
        authState = state
    }

    var isSignedIn: Bool {
        lock.withLock { authState?.isAuthorized == true }
    }

    func hasScope(_ scope: String) -> Bool {
        lock.withLock { authState?.scope?.split(separator: " ").contains(Substring(scope)) == true }
    }

    func set(_ state: OIDAuthState?) {
        lock.withLock { authState = state }
        state?.stateChangeDelegate = self
        if let state {
            persist(state)
        } else {
            keychain.remove()
        }
    }

    func invalidateAccessToken() {
        lock.withLock { authState }?.setNeedsTokenRefresh()
    }

    func didChange(_ state: OIDAuthState) {
        persist(state)
    }

    private func persist(_ state: OIDAuthState) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: state,
                                                           requiringSecureCoding: false)
        else {
            return
        }
        keychain.store(value: data.base64EncodedString())
    }

    func accessToken() async throws -> String {
        guard let state = lock.withLock({ authState }) else {
            throw DriveError.notSignedIn
        }
        return try await withCheckedThrowingContinuation { continuation in
            state.performAction { accessToken, _, error in
                if let accessToken, error == nil {
                    continuation.resume(returning: accessToken)
                } else if let error, (error as NSError).domain == OIDOAuthTokenErrorDomain {
                    continuation.resume(throwing: DriveError.notSignedIn)
                } else {
                    let message = error?.localizedDescription ?? "token"
                    continuation.resume(throwing: DriveError.retryable(message))
                }
            }
        }
    }
}

let driveAuth = DriveAuth()

@MainActor
final class DriveSignInState: ObservableObject {
    var session: (any OIDExternalUserAgentSession)?
}

@MainActor
let driveSignInState = DriveSignInState()

@MainActor
final class DriveStatus: ObservableObject {
    @Published var signedIn = driveAuth.isSignedIn
    @Published var hasYouTube = driveAuth.hasScope(youTubeScope)
    @Published var text = ""
    @Published var percent: Int?
    @Published var email = UserDefaults.standard.string(forKey: "daysGoogleEmail") ?? ""

    func refreshEmail() async {
        guard signedIn, let email = await DriveApi().userEmail() else {
            return
        }
        self.email = email
        UserDefaults.standard.set(email, forKey: "daysGoogleEmail")
    }
}

@MainActor
let driveStatus = DriveStatus()

extension Model {
    func driveSignIn() {
        guard let rootViewController = getRootViewController(), let redirectUri = driveRedirectUri() else {
            makeErrorToast(title: String(localized: "Google Drive client ID is not set"))
            return
        }
        OIDAuthorizationService.discoverConfiguration(forIssuer: driveIssuer) { configuration, _ in
            guard let configuration else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.makeErrorToast(title: String(localized: "Cannot reach Google, check the network"))
                    }
                }
                return
            }
            nonisolated(unsafe) let serviceConfiguration = configuration
            MainActor.assumeIsolated {
                self.driveSignIn(configuration: serviceConfiguration,
                                 redirectUri: redirectUri,
                                 rootViewController: rootViewController)
            }
        }
    }

    private func driveSignIn(configuration: OIDServiceConfiguration,
                             redirectUri: URL,
                             rootViewController: UIViewController)
    {
        let request = OIDAuthorizationRequest(configuration: configuration,
                                              clientId: driveClientId(),
                                              clientSecret: nil,
                                              scopes: driveScopes,
                                              redirectURL: redirectUri,
                                              responseType: OIDResponseTypeCode,
                                              additionalParameters: nil)
        #if targetEnvironment(macCatalyst)
        guard let userAgent = OIDExternalUserAgentCatalyst(presenting: rootViewController) else {
            return
        }
        #else
        guard let userAgent = OIDExternalUserAgentIOS(presenting: rootViewController) else {
            return
        }
        #endif
        driveSignInState.session = OIDAuthState.authState(byPresenting: request,
                                                          externalUserAgent: userAgent,
                                                          callback: makeDriveSignInCallback())
    }

    private nonisolated func makeDriveSignInCallback() -> OIDAuthStateAuthorizationCallback {
        { authState, _ in
            nonisolated(unsafe) let authState = authState
            DispatchQueue.main.async {
                driveAuth.set(authState)
                MainActor.assumeIsolated {
                    driveStatus.signedIn = driveAuth.isSignedIn
                    driveStatus.hasYouTube = driveAuth.hasScope(youTubeScope)
                    driveSignInState.session = nil
                }
                driveUploader.resume()
            }
        }
    }

    func driveSignOut() {
        driveAuth.set(nil)
        driveStatus.signedIn = false
        driveStatus.hasYouTube = false
        driveStatus.text = ""
        driveStatus.email = ""
        UserDefaults.standard.removeObject(forKey: "daysGoogleEmail")
    }
}
