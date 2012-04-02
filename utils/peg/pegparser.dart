// Copyright (c) 2011, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#library('Peg Parser');

/*
 * The following functions are combinators for building Rules.
 *
 * A rule is one of the following
 * - A String which matches the string literally.
 * - A Symbol which matches the symbol's definition.
 * - A list of rules with an optional reducing function, which matches a sequence.
 * - The result of calling one of the combinators.
 *
 * Some rules are 'value-generating' rules, they return an 'abstract syntax
 * tree' with the match.  If a rule is not value-generating [:null:] is the
 * value.
 *
 * A Symbol is always a value-generating rule. If the value is not required, use
 * [:SKIP(aSymbol):] in place of [:aSymbol:].
 *
 * A String is not a value-generating rule but can be converted into one by
 * using [:TEXT('string'):] in place of [:'string':].
 *
 * A list or sequence is value-generating depending on the subrules.  The
 * sequence is value-generating if any of the subrules are value-generating or
 * if there is a reducing function.  If no reducing function is given, the value
 * returned depends on the number of value-generating subrules.  If there is
 * only one value generating subrule, that provideds the value for the sequence.
 * If there are more, then the value is a list of the values of the
 * value-generating subrules.
 */

/**
 * Matches one character by a predicate on the character code.
 * If [spec] is an int, that character is matched.
 * If [spec] is a function it is used
 *
 * Example [: CHARCODE((code) => 48 <= code && code <= 57) :] recognizes an
 * ASCII digit.
 *
 * CHARCODE does not generate a value.
 */
_Rule CHARCODE(spec, [name]) {
  if (spec is int)
    return new _CharCodeRule((code) => code == spec, name);
  else
    return new _CharCodeRule(spec, name);
}

/**
 * Matches one of the [characters].
 *
 * CHAR does not generate a value.
 */
_Rule CHAR([characters]) {
  if (characters == null)
    return const _AnyCharRule();
  if (characters is int)
    return CHARCODE(characters);

  // Find the range of character codes and construct an array of flags for codes
  // within the range.
  List<int> codes = characters.charCodes();
  codes.sort((a, b) => a < b ? -1 : a > b ? 1 : 0);
  int lo = codes[0];
  int hi = codes[codes.length - 1];
  if (lo == hi)
    return CHARCODE(lo);
  int len = hi - lo + 1;
  var flags = new List<bool>(len);
  for (int i = 0; i < len; ++i)
    flags[i] = false;
  for (int code in codes)
    flags[code - lo] = true;

  return CHARCODE((code) => code >= lo && code <= hi && flags[code - lo]);
}

/**
 * Matches the end of the input.
 *
 * END does not generate a value.
 */
_Rule get END() => new _EndOfInputRule();

/**
 * Throws an exception.
 */
_Rule ERROR(String message) => new _ErrorRule(message);

/**
 * Matches [rule] but does not consume the input.  Useful for matching a right
 * context.
 *
 * AT does not generate a value.
 */
_Rule AT(rule) => new _ContextRule(_compile(rule));

/**
 * Matches when [rule] does not match.  No input is consumed.
 *
 * NOT does not generate a value.
 */
_Rule NOT(rule) => new _NegativeContextRule(_compile(rule));

/**
 * Matches [rule] but generates no value even if [rule] generates a value.
 *
 * SKIP never generates a value.
 */
_Rule SKIP(rule) => new _SkipRule(_compile(rule));

/**
 * Matches [rule] in a lexical context where whitespace is not automatically
 * skipped.  Useful for matching what would normally be considered to be tokens.
 * [name] is a user-friendly description of what is being matched and is used in
 * error messages.
 *
 * LEX(rule)
 * LEX(name, rule)
 *
 * LEX does not generate a value.  If a value is required, wrap LEX with TEXT.
 */
