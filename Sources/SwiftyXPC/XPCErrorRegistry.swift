//
//  XPCErrorRegistry.swift
//
//
//  Created by Charles Srstka on 12/19/21.
//

import Foundation
import Synchronization
import XPC

/// A registry which facilitates decoding error types that are sent over an XPC connection.
///
/// If an error is received, it will be looked up in the registry by its domain.
/// If a matching error type exists, that type is used to decode the error using `XPCDecoder`.
/// However, if the error domain is not registered, it will be encapsulated in a `BoxedError` which resembles Foundation's `NSError` class.
///
/// Use this registry to communicate rich error information without being beholden to `Foundation` user info dictionaries.
///
/// In the example below, any `MyError`s which are received over the wire will be converted back to a `MyError` enum, allowing handler functions to check for them:
///
///     enum MyError: Error, Codable {
///         case foo(Int)
///         case bar(String)
///     }
///
///     // then, at app startup time:
///
///     func someAppStartFunction() {
///        XPCErrorRegistry.shared.registerDomain(forErrorType: MyError.self)
///     }
///
///     // and later you can:
///
///     do {
///         try await connection.sendMessage(name: someName)
///     } catch let error as MyError {
///         switch error {
///         case .foo(let foo):
///             print("got foo: \(foo)")
///         case .bar(let bar):
///             print("got bar: \(bar)")
///         }
///     } catch {
///         print("got some other error")
///     }
public final class XPCErrorRegistry: Sendable {
    /// The shared `XPCErrorRegistry` instance.
    public static let shared = XPCErrorRegistry()

    @available(macOS 15.0, macCatalyst 18.0, *)
    private final class MutexWrapper: Sendable {
        let mutex: Mutex<[String: (Error & Codable).Type]>
        init(dict: [String: (Error & Codable).Type]) { mutex = Mutex(dict) }
    }

    private final class LegacyWrapper: @unchecked Sendable {
        let sema = DispatchSemaphore(value: 1)
        var dict: [String: (Error & Codable).Type]
        init(dict: [String: (Error & Codable).Type]) { self.dict = dict }
    }

