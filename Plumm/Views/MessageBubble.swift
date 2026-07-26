//
//  MessageBubble.swift
//  Tek bir mesaj balonu.
//

import SwiftUI

struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 40) }

            Text(message.content)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(message.isUser ? .white : .primary)
                .background(
                    message.isUser
                        ? AnyShapeStyle(Color.pink.gradient)
                        : AnyShapeStyle(Color(.secondarySystemBackground))
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            if !message.isUser { Spacer(minLength: 40) }
        }
        .padding(.horizontal)
    }
}