_Rule LEX(arg1, [arg2]) {
  if (arg2 == null)
    return new _LexicalRule(arg1 is String ? arg1 : null, _compile(arg1));
  else
    return new _LexicalRule(arg1, _compile(arg2));
}

/**
 * Matches [rule] and generates a value from the matched text. If the [rule]
 * matches, then TEXT(rule) matches and has a value derived from the string
 * fragment that was matched.  The default derived value is the string fragment.
 *
 * TEXT always generates a value.
 */
_Rule TEXT(rule, [extractor]) =>
  new _TextValueRule(_compile(rule),
                     extractor == null
                     ? (string, start, end) => string.substring(start, end)
                     : extractor);

/**
 * Matches an optional rule.
 *
 * MAYBE is a value generating matcher.
 *
 * If [rule] is value generating then the value is the value generated by [rule]
 * if it matches, and [:null:] if it does not.
 *
 * If [rule] is not value generatinge then the value is [:true:] if [rule]
 * matches and [:false:] if it does not.
 */
_Rule MAYBE(rule) => new _OptionalRule(_compile(rule));

/**
 * MANY(rule) matches [rule] [min] or more times.
 * [min] must be 0 or 1.
 * If [separator] is provided it is used to match a separator between matches of
 * [rule].
 *
 * MANY is a value generating matcher.  The value is a list of the matches of
 * [rule].  The list may be empty if [:min == 0:].
 */
_Rule MANY(rule, [separator = null, int min = 1]) {
  assert(0 <= min && min <= 1);
  return new _RepeatRule(_compile(rule), _compileOptional(separator), min);
}

/**
 * Matches [rule] zero or more times.  Shorthand for [:MANY(rule, min:0):]
 * TODO: retire min: parameter?
 *
 * MANY0 is a value generating matcher.
 */
_Rule MANY0(rule, [separator = null]) {
  return new _RepeatRule(_compile(rule), _compileOptional(separator), 0);
}

/**
 * Matches [rules] in order until one succeeds.
 *
 * OR is value-generating.
 */
_Rule OR([a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z]) =>
    _compileMultiRule(
        (a is List && b == null)  // Backward compat. OR([a, b]) => OR(a, b).
          ? a
          : _unspread(a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z),
        false,
        (compiledRules, valueCount, reducer) =>
            new _ChoiceRule(compiledRules));



_Rule SEQ([a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z]) =>
  _compile(_unspread(a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z));

/**
 * Matches [rule]
 */
_Rule MEMO(rule) => new _MemoRule(_compile(rule));

_Rule TAG(tag, rule) => _compile([rule, (ast) => [tag, ast]]);


class ParseError implements Exception {
  const ParseError(String this._message);
  String toString() => _message;
  final String _message;
}

/**
 * A grammar is a collection of symbols and rules that may be used to parse an
 * input.
 */
class Grammar {
  Map<String, Symbol> _symbols;

  /** This rule may be set by the user to define whitespace. */
  _Rule _whitespace;

  _Rule get whitespace() => _whitespace;
  void set whitespace(rule) { _whitespace = _compile(rule); }

  Grammar() {
    _symbols = new Map<String, Symbol>();
    whitespace = CHAR(' \t\r\n');
  }

  /**
   * operator [] is used to find or create symbols. Symbols may appear in rules
   * to define recursive rules.
   */
  Symbol operator [](String name) {
    if (_symbols.containsKey(name))
      return _symbols[name];
    Symbol s = new Symbol(name, this);
    _symbols[name] = s;
    return s;
  }

  /**
   * Parses the input string and returns the parsed AST, or throws an exception
   * if the input can't be parsed.
   */
  parse(root, String text) {
    for (var symbol in _symbols.getValues())
      if (symbol._rule == null)
        print('${symbol.name} is undefined');

    var state = new _ParserState(text, whitespace: whitespace);
    var match = _compile(root).match(state, 0);
    if (match == null)
      return diagnose(state);
    var pos = match[0];
    pos = _skip_whitespace(state, pos);
    if (pos == state._end)
      return match[1];
    // TODO: Make this complain about expecting end of file.
    return diagnose(state);
  }

