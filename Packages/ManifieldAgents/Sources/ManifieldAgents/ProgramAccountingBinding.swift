import Foundation
import ManifieldCore

/// The same binding is used by the app factory and integration tests. Missing membership is
/// an error, not an implicit unlimited assignment. Reconstructing it includes persisted spend.
public struct ProgramAccountingBinding: Sendable {
    public let programID: String
    public let subjectID: String
    public let assignmentID: String?
    public let assignmentBudget: ProgramUsageBudget?

    public init(program: ResearchProgram, subjectID: String, ledger: [ProgramUsageEntry]) throws {
        self.programID = program.id; self.subjectID = subjectID
        let spent = ledger.filter { $0.subjectID == subjectID }.reduce(0) { $0 + $1.actualTokens }
        if let execution = program.execution {
            guard let assignment = execution.assignments.first(where: {
                $0.id == subjectID || $0.planID == subjectID
            }), assignment.programID == program.id else {
                throw ResearchError(message: "Cannot bind accounting: assignment \(subjectID) is missing from program \(program.id).")
            }
            self.assignmentID = assignment.id
            self.assignmentBudget = ProgramUsageBudget(limit: assignment.tokenLimit, initialSpent: spent)
        } else if let assignment = program.workerAssignments.first(where: { $0.planID == subjectID }) {
            self.assignmentID = assignment.id
            self.assignmentBudget = ProgramUsageBudget(totalBudget: assignment.tokenBudget, initialSpent: spent)
        } else {
            guard program.branches.contains(where: { $0.planID == subjectID }) else {
                throw ResearchError(message: "Cannot bind accounting: branch \(subjectID) is missing from program \(program.id).")
            }
            self.assignmentID = nil; self.assignmentBudget = nil
        }
    }
}
