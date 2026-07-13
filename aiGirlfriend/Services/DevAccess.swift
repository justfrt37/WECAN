//
//  DevAccess.swift
//  TEMPORARY — gates DEV-only Profile-tab panels (token testing, curated
//  character creation) to the two active dev anonymous-auth uids. This is
//  a hardcoded allowlist, not a build flag: `#if DEBUG` doesn't work here
//  because TestFlight/release builds strip debug code, and these dev
//  devices run the same build everyone else does. Server-side edge
//  functions (dev-upload-image, dev-list-voices, dev-create-character,
//  dev-token-tools) independently re-check the SAME two uids from the JWT —
//  this client-side check only controls whether the panel is even shown.
//
//  DELETE alongside the DEV panels once real RevenueCat/StoreKit purchases
//  are wired up and curated-character creation is retired.
//

import Foundation

enum DevAccess {
    /// Kept in sync with the DEV_UIDS allowlist duplicated in
    /// dev-upload-image, dev-list-voices, dev-create-character, and
    /// dev-token-tools' equivalent (see project memory).
    static let devUserIDs: Set<String> = [
        "81565166-be1e-48f6-a580-3f8b78e378e2",
        "9bd6b9c6-a498-42dd-a337-33a70100117f",
    ]

    // TEMP TESTING (2026-07-12) — forced true to show dev panels to every
    // user while testing Civitai image-gen swap. REVERT to the UID-gated
    // check below once testing is done. Note: server-side dev-* edge
    // functions still independently check devUserIDs from the JWT, so
    // actual dev actions (token add/remove etc.) will still fail for
    // non-dev UIDs even with the panel visible — this only affects
    // client-side visibility.
    static var isDev: Bool {
        return true
        // guard let uid = UserDefaultsManager.shared.userId else { return false }
        // return devUserIDs.contains(uid)
    }
}
