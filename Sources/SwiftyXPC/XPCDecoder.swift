//
//  XPCDecoder.swift
//
//  Created by Charles Srstka on 11/2/21.
//

import Foundation
import System
@preconcurrency import XPC

private protocol XPCDecodingContainer: Sendable {
    var codingPath: [CodingKey] { get }
    var error: Error? { get }
}

private extension XPCDecodingContainer {
    func makeErrorContext(description: String, underlyingError: Error? = nil) -> DecodingError.Context {
        DecodingError.Context(codingPath: codingPath, debugDescription: description, underlyingError: underlyingError)
    }

    func checkType(xpcType: xpc_type_t, swiftType: Any.Type, xpc: xpc_object_t) throws {
        if xpc_get_type(xpc) != xpcType {
            let expectedTypeName = String(cString: xpc_type_get_name(xpcType))
            let actualTypeName = String(cString: xpc_type_get_name(xpc_get_type(xpc)))

            let context = makeErrorContext(
                description: "Incorrect XPC type; want \(expectedTypeName), got \(actualTypeName)"
            )

            throw DecodingError.typeMismatch(swiftType, context)
        }
    }

    func decodeNil(xpc: xpc_object_t) throws {
        try checkType(xpcType: XPC_TYPE_NULL, swiftType: Any?.self, xpc: xpc)
    }

    func decodeBool(xpc: xpc_object_t) throws -> Bool {
        try checkType(xpcType: XPC_TYPE_BOOL, swiftType: Bool.self, xpc: xpc)

        return xpc_bool_get_value(xpc)
    }

    func decodeInteger<I: FixedWidthInteger & SignedInteger>(xpc: xpc_object_t) throws -> I {
        try checkType(xpcType: XPC_TYPE_INT64, swiftType: I.self, xpc: xpc)
        let int = xpc_int64_get_value(xpc)

        if let i = I(exactly: int) {
            return i
        } else {
            let context = makeErrorContext(description: "Integer overflow; \(int) out of bounds")
            throw DecodingError.dataCorrupted(context)
        }
    }

    func decodeInteger<I: FixedWidthInteger & UnsignedInteger>(xpc: xpc_object_t) throws -> I {
        try checkType(xpcType: XPC_TYPE_UINT64, swiftType: I.self, xpc: xpc)
        let int = xpc_uint64_get_value(xpc)

        if let i = I(exactly: int) {
            return i
        } else {
            let context = makeErrorContext(description: "Integer overflow; \(int) out of bounds")
            throw DecodingError.dataCorrupted(context)
        }
    }

    func decodeFloatingPoint<F: BinaryFloatingPoint>(xpc: xpc_object_t) throws -> F {
        try checkType(xpcType: XPC_TYPE_DOUBLE, swiftType: F.self, xpc: xpc)

        return F(xpc_double_get_value(xpc))
    }

    func decodeString(xpc: xpc_object_t) throws -> String {
        try checkType(xpcType: XPC_TYPE_STRING, swiftType: String.self, xpc: xpc)

        let length = xpc_string_get_length(xpc)
        let pointer = xpc_string_get_string_ptr(xpc)

        return withExtendedLifetime(xpc) {
            UnsafeBufferPointer(start: pointer, count: length).withMemoryRebound(to: UInt8.self) {
                String(decoding: $0, as: UTF8.self)
            }
        }
    }
}

/// An implementation of `Decoder` that can decode values sent over an XPC connection.
public final class XPCDecoder: Sendable {
    private final class KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol, XPCDecodingContainer, @unchecked Sendable {
        let dict: xpc_object_t
        let codingPath: [CodingKey]
        var error: Error? { nil }

        private var checkedType = false

        var allKeys: [Key] {
            var keys: [Key] = []

            xpc_dictionary_apply(dict) { cKey, _ in
                let stringKey = String(cString: cKey)
                guard let key = Key(stringValue: stringKey) else {
                    preconditionFailure("Couldn't convert string '\(stringKey)' into key")
                }

                keys.append(key)
                return true
            }

            return keys
        }

        init(wrapping dict: xpc_object_t, codingPath: [CodingKey]) {
            self.dict = dict
            self.codingPath = codingPath
        }

        func contains(_ key: Key) -> Bool { (try? getValue(for: key)) != nil }

