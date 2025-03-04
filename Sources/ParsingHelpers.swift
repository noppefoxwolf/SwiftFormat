//
//  ParsingHelpers.swift
//  SwiftFormat
//
//  Created by Nick Lockwood on 08/04/2019.
//  Copyright © 2019 Nick Lockwood. All rights reserved.
//

import Foundation

// MARK: shared helper methods

public extension Formatter {
    /// Returns the index of the first token of the line containing the specified index
    func startOfLine(at index: Int, excludingIndent: Bool = false) -> Int {
        var index = index
        while let token = token(at: index - 1) {
            if case .linebreak = token {
                break
            }
            index -= 1
        }
        if excludingIndent, case .space = tokens[index] {
            return index + 1
        }
        return index
    }

    /// Returns the index of the linebreak token at the end of the line containing the specified index
    func endOfLine(at index: Int) -> Int {
        var index = index
        while let token = token(at: index) {
            if case .linebreak = token {
                break
            }
            index += 1
        }
        return index
    }

    /// Whether or not the two indices represent tokens on the same line
    func onSameLine(_ lhs: Int, _ rhs: Int) -> Bool {
        startOfLine(at: lhs) == startOfLine(at: rhs)
    }

    /// Returns the space at the start of the line containing the specified index
    func indentForLine(at index: Int) -> String {
        if case let .space(string)? = token(at: startOfLine(at: index)) {
            return string
        }
        return ""
    }

    /// Returns the length (in characters) of the specified token
    func tokenLength(_ token: Token) -> Int {
        let tabWidth = options.tabWidth > 0 ? options.tabWidth : options.indent.count
        return token.columnWidth(tabWidth: tabWidth)
    }

    /// Returns the length (in characters) of the line at the specified index
    func lineLength(at index: Int) -> Int {
        lineLength(upTo: endOfLine(at: index))
    }

    /// Returns the length (in characters) up to (but not including) the specified token index
    func lineLength(upTo index: Int) -> Int {
        lineLength(from: startOfLine(at: index), upTo: index)
    }

    /// Returns the length (in characters) of the specified token range
    func lineLength(from start: Int, upTo end: Int) -> Int {
        if options.assetLiteralWidth == .actualWidth {
            return tokens[start ..< end].reduce(0) { total, token in
                total + tokenLength(token)
            }
        }
        var length = 0
        var index = start
        while index < end {
            let token = tokens[index]
            switch token {
            case .keyword("#colorLiteral"), .keyword("#imageLiteral"):
                guard let startIndex = self.index(of: .startOfScope("("), after: index),
                      let endIndex = endOfScope(at: startIndex)
                else {
                    fallthrough
                }
                length += 2 // visible length of asset literal in Xcode
                index = endIndex + 1
            default:
                length += tokenLength(token)
                index += 1
            }
        }
        return length
    }

    /// Returns white space made up of indent characters equivalent to the specified width
    func spaceEquivalentToWidth(_ width: Int) -> String {
        if !options.smartTabs, options.useTabs, options.tabWidth > 0 {
            let tabs = width / options.tabWidth
            let remainder = width % options.tabWidth
            return String(repeating: "\t", count: tabs) + String(repeating: " ", count: remainder)
        }
        return String(repeating: " ", count: width)
    }

    /// Returns white space made up of indent characters equvialent to the specified token range
    func spaceEquivalentToTokens(from start: Int, upTo end: Int) -> String {
        if !options.smartTabs, options.useTabs, options.tabWidth > 0 {
            return spaceEquivalentToWidth(lineLength(from: start, upTo: end))
        }
        var result = ""
        var index = start
        while index < end {
            let token = tokens[index]
            switch token {
            case let .space(string):
                result += string
            case .keyword("#colorLiteral"), .keyword("#imageLiteral"):
                guard let startIndex = self.index(of: .startOfScope("("), after: index),
                      let endIndex = endOfScope(at: startIndex)
                else {
                    fallthrough
                }
                let length = lineLength(from: index, upTo: endIndex + 1)
                result += String(repeating: " ", count: length)
                index = endIndex
            default:
                result += String(repeating: " ", count: tokenLength(token))
            }
            index += 1
        }
        return result
    }

    /// Returns the starting token for the containing scope at the specified index
    func currentScope(at index: Int) -> Token? {
        last(.startOfScope, before: index)
    }

    /// Returns the index of the ending token for the current scope
    func endOfScope(at index: Int) -> Int? {
        // TODO: should this return the closing `}` for `switch { ...` instead of nested `case`?
        var startIndex: Int
        guard var startToken = token(at: index) else { return nil }
        if case .startOfScope = startToken {
            startIndex = index
        } else if let index = self.index(of: .startOfScope, before: index) {
            startToken = tokens[index]
            startIndex = index
        } else {
            return nil
        }
        guard startToken == .startOfScope("{") else {
            return self.index(after: startIndex, where: {
                $0.isEndOfScope(startToken)
            })
        }
        while let endIndex = self.index(after: startIndex, where: {
            $0.isEndOfScope(startToken)
        }), let token = token(at: endIndex) {
            if token == .endOfScope("}") {
                return endIndex
            }
            startIndex = endIndex
            startToken = token
        }
        return nil
    }

    /// Returns the end of the expression at the specified index, optionally stopping at any of the specified tokens
    func endOfExpression(at index: Int, upTo delimiters: [Token]) -> Int? {
        var index: Int? = index
        if token(at: index!)?.isEndOfScope == true {
            index = self.index(of: .nonSpaceOrLinebreak, after: index!)
        }
        var lastIndex = index
        var wasOperator = true
        while var i = index {
            let token = tokens[i]
            if delimiters.contains(token) {
                return lastIndex
            }
            switch token {
            case .operator(_, .infix):
                wasOperator = true
            case .operator(_, .prefix) where wasOperator, .operator(_, .postfix):
                break
            case .keyword("as"):
                wasOperator = true
                if case let .operator(name, .postfix)? = self.token(at: i + 1),
                   ["?", "!"].contains(name)
                {
                    i += 1
                }
            case .number, .identifier:
                guard wasOperator else {
                    return lastIndex
                }
                wasOperator = false
            case .startOfScope("<"),
                 .startOfScope where wasOperator,
                 .startOfScope("{") where isStartOfClosure(at: i),
                 .startOfScope("(") where isSubscriptOrFunctionCall(at: i),
                 .startOfScope("[") where isSubscriptOrFunctionCall(at: i):
                wasOperator = false
                guard let endIndex = endOfScope(at: i) else {
                    return nil
                }
                i = endIndex
            default:
                return lastIndex
            }
            lastIndex = i
            index = self.index(of: .nonSpaceOrCommentOrLinebreak, after: i)
        }
        return lastIndex
    }
}

enum ScopeType {
    case array
    case arrayType
    case captureList
    case dictionary
    case dictionaryType
    case `subscript`
    case tuple
    case tupleType

    var isType: Bool {
        switch self {
        case .array, .captureList, .dictionary, .subscript, .tuple:
            return false
        case .arrayType, .dictionaryType, .tupleType:
            return true
        }
    }
}

extension Formatter {
    /// Returns true if a token at this position is expected to be a type.
    /// Note: Doesn't actually look at the token to see if it plausibly *is* a type.
    func isTypePosition(at index: Int) -> Bool {
        guard let prevIndex = self.index(
            of: .nonSpaceOrCommentOrLinebreak,
            before: index
        ) else {
            return false
        }
        switch tokens[prevIndex] {
        case .operator("->", .infix), .startOfScope("<"),
             .keyword("is"), .keyword("as"):
            return true
        case .delimiter(":"), .delimiter(","):
            // Check for type declaration
            if let scopeType = scopeType(at: index) {
                return scopeType.isType
            }
            if let token = last(.keyword, before: index),
               [.keyword("let"), .keyword("var")].contains(token)
            {
                return true
            }
            fallthrough
        default:
            return scopeType(at: index)?.isType ?? false
        }
    }