  diagnose(state) {
    var message = 'unexpected error';
    if (!state.max_rule.isEmpty()) {
      var s = new Set();
      for (var rule in state.max_rule)
        s.add(rule.description());
      var tokens = new List<String>.from(s);
      tokens.sort((a, b) =>
                  a.startsWith("'") == b.startsWith("'")
                      ? a.compareTo(b)
                      : a.startsWith("'") ? +1 : -1);
      var expected = Strings.join(tokens, ' or ');
      var found = state.max_pos == state._end ? 'end of file'
          : "'${state._text[state.max_pos]}'";
      message = 'Expected $expected but found $found';
    }
    int start = state.max_pos;
    int end = start;
    while (start >= 1 && state._text[start - 1] != '\n') --start;
    while (end < state._text.length && state._text[end] != '\n') ++end;
    var line = state._text.substring(start, end);
    var indicator = '';
    for (var i = 0; i < line.length && start + i < state.max_pos; i++)
      indicator = indicator + ' ';
    indicator = indicator + '^';
    // TODO: Convert to an exception.
    print(message);
    print(line);
    print(indicator);
    return null;
  }
}

class Symbol {
  final String name;
  final Grammar grammar;
  _Rule _rule;

  Symbol(this.name, this.grammar);

  void set def(rule) {
    assert(_rule == null);  // Assign once.
    _rule = _compile(rule);
  }

  toString() => _rule == null ? '<$name>' : '<$name = $_rule>';
}


class _ParserState {
  _ParserState(this._text, [_Rule whitespace = null]) {
    _end = this._text.length;
    whitespaceRule = whitespace;
    max_rule = [];
  }

  String _text;
  int _end;

  //
  bool inWhitespaceMode = false;
  _Rule whitespaceRule = null;

  // Used for constructing an error message.
  int inhibitExpectedTrackingDepth = 0;
  int max_pos = 0;
  var max_rule;
}

/**
 * An interface tag for rules. If this tag is on a rule, then the description()
 * of the rule is something sensible to put in a message.
 */
interface _Expectable {
  String description();
}

class _Rule {
  const _Rule();
  // Returns null for a match failure or [pos, ast] for success.
  match(_ParserState state, int pos) {
    if (! state.inWhitespaceMode) {
      pos = _skip_whitespace(state, pos);
    }
    return matchAfterWS(state, pos);
  }

  // Faster entry point for matching a sub-rule that is matched to the start
  // position of the super-rule.  Whitespace has already been skipped so no need
  // to try to skip it again.
  matchAfterWS(_ParserState state, int pos) {
    if (state.inhibitExpectedTrackingDepth == 0) {
      // Track position for possible error messaging
      if (pos > state.max_pos) {
        // Store position and the rule.
        state.max_pos = pos;
        if (this is _Expectable) {
          state.max_rule = [this];
        } else {
          state.max_rule = [];
        }
      } else if (pos == state.max_pos) {
        if (this is _Expectable) {
          state.max_rule.add(this);
        }
      }
    }
    // Delegate the matching logic to the the specialized function.
    return _match(state, pos);
  }

  // Overridden in subclasses to match the rule.
  _match(_ParserState state, int pos) => null;

  // Does the rule generate a value (AST) with the match?
  bool get generatesValue() => false;

  get defaultValue() => null;
}

int _skip_whitespace(state, pos) {
  // Returns the next non-whitespace position.
  // This is done by matching the optional whitespaceRule with the current text.
  if (state.whitespaceRule == null)
    return pos;
  state.inWhitespaceMode = true;
  state.inhibitExpectedTrackingDepth++;
  while (true) {
    var match = state.whitespaceRule.match(state, pos);
    if (match == null)
      break;
    pos = match[0];
  }
  state.inWhitespaceMode = false;
  state.inhibitExpectedTrackingDepth--;
  return pos;
}