        private func getValue(for key: CodingKey, allowNull: Bool = false) throws -> xpc_object_t {
            guard let value = try getOptionalValue(for: key, allowNull: allowNull) else {
                let context = makeErrorContext(description: "No value for key '\(key.stringValue)'")
                throw DecodingError.valueNotFound(Any.self, context)
            }

            return value
        }

        private func getOptionalValue(for key: CodingKey, allowNull: Bool = false) throws -> xpc_object_t? {
            try key.stringValue.withCString {
                if !self.checkedType {
                    guard xpc_get_type(self.dict) == XPC_TYPE_DICTIONARY else {
                        let type = String(cString: xpc_type_get_name(xpc_get_type(dict)))
                        let desc = "Unexpected type for KeyedContainer wrapped object: expected dictionary, got \(type)"
                        let context = self.makeErrorContext(description: desc)

                        throw DecodingError.typeMismatch([String: Any].self, context)
                    }

                    self.checkedType = true
                }

                let value = xpc_dictionary_get_value(self.dict, $0)

                if !allowNull, let value = value, case .null = value.type {
                    return nil
                }

                return value
            }
        }

        func decodeNil(forKey key: Key) throws -> Bool {
            try xpc_get_type(getValue(for: key, allowNull: true)) == XPC_TYPE_NULL
        }

        func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
            try decodeBool(xpc: getValue(for: key))
        }

        func decode(_ type: String.Type, forKey key: Key) throws -> String {
            try decodeString(xpc: getValue(for: key))
        }

