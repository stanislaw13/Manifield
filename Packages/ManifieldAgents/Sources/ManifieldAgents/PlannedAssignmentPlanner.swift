import Foundation
import ManifieldCore

public enum PlannedAssignmentPlanner {
    public static func plan(assignment: ResearchAssignment, program: ResearchProgram, runner: AgentRunner,
                            tools: [AgentTool], thinking: ThinkingLevel,
                            save: @escaping @Sendable (PlanDocument) async throws -> Void,
                            onActivity: @escaping @Sendable (AgentActivity) -> Void = { _ in }) async throws -> PlanDocument {
        guard assignment.mode == .planned, let planID = assignment.planID else {
            throw ResearchError(message: "Direct assignments do not have plans.")
        }
        let captured = PlannedAssignmentCapture()
        let submit = FunctionAgentTool(name: "save_assignment_plan", description: "Save this assignment's executable task list. Dependencies refer to earlier task numbers. Mark tasks with substantive mathematical conclusions for independent review. Planning does not require producing a result or solving the mathematics.", schema: #"{"type":"object","properties":{"approach":{"type":"string"},"tasks":{"type":"array","minItems":1,"items":{"type":"object","properties":{"title":{"type":"string"},"kind":{"type":"string"},"depends_on":{"type":"array","items":{"type":"integer"}},"review":{"type":"boolean"}},"required":["title","kind","depends_on","review"]}}},"required":["approach","tasks"]}"#, effect: .finish) { _, json in
            let input = jsonObject(json)
            let tasks = try PlannerValidation.parseTasks(input["tasks"] as? [[String: Any]] ?? [], context: "Assignment: ")
            guard !tasks.isEmpty else { throw ResearchError(message: "A planned assignment needs at least one task.") }
            let plan = PlanDocument(id: planID, goal: assignment.objective, status: .approved, runMode: .auto,
                tokenBudget: assignment.tokenLimit.runnerValue, goalText: assignment.objective,
                approach: try requiredResearchString(input, "approach"), tasks: tasks, program: program.id,
                guidance: assignment.constraints.joined(separator: "\n"))
            try await save(plan)
            await captured.set(plan)
            return "Assignment plan saved in program \(program.id)."
        }
        var config = AgentConfig(systemPrompt: """
            Plan the director's assigned mathematical work. Inspect the library as needed, then
            save one concise executable plan with save_assignment_plan. Stay within the assignment.
            Use research tasks for exploration and new items; prove: <item-id> for an existing lemma.
            A task depending on a lemma must depend on its reviewed proof task, not merely on writing
            a candidate statement. A counterexample audit should submit_problem_challenge if valid;
            it does not also need a solution claim. Any task may honestly report an unresolved gap.
            """, tools: tools + [submit], maxIterations: program.execution!.limits.toolCalls.runnerValue,
            thinking: thinking)
        config.stopOnToolEffect = true
        _ = try await runner.run(config: config, history: [.user("""
            Assignment: \(assignment.objective)
            Constraints: \(assignment.constraints.joined(separator: "\n"))
            Relevant item IDs: \(assignment.itemIDs.joined(separator: ", "))
            Supplied evidence IDs: \(assignment.evidenceIDs.joined(separator: ", "))
            \(ContextAssembly.pinnedTargetSection(program.activeTargetRevision))
            """)], onActivity: onActivity)
        guard let plan = await captured.plan else { throw ResearchError(message: "Planning ended without an executable plan.") }
        return plan
    }
}

private actor PlannedAssignmentCapture {
    var plan: PlanDocument?
    func set(_ plan: PlanDocument) { self.plan = plan }
}
