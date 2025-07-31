//
//  XPCEndpoint.swift
//  SwiftyXPC
//
//  Created by Charles Srstka on 7/24/21.
//

import Foundation
import XPC

/// A reference to an `XPCListener` object.
///
/// An `XPCEndpoint` can be passed over an active XPC connection, allowing the process on the other end to initialize a new `XPCConnection`
/// to communicate with it.
public struct XPCEndpoint: Codable, @unchecked Sendable {
    private struct CanOnlyBeDecodedByXPCDecoder: Error, Sendable {
        var localizedDescription: String { "XPCEndpoint can only be decoded via XPCDecoder." }
    }

    private struct CanOnlyBeEncodedByXPCEncoder: Error, Sendable {
        var localizedDescription: String { "XPCEndpoint can only be encoded via XPCEncoder." }
    }

    let endpoint: xpc_endpoint_t

    init(connection: xpc_connection_t) {
        endpoint = xpc_endpoint_create(connection)
    }

    init(endpoint: xpc_endpoint_t) {
        self.endpoint = endpoint
    }

    func makeConnection() -> xpc_connection_t {
        xpc_connection_create_from_endpoint(endpoint)
    }

    /// Required method for the purpose of conforming to the `Decodable` protocol.
    ///
    /// - Throws: Trying to decode this object from any decoder type other than `XPCDecoder` will result in an error.
    public init(from decoder: Decoder) throws {
        throw CanOnlyBeDecodedByXPCDecoder()
    }

    /// Required method for the purpose of conforming to the `Encodable` protocol.
    ///
    /// - Throws: Trying to encode this object from any encoder type other than `XPCEncoder` will result in an error.
    public func encode(to encoder: Encoder) throws {
        throw CanOnlyBeEncodedByXPCEncoder()
    }
}