    private let errorDomainMapWrapper: any Sendable = {
        let errorDomainMap: [String: (Error & Codable).Type] = [
            String(reflecting: XPCError.self): XPCError.self,
            String(reflecting: XPCConnection.Error.self): XPCConnection.Error.self,
        ]

        if #available(macOS 15.0, macCatalyst 18.0, *) {
            return MutexWrapper(dict: errorDomainMap)
        } else {
            return LegacyWrapper(dict: errorDomainMap)
        }
    }()

    private func withLock<T>(closure: (inout [String: (Error & Codable).Type]) throws -> T) rethrows -> T {
        if #available(macOS 15.0, macCatalyst 18.0, *) {
            return try (self.errorDomainMapWrapper as! MutexWrapper).mutex.withLock { try closure(&$0) }
        } else {
            let wrapper = errorDomainMapWrapper as! LegacyWrapper
            wrapper.sema.wait()
            defer { wrapper.sema.signal() }

            return try closure(&wrapper.dict)
        }
    }

    /// Register an error type.
    ///
    /// - Parameters:
    ///   - domain: An `NSError`-style domain string to associate with this error type. In most cases, you will just pass `nil` for this parameter, in which case the default value of `String(reflecting: errorType)` will be used instead.
    ///   - errorType: An error type to register. This type must conform to `Codable`.
    public func registerDomain(_ domain: String? = nil, forErrorType errorType: (Error & Codable).Type) {
        withLock { $0[domain ?? String(reflecting: errorType)] = errorType }
    }

    func encodeError(_ error: Error, domain: String? = nil) throws -> xpc_object_t {
        try withLock { _ in
            try XPCEncoder().encode(BoxedError(error: error, domain: domain))
        }
    }

    func decodeError(_ error: xpc_object_t) throws -> Error {
        let boxedError = try XPCDecoder().decode(type: BoxedError.self, from: error)

        return boxedError.encodedError ?? boxedError
    }

    func errorType(forDomain domain: String) -> (any (Error & Codable).Type)? {
        withLock { $0[domain] }
    }

    /// An error type representing errors for which we have an `NSError`-style domain and code, but do not know the exact error class.
    ///
    /// To avoid requiring Foundation, this type does not formally adopt the `CustomNSError` protocol, but implements methods which
    /// can be used as a default implementation of the protocol. Foundation clients may want to add an empty implementation as in the example below.
    ///
    ///     extension XPCErrorRegistry.BoxedError: CustomNSError {}
    public struct BoxedError: Error, Codable, Sendable {
        private enum Storage: Sendable {
            case codable(Error & Codable)
            case uncodable(code: Int)
        }

        private enum Key: CodingKey {
            case domain
            case code
            case encodedError
        }

        private let storage: Storage

        /// An `NSError`-style error domain.
        public let errorDomain: String

        /// An `NSError`-style error code.
        public var errorCode: Int {
            switch storage {
            case let .codable(error):
                return error._code
            case let .uncodable(code):
                return code
            }
        }

        /// An `NSError`-style user info dictionary.
        public var errorUserInfo: [String: Any] { [:] }

        /// Hacky default implementation for internal `Error` requirements.
        ///
        /// This isn't great, but it allows this class to have basic functionality without depending on Foundation.
        ///
        /// Give `BoxedError` a default implementation of `CustomNSError` in Foundation clients to avoid this being called.
        public var _domain: String { errorDomain }

        /// Hacky default implementation for internal `Error` requirements.
        ///
        /// This isn't great, but it allows this class to have basic functionality without depending on Foundation.
        ///
        /// Give `BoxedError` a default implementation of `CustomNSError` to avoid this being called.
        public var _code: Int { errorCode }

        fileprivate var encodedError: Error? {
            switch storage {
            case let .codable(error):
                return error
            case .uncodable:
                return nil
            }
        }

        init(domain: String, code: Int) {
            errorDomain = domain
            storage = .uncodable(code: code)
        }

        init(error: Error, domain: String? = nil) {
            errorDomain = domain ?? error._domain

            if let codableError = error as? (Error & Codable) {
                storage = .codable(codableError)
            } else {
                storage = .uncodable(code: error._code)
            }
        }

        /// Included for `Decodable` conformance.
        ///
        /// - Parameter decoder: A decoder.
        ///
        /// - Throws: Any errors that come up in the process of decoding the error.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)

            errorDomain = try container.decode(String.self, forKey: .domain)
            let code = try container.decode(Int.self, forKey: .code)

            if let codableType = XPCErrorRegistry.shared.errorType(forDomain: errorDomain),
               let codableError = try codableType.decodeIfPresent(from: container, key: .encodedError)
            {
                storage = .codable(codableError)
            } else {
                storage = .uncodable(code: code)
            }
        }

        /// Included for `Encodable` conformance.
        ///
        /// - Parameter encoder: An encoder.
        ///
        /// - Throws: Any errors that come up in the process of encoding the error.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)

            try container.encode(errorDomain, forKey: .domain)
            try container.encode(errorCode, forKey: .code)

            if case let .codable(error) = storage {
                try error.encode(into: &container, forKey: .encodedError)
            }
        }
    }
}

private extension Error where Self: Codable {
    static func decode(from error: xpc_object_t, using decoder: XPCDecoder) throws -> Error {
        try decoder.decode(type: self, from: error)
    }

    static func decodeIfPresent<Key>(from keyedContainer: KeyedDecodingContainer<Key>, key: Key) throws -> Self? {
        try keyedContainer.decodeIfPresent(Self.self, forKey: key)
    }

    func encode(using encoder: XPCEncoder) throws -> xpc_object_t {
        try encoder.encode(self)
    }

    func encode<Key>(into keyedContainer: inout KeyedEncodingContainer<Key>, forKey key: Key) throws {
        try keyedContainer.encode(self, forKey: key)
    }
}