        func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
            try decodeFloatingPoint(xpc: getValue(for: key))
        }

        func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
            try decodeFloatingPoint(xpc: getValue(for: key))
        }

        func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
            try decodeInteger(xpc: getValue(for: key))
        }

        func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
            try decodeInteger(xpc: getValue(for: key))
        }

        func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
            try decodeInteger(xpc: getValue(for: key))
        }

        func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
            try decodeInteger(xpc: getValue(for: key))
        }

        func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
            try decodeInteger(xpc: getValue(for: key))
        }

        func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
            try decodeInteger(xpc: getValue(for: key))
        }

        func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
            try decodeInteger(xpc: getValue(for: key))
        }

        func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
            try decodeInteger(xpc: getValue(for: key))
        }

        func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
            try decodeInteger(xpc: getValue(for: key))
        }

        func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
            try decodeInteger(xpc: getValue(for: key))
        }

        func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? {
            try getOptionalValue(for: key).map { try self.decodeBool(xpc: $0) }
        }

        func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? {
            try getOptionalValue(for: key).map { try self.decodeString(xpc: $0) }
        }

        func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? {
            try getOptionalValue(for: key).map { try self.decodeFloatingPoint(xpc: $0) }
        }

        func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? {
            try getOptionalValue(for: key).map { try self.decodeFloatingPoint(xpc: $0) }
        }

        func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? {
            try getOptionalValue(for: key).map { try self.decodeInteger(xpc: $0) }
        }

        func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? {
            try getOptionalValue(for: key).map { try self.decodeInteger(xpc: $0) }
        }

        func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? {
            try getOptionalValue(for: key).map { try self.decodeInteger(xpc: $0) }
        }

        func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? {
            try getOptionalValue(for: key).map { try self.decodeInteger(xpc: $0) }
        }

        func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? {
            try getOptionalValue(for: key).map { try self.decodeInteger(xpc: $0) }
        }

        func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? {
            try getOptionalValue(for: key).map { try self.decodeInteger(xpc: $0) }
        }

        func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? {
            try getOptionalValue(for: key).map { try self.decodeInteger(xpc: $0) }
        }

        func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? {
            try getOptionalValue(for: key).map { try self.decodeInteger(xpc: $0) }
        }

        func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? {
            try getOptionalValue(for: key).map { try self.decodeInteger(xpc: $0) }
        }

        func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? {
            try getOptionalValue(for: key).map { try self.decodeInteger(xpc: $0) }
        }

        func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
            let xpc = try getValue(for: key, allowNull: true)
            let codingPath = self.codingPath + [key]

            if type == XPCFileDescriptor.self {
                try checkType(xpcType: XPC_TYPE_FD, swiftType: XPCFileDescriptor.self, xpc: xpc)

                return XPCFileDescriptor(fileDescriptor: xpc_fd_dup(xpc)) as! T
            } else if #available(macOS 11.0, *), type == FileDescriptor.self {
                try checkType(xpcType: XPC_TYPE_FD, swiftType: FileDescriptor.self, xpc: xpc)

                return FileDescriptor(rawValue: xpc_fd_dup(xpc)) as! T
            } else if type == XPCEndpoint.self {
                try checkType(xpcType: XPC_TYPE_ENDPOINT, swiftType: XPCEndpoint.self, xpc: xpc)

                return XPCEndpoint(endpoint: xpc) as! T
            } else if type == XPCNull.self {
                try checkType(xpcType: XPC_TYPE_NULL, swiftType: XPCNull.self, xpc: xpc)

                return XPCNull.shared as! T
            } else {
                return try _XPCDecoder(xpc: xpc, codingPath: codingPath).decodeTopLevelObject()
            }
        }

        func nestedContainer<NestedKey: CodingKey>(
            keyedBy type: NestedKey.Type,
            forKey key: Key
        ) throws -> KeyedDecodingContainer<NestedKey> {
            let value = try getValue(for: key)
            let codingPath = self.codingPath + [key]

            return KeyedDecodingContainer(KeyedContainer<NestedKey>(wrapping: value, codingPath: codingPath))
        }

        func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
            let value = try getValue(for: key)
            let codingPath = self.codingPath + [key]

            return UnkeyedContainer(wrapping: value, codingPath: codingPath)
        }

        func superDecoder() throws -> Decoder {
            let xpc = try getValue(for: XPCEncoder.Key.super)

            return _XPCDecoder(xpc: xpc, codingPath: codingPath + [XPCEncoder.Key.super])
        }

        func superDecoder(forKey key: Key) throws -> Decoder {
            let xpc = try getValue(for: XPCEncoder.Key.super)

            return _XPCDecoder(xpc: xpc, codingPath: codingPath + [key])
        }
    }

    private final class UnkeyedContainer: UnkeyedDecodingContainer, XPCDecodingContainer, @unchecked Sendable {
        private enum Storage: @unchecked Sendable {
            case array(xpc_object_t)
            case data(ContiguousArray<UInt8>)
            case error(Error)
        }

        let dict: xpc_object_t
        private let storage: Storage

        let codingPath: [CodingKey]
        var count: Int? {
            switch storage {
            case let .array(array):
                return xpc_array_get_count(array)
            case let .data(data):
                return data.count
            case .error:
                return nil
            }
        }

        var isAtEnd: Bool { currentIndex >= (count ?? 0) }
        private(set) var currentIndex: Int

        var error: Error? {
            switch storage {
            case let .error(error):
                return error
            default:
                return nil
            }
        }

        init(wrapping dict: xpc_object_t, codingPath: [CodingKey]) {
            self.dict = dict
            self.codingPath = codingPath
            currentIndex = 0

            do {
                guard xpc_get_type(dict) == XPC_TYPE_DICTIONARY else {
                    let type = String(cString: xpc_type_get_name(xpc_get_type(dict)))
                    let description = "Expected dictionary, got \(type))"
                    let context = DecodingError.Context(codingPath: codingPath, debugDescription: description)

                    throw DecodingError.typeMismatch([String: Any].self, context)
                }

                guard let xpc = xpc_dictionary_get_value(dict, XPCEncoder.UnkeyedContainerDictionaryKeys.contents) else {
                    let description = "Missing contents for unkeyed container"
                    let context = DecodingError.Context(codingPath: codingPath, debugDescription: description)

                    throw DecodingError.dataCorrupted(context)
                }

                switch xpc_get_type(xpc) {
                case XPC_TYPE_ARRAY:
                    storage = .array(xpc)
                case XPC_TYPE_DATA:
                    let length = xpc_data_get_length(xpc)
                    let bytes = ContiguousArray<UInt8>(unsafeUninitializedCapacity: length) { buffer, count in
                        if let ptr = buffer.baseAddress {
                            count = xpc_data_get_bytes(xpc, ptr, 0, length)
                        } else {
                            count = 0
                        }
                    }

                    if bytes.count != length {
                        let description = "Couldn't read data for unknown reason"
                        let context = DecodingError.Context(codingPath: codingPath, debugDescription: description)

                        throw DecodingError.dataCorrupted(context)
                    }

                    storage = .data(bytes)
                default:
                    let type = String(cString: xpc_type_get_name(xpc_get_type(xpc)))
                    let description = "Invalid XPC type for unkeyed container: \(type)"
                    let context = DecodingError.Context(codingPath: self.codingPath, debugDescription: description)

                    throw DecodingError.typeMismatch(Any.self, context)
                }
            } catch {
                storage = .error(error)
            }
        }

        private func readNext(xpcType: xpc_type_t?, swiftType: Any.Type) throws -> xpc_object_t {
            if isAtEnd {
                let context = makeErrorContext(description: "Premature end of array data")
                throw DecodingError.dataCorrupted(context)
            }

            switch storage {
            case let .array(array):
                defer { self.currentIndex += 1 }

                let value = xpc_array_get_value(array, currentIndex)

                if let xpcType = xpcType {
                    try checkType(xpcType: xpcType, swiftType: swiftType, xpc: value)
                }

                return value
            case .data:
                throw DecodingError.dataCorruptedError(
                    in: self,
                    debugDescription: "Tried to read non-byte value from data"
                )
            case let .error(error):
                throw error
            }
        }

        private func decodeFloatingPoint<F: BinaryFloatingPoint>() throws -> F {
            try decodeFloatingPoint(xpc: readNext(xpcType: XPC_TYPE_DOUBLE, swiftType: F.self))
        }

        private func decodeInteger<I: FixedWidthInteger & SignedInteger>() throws -> I {
            try decodeInteger(xpc: readNext(xpcType: nil, swiftType: I.self))
        }

        private func decodeInteger<I: FixedWidthInteger & UnsignedInteger>() throws -> I {
            try decodeInteger(xpc: readNext(xpcType: nil, swiftType: I.self))
        }

        private func decodeByte() throws -> UInt8 {
            if case let .data(bytes) = storage {
                if currentIndex > bytes.count {
                    let context = makeErrorContext(description: "Read past end of data buffer")
                    throw DecodingError.dataCorrupted(context)
                }

                defer { self.currentIndex += 1 }

                return bytes[currentIndex]
            } else {
                return try decodeInteger()
            }
        }

        private func decodeByte() throws -> Int8 {
            return try Int8(bitPattern: decodeByte())
        }

        func decodeNil() throws -> Bool {
            _ = try readNext(xpcType: XPC_TYPE_NULL, swiftType: Any.self)
            return true
        }

        func decode(_ type: Bool.Type) throws -> Bool {
            try decodeBool(xpc: readNext(xpcType: XPC_TYPE_BOOL, swiftType: type))
        }

        func decode(_ type: String.Type) throws -> String {
            try decodeString(xpc: readNext(xpcType: XPC_TYPE_STRING, swiftType: type))
        }

        func decode(_ type: Double.Type) throws -> Double { try decodeFloatingPoint() }
        func decode(_ type: Float.Type) throws -> Float { try decodeFloatingPoint() }
        func decode(_ type: Int.Type) throws -> Int { try decodeInteger() }
        func decode(_ type: Int8.Type) throws -> Int8 { try decodeByte() }
        func decode(_ type: Int16.Type) throws -> Int16 { try decodeInteger() }
        func decode(_ type: Int32.Type) throws -> Int32 { try decodeInteger() }
        func decode(_ type: Int64.Type) throws -> Int64 { try decodeInteger() }
        func decode(_ type: UInt.Type) throws -> UInt { try decodeInteger() }
        func decode(_ type: UInt8.Type) throws -> UInt8 { try decodeByte() }
        func decode(_ type: UInt16.Type) throws -> UInt16 { try decodeInteger() }
        func decode(_ type: UInt32.Type) throws -> UInt32 { try decodeInteger() }
        func decode(_ type: UInt64.Type) throws -> UInt64 { try decodeInteger() }

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            if type == Bool.self {
                return try decode(Bool.self) as! T
            } else if type == String.self {
                return try decode(String.self) as! T
            } else if type == Double.self {
                return try decode(Double.self) as! T
            } else if type == Float.self {
                return try decode(Float.self) as! T
            } else if type == Int.self {
                return try decode(Int.self) as! T
            } else if type == Int8.self {
                return try decode(Int8.self) as! T
            } else if type == Int16.self {
                return try decode(Int16.self) as! T
            } else if type == Int32.self {
                return try decode(Int32.self) as! T
            } else if type == Int64.self {
                return try decode(Int64.self) as! T
            } else if type == UInt.self {
                return try decode(UInt.self) as! T
            } else if type == UInt8.self {
                return try decode(UInt8.self) as! T
            } else if type == UInt16.self {
                return try decode(UInt16.self) as! T
            } else if type == UInt32.self {
                return try decode(UInt32.self) as! T
            } else if type == UInt64.self {
                return try decode(UInt64.self) as! T
            } else if type == XPCFileDescriptor.self {
                let xpc = try readNext(xpcType: XPC_TYPE_FD, swiftType: type)

                return XPCFileDescriptor(fileDescriptor: xpc_fd_dup(xpc)) as! T
            } else if #available(macOS 11.0, *), type == FileDescriptor.self {
                let xpc = try self.readNext(xpcType: XPC_TYPE_FD, swiftType: type)

                return FileDescriptor(rawValue: xpc_fd_dup(xpc)) as! T
            } else if type == XPCEndpoint.self {
                let xpc = try readNext(xpcType: XPC_TYPE_ENDPOINT, swiftType: type)

                return XPCEndpoint(endpoint: xpc) as! T
            } else if type == XPCNull.self {
                _ = try readNext(xpcType: XPC_TYPE_NULL, swiftType: XPCNull.self)

                return XPCNull.shared as! T
            } else {
                let codingPath = nextCodingPath()
                let xpc = try readNext(xpcType: nil, swiftType: type)

                return try _XPCDecoder(xpc: xpc, codingPath: codingPath).decodeTopLevelObject()
            }
        }

        func nestedContainer<NestedKey: CodingKey>(
            keyedBy type: NestedKey.Type
        ) throws -> KeyedDecodingContainer<NestedKey> {
            let codingPath = nextCodingPath()
            let xpc = try readNext(xpcType: nil, swiftType: Any.self)

            return KeyedDecodingContainer(KeyedContainer(wrapping: xpc, codingPath: codingPath))
        }

        func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
            let codingPath = nextCodingPath()
            let xpc = try readNext(xpcType: nil, swiftType: Any.self)

            return UnkeyedContainer(wrapping: xpc, codingPath: codingPath)
        }

        func superDecoder() throws -> Decoder {
            let key = XPCEncoder.Key.super

            guard let xpc = xpc_dictionary_get_value(dict, key.stringValue) else {
                let context = makeErrorContext(description: "No encoded value for super")
                throw DecodingError.valueNotFound(Any.self, context)
            }

            return _XPCDecoder(xpc: xpc, codingPath: codingPath + [key])
        }

        private func nextCodingPath() -> [CodingKey] {
            codingPath + [XPCEncoder.Key.arrayIndex(currentIndex)]
        }
    }

    private final class SingleValueContainer: SingleValueDecodingContainer, XPCDecodingContainer, @unchecked Sendable {
        let codingPath: [CodingKey]
        let xpc: xpc_object_t
        var error: Error? { nil }

        init(wrapping xpc: xpc_object_t, codingPath: [CodingKey]) {
            self.codingPath = codingPath
            self.xpc = xpc
        }

        func decodeNil() -> Bool {
            do {
                try decodeNil(xpc: xpc)
                return true
            } catch {
                return false
            }
        }

        func decode(_ type: Bool.Type) throws -> Bool { try decodeBool(xpc: xpc) }
        func decode(_ type: String.Type) throws -> String { try decodeString(xpc: xpc) }
        func decode(_ type: Double.Type) throws -> Double { try decodeFloatingPoint(xpc: xpc) }
        func decode(_ type: Float.Type) throws -> Float { try decodeFloatingPoint(xpc: xpc) }
        func decode(_ type: Int.Type) throws -> Int { try decodeInteger(xpc: xpc) }
        func decode(_ type: Int8.Type) throws -> Int8 { try decodeInteger(xpc: xpc) }
        func decode(_ type: Int16.Type) throws -> Int16 { try decodeInteger(xpc: xpc) }
        func decode(_ type: Int32.Type) throws -> Int32 { try decodeInteger(xpc: xpc) }
        func decode(_ type: Int64.Type) throws -> Int64 { try decodeInteger(xpc: xpc) }
        func decode(_ type: UInt.Type) throws -> UInt { try decodeInteger(xpc: xpc) }
        func decode(_ type: UInt8.Type) throws -> UInt8 { try decodeInteger(xpc: xpc) }
        func decode(_ type: UInt16.Type) throws -> UInt16 { try decodeInteger(xpc: xpc) }
        func decode(_ type: UInt32.Type) throws -> UInt32 { try decodeInteger(xpc: xpc) }
        func decode(_ type: UInt64.Type) throws -> UInt64 { try decodeInteger(xpc: xpc) }

        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            if type == XPCFileDescriptor.self {
                try checkType(xpcType: XPC_TYPE_FD, swiftType: XPCFileDescriptor.self, xpc: xpc)

                return XPCFileDescriptor(fileDescriptor: xpc_fd_dup(xpc)) as! T
            } else if #available(macOS 11.0, *), type == FileDescriptor.self {
                try checkType(xpcType: XPC_TYPE_FD, swiftType: XPCFileDescriptor.self, xpc: self.xpc)

                return FileDescriptor(rawValue: xpc_fd_dup(self.xpc)) as! T
            } else if type == XPCEndpoint.self {
                try checkType(xpcType: XPC_TYPE_ENDPOINT, swiftType: type, xpc: xpc)

                return XPCEndpoint(endpoint: xpc) as! T
            } else if type == XPCNull.self {
                try checkType(xpcType: XPC_TYPE_NULL, swiftType: XPCNull.self, xpc: xpc)

                return XPCNull.shared as! T
            } else {
                return try _XPCDecoder(xpc: xpc, codingPath: codingPath).decodeTopLevelObject()
            }
        }
    }

    private final class _XPCDecoder: Decoder, @unchecked Sendable {
        let xpc: xpc_object_t
        let codingPath: [CodingKey]
        var userInfo: [CodingUserInfoKey: Any] { [:] }
        var topLevelContainer: XPCDecodingContainer?

        init(xpc: xpc_object_t, codingPath: [CodingKey]) {
            self.xpc = xpc
            self.codingPath = codingPath
        }

        func decodeTopLevelObject<T: Decodable>() throws -> T {
            if #available(macOS 13.0, *),
               xpc_get_type(xpc) == XPC_TYPE_DICTIONARY,
               let content = xpc_dictionary_get_value(xpc, XPCEncoder.UnkeyedContainerDictionaryKeys.contents),
               xpc_get_type(content) == XPC_TYPE_DATA,
               let bytes = T.self as? any RangeReplaceableCollection<UInt8>.Type
            {
                let buffer = UnsafeRawBufferPointer(
                    start: xpc_data_get_bytes_ptr(content),
                    count: xpc_data_get_length(content)
                )

                return bytes.init(buffer) as! T
            }

            let value = try T(from: self)

            if let error = topLevelContainer?.error {
                throw error
            }

            return value
        }

        func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedDecodingContainer<Key> {
            precondition(topLevelContainer == nil, "Can only have one top-level container")

            let container = KeyedContainer<Key>(wrapping: xpc, codingPath: codingPath)
            topLevelContainer = container

            return KeyedDecodingContainer(container)
        }

        func unkeyedContainer() -> UnkeyedDecodingContainer {
            precondition(topLevelContainer == nil, "Can only have one top-level container")

            let container = UnkeyedContainer(wrapping: xpc, codingPath: codingPath)
            topLevelContainer = container

            return container
        }

        func singleValueContainer() -> SingleValueDecodingContainer {
            precondition(topLevelContainer == nil, "Can only have one top-level container")

            let container = SingleValueContainer(wrapping: xpc, codingPath: codingPath)
            topLevelContainer = container

            return container
        }
    }

    /// Create an `XPCDecoder`.
    public init() {}

    /// Decode an XPC object originating from a remote connection.
    ///
    /// - Parameters:
    ///   - type: The expected type of the decoded object.
    ///   - xpcObject: The XPC object to decode.
    ///
    /// - Returns: The decoded value.
    ///
    /// - Throws: Any errors that come up in the process of decoding the XPC object.
    public func decode<T: Decodable>(type: T.Type, from xpcObject: xpc_object_t) throws -> T {
        let decoder = _XPCDecoder(xpc: xpcObject, codingPath: [])
        let container = decoder.singleValueContainer()

        return try container.decode(type)
    }
}
