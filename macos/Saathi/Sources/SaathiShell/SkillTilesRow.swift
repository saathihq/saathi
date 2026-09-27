//
//  SkillTilesRow.swift
//  SaathiShell
//
//  OpenClicky's "Add skills" row, ported: one 40 pt tile per library skill (click toggles it, a blue
//  check marks an active one) and a "+" tile. The "+" swaps the row for the "Create a skill…" field,
//  which asks the backend to draft a SKILL.md and activates it.
//
//  The store is optional because the panel is built before the shell has one — and because a test
//  that renders the island must not create `~/.saathi/skills` as a side effect. Without a store the
//  row is just the "+" tile, inert: the shape is right and nothing pretends to work.
//

import AppKit
import SaathiKit
import SwiftUI

struct SkillTilesRow: View {
    let store: SkillLibraryStore?
    /// Told when the composer opens and closes, so the panel can take the keyboard for exactly
    /// that long.
    var onComposingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        if let store {
            SkillTilesContent(store: store, onComposingChanged: onComposingChanged)
        } else {
            Button(action: {}) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.4))
                    .frame(width: SkillTilesContent.tileSize, height: SkillTilesContent.tileSize)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .disabled(true)
            .frame(height: SkillTilesContent.tileSize)
        }
    }
}

struct SkillTilesContent: View {
    @ObservedObject var store: SkillLibraryStore
    var onComposingChanged: (Bool) -> Void = { _ in }
    @State private var isComposing = false
    @State private var request = ""
    @FocusState private var isRequestFieldFocused: Bool

    static let tileSize: CGFloat = 40
    private var tileSize: CGFloat { Self.tileSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isComposing || store.isCreating {
                composer
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.librarySkills, id: \.id) { skill in
                            skillTile(skill)
                        }
                        Button(action: { isComposing = true; isRequestFieldFocused = true }) {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Color.white.opacity(0.85))
                                .frame(width: tileSize, height: tileSize)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.10)))
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .help("Create a skill, or open the skills folder from the tile's menu")
                        .contextMenu {
                            Button("Open skills folder") { NSWorkspace.shared.open(store.userSkillsDirectory) }
                        }
                    }
                }
                .frame(height: tileSize)
            }

            if let error = store.lastError {
                Text(error)
                    .font(.system(size: 9.5))
                    .foregroundColor(Color(hex: "#FF6B6B"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(error)
            }
        }
        .onChange(of: isComposing) { onComposingChanged($0) }
        // The view is torn down when the island collapses, taking `isComposing` with it and never
        // calling `onChange`; without this the panel would go on holding the keyboard for a field
        // that no longer exists.
        .onDisappear { onComposingChanged(false) }
    }

    private func skillTile(_ skill: SkillFile) -> some View {
        let isActive = store.activeIds.contains(skill.id)
        return Button(action: { store.setActive(skill.id, !isActive) }) {
            Text(String(skill.name.prefix(1)).uppercased())
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(isActive ? .white : Color.white.opacity(0.7))
                .frame(width: tileSize, height: tileSize)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isActive ? Color.white.opacity(0.16) : Color.white.opacity(0.08))
                )
                .overlay(alignment: .topTrailing) {
                    if isActive {
                        Image(systemName: "checkmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(DS.Colors.blue500))
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("\(skill.name) — \(skill.description)\n\(isActive ? "Active. Click to turn off." : "Off. Click to activate.")")
    }

    private var composer: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 10)).foregroundColor(Color.white.opacity(0.6))
            TextField("Create a skill…", text: $request)
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .focused($isRequestFieldFocused)
                .onSubmit(create)
                .onExitCommand { isComposing = false }
                .disabled(store.isCreating)
            if store.isCreating {
                ProgressView().controlSize(.mini)
            } else {
                Button(action: { isComposing = false; request = "" }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Cancel")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(height: tileSize)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.10)))
    }

    private func create() {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !store.isCreating else { return }
        Task { @MainActor in
            do {
                _ = try await store.createSkill(request: text)
                request = ""
                isComposing = false
            } catch {
                // The store publishes `lastError`; the composer stays open so it can be retried.
            }
        }
    }
}
