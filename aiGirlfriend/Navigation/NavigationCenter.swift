//
//  NavigationCenter.swift
//  aiGirlfriend
//
//  Bible projesindeki router pattern'i (NavigationCenter + NavigationDestination)
//  bu projeye uyarlandı. Aynı API: navigateToDestination / navigateToBacK.
//

import Foundation
import SwiftUI

@Observable class NavigationCenter {
    var path: NavigationPath = NavigationPath()

    @ViewBuilder
    func view(destination: NavigationDestination) -> some View {
        switch destination {
        case .chat(let character):
            ChatView(character: character)
        }
    }

    func navigateToDestination(destinaiton: NavigationDestination) {
        path.append(destinaiton)
    }

    func navigateToBacK() {
        path.removeLast()
    }
}

enum NavigationDestination: Hashable {
    case chat(character: Character)
}