    /// Returns the type of the containing scope at the specified index
    func scopeType(at index: Int) -> ScopeType? {
        guard let token = token(at: index) else {
            return nil
        }
        guard case .startOfScope = token else {
            guard let startIndex = self.index(of: .startOfScope, before: index) else {
                return nil
            }
            return scopeType(at: startIndex)
        }
        switch token {
        case .startOfScope("["), .startOfScope("("):
            guard let endIndex = endOfScope(at: index) else {
                return nil
            }
            var isType = false
            if let nextIndex = self.index(of: .nonSpaceOrCommentOrLinebreak, after: endIndex, if: {
                $0.isOperator(".")
            }), [.identifier("self"), .identifier("init")]
                .contains(next(.nonSpaceOrCommentOrLinebreak, after: nextIndex))
            {
                isType = true
            } else if next(.nonSpaceOrComment, after: endIndex) == .startOfScope("(") {
                isType = true
            } else if let prevIndex = self.index(of: .nonSpaceOrCommentOrLinebreak, before: index) {
                switch tokens[prevIndex] {
                case .identifier, .endOfScope(")"), .endOfScope("]"),
                     .operator("?", _), .operator("!", _),
                     .endOfScope where token.isStringDelimiter:
                    if tokens[prevIndex + 1 ..< index].contains(where: { $0.isLinebreak }) {
                        break
                    }
                    return .subscript
                case .startOfScope("{") where isInClosureArguments(at: index):
                    return .captureList
                case .delimiter(":"), .delimiter(","):
                    // Check for type declaration
                    if let scopeStart = self.index(of: .startOfScope, before: prevIndex) {
                        switch tokens[scopeStart] {
                        case .startOfScope("("):
                            if last(.keyword, before: scopeStart) == .keyword("func") {
                                isType = true
                                break
                            }
                            fallthrough
                        case .startOfScope("["):
                            guard let type = scopeType(at: scopeStart) else {
                                return nil
                            }
                            isType = type.isType
                        default:
                            break
                        }
                    }
                    if let token = last(.keyword, before: index),
                       [.keyword("let"), .keyword("var")].contains(token)
                    {
                        isType = true
                    }
                case .operator("->", _), .startOfScope("<"):
                    isType = true
                case .startOfScope("["), .startOfScope("("):
                    guard let type = scopeType(at: prevIndex) else {
                        return nil
                    }
                    isType = type.isType
                case .operator("=", .infix):
                    isType = lastSignificantKeyword(at: prevIndex) == "typealias"
                default:
                    break
                }
            }
            if token == .startOfScope("(") {
                return isType ? .tupleType : .tuple
            }
            if !isType {
                return self.index(of: .delimiter(":"), after: index) == nil ? .array : .dictionary
            }
            return self.index(of: .delimiter(":"), after: index) == nil ? .arrayType : .dictionaryType
        default:
            return nil
        }
    }

    /// Returns true if the modifiers list for the given declaration contain a
    /// modifier matching the specified predicate
    func modifiersForDeclaration(at index: Int, contains: (Int, String) -> Bool) -> Bool {
        var index = index
        while var prevIndex = self.index(of: .nonSpaceOrCommentOrLinebreak, before: index) {
            let token = tokens[prevIndex]
            switch token {
            case _ where token.isModifierKeyword || token.isAttribute:
                if contains(prevIndex, token.string) {
                    return true
                }
            case .endOfScope(")"):
                guard let startIndex = self.index(of: .startOfScope("("), before: prevIndex),
                      last(.nonSpaceOrCommentOrLinebreak, before: startIndex, if: {
                          $0.isAttribute || _FormatRules.aclModifiers.contains($0.string)
                      }) != nil
                else {
                    return false
                }
                prevIndex = startIndex
            case .identifier:
                guard let startIndex = startOfAttribute(at: prevIndex),
                      let nextIndex = self.index(of: .operator(".", .infix), after: startIndex)
                else {
                    return false
                }
                prevIndex = nextIndex
            default:
                return false
            }
            index = prevIndex
        }
        return false
    }

    /// Returns true if the modifiers list for the given declaration contain the
    /// specified modifier
    func modifiersForDeclaration(at index: Int, contains: String) -> Bool {
        modifiersForDeclaration(at: index, contains: { $1 == contains })
    }

    /// Returns the index of the specified modifier for a given declaration, or
    /// nil if the type doesn't have that modifier
    func indexOfModifier(_ modifier: String, forDeclarationAt index: Int) -> Int? {
        var i: Int?
        return modifiersForDeclaration(at: index, contains: {
            i = $0
            return $1 == modifier
        }) ? i : nil
    }

    /// Returns the index of the first modifier in a list
    func startOfModifiers(at index: Int, includingAttributes: Bool) -> Int {
        var startIndex = index
        _ = modifiersForDeclaration(at: index, contains: { i, name in
            if !includingAttributes, name.hasPrefix("@") {
                return true
            }
            startIndex = i
            return false
        })
        return startIndex
    }

    /// Gather declared variable names, starting at index after let/var keyword
    func processDeclaredVariables(at index: inout Int, names: inout Set<String>) {
        processDeclaredVariables(at: &index, names: &names, removeSelf: false,
                                 onlyLocal: false, scopeAllowsImplicitSelfRebinding: false)
    }

    /// Returns true if token is inside the return type of a function or subscript
    func isInReturnType(at i: Int) -> Bool {
        startOfReturnType(at: i) != nil
    }

    /// Returns the index of the `->` operator for the current return type declaration if
    /// the specified index is in a return type declaration.
    func startOfReturnType(at i: Int) -> Int? {
        guard let startIndex = indexOfLastSignificantKeyword(
            at: i, excluding: ["throws", "rethrows", "async"]
        ), ["func", "subscript"].contains(tokens[startIndex].string) else {
            return nil
        }

        let endIndex = index(of: .startOfScope("{"), after: i) ?? i

        return index(of: .operator("->", .infix), in: startIndex + 1 ..< endIndex)
    }

    func isStartOfClosure(at i: Int, in _: Token? = nil) -> Bool {
        guard token(at: i) == .startOfScope("{") else {
            return false
        }
        if isConditionalStatement(at: i) {
            if let endIndex = endOfScope(at: i),
               [.startOfScope("("), .operator(".", .infix)]
               .contains(next(.nonSpaceOrComment, after: endIndex) ?? .space("")) ||
               next(.nonSpaceOrCommentOrLinebreak, after: endIndex) == .startOfScope("{")
            {
                return true
            }
            return false
        }
        guard var prevIndex = index(of: .nonSpaceOrCommentOrLinebreak, before: i) else {
            return true
        }
        switch tokens[prevIndex] {
        case .startOfScope("("), .startOfScope("["), .startOfScope("{"),
             .operator(_, .infix), .operator(_, .prefix), .delimiter, .keyword("return"),
             .keyword("in"), .keyword("where"), .keyword("try"), .keyword("throw"), .keyword("await"):
            return true
        case .operator(_, .none),
             .keyword("deinit"), .keyword("catch"), .keyword("else"), .keyword("repeat"),
             .keyword("throws"), .keyword("rethrows"):
            return false
        case .endOfScope("}"):
            guard let startOfScope = index(of: .startOfScope("{"), before: prevIndex) else {
                return false
            }
            return !isStartOfClosure(at: startOfScope)
        case .endOfScope(")"), .endOfScope(">"):
            guard var startOfScope = index(of: .startOfScope, before: prevIndex),
                  var prev = index(of: .nonSpaceOrCommentOrLinebreak, before: startOfScope)
            else {
                return true
            }
            if tokens[prevIndex] == .endOfScope(">"), tokens[prev] == .endOfScope(")") {
                startOfScope = index(of: .startOfScope, before: prev) ?? startOfScope
                prev = index(of: .nonSpaceOrCommentOrLinebreak, before: startOfScope) ?? prev
            }
            switch tokens[prev] {
            case .identifier:
                prevIndex = prev
            case .operator("?", .postfix), .operator("!", .postfix):
                switch token(at: prev - 1) {
                case .identifier?:
                    prevIndex = prev - 1
                case .keyword("init")?:
                    return false
                default:
                    return true
                }
            case .operator("->", .infix), .keyword("init"),
                 .keyword("subscript"):
                return false
            case .endOfScope(">"):
                guard let startIndex = index(of: .startOfScope("<"), before: prev) else {
                    fatalError("Expected <", at: prev - 1)
                    return false
                }
                guard let prevIndex = index(of: .nonSpaceOrComment, before: startIndex, if: {
                    $0.isIdentifier
                }) else {
                    return false
                }
                return last(.nonSpaceOrCommentOrLinebreak, before: prevIndex) != .keyword("func")
            default:
                if let nextIndex = index(of: .nonSpaceOrCommentOrLinebreak, after: i),
                   isAccessorKeyword(at: nextIndex) || isAccessorKeyword(at: prevIndex)
                {
                    return false
                } else {
                    return !isConditionalStatement(at: startOfScope)
                }
            }
            fallthrough
        case .endOfScope where tokens[prevIndex].isStringDelimiter, .identifier, .number:
            if let nextIndex = index(of: .nonSpaceOrCommentOrLinebreak, after: i),
               isAccessorKeyword(at: nextIndex) || isAccessorKeyword(at: prevIndex)
            {
                return false
            }
            guard let prevKeywordIndex = indexOfLastSignificantKeyword(at: prevIndex) else {
                return true
            }
            switch tokens[prevKeywordIndex].string {
            case "var":
                if lastIndex(of: .operator("=", .infix), in: prevKeywordIndex + 1 ..< i) != nil {
                    return true
                }
                var index = prevKeywordIndex
                while let nextIndex = self.index(of: .nonSpaceOrComment, after: index),
                      nextIndex < i
                {
                    switch tokens[nextIndex] {
                    case .operator("=", .infix):
                        return true
                    case .linebreak:
                        guard let nextIndex =
                            self.index(of: .nonSpaceOrCommentOrLinebreak, after: nextIndex)
                        else {
                            return true
                        }
                        if tokens[nextIndex] != .startOfScope("{"),
                           isEndOfStatement(at: index), isStartOfStatement(at: nextIndex)
                        {
                            return true
                        }
                        index = nextIndex
                    default:
                        index = nextIndex
                    }
                }
                return false
            case "class", "actor", "struct", "protocol", "enum", "extension",
                 "func", "subscript", "throws", "rethrows", "async", "catch":
                return false
            default:
                return true
            }
        case .operator("?", .postfix), .operator("!", .postfix),
             .keyword, .endOfScope("]"), .endOfScope(">"):
            return false
        default:
            return true
        }
    }

