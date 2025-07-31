//
//  XPCService.swift
//  Example XPC Service
//
//  Created by Charles Srstka on 5/5/22.
//

import SwiftyXPC

@main
final class XPCService: Sendable {
    static func main() {
        do {
            let xpcService = XPCService()

            // In an actual product, you should always set a real code signing requirement here, for security
            let requirement: String? = nil

            let serviceListener = try XPCListener(type: .service, codeSigningRequirement: requirement)

            serviceListener.setMessageHandler(name: CommandSet.capitalizeString) { try await xpcService.capitalizeString($0, string: $1) }
            serviceListener.setMessageHandler(name: CommandSet.longRunningTask) { try await xpcService.longRunningTask($0, endpoint: $1) }

            serviceListener.activate()
            fatalError("Should never get here")
        } catch {
            fatalError("Error while setting up XPC service: \(error)")
        }
    }

    private func capitalizeString(_: XPCConnection, string: String) async throws -> String {
        string.uppercased()
    }

    private func longRunningTask(_: XPCConnection, endpoint: XPCEndpoint) async throws {
        let remoteConnection = try XPCConnection(
            type: .remoteServiceFromEndpoint(endpoint),
            codeSigningRequirement: nil
        )

        remoteConnection.activate()

        for i in 0 ... 100 {
            try await Task.sleep(for: .milliseconds(100))

            try remoteConnection.sendOnewayMessage(
                name: LongRunningTaskMessage.progressNotification,
                message: Double(i) / 100.0
            )
        }
    }
}