_Rule _compileOptional(rule) {
  return rule == null ? null : _compile(rule);
}

_Rule _compile(rule) {
  if (rule is _Rule)
    return rule;
  if (rule is String)
    return new _StringRule(rule);
  if (rule is Symbol)
    return new _SymbolRule(rule);
  if (rule is RegExp)
    return new _RegExpRule(rule);
  if (rule is List) {
    return _compileMultiRule(
        rule, true,
        (compiledRules, valueCount, reducer) =>
            new _SequenceRule(compiledRules, valueCount, reducer));
  }
  throw new Exception('Cannot compile rule: $rule');
}

class _EndOfInputRule extends _Rule {
  _match(_ParserState state, int pos) {
    if (pos == state._end)
      return [pos, null];
    return null;
  }

  toString() => 'END';
}

class _ErrorRule extends _Rule {
  String message;
  _ErrorRule(String this.message);
  _match(_ParserState state, int pos) {
    throw new ParseError(message);
  }

  toString() => 'ERROR($message)';
}

class _CharCodeRule extends _Rule {
  Function _predicate;
  var _name;
  _CharCodeRule(this._predicate, this._name);
  _match(_ParserState state, int pos) {
    if (pos == state._end)
      return null;
    int code = state._text.charCodeAt(pos);
    if (_predicate(code))
      return [pos + 1, null];
    return null;
  }

  toString() => _name == null ? 'CHARCODE($_predicate)' : 'CHARCODE($_name)';
}

class _AnyCharRule extends _Rule {
  const _AnyCharRule();
  _match(_ParserState state, int pos) {
    if (pos == state._end)
      return null;
    return [pos + 1, null];
  }

  toString() => 'CHAR()';
}

class _SymbolRule extends _Rule {
  final Symbol _symbol;
  _SymbolRule(Symbol this._symbol);
  _match(_ParserState state, int pos) {
    if (_symbol._rule == null)
      throw new Exception("Symbol '${_symbol.name}' is undefined");
    return _symbol._rule.match(state, pos);
  }

  bool get generatesValue() => true;

  toString() => '<${_symbol.name}>';
}

class _SkipRule extends _Rule {
  // A rule that has no value.
  _Rule _rule;
  _SkipRule(_Rule this._rule);
  _match(_ParserState state, int pos) {
    var match = _rule.matchAfterWS(state, pos);
    if (match == null)
      return null;
    return [match[0], null];
  }

  toString() => 'TOKEN($_rule)';
}

class _StringRule extends _Rule implements _Expectable {
  final String _string;
  int _len;
  _StringRule(this._string) {
    _len = _string.length;
  }

  _match(_ParserState state, int pos) {
    if (pos + _len > state._end)
      return null;
    for (int i = 0; i < _len; i++) {
      if (state._text.charCodeAt(pos + i) != _string.charCodeAt(i))
        return null;
    }
    return [pos + _len, null];
  }

  //get defaultValue() => _string;

  toString() => '"$_string"';

  description() => "'$_string'";
}

class _RegExpRule extends _Rule {
  RegExp _re;
  _RegExpRule(this._re) {
    // There is no convenient way to match an anchored substring.
    throw new Exception('RegExp matching not supported');
  }

  toString() => '"$_re"';
}

class _LexicalRule extends _Rule implements _Expectable {
  final String _name;
  final _Rule _rule;

  _LexicalRule(String this._name, _Rule this._rule);

  _match(_ParserState state, int pos) {
    state.inWhitespaceMode = true;
    state.inhibitExpectedTrackingDepth++;
    var match = _rule.matchAfterWS(state, pos);
    state.inhibitExpectedTrackingDepth--;
    state.inWhitespaceMode = false;
    return match;
  }

  toString() => _name;

