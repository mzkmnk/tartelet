public protocol Shell {
    func runExecutable(
        atPath executablePath: String,
        withArguments arguments: [String],
        environment: [String: String],
        standardInput: String?
    ) async throws -> String
}

public extension Shell {
    func runExecutable(
        atPath executablePath: String,
        withArguments arguments: [String]
    ) async throws -> String {
        try await runExecutable(
            atPath: executablePath,
            withArguments: arguments,
            environment: [:],
            standardInput: nil
        )
    }

    func runExecutable(
        atPath executablePath: String,
        withArguments arguments: [String],
        environment: [String: String]
    ) async throws -> String {
        try await runExecutable(
            atPath: executablePath,
            withArguments: arguments,
            environment: environment,
            standardInput: nil
        )
    }
}
