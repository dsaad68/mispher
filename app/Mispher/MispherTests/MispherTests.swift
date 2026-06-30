//
//  MispherTests.swift
//  MispherTests
//
//  Created by Daniel Saad on 04.06.26.
//

@testable import Mispher
import Testing

/// Tests for `TranslationClient.clean`, which sanitizes the model's reply before
/// it's shown beneath the transcript: trim whitespace and drop a stray trailing
/// chat-end token if the server ever leaks one into the content.
struct TranslationClientCleanTests {
    @Test func passesThroughCleanText() {
        #expect(TranslationClient.clean("Are you Teacher Wang's sister?")
            == "Are you Teacher Wang's sister?")
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(TranslationClient.clean("  \n  Hello there \n ") == "Hello there")
    }

    @Test func stripsTrailingChatEndToken() {
        #expect(TranslationClient.clean("Hello there<|im_end|>") == "Hello there")
    }

    @Test func dropsAnythingAfterChatEndToken() {
        #expect(TranslationClient.clean("Hello<|im_end|>\n<|im_start|>user\nignore me") == "Hello")
    }

    @Test func trimsAfterStrippingToken() {
        #expect(TranslationClient.clean("  Hello world  <|im_end|>  ") == "Hello world")
    }

    @Test func emptyStaysEmpty() {
        #expect(TranslationClient.clean("") == "")
    }

    @Test func preservesInternalPunctuationAndSpaces() {
        #expect(TranslationClient.clean("Yes, you must be his students, right?")
            == "Yes, you must be his students, right?")
    }
}