  description() => _name == null ? '?' : _name;
}

class _TextValueRule extends _Rule {
  final _Rule _rule;
  final _extract;  // Function

  _TextValueRule(_Rule this._rule, Function this._extract);

  _match(_ParserState state, int pos) {
    var match = _rule.matchAfterWS(state, pos);
    if (match == null) {
      return null;
    }
    var endPos = match[0];
    return [endPos, _extract(state._text, pos, endPos)];
  }

  bool get generatesValue() => true;

  toString() => 'TEXT($_rule)';
}

_Rule _compileMultiRule(List rules,
                        bool allowReducer,
                        finish(compiledRules, valueCount, reducer)) {
  int valueCount = 0;
  List compiledRules = new List<_Rule>();
  Function reducer;
  for (var rule in rules) {
    if (reducer != null)
      throw new Exception('Reducer must be last in sequence: $rule');
    if (rule is Function) {
      if (allowReducer)
        reducer = rule;
      else
        throw new Exception('Bad rule: "$rule"');
    } else {
      _Rule compiledRule = _compile(rule);
      if (compiledRule.generatesValue)
        ++valueCount;
      compiledRules.add(compiledRule);
    }
  }
  return finish(compiledRules, valueCount, reducer);
}

String _formatMultiRule(String functor, List rules) {
  var sb = new StringBuffer(functor);
  sb.add('(');
  var separator = '';
  for (var rule in rules) {
    sb.add(separator);
    sb.add(rule);
    separator = ',';
  }
  sb.add(')');
  return sb.toString();
}

class _SequenceRule extends _Rule {
  // This rule matches the component rules in order.
  final List<_Rule> _rules;
  final int _generatingSubRules = 0;
  final Function _reducer;
  bool _generatesValue;
  _SequenceRule(List<_Rule> this._rules,
                int this._generatingSubRules,
                Function this._reducer) {
    _generatesValue = _generatingSubRules > 0 || _reducer != null;
  }

  _match(state, pos) {
    var sequence = [];
    for (var rule in _rules) {
      var match = rule.match(state, pos);
      if (match == null)
        return null;
      if (rule.generatesValue) {
        var ast = match[1];
        sequence.add(ast);
      }
      pos = match[0];
    }
    if (_reducer == null) {
      if (_generatingSubRules == 0)
        return [pos, null];
      if (_generatingSubRules == 1)
        return [pos, sequence[0]];
      return [pos, sequence];
    } else {
      return [pos, _apply(_reducer, sequence)];
    }
  }

  bool get generatesValue() => _generatesValue;

  toString() => _formatMultiRule('SEQ', _rules);
}

class _ChoiceRule extends _Rule {
  // This rule matches the first component rule that matches.
  List<_Rule> _rules;
  _ChoiceRule(List<_Rule> this._rules);

  _match(state, pos) {
    for (var rule in _rules) {
      var match = rule.match(state, pos);
      if (match != null) {
        /*
        if (!rule.generatesValue) {
          var value = rule.defaultValue;
          if (value != null)
            return [match[0], value];
        }
        */
        return match;
      }
    }
    return null;
  }

  bool get generatesValue() => true;

  toString() => _formatMultiRule('OR', _rules);
}

class _OptionalRule extends _Rule {
  _Rule _rule;
  _OptionalRule(_Rule this._rule);
  _match(_ParserState state, int pos) {
    var match = _rule.match(state, pos);
    if (_rule.generatesValue)
      return match == null
          ? [pos, null]
          : match;
    return match == null
        ? [pos, false]
        : [match[0], true];
  }

  bool get generatesValue() => true;

  toString() => 'MAYBE($_rule)';
}

class _ContextRule extends _Rule {
  _Rule _rule;
  _ContextRule(_Rule this._rule);
  _match(_ParserState state, int pos) {
    // TODO: protect error state.
    var match = _rule._match(state, pos);
    if (match == null)
      return null;
    return [pos, null];
  }

