import Foundation

/// A tool whose operation receives the provider call ID for durable idempotency.
public struct FunctionAgentTool: AgentTool {
    public let spec: ToolSpec
    public let turnEffect: AgentToolEffect
    private let operation: @Sendable (String, String) async throws -> String
    public init(name: String, description: String, schema: String,
                effect: AgentToolEffect = .none,
                operation: @escaping @Sendable (String, String) async throws -> String) {
        self.spec = ToolSpec(name: name, description: description, inputSchemaJSON: schema)
        self.turnEffect = effect; self.operation = operation
    }
    public func execute(inputJSON: String) async throws -> String {
        try await operation(UUID().uuidString, inputJSON)
    }
    public func execute(callID: String, inputJSON: String) async throws -> String {
        try await operation(callID, inputJSON)
    }
}
