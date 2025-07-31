//
//  XPCListener.swift
//  SwiftyXPC
//
//  Created by Charles Srstka on 8/8/21.
//

import Foundation
import os
import System
import XPC

/// A listener that waits for new incoming connections, configures them, and accepts or rejects them.
///
/// Each XPC service, launchd agent, or launchd daemon typically has at least one `XPCListener` object that listens for connections to a specified service name.
///
/// Create an `XPCListener` via `init(type:codeSigningRequirement:)`.
///
/// Use the `setMessageHandler` family of functions to set up handler functions to receive messages.
///
/// A listener must receive `.activate()` before it can receive any messages.
public final class XPCListener: @unchecked Sendable {
    /// The type of the listener.
    public enum ListenerType: Sendable {
        /// An anonymous listener connection. This can be passed to other processes by embedding its `endpoint` in an XPC message.
        case anonymous
        /// A service listener used to listen for incoming connections in an embedded XPC service. Requires the service’s `Info.plist` to be configured correctly.
        case service
        /// A service listener used to listen for incoming connections in a Mach service, advertised to the system by the given `name`.
        case machService(name: String)
    }

    private enum Backing: Sendable {
        case xpcMain
        case connection(connection: XPCConnection, isMulti: Bool)
    }

    /// The type of this listener.
    public let type: ListenerType
    private let backing: Backing

    /// Returns an endpoint object that may be sent over an existing connection.
    ///
    /// The receiver of the endpoint can use this object to create a new connection to this `XPCListener` object.
    /// The resulting `XPCEndpoint` object uniquely names this listener object across connections.
    public var endpoint: XPCEndpoint {
        switch backing {
        case .xpcMain:
            fatalError("Can't get endpoint for main service listener")
        case let .connection(connection, _):
            return connection.makeEndpoint()
        }
    }

    // because xpc_main takes a C function that can't capture any context, we need to store the xpc_main listener globally
    private class XPCMainListenerStorage: @unchecked Sendable {
        var xpcMainListener: XPCListener?
    }

    private static let xpcMainListenerStorage = XPCMainListenerStorage()

    private var _messageHandlers: [String: XPCConnection.MessageHandler] = [:]
    private var messageHandlers: [String: XPCConnection.MessageHandler] {
        if case let .connection(connection, isMulti) = backing, !isMulti {
            return connection.messageHandlers
        }

        return _messageHandlers
    }

    /// Set a message handler for an incoming message, identified by the `name` parameter, without taking any arguments or returning any value.
    ///
    /// - Parameters:
    ///   - name: A name uniquely identifying the message. This must match the name that the sending process passes to `sendMessage(name:)`.
    ///   - handler: Pass a function that processes the message, optionally throwing an error.
    public func setMessageHandler(name: String, handler: @Sendable @escaping (XPCConnection) async throws -> Void) {
        setMessageHandler(name: name) { (connection: XPCConnection, _: XPCNull) async throws -> XPCNull in
            try await handler(connection)
            return XPCNull.shared
        }
    }

    /// Set a message handler for an incoming message, identified by the `name` parameter, taking an argument but not returning any value.
    ///
    /// - Parameters:
    ///   - name: A name uniquely identifying the message. This must match the name that the sending process passes to `sendMessage(name:request:)`.
    ///   - handler: Pass a function that processes the message, optionall throwing an error. The request value must
    ///     conform to the `Codable` protocol, and will automatically be type-checked by `XPCConnection` upon receiving a message.
    public func setMessageHandler<Request: Codable>(
        name: String,
        handler: @Sendable @escaping (XPCConnection, Request) async throws -> Void
    ) {
        setMessageHandler(name: name) { (connection: XPCConnection, request: Request) async throws -> XPCNull in
            try await handler(connection, request)
            return XPCNull.shared
        }
    }

    /// Set a message handler for an incoming message, identified by the `name` parameter, without taking any arguments but returning a value.
    ///
    /// - Parameters:
    ///   - name: A name uniquely identifying the message. This must match the name that the sending process passes to `sendMessage(name:)`.
    ///   - handler: Pass a function that processes the message and either returns a value or throws an error. The return value must
    ///     conform to the `Codable` protocol.
    public func setMessageHandler<Response: Codable>(
        name: String,
        handler: @Sendable @escaping (XPCConnection) async throws -> Response
    ) {
        setMessageHandler(name: name) { (connection: XPCConnection, _: XPCNull) async throws -> Response in
            try await handler(connection)
        }
    }

    /// Set a message handler for an incoming message, identified by the `name` parameter, taking an argument and returning a value.
    ///
    /// Example usage:
    ///
    ///     listener.setMessageHandler(
    ///         name: "com.example.SayHello",
    ///         handler: self.sayHello
    ///     )
    ///
    ///     // ... later in the same class ...
    ///
    ///     func sayHello(
    ///         connection: XPCConnection,
    ///         message: String
    ///     ) async throws -> String {
    ///         self.logger.notice("Caller sent message: \(message)")
    ///
    ///         if message == "Hello, World!" {
    ///             return "Hello back!"
    ///         } else {
    ///             throw RudeCallerError(message: "You didn't say hello!")
    ///         }
    ///     }
    ///
    /// - Parameters:
    ///   - name: A name uniquely identifying the message. This must match the name that the sending process passes to `sendMessage(name:request:)`.
    ///   - handler: Pass a function that processes the message and either returns a value or throws an error. Both the request and return values must conform to the `Codable` protocol. The types are automatically type-checked by `XPCConnection` upon receiving a message.
    public func setMessageHandler<Request: Codable, Response: Codable>(
        name: String,
        handler: @Sendable @escaping (XPCConnection, Request) async throws -> Response
    ) {
        if case let .connection(connection, isMulti) = backing, !isMulti {
            connection.setMessageHandler(name: name, handler: handler)
            return
        }

        _messageHandlers[name] = XPCConnection.MessageHandler(closure: handler)
    }