  toString() => 'AT($_rule)';
}

class _NegativeContextRule extends _Rule {
  _Rule _rule;
  _NegativeContextRule(_Rule this._rule);
  _match(_ParserState state, int pos) {
    // TODO: protect error state.
    var match = _rule._match(state, pos);
    if (match == null)
      return [pos, null];
    return null;
  }

  toString() => 'NOT($_rule)';
}

class _RepeatRule extends _Rule {
  // Matches zero, one or more items.
  _Rule _rule;
  _Rule _separator;
  int _min;

  _RepeatRule(this._rule, this._separator, this._min);

  _match(state, pos) {
    // First match.
    var match = _rule.match(state, pos);
    if (match == null)
      if (_min == 0)
        return [pos, []];
      else
        return null;
    pos = match[0];
    var result = [match[1]];

    // Subsequent matches:
    while (true)  {
      var newPos = pos;
      if (_separator != null) {
        match = _separator.match(state, pos);
        if (match == null)
          return [pos, result];
        newPos = match[0];
      }
      match = _rule.match(state, newPos);
      if (match == null)
        return [pos, result];
      pos = match[0];
      result.add(match[1]);
    }
  }

  bool get generatesValue() => true;

  toString() => 'MANY(min:$_min, $_rule${_separator==null?'':", sep: $_separator"})';
}

class _MemoRule extends _Rule {
  final _Rule _rule;

  var parseInstance;

  // A map from position to result.  Can this be replaced with something
  // smaller?
  // TODO: figure out how to discard the map and parseInstance after parsing.
  Map<int,Object> map;

  _MemoRule(this._rule);

  _match(state, pos) {
    // See if we are still parsing the same input.  Relies on the fact that the
    // input is a string and strings are immutable.
    if (parseInstance !== state._text) {
      map = new Map<int,Object>();
      parseInstance = state._text;
    }
    // TODO: does this have to check or preserve parse state (like
    // inWhitespaceMode, error position info etc?)
    // Stored result can be null (memoized failure).
    if (map.containsKey(pos)) {
      return map[pos];
    }
    var match = _rule.match(state, pos);
    map[pos] = match;
    return match;
  }

  bool get generatesValue() => _rule.generatesValue;

  toString() => 'MEMO($_rule)';
}

_apply(fn, List args) {
  switch (args.length) {
    case 0: return fn();
    case 1: return fn(args[0]);
    case 2: return fn(args[0], args[1]);
    case 3: return fn(args[0], args[1], args[2]);
    case 4: return fn(args[0], args[1], args[2], args[3]);
    case 5: return fn(args[0], args[1], args[2], args[3], args[4]);
    case 6: return fn(args[0], args[1], args[2], args[3], args[4],
                      args[5]);
    case 7: return fn(args[0], args[1], args[2], args[3], args[4],
                      args[5], args[6]);
    case 8: return fn(args[0], args[1], args[2], args[3], args[4],
                      args[5], args[6], args[7]);
    case 9: return fn(args[0], args[1], args[2], args[3], args[4],
                      args[5], args[6], args[7], args[8]);
    case 10: return fn(args[0], args[1], args[2], args[3], args[4],
                       args[5], args[6], args[7], args[8], args[9]);

    default:
      throw new Exception('Too many arguments in _apply: $args');
  }
}

List _unspread(a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q,r,s,t,u,v,w,x,y,z) {
  List list = new List();
  add(element) { if (element != null) list.add(element); }
  add(a);
  add(b);
  add(c);
  add(d);
  add(e);
  add(f);
  add(g);
  add(h);
  add(i);
  add(j);
  add(k);
  add(l);
  add(m);
  add(n);
  add(o);
  add(p);
  add(q);
  add(r);
  add(s);
  add(t);
  add(u);
  add(v);
  add(w);
  add(x);
  add(y);
  add(z);
  return list;
}
