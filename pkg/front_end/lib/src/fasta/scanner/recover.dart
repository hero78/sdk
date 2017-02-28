// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style licenset hat can be found in the LICENSE file.

library fasta.scanner.recover;

import 'token.dart' show StringToken, Token;

import 'error_token.dart' show NonAsciiIdentifierToken, ErrorKind, ErrorToken;

import 'precedence.dart' as Precedence;

import 'precedence.dart' show PrecedenceInfo;

/// Recover from errors in [tokens]. The original sources are provided as
/// [bytes]. [lineStarts] are the beginning character offsets of lines, and
/// must be updated if recovery is performed rewriting the original source
/// code.
Token defaultRecoveryStrategy(
    List<int> bytes, Token tokens, List<int> lineStarts) {
  // See [Parser.reportErrorToken](package:front_end/src/fasta/parser/src/parser.dart) for how
  // it currently handles lexical errors. In addition, notice how the parser
  // calls [handleInvalidExpression], [handleInvalidFunctionBody], and
  // [handleInvalidTypeReference] to allow the listener to recover its internal
  // state. See [package:compiler/src/parser/element_listener.dart] for an
  // example of how these events are used.
  //
  // In addition, the scanner will attempt a bit of recovery when braces don't
  // match up during brace grouping. See
  // [ArrayBasedScanner.discardBeginGroupUntil](array_based_scanner.dart). For
  // more details on brace grouping see
  // [AbstractScanner.unmatchedBeginGroup](abstract_scanner.dart).

  /// Tokens with errors.
  ErrorToken error;

  /// Used for appending to [error].
  ErrorToken errorTail;

  /// Tokens without errors.
  Token good;

  /// Used for appending to [good].
  Token goodTail;

  /// The previous token appended to [good]. Since tokens are single linked
  /// lists, this allows us to rewrite the current token without scanning all
  /// of [good]. This is supposed to be the token immediately before
  /// [goodTail], that is, `beforeGoodTail.next == goodTail`.
  Token beforeGoodTail;

  recoverIdentifier(NonAsciiIdentifierToken first) {
    List<int> codeUnits = <int>[];

    // True if the previous good token is an identifier and ends right where
    // [first] starts. This is the case for input like `blåbærgrød`. In this
    // case, the scanner produces this sequence of tokens:
    //
    //     [
    //        StringToken("bl"),
    //        NonAsciiIdentifierToken("å"),
    //        StringToken("b"),
    //        NonAsciiIdentifierToken("æ"),
    //        StringToken("rgr"),
    //        NonAsciiIdentifierToken("ø"),
    //        StringToken("d"),
    //        EOF,
    //     ]
    bool prepend = false;

    // True if following token is also an identifier that starts right where
    // [errorTail] ends. This is the case for "b" above.
    bool append = false;
    if (goodTail != null) {
      if (goodTail.info == Precedence.IDENTIFIER_INFO &&
          goodTail.charEnd == first.charOffset) {
        prepend = true;
      }
    }
    Token next = errorTail.next;
    if (next.info == Precedence.IDENTIFIER_INFO &&
        errorTail.charOffset + 1 == next.charOffset) {
      append = true;
    }
    if (prepend) {
      codeUnits.addAll(goodTail.value.codeUnits);
    }
    NonAsciiIdentifierToken current = first;
    while (current != errorTail) {
      codeUnits.add(current.character);
      current = current.next;
    }
    codeUnits.add(errorTail.character);
    int charOffset = first.charOffset;
    if (prepend) {
      charOffset = goodTail.charOffset;
      if (beforeGoodTail == null) {
        // We're prepending the first good token, so the new token will become
        // the first good token.
        good = null;
        goodTail = null;
        beforeGoodTail = null;
      } else {
        goodTail = beforeGoodTail;
      }
    }
    if (append) {
      codeUnits.addAll(next.value.codeUnits);
      next = next.next;
    }
    String value = new String.fromCharCodes(codeUnits);
    return synthesizeToken(charOffset, value, Precedence.IDENTIFIER_INFO)
      ..next = next;
  }

  recoverExponent() {
    return synthesizeToken(errorTail.charOffset, "NaN", Precedence.DOUBLE_INFO)
      ..next = errorTail.next;
  }

  recoverString() {
    // TODO(ahe): Improve this.
    return skipToEof(errorTail);
  }

  recoverHexDigit() {
    return synthesizeToken(errorTail.charOffset, "-1", Precedence.INT_INFO)
      ..next = errorTail.next;
  }

  recoverStringInterpolation() {
    // TODO(ahe): Improve this.
    return skipToEof(errorTail);
  }

  recoverComment() {
    // TODO(ahe): Improve this.
    return skipToEof(errorTail);
  }

  recoverUnmatched() {
    // TODO(ahe): Try to use top-level keywords (such as `class`, `typedef`,
    // and `enum`) and identation to recover.
    return errorTail.next;
  }

  for (Token current = tokens; !current.isEof; current = current.next) {
    if (current is ErrorToken) {
      ErrorToken first = current;
      Token next = current;
      bool treatAsWhitespace = false;
      do {
        current = next;
        if (errorTail == null) {
          error = next;
        } else {
          errorTail.next = next;
        }
        errorTail = next;
        next = next.next;
      } while (next is ErrorToken && first.errorCode == next.errorCode);

      switch (first.errorCode) {
        case ErrorKind.Encoding:
        case ErrorKind.NonAsciiWhitespace:
        case ErrorKind.AsciiControlCharacter:
          treatAsWhitespace = true;
          break;

        case ErrorKind.NonAsciiIdentifier:
          current = recoverIdentifier(first);
          assert(current.next != null);
          break;

        case ErrorKind.MissingExponent:
          current = recoverExponent();
          assert(current.next != null);
          break;

        case ErrorKind.UnterminatedString:
          current = recoverString();
          assert(current.next != null);
          break;

        case ErrorKind.ExpectedHexDigit:
          current = recoverHexDigit();
          assert(current.next != null);
          break;

        case ErrorKind.UnexpectedDollarInString:
          current = recoverStringInterpolation();
          assert(current.next != null);
          break;

        case ErrorKind.UnterminatedComment:
          current = recoverComment();
          assert(current.next != null);
          break;

        case ErrorKind.UnmatchedToken:
          current = recoverUnmatched();
          assert(current.next != null);
          break;

        case ErrorKind.UnterminatedToken: // TODO(ahe): Can this happen?
        default:
          treatAsWhitespace = true;
          break;
      }
      if (treatAsWhitespace) continue;
    }
    if (goodTail == null) {
      good = current;
    } else {
      goodTail.next = current;
    }
    beforeGoodTail = goodTail;
    goodTail = current;
  }

  errorTail.next = good;
  return error;
}

Token synthesizeToken(int charOffset, String value, PrecedenceInfo info) {
  return new StringToken.fromString(info, value, charOffset);
}

Token skipToEof(Token token) {
  while (!token.isEof) {
    token = token.next;
  }
  return token;
}

String closeBraceFor(String openBrace) {
  return const {
    '(': ')',
    '[': ']',
    '{': '}',
    '<': '>',
    r'${': '}',
  }[openBrace];
}
