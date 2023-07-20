//
//  JSCRunner.swift
//  Suwatte (iOS)
//
//  Created by Mantton on 2023-07-06.
//

import Foundation
import JavaScriptCore

protocol JSCContextProtocol : NSObject {
    var runnerClass: JSValue { get }
}

protocol DaisukeInterface: Codable, Hashable, Identifiable {}

@objc protocol JSObjectProtocol: JSExport {
    var setThisValue: (@convention(block) (JSValue) -> Void)? { get }
}

class JSObject: NSObject, JSObjectProtocol {
    var this: JSManagedValue?
    
    override init() {
        super.init()
    }
    
    var setThisValue: (@convention(block) (JSValue) -> Void)? {
        return { [unowned self] (value: JSValue) in
            self.this = JSManagedValue(value: value)
        }
    }
    
    func getRunnerID() throws -> String {
        guard let runner = this?.value.context.daisukeRunner() else {
            throw DaisukeEngine.Errors.RunnerNotFoundOnContainedObject
        }
        
        guard let id = runner.forProperty("info")?.forProperty("id")?.toString() else {
            throw DaisukeEngine.Errors.UnableToFetchRunnerIDInContainedObject
        }
        
        return id
    }
}

// MARK: - Runner Info Model
protocol RunnerInfo: Parsable {
    var id: String { get }
    var name: String { get }
    var version: Double { get }
    var minSupportedAppVersion: String? { get }
    var thumbnail: String? { get }
}

// MARK: - Runner Intents
struct RunnerIntents: Parsable {
    let preferenceMenuBuilder: Bool
    
    let authenticatable: Bool
    let authenticationMethod: AuthenticationMethod
    let basicAuthLabel: BasicAuthenticationUIIdentifier?
    let imageRequestHandler: Bool
    let pageLinkResolver: Bool
    let libraryPageLinkProvider: Bool
    let browsePageLinkProvider: Bool
    
    // JSCCS
    let chapterEventHandler: Bool
    let contentEventHandler: Bool
    let chapterSyncHandler: Bool
    let librarySyncHandler: Bool
    let hasTagsView: Bool
    
    // MSB
    let pageReadHandler: Bool
    let providesReaderContext: Bool
    let canRefreshHighlight: Bool
    
    // Context Menu
    let isContextMenuProvider: Bool
    
    // JSC CT
    let advancedTracker: Bool
    
    enum AuthenticationMethod: String, Codable {
        case webview, basic, oauth, unknown
    }
    enum BasicAuthenticationUIIdentifier: Int, Codable {
        case EMAIL
        case USERNAME
    }
}

// MARK: - JSC Runner
protocol JSCRunner: JSCContextProtocol {
    var info:  RunnerInfo { get }
    var intents: RunnerIntents { get }
    var environment: RunnerEnvironment { get }
    var configCache: [String: DSKCommon.DirectoryConfig] { get set }
    init(value: JSValue) throws
}


extension JSCRunner {
    var id: String {
        info.id
    }
    
    var name: String {
        info.name
    }
    
    var version: Double {
        info.version
    }
    
    var thumbnailURL: URL? {
        DataManager.shared.getRunner(id).flatMap { URL(string: $0.thumbnail) }
    }
}


// MARK: - Paths

// MARK: - JS Method Callers
extension JSCRunner {
    func methodExists(method: String) -> Bool {
        runnerClass.hasProperty(method)
    }
    
    func callOptionalVoidMethod(method: String, arguments: [Any]) async throws {
        try await withUnsafeThrowingContinuation { handler in
            guard runnerClass.hasProperty(method) else {
                handler.resume()
                return
            }
            runnerClass.daisukeCall(method: method, arguments: arguments) { _ in
                handler.resume()
            } onFailure: { error in
                handler.resume(throwing: error)
            }
        } as Void
    }
    
    func callMethodReturningDecodable<T: Decodable>(method: String, arguments: [Any], resolvesTo _: T.Type) async throws -> T? {
        try await withCheckedThrowingContinuation { handler in
            guard runnerClass.hasProperty(method) else {
                handler.resume(throwing: DaisukeEngine.Errors.MethodNotFound(name: method))
                return
            }
            runnerClass.daisukeCall(method: method, arguments: arguments) { value in
                
                if value.isNull || value.isUndefined {
                    handler.resume(returning: nil)
                    return
                }
                let str = DaisukeEngine.stringify(val: value)
                guard let str = str else {
                    handler.resume(throwing: DaisukeEngine.Errors.NamedError(name: "Invalid Return", message: "Returned Array Object cannot be converted to JSON String"))
                    return
                }
                do {
                    let jsonData = str.data(using: .utf8, allowLossyConversion: false)!
                    let output: T = try DaisukeEngine.decode(data: jsonData, to: T.self)
                    handler.resume(returning: output)
                } catch {
                    handler.resume(throwing: error)
                }
            } onFailure: { error in
                handler.resume(throwing: error)
            }
        }
    }
    
