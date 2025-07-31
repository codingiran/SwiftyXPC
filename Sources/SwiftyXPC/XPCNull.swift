//
//  XPCNull.swift
//
//
//  Created by Charles Srstka on 12/27/21.
//

import Foundation

/// A class representing a null value in XPC.
public struct XPCNull: Codable, Sendable {
    /// The shared `XPCNull` instance.
    public static let shared = Self()
}
