//
//  ProcessIDs.swift
//
//
//  Created by Charles Srstka on 10/14/23.
//

import Darwin
import SwiftyXPC
import System

// swift-format-ignore: AllPublicDeclarationsHaveDocumentation
public struct ProcessIDs: Codable, Sendable {
    public let pid: pid_t
    public let effectiveUID: uid_t
    public let effectiveGID: gid_t
    public let auditSessionID: au_asid_t

    public init(connection: XPCConnection) throws {
        pid = getpid()
        effectiveUID = geteuid()
        effectiveGID = getegid()
        auditSessionID = connection.auditSessionIdentifier
    }
}