    func callMethodReturningObject<T: Parsable>(method: String, arguments: [Any], resolvesTo _: T.Type) async throws -> T {
        try await withCheckedThrowingContinuation { handler in
            
            guard runnerClass.hasProperty(method) else {
                handler.resume(throwing: DaisukeEngine.Errors.MethodNotFound(name: method))
                return
            }
            
            runnerClass.daisukeCall(method: method, arguments: arguments) { value in
                do {
                    let object = try T(value: value)
                    handler.resume(returning: object)
                } catch {
                    handler.resume(throwing: error)
                }
                
            } onFailure: { error in
                handler.resume(throwing: error)
            }
        }
    }
    
    func callMethodReturningDecodable<T: Decodable>(method: String, arguments: [Any], resolvesTo _: T.Type) async throws -> T {
        try await withCheckedThrowingContinuation { handler in
            guard runnerClass.hasProperty(method) else {
                handler.resume(throwing: DaisukeEngine.Errors.MethodNotFound(name: method))
                return
            }
            runnerClass.daisukeCall(method: method, arguments: arguments) { value in
                
                let str = DaisukeEngine.stringify(val: value)
                guard let str = str else {
                    handler.resume(throwing: DaisukeEngine.Errors.NamedError(name: "Invalid Return", message: "Returned Array Object cannot be converted to JSON String"))
                    return
                }
                do {
                    let jsonData = str.data(using: .utf8, allowLossyConversion: false)!
                    let output: T = try DaisukeEngine.decode(data: jsonData, to: T.self)
                    handler.resume(returning: output)
                } catch {
                    handler.resume(throwing: error)
                }
            } onFailure: { error in
                handler.resume(throwing: error)
            }
        }
    }
    
    func callContextMethod<T: Decodable>(method: String, arguments _: [Any]? = nil, resolvesTo _: T.Type) async throws -> T {
        try await withCheckedThrowingContinuation { handler in
            runnerClass.context!.evaluateScript(method).daisukeCall { value in
                let str = DaisukeEngine.stringify(val: value)
                guard let str = str else {
                    handler.resume(throwing: DaisukeEngine.Errors.NamedError(name: "Invalid Return", message: "Returned Array Object cannot be converted to JSON String"))
                    return
                }
                do {
                    let jsonData = str.data(using: .utf8, allowLossyConversion: false)!
                    let output: T = try DaisukeEngine.decode(data: jsonData, to: T.self)
                    handler.resume(returning: output)
                } catch {
                    handler.resume(throwing: error)
                }
            } onFailure: { error in
                handler.resume(throwing: error)
            }
        }
    }
}

// MARK: - Preferences
extension JSCRunner {
    func saveState() {
        UserDefaults.standard.set(intents.imageRequestHandler, forKey: STTKeys.RunnerOverridesImageRequest(id))
        UserDefaults.standard.set(intents.pageLinkResolver, forKey: STTKeys.PageLinkResolver(id))
    }
    // Preference
    func buildPreferenceMenu() async throws -> [DSKCommon.PreferenceGroup] {
        return try await callContextMethod(method: "generatePreferenceMenu", resolvesTo: [DSKCommon.PreferenceGroup].self)
    }
    
    func updateSourcePreference(key: String, value: Any) async {
        let context = runnerClass.context!
        let function = context.evaluateScript("updateSourcePreferences")
        function?.daisukeCall(arguments: [key, value], onSuccess: { _ in
            context.evaluateScript("console.log('[\(key)] Preference Updated')")
        }, onFailure: { error in
            context.evaluateScript("console.error('[\(key)] Preference Failed To Update: \(error)')")
            
        })
    }
    
}
// MARK: - Authenticatable
extension JSCRunner {
    // Auth
    func getAuthenticatedUser() async throws -> DSKCommon.User? {
        return try await callMethodReturningDecodable(method: "getAuthenticatedUser", arguments: [], resolvesTo: DSKCommon.User?.self)
    }
    
    func handleUserSignOut() async throws {
        try await callOptionalVoidMethod(method: "handleUserSignOut", arguments: [])
    }
    