    private let _codeSigningRequirement: String?

    private var _errorHandler: XPCConnection.ErrorHandler?

    /// A handler that will be called if a communication error occurs.
    public var errorHandler: XPCConnection.ErrorHandler? {
        get {
            if case let .connection(connection, isMulti) = backing, !isMulti {
                return connection.errorHandler
            }

            return _errorHandler
        }
        set {
            if case let .connection(connection, isMulti) = backing, !isMulti {
                connection.errorHandler = newValue
            } else {
                _errorHandler = newValue
            }
        }
    }

    /// Create a new `XPCListener`.
    ///
    /// - Parameters:
    ///   - type: The type of listener to create. Check the documentation for `ListenerType` for possible values.
    ///   - requirement: An optional code signing requirement. If specified, the listener will reject all messages from processes that do not meet the specified requirement.
    ///
    /// - Throws: Any errors that come up in the process of creating the listener.
    public init(type: ListenerType, codeSigningRequirement requirement: String?) throws {
        self.type = type

        switch type {
        case .anonymous:
            _codeSigningRequirement = nil
            backing = try .connection(
                connection: XPCConnection.makeAnonymousListenerConnection(codeSigningRequirement: requirement),
                isMulti: false
            )
        case .service:
            backing = .xpcMain
            _codeSigningRequirement = requirement
        case let .machService(name):
            let connection = try XPCConnection(
                machServiceName: name,
                flags: XPC_CONNECTION_MACH_SERVICE_LISTENER,
                codeSigningRequirement: requirement
            )

            _codeSigningRequirement = nil
            backing = .connection(connection: connection, isMulti: true)
        }

        setUpConnection(requirement: requirement)
    }

    private func setUpConnection(requirement: String?) {
        switch backing {
        case .xpcMain:
            Self.xpcMainListenerStorage.xpcMainListener = self
        case .connection(let connection, _):
            connection.customEventHandler = { [weak self] in
                do {
                    guard case .connection = $0.type else {
                        preconditionFailure("XPCListener is required to have connection backing when run as a Mach service")
                    }

                    let newConnection = try XPCConnection(connection: $0, codeSigningRequirement: requirement)

                    newConnection.messageHandlers = self?.messageHandlers ?? [:]
                    newConnection.errorHandler = self?.errorHandler

                    newConnection.activate()
                } catch {
                    self?.errorHandler?(connection, error)
                }
            }
        }
    }

    /// Cancels the listener and ensures that its event handler doesn't fire again.
    ///
    /// After this call, any messages that have not yet been sent will be discarded, and the connection will be unwound.
    /// If there are messages that are awaiting replies, they will receive the `XPCError.connectionInvalid` error.
    public func cancel() {
        switch backing {
        case .xpcMain:
            fatalError("XPC service listener cannot be cancelled")
        case let .connection(connection, _):
            connection.cancel()
        }
    }

    /// Activate the connection.
    ///
    /// Listeners start in an inactive state, so you must call `activate()` on a connection before it will send or receive any messages.
    public func activate() {
        switch backing {
        case .xpcMain:
            xpc_main {
                do {
                    let xpcMainListener = XPCListener.xpcMainListenerStorage.xpcMainListener!

                    let connection = try XPCConnection(
                        connection: $0,
                        codeSigningRequirement: xpcMainListener._codeSigningRequirement
                    )

                    connection.messageHandlers = xpcMainListener._messageHandlers
                    connection.errorHandler = xpcMainListener._errorHandler

                    connection.activate()
                } catch {
                    os_log(.fault, "Can’t initialize incoming XPC connection!")
                }
            }
        case let .connection(connection, _):
            connection.activate()
        }
    }

    /// Suspends the listener so that the event handler block doesn't fire and the listener doesn't attempt to send any messages it has in its queue.
    ///
    /// All calls to `suspend()` must be balanced with calls to `resume()` before releasing the last reference to the listener.
    ///
    /// Suspension is asynchronous and non-preemptive, and therefore this method will not interrupt the execution of an already-running event handler block.
    /// If the event handler is executing at the time of this call, it will finish, and then the listener will be suspended before the next scheduled invocation of
    /// the event handler. The XPC runtime guarantees this non-preemptiveness even for concurrent target queues.
    ///
    /// Listeners initialized with the `.service` type cannot be suspended, so calling `.suspend()` on these listeners is considered an error.
    public func suspend() {
        switch backing {
        case .xpcMain:
            fatalError("XPC service listener cannot be suspended")
        case let .connection(connection, _):
            connection.suspend()
        }
    }

    /// Resumes a suspended listener.
    ///
    /// In order for a listener to become live, every call to `suspend()` must be balanced with a call to `resume()`.
    /// Calling `resume()` more times than `suspend()` has been called is considered an error.
    ///
    /// Listeners initialized with the `.service` type cannot be suspended, so calling `.resume()` on these listeners is considered an error.
    public func resume() {
        switch backing {
        case .xpcMain:
            fatalError("XPC service listener cannot be resumed")
        case let .connection(connection, _):
            connection.resume()
        }
    }
}
