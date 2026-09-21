//
//  IslandAgentsView.swift
//  SaathiShell
//
//  OpenClicky's Agents tab. The layout is the port — a scrolling two-column grid of thread cards
//  under a day heading — and what it has to show is the part Saathi does not have yet: there is no
//  agent lane, so there are no threads and the tab says so in OpenClicky's own empty state.
//
//  Written against a thread list rather than around one, so the lane can be dropped in behind it
//  without this file changing shape.
//

import SaathiKit
import SwiftUI

/// One run of the doing lane, as the tab needs to draw it.
struct IslandAgentThread: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let updatedAt: Date
}

struct IslandAgentsView: View {
    @ObservedObject var model: IslandModel

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                // Saathi has no doing lane yet, on any lane. Said plainly rather than shown as an
                // empty grid that looks like something failed to load — and not as "connect a
                // backend", which sent someone with a working own-key install off to configure
                // something that would not have given them agents either.
                emptyState("No agents yet", detail: "Saathi can talk and look at the screen. Doing work is not wired up.")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private func emptyState(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundColor(Color.white.opacity(0.55))
            }
        }
        .padding(.top, 8)
    }
}

/// One agent thread, tinted by a stable per-thread hue — OpenClicky's `AgentCardView`. Unused until
/// the lane lands; kept because it is the port, and re-deriving it later is how the card ends up
/// looking almost but not quite like the one it is meant to match.
struct IslandAgentCardView: View {
    let thread: IslandAgentThread
    let onOpen: () -> Void

    private var hue: Double {
        let hash = thread.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Double(hash % 360) / 360.0
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                Text(thread.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let subtitle = thread.subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(Color.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(hue: hue, saturation: 0.45, brightness: 0.30))
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}
