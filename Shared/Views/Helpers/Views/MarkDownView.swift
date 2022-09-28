//
//  MarkdownView.swift
//  Suwatte
//
//  Created by Mantton on 2022-03-07.
//

import SwiftUI

struct MarkDownView: View {
    let text: String
    var font: Font.Weight = .light
    @State private var formattedText: AttributedString?

    var body: some View {
        Group {
            if let formattedText = formattedText {
                Text(formattedText)
                    .fontWeight(font)
            } else {
                Text(text)
                    .fontWeight(font)
            }
        }
        .onAppear(perform: formatText)
    }

    private func formatText() {
        try? formattedText = AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    }
}
struct HTMLStringView: View {
    @State private var formatted = ""
    var text: String
    var body: some View {
        Text(formatted)
            .task {
                formatted = text
                if let x = try? text.htmlToString() {
                    formatted = x
                }
            }
    }
}


extension String {
    fileprivate func htmlToString() throws -> String {
        try NSAttributedString(data: self.data(using: .utf16)!,
                                        options: [.documentType: NSAttributedString.DocumentType.html],
                                        documentAttributes: nil).string
    }
}

