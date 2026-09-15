//
//  Expression.swift
//  SaathiMascot
//
//  Every face the character can hold. The raw values are the keys in mascot.json and the names
//  in the web demo, so the three never drift; a test pins that.
//

public enum Expression: String, CaseIterable, Sendable {
    case sleeping, waking, idle, listening, thinking, searching, working, excited, surprised,
         suspicious, angry, drowsy, happy, curious, confused, bored, proud, shy, sad, laughing,
         scared, playful, celebrate, orbit, radar, progress, spawning, humming, loading, dictating,
         sending, receiving, uploading, writing, notifying, alerting, bouncing, dragging
    case poweringDown = "powering-down"
}