    func isInClosureArguments(at i: Int) -> Bool {
        var i = i
        while let token = token(at: i) {
            switch token {
            case .keyword("in"), .keyword("throws"), .keyword("rethrows"):
                guard let scopeIndex = index(of: .startOfScope, before: i, if: {
                    $0 == .startOfScope("{")
                }) else {
                    return false
                }
                return isStartOfClosure(at: scopeIndex)
            case .startOfScope("("), .startOfScope("["), .startOfScope("<"),
                 .endOfScope(")"), .endOfScope("]"), .endOfScope(">"),
                 .keyword where token.isAttribute, _ where token.isComment:
                break
            case .keyword, .startOfScope, .endOfScope:
                return false
            default:
                break
            }
            i += 1
        }
        return false
    }

    func isAccessorKeyword(at i: Int, checkKeyword: Bool = true) -> Bool {
        guard !checkKeyword ||
            ["get", "set", "willSet", "didSet"].contains(token(at: i)?.string ?? ""),
            var prevIndex = index(of: .nonSpaceOrCommentOrLinebreak, before: i)
        else {
            return false
        }
        if tokens[prevIndex] == .endOfScope("}"),
           let startIndex = index(of: .startOfScope("{"), before: prevIndex),
           let prev = index(of: .nonSpaceOrCommentOrLinebreak, before: startIndex)
        {
            prevIndex = prev
            if tokens[prevIndex] == .endOfScope(")"),
               let startIndex = index(of: .startOfScope("("), before: prevIndex),
               let prev = index(of: .nonSpaceOrCommentOrLinebreak, before: startIndex)
            {
                prevIndex = prev
            }
            return isAccessorKeyword(at: prevIndex)
        } else if tokens[prevIndex] == .startOfScope("{") {
            switch lastSignificantKeyword(at: prevIndex, excluding: ["where"]) {
            case "var"?, "subscript"?:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Returns true if the token at the specified index is part of a conditional statement
    func isConditionalStatement(at i: Int) -> Bool {
        startOfConditionalStatement(at: i) != nil
    }

    /// If the token at the specified index is part of a conditional statement, returns the index of the first
    /// token in the statement (e.g. `if`, `guard`, `while`, etc.), otherwise returns nil
    func startOfConditionalStatement(at i: Int) -> Int? {
        guard var index = indexOfLastSignificantKeyword(at: i, excluding: ["else"]) else {
            return nil
        }

        func isAfterBrace(_ index: Int, _ i: Int) -> Bool {
            if let scopeStart = lastIndex(of: .startOfScope, in: index ..< i) {
                return isAfterBrace(index, scopeStart)
            }
            guard let braceIndex = lastIndex(
                of: .endOfScope("}"),
                in: index ..< i
            ) else {
                return false
            }
            guard let nextToken = next(.nonSpaceOrComment, after: braceIndex),
                  !nextToken.isOperator(ofType: .infix),
                  !nextToken.isOperator(ofType: .postfix),
                  nextToken != .startOfScope("(")
            else {
                return isAfterBrace(index, braceIndex)
            }
            return true
        }

        if tokens[index] == .keyword("case"), let i = self.index(
            of: .nonSpaceOrCommentOrLinebreak,
            before: index,
            if: { $0 != .delimiter(",") }
        ) {
            index = i
        }

        switch tokens[index].string {
        case "let", "var":
            guard let prevIndex = self
                .index(of: .nonSpaceOrCommentOrLinebreak, before: index)
            else {
                return nil
            }
            switch tokens[prevIndex] {
            case let .keyword(name) where
                ["if", "guard", "while", "for", "case", "catch"].contains(name):
                fallthrough
            case .delimiter(","):
                return isAfterBrace(prevIndex, i) ? nil : prevIndex
            default:
                return nil
            }
        case "if", "guard", "while", "for", "case", "where", "switch":
            if isAfterBrace(index, i) {
                return nil
            }
            return index
        default:
            return nil
        }
    }

    func lastSignificantKeyword(at i: Int, excluding: [String] = []) -> String? {
        guard let index = indexOfLastSignificantKeyword(at: i, excluding: excluding),
              case let .keyword(keyword) = tokens[index]
        else {
            return nil
        }
        return keyword
    }

    func indexOfLastSignificantKeyword(at i: Int, excluding: [String] = []) -> Int? {
        guard let token = token(at: i),
              let index = token.isKeyword ? i : index(of: .keyword, before: i),
              case let .keyword(keyword) = tokens[index]
        else {
            return nil
        }
        switch keyword {
        case let name where
            name.hasPrefix("#") || name.hasPrefix("@") || excluding.contains(name):
            fallthrough
        case "in", "is", "as", "try", "await":
            return indexOfLastSignificantKeyword(at: index - 1, excluding: excluding)
        default:
            guard let braceIndex = self.index(of: .startOfScope("{"), in: index ..< i),
                  let endIndex = endOfScope(at: braceIndex),
                  next(.nonSpaceOrComment, after: endIndex) != .startOfScope("(")
            else {
                return index
            }
            if keyword == "if" || ["var", "let"].contains(keyword) &&
                last(.nonSpaceOrCommentOrLinebreak, before: index) == .keyword("if"),
                self.index(of: .startOfScope("{"), in: endIndex ..< i) == nil
            {
                return index
            }
            return nil
        }
    }

    /// Returns true if the token at the specified index is part of an @attribute
    func isAttribute(at i: Int) -> Bool {
        startOfAttribute(at: i) != nil
    }

    /// If the token at the specified index is part of an @attribute, returns the index of the first
    /// token in the attribute
    func startOfAttribute(at i: Int) -> Int? {
        switch tokens[i] {
        case let token where token.isAttribute:
            return i
        case .endOfScope(")"):
            guard let openParenIndex = index(of: .startOfScope("("), before: i),
                  let prevTokenIndex = index(of: .nonSpaceOrComment, before: openParenIndex)
            else {
                return nil
            }
            return startOfAttribute(at: prevTokenIndex)
        case .identifier:
            guard let dotIndex = index(of: .nonSpaceOrCommentOrLinebreak, before: i, if: {
                $0.isOperator(".")
            }), let prevTokenIndex = index(of: .nonSpaceOrCommentOrLinebreak, before: dotIndex) else {
                return nil
            }
            return startOfAttribute(at: prevTokenIndex)
        default:
            return nil
        }
    }

    /// If the token at the specified index is part of an @attribute, returns the index of the last
    /// token in the attribute
    func endOfAttribute(at i: Int) -> Int? {
        guard let startIndex = index(of: .nonSpaceOrCommentOrLinebreak, after: i) else {
            return i
        }
        switch tokens[startIndex] {
        case .startOfScope("(") where !tokens[i + 1 ..< startIndex].contains(where: { $0.isLinebreak }):
            guard let closeParenIndex = index(of: .endOfScope(")"), after: startIndex) else {
                return nil
            }
            return closeParenIndex
        case .operator(".", .infix):
            guard let nextIndex = index(of: .nonSpaceOrCommentOrLinebreak, after: startIndex) else {
                return nil
            }
            return endOfAttribute(at: nextIndex)
        case .startOfScope("<"):
            guard let nextIndex = index(of: .endOfScope(">"), after: startIndex) else {
                return nil
            }
            return endOfAttribute(at: nextIndex)
        default:
            return i
        }
    }

    /// Determine if next line after this token should be indented
    func isEndOfStatement(at i: Int, in scope: Token? = nil) -> Bool {
        guard let token = token(at: i) else { return true }
        switch token {
        case .endOfScope("case"), .endOfScope("default"):
            return false
        case let .keyword(string):
            // TODO: handle context-specific keywords
            // associativity, convenience, dynamic, didSet, final, get, infix, indirect,
            // lazy, left, mutating, none, nonmutating, open, optional, override, postfix,
            // precedence, prefix, Protocol, required, right, set, Type, unowned, weak, willSet
            switch string {
            case "let", "func", "var", "if", "as", "import", "try", "guard", "case",
                 "for", "init", "switch", "throw", "where", "subscript", "is",
                 "while", "associatedtype", "inout", "await":
                return false
            case "in":
                return lastSignificantKeyword(at: i) != "for"
            case "return":
                guard let nextToken = next(.nonSpaceOrCommentOrLinebreak, after: i) else {
                    return true
                }
                switch nextToken {
                case .keyword, .endOfScope("case"), .endOfScope("default"):
                    return true
                default:
                    return false
                }
            default:
                return true
            }
        case .delimiter(","):
            guard let scope = scope ?? currentScope(at: i) else {
                return false
            }
            // For arrays or argument lists, we already indent
            return ["<", "[", "(", "case", "default"].contains(scope.string)
        case .delimiter(":"):
            guard let scope = scope ?? currentScope(at: i) else {
                return false
            }
            // For arrays or argument lists, we already indent
            return ["case", "default", "("].contains(scope.string)
        case .operator(_, .infix), .operator(_, .prefix):
            return false
        case .operator("?", .postfix), .operator("!", .postfix):
            switch self.token(at: i - 1) {
            case .keyword("as")?, .keyword("try")?:
                return false
            default:
                return true
            }
        default:
            if let attributeIndex = startOfAttribute(at: i),
               let prevIndex = index(of: .nonSpaceOrCommentOrLinebreak, before: attributeIndex)
            {
                return isEndOfStatement(at: prevIndex, in: scope)
            }
            return true
        }
    }

    /// Determine if line starting with this token should be indented
    func isStartOfStatement(at i: Int, in scope: Token? = nil) -> Bool {
        guard let token = token(at: i) else { return true }
        switch token {
        case let .keyword(string) where [
            "where", "dynamicType", "rethrows", "throws",
        ].contains(string):
            return false
        case .keyword("as"):
            // For case statements, we already indent
            return (scope ?? currentScope(at: i))?.string == "case"
        case .keyword("in"):
            let scope = (scope ?? currentScope(at: i))?.string
            // For case statements and closures, we already indent
            return scope == "case" || (scope == "{" && lastSignificantKeyword(at: i) != "for")
        case .keyword("is"):
            guard let lastToken = last(.nonSpaceOrCommentOrLinebreak, before: i) else {
                return false
            }
            return [.endOfScope("case"), .keyword("case"), .delimiter(",")].contains(lastToken)
        case .space, .delimiter, .operator(_, .infix), .operator(_, .postfix),
             .endOfScope("}"), .endOfScope("]"), .endOfScope(")"), .endOfScope(">"):
            return false
        case .startOfScope("{") where isStartOfClosure(at: i):
            guard last(.nonSpaceOrComment, before: i)?.isLinebreak == true,
                  let prevIndex = index(of: .nonSpaceOrCommentOrLinebreak, before: i),
                  let prevToken = self.token(at: prevIndex)
            else {
                return false
            }
            if prevToken.isIdentifier, !["true", "false", "nil"].contains(prevToken.string) {
                return false
            }
            if [.endOfScope(")"), .endOfScope("]")].contains(prevToken),
               let startIndex = index(of: .startOfScope, before: prevIndex),
               !tokens[startIndex ..< prevIndex].contains(where: { $0.isLinebreak })
               || indentForLine(at: startIndex) == indentForLine(at: prevIndex)
            {
                return false
            }
            return true
        case .identifier("async"):
            if next(.nonSpaceOrCommentOrLinebreak, after: i) == .keyword("let") {
                return true
            }
            if last(.nonSpaceOrCommentOrLinebreak, before: i) == .endOfScope(")"),
               lastSignificantKeyword(at: i) == "func"
            {
                return false
            }
            fallthrough
        case .identifier:
            if isTrailingClosureLabel(at: i) {
                return false
            }
            fallthrough
        case .keyword("try"), .keyword("await"):
            guard let prevToken = last(.nonSpaceOrComment, before: i) else {
                return true
            }
            guard prevToken.isLinebreak else {
                return false
            }
            if let prevToken = last(.nonSpaceOrCommentOrLinebreak, before: i) {
                switch prevToken {
                case .number, .operator(_, .postfix), .endOfScope, .identifier,
                     .startOfScope("{"), .delimiter(";"),
                     .keyword("in") where lastSignificantKeyword(at: i) != "for":
                    return true
                default:
                    return false
                }
            }
            return true
        case .keyword:
            return true
        default:
            guard let prevToken = last(.nonSpaceOrComment, before: i) else {
                return true
            }
            guard prevToken.isLinebreak else {
                return false
            }
            if let prevToken = last(.nonSpaceOrCommentOrLinebreak, before: i),
               prevToken == .keyword("return") || prevToken.isOperator(ofType: .infix)
            {
                return false
            }
            return true
        }
    }

    func isTrailingClosureLabel(at i: Int) -> Bool {
        if case .identifier? = token(at: i),
           last(.nonSpaceOrCommentOrLinebreak, before: i) == .endOfScope("}"),
           let nextIndex = index(of: .nonSpaceOrComment, after: i, if: { $0 == .delimiter(":") }),
           let nextNextIndex = index(of: .nonSpaceOrCommentOrLinebreak, after: nextIndex),
           isStartOfClosure(at: nextNextIndex, in: nil)
        {
            return true
        }
        return false
    }

    func isSubscriptOrFunctionCall(at i: Int) -> Bool {
        guard case let .startOfScope(string)? = token(at: i), ["[", "("].contains(string),
              let prevToken = last(.nonSpaceOrComment, before: i)
        else {
            return false
        }
        switch prevToken {
        case .identifier, .operator(_, .postfix),
             .endOfScope("]"), .endOfScope(")"), .endOfScope("}"),
             .endOfScope where prevToken.isStringDelimiter:
            return true
        default:
            return false
        }
    }

    /// Returns true if the token at the specified index is inside a single-line string literal (including inside an interpolation)
    func isInSingleLineStringLiteral(at i: Int) -> Bool {
        var i = i
        while let token = token(at: i), !token.isLinebreak {
            if token.isStringDelimiter {
                return !token.isMultilineStringDelimiter
            }
            i -= 1
        }
        return false
    }

    /// Crude check to detect if code is inside a Result Builder
    /// Note: this will produce false positives for any init that takes a closure
    func isInResultBuilder(at i: Int) -> Bool {
        var i = i
        while let startIndex = index(before: i, where: {
            [.startOfScope("{"), .startOfScope(":")].contains($0)
        }) {
            guard let prevIndex = index(before: startIndex, where: {
                !$0.isSpaceOrCommentOrLinebreak && !$0.isEndOfScope
            }) else {
                return false
            }
            if case let .identifier(name) = tokens[prevIndex], name.first?.isUppercase == true {
                switch last(.nonSpaceOrComment, before: prevIndex) {
                case .identifier("some")?, .delimiter?, .startOfScope?, .endOfScope?,
                     .operator(_, .infix)?, .operator(_, .prefix)?, nil:
                    return true
                default:
                    break
                }
            }
            i = prevIndex
        }
        return false
    }

    /// Detect if identifier requires backtick escaping
    func backticksRequired(at i: Int, ignoreLeadingDot: Bool = false) -> Bool {
        guard let token = token(at: i), token.isIdentifier else {
            return false
        }
        let unescaped = token.unescaped()
        if !unescaped.isSwiftKeyword {
            switch unescaped {
            case "_":
                return true
            case "self":
                if last(.nonSpaceOrCommentOrLinebreak, before: i)?.isOperator(".") == true {
                    return true
                }
                fallthrough
            case "super", "nil", "true", "false":
                if options.swiftVersion < "4" {
                    return true
                }
            case "Self", "Any":
                if let prevToken = last(.nonSpaceOrCommentOrLinebreak, before: i),
                   [.delimiter(":"), .operator("->", .infix)].contains(prevToken)
                {
                    // TODO: check for other cases where it's safe to use unescaped
                    return false
                }
            case "Type":
                if currentScope(at: i) == .startOfScope("{") {
                    // TODO: check it's actually inside a type declaration, otherwise backticks aren't needed
                    return true
                }
                if last(.nonSpaceOrCommentOrLinebreak, before: i)?.isOperator(".") == true {
                    return true
                }
                return false
            case "get", "set", "willSet", "didSet":
                return isAccessorKeyword(at: i, checkKeyword: false)
            case "actor":
                if last(.nonSpaceOrCommentOrLinebreak, before: i)?.isOperator(ofType: .infix) == true {
                    return false
                }
            default:
                return false
            }
        }
        if let prevIndex = index(of: .nonSpaceOrCommentOrLinebreak, before: i, if: {
            $0.isOperator(".")
        }) {
            if unescaped == "init" {
                return true
            }
            if options.swiftVersion >= "5" || self.token(at: prevIndex - 1)?.isOperator("\\") != true {
                return ignoreLeadingDot
            }
            return true
        }
        guard !["let", "var"].contains(unescaped) else {
            return true
        }
        return !isArgumentPosition(at: i)
    }

    /// Is token at argument position
    func isArgumentPosition(at i: Int) -> Bool {
        assert(tokens[i].isIdentifierOrKeyword)
        guard let nextIndex = index(of: .nonSpaceOrCommentOrLinebreak, after: i) else {
            return false
        }
        let nextToken = tokens[nextIndex]
        if nextToken == .delimiter(":") || (nextToken.isIdentifier &&
            next(.nonSpaceOrCommentOrLinebreak, after: nextIndex) == .delimiter(":")),
            currentScope(at: i) == .startOfScope("(")
        {
            return true
        }
        return false
    }

    /// Determine if the specified token is the start of a commented line of code
    func isCommentedCode(at i: Int) -> Bool {
        if token(at: i) == .startOfScope("//"), token(at: i - 1)?.isSpace != true {
            switch token(at: i + 1) {
            case nil, .linebreak?:
                return true
            case let .space(space)? where space.hasPrefix(options.indent):
                return true
            default:
                break
            }
        }
        return false
    }

    /// Returns true if the identifier at the specified index is a label
    func isLabel(at i: Int) -> Bool {
        guard case .identifier = token(at: i) else {
            return false
        }
        return next(.nonSpaceOrCommentOrLinebreak, after: i) == .delimiter(":")
    }

    /// Returns true if the token at the specified index is the opening delimiter of a parameter list
    /// (i.e. either the `(` for a function, or the `<` for some generic parameters)
    func isParameterList(at i: Int) -> Bool {
        assert([.startOfScope("("), .startOfScope("<")].contains(tokens[i]))
        guard let endIndex = endOfScope(at: i),
              let nextIndex = index(of: .nonSpaceOrCommentOrLinebreak, after: endIndex)
        else { return false }
        switch tokens[nextIndex] {
        case .operator("->", .infix), .keyword("throws"), .keyword("rethrows"):
            return true
        case .keyword("in"):
            return last(.nonSpaceOrLinebreak, before: i) != .keyword("for")
        case .identifier("async"):
            if let nextToken = next(.nonSpaceOrCommentOrLinebreak, after: nextIndex),
               [.operator("->", .infix), .keyword("throws"), .keyword("rethrows")].contains(nextToken)
            {
                return true
            }
        default:
            if let funcIndex = index(of: .keyword, before: i, if: {
                [.keyword("func"), .keyword("init"), .keyword("subscript")].contains($0)
            }), lastIndex(of: .endOfScope("}"), in: funcIndex ..< i) == nil {
                // Is parameters at start of function
                return true
            }
        }
        return false
    }

    /// Returns if the `case` keyword at the specified index is part of an enum (as opposed to `if case`)
    func isEnumCase(at i: Int) -> Bool {
        assert(tokens[i] == .keyword("case"))
        switch last(.nonSpaceOrCommentOrLinebreak, before: i) {
        case .identifier?, .endOfScope(")")?, .startOfScope("{")?:
            return true
        default:
            return false
        }
    }

    /// Parses a type name starting at the given index, of one of the following forms:
    ///  - `Foo`
    ///  - `[...]`
    ///  - `(...)`
    ///  - `Foo<...>`
    ///  - `(...) -> ...`
    ///  - `...?`
    ///  - `...!`
    func parseType(at startOfTypeIndex: Int) -> (name: String, range: ClosedRange<Int>) {
        let baseType = parseNonOptionalType(at: startOfTypeIndex)

        // Any type can be optional, so check for a trailing `?` or `!`
        if let nextToken = index(of: .nonSpaceOrCommentOrLinebreak, after: baseType.range.upperBound),
           ["?", "!"].contains(tokens[nextToken].string)
        {
            let typeRange = baseType.range.lowerBound ... nextToken
            return (name: tokens[typeRange].string, range: typeRange)
        }

        return baseType
    }

    private func parseNonOptionalType(at startOfTypeIndex: Int) -> (name: String, range: ClosedRange<Int>) {
        // Parse types of the form `[...]`
        if tokens[startOfTypeIndex] == .startOfScope("["),
           let endOfScope = endOfScope(at: startOfTypeIndex)
        {
            let typeRange = startOfTypeIndex ... endOfScope
            return (name: tokens[typeRange].string, range: typeRange)
        }

        // Parse types of the form `(...)` or `(...) -> ...`
        if tokens[startOfTypeIndex] == .startOfScope("("),
           let endOfScope = endOfScope(at: startOfTypeIndex)
        {
            // Parse types of the form `(...) -> ...`
            if let closureReturnIndex = index(of: .nonSpaceOrCommentOrLinebreak, after: endOfScope),
               tokens[closureReturnIndex] == .operator("->", .infix),
               let returnTypeIndex = index(of: .nonSpaceOrCommentOrLinebreak, after: closureReturnIndex)
            {
                let returnTypeRange = parseType(at: returnTypeIndex).range
                let typeRange = startOfTypeIndex ... returnTypeRange.upperBound
                return (name: tokens[typeRange].string, range: typeRange)
            }

            // Otherwise this is just `(...)`
            let typeRange = startOfTypeIndex ... endOfScope
            return (name: tokens[typeRange].string, range: typeRange)
        }

        // Parse types of the form `Foo<...>`
        if let nextTokenIndex = index(of: .nonSpaceOrCommentOrLinebreak, after: startOfTypeIndex),
           tokens[nextTokenIndex] == .startOfScope("<"),
           let endOfScope = endOfScope(at: nextTokenIndex)
        {
            let typeRange = startOfTypeIndex ... endOfScope
            return (name: tokens[typeRange].string, range: typeRange)
        }

        // Otherwise this is just a single identifier
        return (name: tokens[startOfTypeIndex].string, range: startOfTypeIndex ... startOfTypeIndex)
    }

    struct ImportRange: Comparable {
        var module: String
        var range: Range<Int>
        var attributes: [String]

        var isTestable: Bool {
            attributes.contains("@testable")
        }

        static func < (lhs: ImportRange, rhs: ImportRange) -> Bool {
            let la = lhs.module.lowercased()
            let lb = rhs.module.lowercased()
            return la == lb ? lhs.module < rhs.module : la < lb
        }
    }

    /// Shared import rules implementation
    func parseImports() -> [[ImportRange]] {
        var importStack = [[ImportRange]]()
        var importRanges = [ImportRange]()
        forEach(.keyword("import")) { i, _ in
            func pushStack() {
                importStack.append(importRanges)
                importRanges.removeAll()
            }
            // Get start of line
            var startIndex = index(of: .linebreak, before: i) ?? 0
            // Check for attributes
            var previousKeywordIndex = index(of: .keyword, before: i)
            while let previousIndex = previousKeywordIndex {
                var nextStart: Int? // workaround for Swift Linux bug
                if tokens[previousIndex].isAttribute {
                    if previousIndex < startIndex {
                        nextStart = index(of: .linebreak, before: previousIndex) ?? 0
                    }
                    previousKeywordIndex = index(of: .keyword, before: previousIndex)
                    startIndex = nextStart ?? startIndex
                } else if previousIndex >= startIndex {
                    // Can't handle another keyword on same line as import
                    return
                } else {
                    break
                }
            }
            // Gather comments
            let codeStartIndex = startIndex
            var prevIndex = index(of: .linebreak, before: startIndex) ?? 0
            while startIndex > 0,
                  next(.nonSpace, after: prevIndex)?.isComment == true,
                  next(.nonSpaceOrComment, after: prevIndex)?.isLinebreak == true
            {
                if prevIndex == 0, index(of: .startOfScope("#if"), before: startIndex) != nil {
                    break
                }
                startIndex = prevIndex
                prevIndex = index(of: .linebreak, before: startIndex) ?? 0
            }
            // Check if comment is potentially a file header
            if last(.nonSpaceOrCommentOrLinebreak, before: startIndex) == nil {
                for case let .commentBody(body) in tokens[startIndex ..< codeStartIndex] {
                    if body.contains("created") || body.contains("Created") ||
                        body.contains(options.fileInfo.fileName ?? ".swift")
                    {
                        startIndex = codeStartIndex
                        break
                    }
                }
            }
            // Get end of line
            let endIndex = index(of: .linebreak, after: i) ?? tokens.count
            // Get name
            if let firstPartIndex = index(of: .identifier, after: i) {
                var name = tokens[firstPartIndex].string
                var partIndex = firstPartIndex
                loop: while let nextPartIndex = index(of: .nonSpaceOrCommentOrLinebreak, after: partIndex) {
                    switch tokens[nextPartIndex] {
                    case .operator(".", .infix):
                        name += "."
                    case let .identifier(string):
                        name += string
                    default:
                        break loop
                    }
                    partIndex = nextPartIndex
                }
                let range = startIndex ..< endIndex as Range
                importRanges.append(ImportRange(
                    module: name,
                    range: range,
                    attributes: tokens[range].compactMap { $0.isAttribute ? $0.string : nil }
                ))
            } else {
                // Error
                pushStack()
                return
            }
            if next(.spaceOrCommentOrLinebreak, after: endIndex)?.isLinebreak == true {
                // Blank line after - consider this the end of a block
                pushStack()
                return
            }
            if var nextTokenIndex = index(of: .nonSpaceOrCommentOrLinebreak, after: endIndex) {
                while tokens[nextTokenIndex].isAttribute {
                    guard let nextIndex = index(of: .nonSpaceOrLinebreak, after: nextTokenIndex) else {
                        // End of imports
                        pushStack()
                        return
                    }
                    nextTokenIndex = nextIndex
                }
                if tokens[nextTokenIndex] != .keyword("import") {
                    // End of imports
                    pushStack()
                    return
                }
            }
        }
        // End of imports
        importStack.append(importRanges)
        return importStack
    }

    enum Declaration: Equatable {
        /// A type-like declaration with body of additional declarations (`class`, `struct`, etc)
        indirect case type(kind: String, open: [Token], body: [Declaration], close: [Token])

        /// A simple declaration (like a property or function)
        case declaration(kind: String, tokens: [Token])

        /// A #if ... #endif conditional compilation block with a body of additional declarations
        indirect case conditionalCompilation(open: [Token], body: [Declaration], close: [Token])

        /// The tokens in this declaration
        var tokens: [Token] {
            switch self {
            case let .declaration(_, tokens):
                return tokens
            case let .type(_, openTokens, bodyDeclarations, closeTokens),
                 let .conditionalCompilation(openTokens, bodyDeclarations, closeTokens):
                return openTokens + bodyDeclarations.flatMap { $0.tokens } + closeTokens
            }
        }

        /// The opening tokens of the declaration (before the body)
        var openTokens: [Token] {
            switch self {
            case .declaration:
                return tokens
            case let .type(_, open, _, _),
                 let .conditionalCompilation(open, _, _):
                return open
            }
        }

        /// The body of this declaration, if applicable
        var body: [Declaration]? {
            switch self {
            case .declaration:
                return nil
            case let .type(_, _, body, _),
                 let .conditionalCompilation(_, body, _):
                return body
            }
        }

        /// The closing tokens of the declaration (after the body)
        var closeTokens: [Token] {
            switch self {
            case .declaration:
                return []
            case let .type(_, _, _, close),
                 let .conditionalCompilation(_, _, close):
                return close
            }
        }

        /// The keyword that determines the specific type of declaration that this is
        /// (`class`, `func`, `let`, `var`, etc.)
        var keyword: String {
            switch self {
            case let .declaration(kind, _),
                 let .type(kind, _, _, _):
                return kind
            case .conditionalCompilation:
                return "#if"
            }
        }

        /// Whether or not this declaration defines a type (a class, enum, etc, but not an extension)
        var definesType: Bool {
            ["class", "actor", "enum", "protocol", "struct", "typealias"].contains(keyword)
        }

        /// The name of this type or variable
        var name: String? {
            let parser = Formatter(openTokens)
            guard let keywordIndex = openTokens.firstIndex(of: .keyword(keyword)),
                  let nameIndex = parser.index(of: .identifier, after: keywordIndex)
            else {
                return nil
            }

            return parser.fullyQualifiedName(startingAt: nameIndex).name
        }
    }

    /// The fully qualified name starting at the given index
    func fullyQualifiedName(startingAt index: Int) -> (name: String, endIndex: Int) {
        // If the identifier is followed by a dot, it's actually the first
        // part of the fully-qualified name and we should skip through
        // to the last component of the name.
        var name = tokens[index].string
        var index = index

        while token(at: index + 1)?.string == ".",
              let nextIdentifier = token(at: index + 2),
              nextIdentifier.is(.identifier) == true
        {
            name = "\(name).\(nextIdentifier.string)"
            index += 2
        }

        return (name, index)
    }

    /// Get the type of the declaration starting at the index of the declaration keyword
    func declarationType(at index: Int) -> String? {
        guard let token = token(at: index), token.isDeclarationTypeKeyword,
              case let .keyword(keyword) = token
        else {
            return nil
        }
        if keyword == "class" {
            var nextIndex = index
            while let i = self.index(of: .nonSpaceOrCommentOrLinebreak, after: nextIndex) {
                let nextToken = tokens[i]
                if nextToken.isDeclarationTypeKeyword {
                    return nextToken.string
                }
                guard nextToken.isModifierKeyword else {
                    break
                }
                nextIndex = i
            }
            return keyword
        }
        return keyword
    }

    /// Gather declared name(s), starting at the index of the declaration keyword
    func namesInDeclaration(at index: Int) -> Set<String>? {
        guard case let .keyword(keyword)? = token(at: index) else {
            return nil
        }
        switch keyword {
        case "let", "var":
            var index = index + 1
            var names = Set<String>()
            processDeclaredVariables(at: &index, names: &names)
            return names
        case "func", "class", "actor", "struct", "enum":
            guard let name = next(.identifier, after: index) else {
                return nil
            }
            return [name.string]
        default:
            return nil
        }
    }

    /// Parse all declarations in the formatter's token range
    func parseDeclarations() -> [Declaration] {
        var declarations = [Declaration]()
        var startOfDeclaration = 0
        forEachToken(onlyWhereEnabled: false) { i, token in
            guard i >= startOfDeclaration,
                  token.isDeclarationTypeKeyword || token == .startOfScope("#if")
            else {
                return
            }

            // Get declaration keyword
            var searchIndex = i
            let declarationKeyword = declarationType(at: i) ?? "#if"
            switch token {
            case .startOfScope("#if"):
                // For conditional compilation blocks, the `declarationKeyword` _is_ the `startOfScope`
                // so we can immediately skip to the corresponding #endif
                if let endOfConditionalCompilationScope = endOfScope(at: i) {
                    searchIndex = endOfConditionalCompilationScope
                }
            case .keyword("class") where declarationKeyword != "class":
                // Most declarations will include exactly one token that `isDeclarationTypeKeyword` in
                //  - `class func` methods will have two (and the first one will be incorrect!)
                searchIndex = index(of: .keyword(declarationKeyword), after: i) ?? searchIndex
            case .keyword("import"):
                // Symbol imports (like `import class Module.Type`) will have an extra `isDeclarationTypeKeyword`
                // immediately following their `declarationKeyword`, so we need to skip them.
                if let symbolTypeKeywordIndex = index(of: .nonSpaceOrComment, after: i),
                   tokens[symbolTypeKeywordIndex].isDeclarationTypeKeyword
                {
                    searchIndex = symbolTypeKeywordIndex
                }
            case .keyword("protocol"), .keyword("struct"), .keyword("actor"),
                 .keyword("enum"), .keyword("extension"):
                if let scopeStart = index(of: .startOfScope("{"), after: i) {
                    searchIndex = endOfScope(at: scopeStart) ?? searchIndex
                }
            default:
                break
            }

            // Search for the next declaration so we know where this declaration ends.
            let nextDeclarationKeywordIndex = index(after: searchIndex, where: {
                $0.isDeclarationTypeKeyword || $0 == .startOfScope("#if")
            })

            // Search backward from the next declaration keyword to find where declaration begins.
            var endOfDeclaration = nextDeclarationKeywordIndex.flatMap {
                index(before: startOfModifiers(at: $0, includingAttributes: true), where: {
                    !$0.isSpaceOrCommentOrLinebreak
                }).map { endOfLine(at: $0) }
            }

            // Prefer keeping linebreaks at the end of a declaration's tokens,
            // instead of the start of the next delaration's tokens
            while let linebreakSearchIndex = endOfDeclaration,
                  self.token(at: linebreakSearchIndex + 1)?.isLinebreak == true
            {
                endOfDeclaration = linebreakSearchIndex + 1
            }

            let declarationRange = startOfDeclaration ... min(endOfDeclaration ?? .max, tokens.count - 1)
            startOfDeclaration = declarationRange.upperBound + 1
            let declaration = Array(tokens[declarationRange])
            declarations.append(.declaration(kind: isEnabled ? declarationKeyword : "", tokens: declaration))
        }
        if startOfDeclaration < tokens.count {
            let declaration = Array(tokens[startOfDeclaration...])
            declarations.append(.declaration(kind: "", tokens: declaration))
        }

        return declarations.map { declaration in
            let declarationParser = Formatter(declaration.tokens)

            /// Parses this declaration into a body of declarations separate from the start and end tokens
            func parseBody(in bodyRange: ClosedRange<Int>) -> (start: [Token], body: [Declaration], end: [Token]) {
                var startTokens = declarationParser.tokens[...bodyRange.lowerBound]
                var bodyTokens = declarationParser.tokens[bodyRange.lowerBound + 1 ..< bodyRange.upperBound]
                var endTokens = declarationParser.tokens[bodyRange.upperBound...]

                // Move the leading newlines from the `body` into the `start` tokens
                // so the first body token is the start of the first declaration
                while bodyTokens.first?.isLinebreak == true {
                    startTokens.append(bodyTokens.removeFirst())
                }

                // Move the closing brace's indentation token from the `body` into the `end` tokens
                if bodyTokens.last?.isSpace == true {
                    endTokens.insert(bodyTokens.removeLast(), at: endTokens.startIndex)
                }

                // Parse the inner body declarations of the type
                let bodyDeclarations = Formatter(Array(bodyTokens)).parseDeclarations()

                return (Array(startTokens), bodyDeclarations, Array(endTokens))
            }

            // If this declaration represents a type, we need to parse its inner declarations as well.
            let typelikeKeywords = ["class", "actor", "struct", "enum", "protocol", "extension"]

            if typelikeKeywords.contains(declaration.keyword),
               let declarationTypeKeywordIndex = declarationParser
               .index(after: -1, where: { $0.string == declaration.keyword }),
               let startOfBody = declarationParser
               .index(of: .startOfScope("{"), after: declarationTypeKeywordIndex),
               let endOfBody = declarationParser.endOfScope(at: startOfBody)
            {
                let (startTokens, bodyDeclarations, endTokens) = parseBody(in: startOfBody ... endOfBody)

                return .type(
                    kind: declaration.keyword,
                    open: startTokens,
                    body: bodyDeclarations,
                    close: endTokens
                )
            }

            // If this declaration represents a conditional compilation block,
            // we also have to parse its inner declarations.
            else if declaration.keyword == "#if",
                    let declarationTypeKeywordIndex = declarationParser
                    .index(after: -1, where: { $0.string == declaration.keyword }),
                    let endOfBody = declarationParser.endOfScope(at: declarationTypeKeywordIndex)
            {
                let startOfBody = declarationParser.endOfLine(at: declarationTypeKeywordIndex)
                let (startTokens, bodyDeclarations, endTokens) = parseBody(in: startOfBody ... endOfBody)

                return .conditionalCompilation(
                    open: startTokens,
                    body: bodyDeclarations,
                    close: endTokens
                )
            } else {
                return declaration
            }
        }
    }

    /// The type of scope that a declaration is contained within
    enum DeclarationScope {
        /// The declaration is a top-level global
        case global

        /// The declaration is a member of some type
        case type

        /// The declaration is within some local scope,
        /// like a function body.
        case local
    }

    /// Returns the declaration scope (global, type, or local) that the
    /// given token index is contained by.
    func declarationScope(at i: Int) -> DeclarationScope {
        /// Declarations which have `DeclarationScope.type`
        let typeDeclarations = Set(["class", "actor", "struct", "enum", "extension"])

        /// Declarations which have `DeclarationScope.local`
        let localDeclarations = Set(["let", "var", "func", "subscript", "init", "deinit"])

        let allDeclarationScopes = typeDeclarations.union(localDeclarations)

        // back track through tokens until we find a startOfScope("{") that isDeclarationTypeKeyword
        //  - we have to skip scopes that sit between this token and the its actual start of scope,
        //    so we have to keep track of the number of unpaired end scope tokens we have encountered
        var unpairedEndScopeCount = 0
        var currentIndex = i
        var startOfScope: Int?

        while startOfScope == nil, currentIndex > 0 {
            currentIndex -= 1

            if tokens[currentIndex] == .endOfScope("}") {
                unpairedEndScopeCount += 1
            } else if tokens[currentIndex] == .startOfScope("{") {
                if unpairedEndScopeCount == 0 {
                    startOfScope = currentIndex
                } else {
                    unpairedEndScopeCount -= 1
                }
            }
        }

        // If this declaration isn't within any scope,
        // it must be a global.
        guard
            let startOfScopeIndex = startOfScope,
            let declarationTypeKeyword = lastToken(before: startOfScopeIndex, where: { allDeclarationScopes.contains($0.string) })
        else {
            return .global
        }

        if typeDeclarations.contains(declarationTypeKeyword.string) {
            return .type
        } else {
            return .local
        }
    }

    /// Swift modifier keywords, in preferred order
    var modifierOrder: [String] {
        var priorities = [String: Int]()
        for (i, modifiers) in _FormatRules.defaultModifierOrder.enumerated() {
            for modifier in modifiers {
                priorities[modifier] = i
            }
        }
        var order = options.modifierOrder.flatMap { _FormatRules.mapModifiers($0) ?? [] }
        for (i, modifiers) in _FormatRules.defaultModifierOrder.enumerated() {
            let insertionPoint = order.firstIndex(where: { modifiers.contains($0) }) ??
                order.firstIndex(where: { (priorities[$0] ?? 0) > i }) ?? order.count
            order.insert(contentsOf: modifiers.filter { !order.contains($0) }, at: insertionPoint)
        }
        return order
    }

    /// Returns the index where the `wrap` rule should add the next linebreak in the line at the selected index.
    ///
    /// If the line does not need to be wrapped, this will return `nil`.
    ///
    /// - Note: This checks the entire line from the start of the line, the linebreak may be an index preceding the
    ///         `index` passed to the function.
    func indexWhereLineShouldWrapInLine(at index: Int) -> Int? {
        indexWhereLineShouldWrap(from: startOfLine(at: index, excludingIndent: true))
    }

    func indexWhereLineShouldWrap(from index: Int) -> Int? {
        var lineLength = self.lineLength(upTo: index)
        var stringLiteralDepth = 0
        var currentPriority = 0
        var lastBreakPoint: Int?
        var lastBreakPointPriority = Int.min

        let maxWidth = options.maxWidth
        guard maxWidth > 0 else { return nil }

        func addBreakPoint(at i: Int, relativePriority: Int) {
            guard stringLiteralDepth == 0, currentPriority + relativePriority >= lastBreakPointPriority,
                  !isInClosureArguments(at: i + 1)
            else {
                return
            }
            let i = self.index(of: .nonSpace, before: i + 1) ?? i
            if token(at: i + 1)?.isLinebreak == true || token(at: i)?.isLinebreak == true {
                return
            }
            lastBreakPoint = i
            lastBreakPointPriority = currentPriority + relativePriority
        }

        var i = index
        let endIndex = endOfLine(at: index)
        while i < endIndex {
            var token = tokens[i]
            switch token {
            case .linebreak:
                return nil
            case .keyword("#colorLiteral"), .keyword("#imageLiteral"):
                guard let startIndex = self.index(of: .startOfScope("("), after: i),
                      let endIndex = endOfScope(at: startIndex)
                else {
                    return nil // error
                }
                token = .space(spaceEquivalentToTokens(from: i, upTo: endIndex + 1)) // hack to get correct length
                i = endIndex
            case let .delimiter(string) where options.noWrapOperators.contains(string),
                 let .operator(string, .infix) where options.noWrapOperators.contains(string):
                // TODO: handle as/is
                break
            case .delimiter(","):
                addBreakPoint(at: i, relativePriority: 0)
            case .operator("=", .infix) where self.token(at: i + 1)?.isSpace == true:
                addBreakPoint(at: i, relativePriority: -9)
            case .operator(".", .infix):
                addBreakPoint(at: i - 1, relativePriority: -2)
            case .operator("->", .infix):
                if isInReturnType(at: i) {
                    currentPriority -= 5
                }
                addBreakPoint(at: i - 1, relativePriority: -5)
            case .operator(_, .infix) where self.token(at: i + 1)?.isSpace == true:
                addBreakPoint(at: i, relativePriority: -3)
            case .startOfScope("{"):
                if !isStartOfClosure(at: i) ||
                    next(.keyword, after: i) != .keyword("in"),
                    next(.nonSpace, after: i) != .endOfScope("}")
                {
                    addBreakPoint(at: i, relativePriority: -6)
                }
                if isInReturnType(at: i) {
                    currentPriority += 5
                }
                currentPriority -= 6
            case .endOfScope("}"):
                currentPriority += 6
                if last(.nonSpace, before: i) != .startOfScope("{") {
                    addBreakPoint(at: i - 1, relativePriority: -6)
                }
            case .startOfScope("("):
                currentPriority -= 7
            case .endOfScope(")"):
                currentPriority += 7
            case .startOfScope("["):
                currentPriority -= 8
            case .endOfScope("]"):
                currentPriority += 8
            case .startOfScope("<"):
                currentPriority -= 9
            case .endOfScope(">"):
                currentPriority += 9
            case .startOfScope where token.isStringDelimiter:
                stringLiteralDepth += 1
            case .endOfScope where token.isStringDelimiter:
                stringLiteralDepth -= 1
            case .keyword("else"), .keyword("where"):
                addBreakPoint(at: i - 1, relativePriority: -1)
            case .keyword("in"):
                if last(.keyword, before: i) == .keyword("for") {
                    addBreakPoint(at: i, relativePriority: -11)
                    break
                }
                addBreakPoint(at: i, relativePriority: -5 - currentPriority)
            default:
                break
            }
            lineLength += tokenLength(token)
            if lineLength > maxWidth, let breakPoint = lastBreakPoint, breakPoint < i {
                return breakPoint
            }
            i += 1
        }
        return nil
    }

    /// Indent level to use for wrapped lines at the specified position (based on statement type)
    func linewrapIndent(at index: Int) -> String {
        guard let commaIndex = self.index(of: .nonSpaceOrCommentOrLinebreak, before: index + 1, if: {
            $0 == .delimiter(",")
        }),
            case let firstToken = startOfLine(at: commaIndex, excludingIndent: true),
            let firstNonBrace = (firstToken ..< commaIndex).first(where: {
                let token = self.tokens[$0]
                return !token.isEndOfScope && !token.isSpaceOrComment
            })
        else {
            if next(.nonSpaceOrCommentOrLinebreak, after: index) == .operator(".", .infix),
               var prevIndex = self.index(of: .nonSpaceOrLinebreak, before: index)
            {
                if case .endOfScope = tokens[prevIndex] {
                    prevIndex = self.index(of: .startOfScope, before: index) ?? prevIndex
                }
                if case let lineStart = startOfLine(at: prevIndex, excludingIndent: true),
                   tokens[lineStart] == .operator(".", .infix),
                   self.index(of: .startOfScope, before: index) ?? -1 < lineStart
                {
                    return indentForLine(at: lineStart)
                }
            }
            return options.indent
        }
        if case .endOfScope = tokens[firstToken],
           next(.nonSpaceOrCommentOrLinebreak, after: firstNonBrace - 1) == .delimiter(",")
        {
            return ""
        }
        guard let keywordIndex = lastIndex(in: firstNonBrace ..< commaIndex, where: {
            [.keyword("if"), .keyword("guard"), .keyword("while")].contains($0)
        }) ?? lastIndex(in: firstNonBrace ..< commaIndex, where: {
            [.keyword("let"), .keyword("var"), .keyword("case")].contains($0)
        }), let nextTokenIndex = self.index(of: .nonSpace, after: keywordIndex) else {
            return options.indent
        }
        return spaceEquivalentToTokens(from: firstToken, upTo: nextTokenIndex)
    }

    /// Returns the equivalent type token for a given value token
    func typeToken(forValueToken token: Token) -> Token {
        switch token {
        case let .number(_, type):
            switch type {
            case .decimal:
                return .identifier("Double")
            default:
                return .identifier("Int")
            }
        case let .identifier(name):
            return ["true", "false"].contains(name) ? .identifier("Bool") : .identifier(name)
        case let token:
            return token.isStringDelimiter ? .identifier("String") : token
        }
    }

    /// Returns end of last index of Void type declaration starting at specified index, or nil if not Void
    func endOfVoidType(at index: Int) -> Int? {
        switch tokens[index] {
        case .identifier("Void"):
            return index
        case .identifier("Swift"):
            guard let dotIndex = self.index(of: .nonSpaceOrLinebreak, after: index, if: {
                $0 == .operator(".", .infix)
            }), let voidIndex = self.index(of: .nonSpace, after: dotIndex, if: {
                $0 == .identifier("Void")
            }) else { return nil }
            return voidIndex
        case .startOfScope("("):
            guard let nextIndex = self.index(of: .nonSpace, after: index) else {
                return nil
            }
            switch tokens[nextIndex] {
            case .endOfScope(")"):
                return nextIndex
            case .identifier("Void"):
                guard let nextIndex = self.index(of: .nonSpace, after: nextIndex),
                      case .endOfScope(")") = tokens[nextIndex]
                else {
                    return nil
                }
                return nextIndex
            default:
                return nil
            }
        default:
            return nil
        }
    }

    struct SwitchCaseRange {
        let beforeDelimiterRange: Range<Int>
        let delimiterToken: Token
        let afterDelimiterRange: Range<Int>
    }

    func parseSwitchCaseRanges() -> [[SwitchCaseRange]] {
        var result: [[SwitchCaseRange]] = []

        forEach(.endOfScope("case")) { i, _ in
            var switchCaseRanges: [SwitchCaseRange] = []
            guard let lastDelimiterIndex = index(of: .startOfScope(":"), after: i),
                  let endIndex = index(after: lastDelimiterIndex, where: { $0.isLinebreak }) else { return }

            var idx = i
            while idx < endIndex,
                  let startOfCaseIndex = index(of: .nonSpaceOrCommentOrLinebreak, after: idx),
                  let delimiterIndex = index(after: idx, where: {
                      $0 == .delimiter(",") || $0 == .startOfScope(":")
                  }),
                  let delimiterToken = token(at: delimiterIndex),
                  let endOfCaseIndex = lastIndex(
                      of: .nonSpaceOrCommentOrLinebreak,
                      in: startOfCaseIndex ..< delimiterIndex
                  )
            {
                let afterDelimiterRange: Range<Int>

                let startOfCommentIdx = delimiterIndex + 1
                if startOfCommentIdx <= endIndex,
                   token(at: startOfCommentIdx)?.isSpaceOrCommentOrLinebreak == true,
                   let nextNonSpaceOrComment = index(of: .nonSpaceOrComment, after: startOfCommentIdx)
                {
                    if token(at: startOfCommentIdx)?.isLinebreak == true
                        || token(at: nextNonSpaceOrComment)?.isSpaceOrCommentOrLinebreak == false
                    {
                        afterDelimiterRange = startOfCommentIdx ..< (startOfCommentIdx + 1)
                    } else if endIndex > startOfCommentIdx {
                        afterDelimiterRange = startOfCommentIdx ..< (nextNonSpaceOrComment + 1)
                    } else {
                        afterDelimiterRange = endIndex ..< (endIndex + 1)
                    }
                } else {
                    afterDelimiterRange = 0 ..< 0
                }

                let switchCaseRange = SwitchCaseRange(
                    beforeDelimiterRange: Range(startOfCaseIndex ... endOfCaseIndex),
                    delimiterToken: delimiterToken,
                    afterDelimiterRange: afterDelimiterRange
                )

                switchCaseRanges.append(switchCaseRange)

                if afterDelimiterRange.isEmpty {
                    idx = delimiterIndex
                } else if afterDelimiterRange.count > 1 {
                    idx = afterDelimiterRange.upperBound
                } else {
                    idx = afterDelimiterRange.lowerBound
                }
            }
            result.append(switchCaseRanges)
        }
        return result
    }

    struct EnumCaseRange: Comparable {
        let value: Range<Int>
        let endOfCaseRangeToken: Token

        static func < (lhs: Formatter.EnumCaseRange, rhs: Formatter.EnumCaseRange) -> Bool {
            lhs.value.lowerBound < rhs.value.lowerBound
        }
    }

    func parseEnumCaseRanges() -> [[EnumCaseRange]] {
        var indexedRanges: [Int: [EnumCaseRange]] = [:]

        forEach(.keyword("case")) { i, _ in
            guard isEnumCase(at: i) else { return }

            var idx = i
            while
                let starOfCaseRangeIdx = index(of: .identifier, after: idx),
                lastSignificantKeyword(at: starOfCaseRangeIdx) == "case",
                let lastCaseIndex = lastIndex(of: .keyword("case"), in: i ..< starOfCaseRangeIdx),
                lastCaseIndex == i,
                let endOfCaseRangeIdx = index(
                    after: starOfCaseRangeIdx,
                    where: { $0 == .delimiter(",") || $0.isLinebreak }
                ),
                let endOfCaseRangeToken = token(at: endOfCaseRangeIdx)
            {
                let startOfScopeIdx = index(of: .startOfScope, before: starOfCaseRangeIdx) ?? 0

                var indexedCase = indexedRanges[startOfScopeIdx, default: []]
                indexedCase.append(
                    EnumCaseRange(
                        value: starOfCaseRangeIdx ..< endOfCaseRangeIdx,
                        endOfCaseRangeToken: endOfCaseRangeToken
                    )
                )
                indexedRanges[startOfScopeIdx] = indexedCase

                idx = endOfCaseRangeIdx
            }
        }

        return Array(indexedRanges.values)
    }
}

extension _FormatRules {
    /// Short date formatter. Used by fileHeader rule
    static var shortDateFormatter: (Date) -> String = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return { formatter.string(from: $0) }
    }()

    /// Year formatter. Used by fileHeader rule
    static var yearFormatter: (Date) -> String = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return { formatter.string(from: $0) }
    }()

    /// Current year. Used by fileHeader rule
    static var currentYear: String = yearFormatter(Date())

    /// Swiftlint semantic modifier groups
    static let semanticModifierGroups = ["acl", "setteracl", "mutators", "typemethods", "owned"]

    /// All modifiers
    static let allModifiers = Set(defaultModifierOrder.flatMap { $0 })

    /// ACL modifiers
    static let aclModifiers = ["private", "fileprivate", "internal", "public", "open"]

    /// ACL setter modifiers
    static let aclSetterModifiers = aclModifiers.map { "\($0)(set)" }

    /// Ownership modifiers
    static let ownershipModifiers = ["weak", "unowned"]

    /// Modifier mapping (designed to match SwiftLint)
    static func mapModifiers(_ input: String) -> [String]? {
        switch input.lowercased() {
        case "acl":
            return aclModifiers
        case "setteracl":
            return aclSetterModifiers
        case "mutators":
            return ["mutating", "nonmutating"]
        case "typemethods":
            return [] // Not clear what this is for - legacy?
        case "owned":
            return ownershipModifiers
        case let input:
            if allModifiers.contains(input) {
                return [input]
            }
            guard let index = input.firstIndex(of: "(") else {
                return nil
            }
            let input = String(input[..<index])
            return allModifiers.contains(input) ? [input] : nil
        }
    }

    /// Swift modifier keywords, in default order
    static let defaultModifierOrder = [
        ["override"],
        aclModifiers,
        aclSetterModifiers,
        ["final", "dynamic"],
        ["optional", "required"],
        ["convenience"],
        ["indirect"],
        ["isolated", "nonisolated"],
        ["lazy"],
        ownershipModifiers,
        ["static", "class"],
        ["mutating", "nonmutating"],
        ["prefix", "infix", "postfix"],
    ]

    /// Global swift functions
    static let globalSwiftFunctions = [
        "min", "max", "abs", "print", "stride", "zip",
    ]
}

extension Token {
    /// Whether or not this token "defines" the specific type of declaration
    ///  - A valid declaration will usually include exactly one of these keywords in its outermost scope.
    ///  - Notable exceptions are `class func` and symbol imports (like `import class Module.Type`)
    ///    which will include two of these keywords.
    var isDeclarationTypeKeyword: Bool {
        isDeclarationTypeKeyword(excluding: [])
    }

    /// Whether or not this token "defines" the specific type of declaration
    ///  - A valid declaration will usually include exactly one of these keywords in its outermost scope.
    ///  - Notable exceptions are `class func` and symbol imports (like `import class Module.Type`)
    ///    which will include two of these keywords.
    func isDeclarationTypeKeyword(excluding keywordsToExclude: [String]) -> Bool {
        guard case let .keyword(keyword) = self else {
            return false
        }

        // All of the keywords that map to individual Declaration grammars
        // https://docs.swift.org/swift-book/ReferenceManual/Declarations.html#grammar_declaration
        var declarationTypeKeywords = Set<String>([
            "import", "let", "var", "typealias", "func", "enum", "case",
            "struct", "class", "actor", "protocol", "init", "deinit",
            "extension", "subscript", "operator", "precedencegroup",
            "associatedtype",
        ])

        for keywordToExclude in keywordsToExclude {
            declarationTypeKeywords.remove(keywordToExclude)
        }

        return declarationTypeKeywords.contains(keyword)
    }

    var isModifierKeyword: Bool {
        switch self {
        case let .keyword(keyword), let .identifier(keyword):
            return _FormatRules.allModifiers.contains(keyword)
        default:
            return false
        }
    }
}
