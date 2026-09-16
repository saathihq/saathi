//
//  ExpressionTable.swift
//  SaathiShell
//
//  One face per state. Lives here rather than in SaathiKit because the kit does not know the
//  character exists; this is the only module that sees both.
//

import SaathiKit
import SaathiMascot

public extension CompanionState {
    var mascotExpression: MascotExpression {
        switch self {
        case .asleep: return .sleeping
        case .idle: return .idle
        case .listening: return .listening
        case .thinking: return .thinking
        case .speaking: return .dictating
        case .showingStep: return .working
        case .celebrating: return .celebrate
        case .alert: return .alerting
        case .poweringDown: return .poweringDown
        }
    }
}