    // Basic Auth
    func handleBasicAuthentication(id: String, password: String) async throws {
        try await callOptionalVoidMethod(method: "handleBasicAuth", arguments: [id, password])
    }
    
    
    // Web Auth
    func getWebAuthRequestURL() async throws -> DSKCommon.BasicURL {
        return try await callMethodReturningObject(method: "getWebAuthRequestURL", arguments: [], resolvesTo: DSKCommon.BasicURL.self)
    }
    
    func didReceiveCookieFromWebAuthResponse(name: String) async throws -> Bool {
        return try await callMethodReturningDecodable(method: "didReceiveSessionCookieFromWebAuthResponse", arguments: [name], resolvesTo: Bool.self)
    }
    
    
    // OAuth
    func getOAuthRequestURL() async throws -> DSKCommon.BasicURL {
        return try await callMethodReturningObject(method: "getOAuthRequestURL", arguments: [], resolvesTo: DSKCommon.BasicURL.self)
    }
    
    func handleOAuthCallback(response: String) async throws {
        try await callOptionalVoidMethod(method: "handleOAuthCallback", arguments: [response])
    }
}

// MARK: - Directory Handler
extension JSCRunner {
    func getDirectory<T: Codable>(request: DSKCommon.DirectoryRequest) async throws -> DSKCommon.PagedResult<T> {
        let object = try request.asDictionary()
        return try await callMethodReturningDecodable(method: "getDirectory", arguments: [object], resolvesTo: DSKCommon.PagedResult<T>.self)
    }
    
    func getDirectoryConfig(key: String?) async throws -> DSKCommon.DirectoryConfig {
        if let config = configCache[key ?? "default"] {
            return config
        }
        let data: DSKCommon.DirectoryConfig = try await callMethodReturningDecodable(method: "getDirectoryConfig", arguments: [key as Any], resolvesTo: DSKCommon.DirectoryConfig.self)
        configCache[key ?? "default"] = data
        return data
    }
}


//MARK: - Page Resolver
extension JSCRunner {
    func willRequestImage(imageURL: URL) async throws -> DSKCommon.Request {
        return try await callMethodReturningDecodable(method: "willRequestImage", arguments: [imageURL.absoluteString], resolvesTo: DSKCommon.Request.self)
    }
    func getSectionsForPage<T: JSCObject>(link: DSKCommon.PageLink) async throws -> [DSKCommon.PageSection<T>] {
        let pageLink = try link.asDictionary()
        return try await callMethodReturningDecodable(method: "getSectionsForPage", arguments: [pageLink], resolvesTo: [DSKCommon.PageSection<T>].self)
    }
    
    func willResolveSectionsForPage(link: DSKCommon.PageLink) async throws  {
        let pageLink = try link.asDictionary()
        try await callOptionalVoidMethod(method: "willResolveSectionsForPage", arguments: [pageLink])
        
    }
    func resolvePageSection<T: JSCObject>(link: DSKCommon.PageLink, section: String) async throws -> DSKCommon.ResolvedPageSection<T> {
        let pageLink = try link.asDictionary()
        return try await callMethodReturningDecodable(method: "resolvePageSection", arguments: [pageLink, section], resolvesTo: DSKCommon.ResolvedPageSection<T>.self)
    }
}

// MARK: - Page Provider
extension JSCRunner {
    func getLibraryPageLinks() async throws -> [DSKCommon.PageLinkLabel] {
        try await callMethodReturningDecodable(method: "getLibraryPageLinks", arguments: [], resolvesTo: [DSKCommon.PageLinkLabel].self)
    }
    func getBrowsePageLinks() async throws -> [DSKCommon.PageLinkLabel] {
        try await callMethodReturningDecodable(method: "getBrowsePageLinks", arguments: [], resolvesTo: [DSKCommon.PageLinkLabel].self)
    }
}

// MARK: - Synchronous Call
extension JSCRunner {
    
    func synchronousCall<T: Decodable>(method: String, arguments: [Any]) throws -> T {
        
        guard runnerClass.hasProperty(method) else {
            throw DaisukeEngine.Errors.MethodNotFound(name: method)
        }
        
        let result = runnerClass.invokeMethod(method, withArguments: arguments)
        let error = runnerClass.context!.exception
        
        // Error Occured in Execution
        if let error {
            throw DaisukeEngine.Errors.nativeError(for: error)
        }
        
        guard let result, let str = DaisukeEngine.stringify(val: result) else {
            throw DSK.Errors.ObjectConversionFailed
        }
        
        let jsonData = str.data(using: .utf8, allowLossyConversion: false)!
        let output: T = try DaisukeEngine.decode(data: jsonData, to: T.self)
        return output
    }
}

