# Completion plumbing - server and plugin plan

Status: DELIVERED - agreed 2026-08-21, completion and signature help shipped
2026-08-21/22 once PasTree's completion API landed. Kept as the record of the
seam and its reasons; open polish is under "Deferred polish" below.

Scope: everything completion needs in THIS repository - the LSP server and the
RAD Studio plugin - built now, against a seam, so that when PasTree grows its
completion API (planned separately, in the PasTree repository) it drops into
one unit and everything around it already works. The companion documents:
[SPEC.md](SPEC.md) owns the protocol inventory (completion is its tier-3
entry), [clients/rad-studio/SPEC.md](clients/rad-studio/SPEC.md) owns the
ToolsAPI side and the decided endgame this plan feeds (the Code Insight
manager route).

## The seam: one unit owns the PasTree call

`source/PasLsp.Completion.pas` (new) is the ONLY unit that will ever call the
future PasTree completion API. Everything else in this plan compiles and runs
before that API exists.

What the server hands across the seam (this is the requirement list for the
PasTree-side plan, to be reconciled with it):

- **The current overlay text of the edited file** - not the model's copy. The
  model is stale by definition mid-typing; the overlay is the truth
  (`PasLsp.Documents` already enforces that rule for every other request). The
  provider needs the live text to read the token being typed and the dotted
  prefix left of the cursor.
- The analysis snapshot (model), the module id, and the position - 1-based
  line/col in UTF-16 code units, PasTree's own convention, so the existing
  `PasLsp.Protocol` conversions apply unchanged.

What the server needs back, per item: name, symbol kind, a short detail string
(signature), and - non-negotiable - **the replace span**: the start column of
the partially-typed token the item replaces. LSP clients edit by `textEdit`
range, and a provider that only returns names forces every client to re-derive
tokenization; the provider computed it anyway.

**The engine is wired (2026-08-21).** The seam now runs
`PasTree.Sema.Complete` - per request: preprocess+parse the live overlay
text into a fresh model (so "as analyzed" and "as typed" are the same text),
then `TPasCompletion` BRIDGED to the last completed closure analysis, where
every name leaving the overlay (inherited members, used units' types)
resolves through the project. No analysis yet degrades to standalone mode:
locals, own-unit names and keywords still answer. The replace span comes
from the engine's caret primitive (mid-word invocation spans the whole word,
the clangd behavior; the server never filters by prefix - clients do).
Buckets map to `sortText` (`00`-`09` + lowercased name), so precedence-aware
clients sort by resolution precedence. `cMinPasTreeVersion` is pinned at the
engine's stabilization version.

The interim keyword provider this plan shipped first (revising its own
stub-by-default: a mechanism has to be SEEN working) served its purpose -
every wiring fix from the wire format to the RAD viewer's columns landed
against it - and was deleted the day the engine arrived.

## List order and filtering - the rules (DRAFT 2026-11-05, under discussion)

**Goal: guess what the user is about to type here, from the context.** The
constraint on every rule below: it is simple enough to state in one row of
one table. A rule that needs a paragraph to explain is a rule the user cannot
predict, and a list the user cannot predict is one they stop reading.

### Terms

- **Context** - a position where the engine knows what the next value (or
  type) must be, and so what "fits" means there. A context only ORDERS the
  list. **Never listed** is the one exception: what the grammar forbids at
  the position, whatever its type - a procedure where a value is read, a
  variable where a constant must stand. Nothing is hidden for its type alone.
- **`Self`** - ranked in every value position as a value of the method's
  type (a helper's extended type), and in a class method as the class's name
  is, the class reference it is; its row shows that type (`Self: TFoo`,
  `Self: class of TFoo`). It has no declaration, and until 0.84.22 it was an
  untyped row, fit 3, after every other match of its name.

Value positions:

| Context | Example | Fits | Never listed | State |
|---|---|---|---|---|
| assignment | `X := \|` | assignable to X's type. For a Boolean - here, in an argument, `Exit(`, a default or a constant, not in a condition or an operand of `and` / `or` / `not` - `True` and `False` before every other Boolean (Conv). `High` / `Low` / `Pred` / `Succ`, whose type their argument decides, are fit 1 wherever an ordinal or a number is read (`for I := 0 to High(A)`), not "leads" | procedures | 0.84; Boolean literals, `High` 0.85.0 |
| ... a root target | `O := \|`, `Test(\|` for `Test(AObj: TObject)`, an `IInterface` | at `:=` and a value argument (not `var` / `out`) of exactly TObject or IInterface, every class - every interface - that converts is fit 1 alike: the root itself gains no fit 0 over a descendant, and proximity decides (`Test(Ac\|`: a local `Acc: TAccount` above System's `AcquireExceptionObject: TObject`). A narrower target (`TAccount`) keeps the exact type at fit 0; so does a comparison | procedures | 0.85.11 (decided by Alex, 2026-11-09) |
| comparison | `if X = \|`, `<>` `<` `>` `<=` `>=` | comparable with X; a longer left side (`if I + 1 = \|`, `A and B = \|`, a literal) by the type of the expression it is - `=` binds loosest. Inside a fit a constant - a true or typed constant, an enumeration value, `nil`, `True`, `False` - comes before a variable or a function (Conv), except the routine's own locals and parameters (`Status <> AStatus`): what a value is compared with is mostly a constant (`X = nil`, `K = kOne`) | procedures | 0.84; a longer left side 0.84.20; constants first 0.85.0 |
| a member chain in either | `X := Obj.\|` | the same, for the chain's last member | procedures | 0.84 |
| an inline variable's initializer | `var X: T := \|` | assignable to T - the assignment, with the type written out | procedures | 0.84 |
| ... untyped | `var X := \|`, an inline `const C = \|` | no context: the initializer gives the type | procedures (dcc 37 compiles `var X := Proc` into a variable of type `Procedure` that cannot be called) | 0.85.8 |
| a call argument | `Foo(A, \|)` | assignable to that parameter; over overloads, the best fit for the arguments written among those taking at least this many; an intrinsic by its table signature (`Assert(\|` a Boolean). Overloads the written arguments cannot tell apart that take different types at the caret (`SetValue('Name', \|` over Char, Byte, Boolean, string ...) rank each item by its best fit over those types (at most 16, each taken by value or each `var`) - the first one alone made every Byte and Boolean wrong | procedures | 0.84.9; tied overloads 0.85.11; an argument naming another unit's enumeration value picks the overload 0.84.21; a routine of the unit being edited, 0.85.2 (its parameter was taken for a type name, and nothing was ranked) |
| ... a `var`/`out` argument | `Inc(\|)`, `TryStrToInt(S, \|)` | a variable of exactly that type. An intrinsic's has none, its shape ranks: `Inc(\|` / `Dec(\|` an ordinal (an integer, a Char, a Boolean, an enumeration) or a typed pointer fit 1 (dcc 37: an untyped Pointer is E2001), `SetLength(\|` a string or a dynamic array fit 1; a value with members leads, any other is fit 3. A property is fit 3 or leads | constants, functions, procedures | 0.84.9; the intrinsics' shapes 0.85.5 (the all-context replay: 5% of these sites ranked) |
| ... `Assigned(\|)` | `if Assigned(\|)` | a reference: a class, an interface, a pointer, a dynamic array, a procedural value, a class reference fit 1 (dcc 37: a string is E2008); a value with members leads, a scalar is fit 3 | procedures | 0.85.5 |
| ... an untyped or generic parameter | `FillChar(\|`, `Max<T>(\|` | no context (an open array too) | procedures | 0.84.9 |
| a value typecast | `Int64(\|)`, `TFoo(\|)`, `PChar(\|)` | the cast's family: any ordinal (integer, enumeration, Char, Boolean) for an ordinal type, and a set of exactly its size (`Longword(S)` for a set of 0..31; dcc 37, E2089 for another size - 0.85.11); a class, interface, pointer, class reference, procedural value or `nil` for a class, interface or pointer type (a string or a dynamic array too for a pointer; an integer leads); for a float (`Double(\|`) any number or a Variant, and a value of exactly its size (dcc 37: `Single(P)` on Win32, `Double(S)` on Win64); for a record (`TRec(\|`) a value of exactly its size, by the analysis's SizeOf. A scalar of another size is fit 3 (E2089), so is a true constant or an enumeration value for a record (`TRec4(K)` is E2089 though K's type has the size); a record of another size leads. A constructor's `(` stays a call | procedures | 0.84.13; a float or a record 0.84.21 (a record the analysis cannot measure ranks nothing) |
| `Exit(\|)` | | the innermost routine's result type | procedures | 0.84.10 |
| ... in a procedure | `Exit(\|` in a procedure, a constructor, a destructor, a procedure nested in a function, an anonymous procedure | nothing: the list is empty - `Exit(X)` is E2025 there (dcc 37), so no item can stand | everything | 0.85.8 (it listed every procedure, unranked) |
| a condition | `if \|`, `while \|`, `until \|`, `if not \|`, `if (\|` | Boolean; an intrinsic by its fixed result (`Assigned`, `Odd`) | procedures | 0.84.8; `if (\|` 0.84.14 |
| ... an operand of `and` / `or` / `xor` | `if A and \|`, `while (X > 0) or \|`, `I and \|` | the left operand's type when it is a Boolean (logical) or an integer (bitwise), else none; `and` binds tighter than `=`, so in `if A = B and \|` B decides. A parenthesized comparison or `in` on the left (`(A <> B) and \|`, `(X = nil) or (\|`) is a Boolean whatever its operands - `nil` and an untyped call included | procedures | 0.84.14; a parenthesized relation 0.85.11 (18% of these requests ranked nothing); a left operand longer than a designator (`X * Y and \|`: the product) 0.84.20 |
| ... `not` | `X := not \|`, `Foo(not \|)`, `A and not \|` | what the `not` stands for: a Boolean where a Boolean or nothing is expected, the integer type where an integer is (a bitwise not), none elsewhere | procedures | 0.84.14 |
| ... a grouping paren | `if (\|`, `if (A) and (\|`, `X := (\|` | what the position of its `(` expects; a call's or a cast's `(` and a record or array constant's are their own | as that position | 0.84.14 |
| a `case` selector | `case \| of` | any ordinal (integer, enumeration, Char, Boolean) is fit 1; a float, a set fit 3; a value with members leads, and so does a string value, after the others (`case S[I] of` selects by a Char; the type name `string` stays fit 3) | procedures | 0.84.10; a string leads 0.85.0 |
| a `case` label | `case K of \|:`, after `,` and `..` in a label list, a later arm's label | constants of K's type | variables, typed constants, functions, procedures, `Self` (0.85.8) - a label is a constant expression (the intrinsics one may call stay: `Ord`, `High`, `SizeOf`) | 0.84.10 |
| `for` bounds | `for I := \| to \|`, `downto \|` | I's type; an inline `for var I :=` with no declared type expects nothing | procedures | 0.84.11 |
| `for ... in` | `for X in \|` | what can be enumerated: an array, a set, a string, a class or record with GetEnumerator; where X has a declared type, the collection whose element is that type first, one whose element converts to it next, one whose element does not leads; a value with members leads, a scalar is wrong | procedures | 0.84.11 (a class or record helper's GetEnumerator counts; one helping an ordinal type does not, as dcc 37 rejects `for X in K` there too - E2430; `for var X in` ranks every collection alike) |
| an index | `A[\|]`, `Dict[\|]`, `M[I, \|]` | the index type: Integer for a dynamic array, a string or a pointer, the declared ordinal for a static one (each dimension its own), the parameter of an array property (a dictionary's key; a default property through the bare brackets) | procedures | 0.84.12 |
| a set element | `S := [\|]`, `K in [\|`, after `,` and `..` in the brackets, `Include(S, \|)` | the set's element type; after `in` the type of K; a dynamic array's element (`Arr := [\|]`), an open array argument's (`Foo([\|])`) | procedures (an array of a procedural type keeps them) | 0.84.12; an operand of `+` / `-` / `*` (`S + [\|`, `Arr + [\|`: the left operand's element) 0.84.20; a true set constant on the left (`SECTION_WORDS + [\|`, typed by its first element's enumeration), a field typed `set of T` inline (`F.Flags := [\|`), `Foo([\|` with the `(` not closed yet 0.85.11. Not yet: an open array of class references (`RegisterClasses([\|`) ranks nothing |
| an operand of an operator | `X := A + \|`, `-` `*` `/` `div` `mod` `shl` `shr` | the left operand's family. A number: after `+` `-` `*` `/` its own type is fit 0, any other integer or float fit 1; `div` `mod` `shl` `shr` want an integer - its type, a float is fit 3. A string or Char after `+`: a string (a Char converts). A set after `+` `-` `*`: the set. A dynamic array after `+`: itself. A typed pointer after `+` `-`: an integer; an untyped Pointer nothing (dcc 37: `P + 1` is E2015). A record: the right parameter of its `class operator` for that operator, the record being the first. The left operand is the expression precedence makes it (`*` `/` `div` `mod` `and` `shl` `shr` above `+` `-` `or` `xor` above the comparisons, left to right within a level): in `A + B * \|` B, in `if A = B + \|` B, in `A - B + \|` the difference - typed by the analysis's operator table over names, member chains, calls, literals and grouping parens. A sign (`X := -\|`) stands for what its own position expects: an integer, a float with any number fitting | procedures | 0.84.20 (`and` / `or` / `xor`: 0.84.14, under the condition). Not yet: a record whose overloads of the operator take different right types ranks nothing; a typed pointer without POINTERMATH (`PInteger`) ranks an integer though dcc rejects the sum; a set constructor or `@X` as a left operand is not typed - nothing is ranked |
| `with \| do` | `with A, \| do` | a value with members: a class, a record, an interface, a class reference, a class name (dcc 37 takes `with TFoo do` with class members or none); a record type's name leads when the type names a member - a class var, a class or static method, a constructor, a class property (`with TRec.Make do`) - and is fit 3 without one, since the bare name is E2029; a pointer or an array leads, a scalar is fit 3 | procedures | 0.84.15; a type's name 0.84.21 |
| `raise \|` | | an exception instance: a class descending from Exception fits - a variable, a function, the class name (`EFoo.Create`), the nearer to Exception first (Conv: Exception itself, then its children, 0.85.0); another class leads, a scalar is fit 3; `raise` alone stays legal | procedures | 0.84.15 (Exception is the class of that name the caret's unit can see: without SysUtils every class fits) |
| `raise X at \|` | | an address: a pointer fits - an untyped or a typed one, `nil`; any other scalar is fit 3 (dcc 37: E2017 for an integer too), an object or a record leads | procedures | 0.84.21 |
| a default parameter value, a typed constant | `(A: Integer = \|)`, `const C: T = \|`, an initialized global `var G: T = \|` | constants of the type | variables, typed constants, functions, procedures, `Self` - a constant expression (the intrinsics one may call stay: `Ord`, `High`, `SizeOf`); a procedural type's constant keeps the routines | 0.84.15 (an inline `var X: T := \|` is no constant and keeps them); after an operator inside one (`= A + \|`) 0.85.8 |
| an untyped constant | `const C = \|`, `C = A + \|` | any constant, ranked by nothing | variables, typed constants, functions, procedures, `Self` - a constant expression, decided by the declaration, not by the operator before the caret (an inline `const C = \|` is initialized at run time and keeps them, procedures aside) | 0.85.8 (it listed every variable and routine) |
| a static array's bounds | `array[\|] of`, `array[TKind, \|]`, `array[0..\|]`, `packed array[\|]`, a field's or an inline variable's | any ordinal: an ordinal type (an enumeration, a subrange, Integer, Boolean, Char) is fit 0 where a whole range may stand (not after `..`: the commonest bound, 0.85.0), an ordinal constant fit 1, a type or a constant of another scalar kind fit 3; after `..` a constant of the low bound's type, as a `case` label (an integer literal's Integer, a one-character literal's Char) | variables, typed constants, functions, procedures - a constant expression (the intrinsics one may call stay: `High`, `Low`, `Ord`, `SizeOf`, `Pred`, `Succ`) | 0.84.17 (a value's index `A[\|]` and a set constructor keep their own rows) |
| a subrange's high bound | `T = clRed..\|`, `var X: 0..\|` | a constant of the low bound's type; any ordinal when the low bound cannot be typed | as a static array's bounds | 0.84.17 (a low bound longer than one name or literal - `Ord('A') + 1..\|` - expects any ordinal) |
| an event or method pointer, a procedural variable or parameter | `OnClick := \|`, `P := \|`, `Foo(\|` for a procedural parameter | a routine whose signature the type takes is fit 0 - `of object` a method, a plain type a plain routine (or a static class method), `reference to` either; a procedure of another signature or kind is fit 3; a function that does not fit is judged by its result | - | 0.84.15 (a routine only the buffer declares, since the last analysis, leads: no signature to compare yet) |
| a property accessor | `property P: T read \|`, `write \|`, `stored \|` | the class's own and inherited members, visibility applied. Fit 0 (each rule dcc 37-probed): a field of exactly T and a `function: T` after `read`; a field of T and a `procedure(Value: T)` taking it by value or `const` after `write`; a Boolean field, a parameterless Boolean function, `True` / `False` after `stored`. An array property's methods take its index parameters first - the same types and the same modes (`const I` for `I` is E2008) - and `index N` adds an Integer after them (by value or `const`; a `stored` function takes that Integer alone); a non-static class function serves an instance property. A record field leads (`read FRec.X` compiles). Fit 3: the same shape of another type (E2010 / E2008), a `var` / `out` value (E2282), a field for an array property, a class var or a static class method for an instance property (E2356), anything but a class var or a static class method for a `class property` (E2355). A member of the right shape and the wrong type stays listed: pastree-lsp's class completion asks this list whether a name is already a member | procedures after `read` / `stored`, functions after `write`; properties, constructors, types; anything outside the class (another unit's private members included) | 0.84.18; a prefix that lexes as a reserved word (`read FOr\|` is `read for`, words being case-insensitive) keeps the accessor 0.85.11 (it was an expression); a property redeclaring an inherited one without a type (`property Foo read \|`) ranks by the inherited property's type 0.84.21 (an inherited array property has nothing to compare: every member leads) |
| a property's `default` / `index` | `property P: T read F default \|`, `index \|` | constants of T; of Integer | variables, typed constants, functions, procedures - a constant expression | 0.84.18 |
| `inherited` | `inherited \|` in a method body | the ancestors' methods and properties (dcc 37: `X := inherited Prop` compiles; a field, a type, a constant is E2096). The enclosing method's own name is fit 0 - what a bare `inherited` calls, `inherited Create` in a constructor - and in a constructor so is every ancestor's constructor (`inherited Create(AOwner)` from `CreateNew`, 0.85.0); every other one is fit 1. In a class method an instance method or property is fit 3 (dcc 37: E2076, E2233); a class method, a static one, a class property and a constructor stay fit 1. `inherited Foo(\|` is a call argument | fields, variables, types, constants, global routines, the class's own new methods; outside a method body nothing | 0.84.18; a class method 0.84.21 |

Type positions (types alone are listed; the context ranks them). A type
item's fit is decided by its own type, not as a value: fit 1 where the
position takes it, fit 2 where it may (a generic parameter, a unit name as
a qualifier, a type whose category or ancestry cannot be followed), fit 3
where dcc rejects it. A ranked position also never lists a type of a
category that cannot stand there at all - a scalar after `is` - as the
heritage list does (a type position's "never listed"):

| Context | Example | Fits | State |
|---|---|---|---|
| a declaration | `Name: \|`; a type constructor's tail: `array of \|`, `array[..] of \|`, `file of \|`; a pointer's `^\|` | any type; types alone - no constant, enumeration value, variable or routine (a subrange there is written by hand). No helper (E2527) except after `^`, which takes one. Nothing ranks; the compiler's own simple types (Integer, Boolean, string, Char, Byte, Word, Cardinal, Double, Pointer, Variant ...; then the other builtins - Int64, SmallInt, AnsiChar ... - and System's Int8 .. UInt32, FixedInt, TDateTime) come first (Conv 0, 1, 2, every other row Conv 3 - 0.85.10: `Name: Int\|` put Int64Rec, INIT_ONCE and the rest above Integer). `^\|;` and `^\|)` complete: `^;` lexes as a caret character, and the text is split at the caret (0.85.10) | done; the tails and `^` 0.85.3 (an IDE test: `array of acc\|` listed the ACCESS_ constants) |
| `class of` | `TC = class of \|` | classes (E2021 otherwise), fit 1; no type of another category, no value | 0.85.3 |
| `set of` | `set of \|` | an ordinal type: one of at most 256 values in 0..255 (an enumeration, Byte, Boolean, AnsiChar) fit 1; a wider one (Integer, Word, a 16-bit Char - W1050) fit 3 (E2028); a range the analysis cannot tell leads; no type of another category, no value | 0.85.3 |
| a generic argument | `TList<\|>`, `TDictionary<string, \|>`, `Foo<\|>(...)` | what the parameter's constraint admits: `class` - classes; `record` - value types (a record, an ordinal, a float, a set); `constructor` - classes (dcc 37 accepts every class, whatever its own `Create` takes, and no record); a class - its descendants; an interface - its descendants and the classes listing it (another class leads: an interface it lists may descend from it); several constraints - what all admit. What a constraint rejects is fit 3; no constraint ranks nothing. No value. A helper is listed (dcc 37 takes `TList<THelper>`); the compiler's simple types first within a fit, as in a declaration (0.85.10) | 0.84.16 (`Foo<\|` on a name that is no generic stays a comparison) |
| `is` / `as`, `is not` | `if Sender is \|`, `Sender as \|` | after a class: its descendants; the class itself and its ancestors lead (the test is true of any non-nil value); an unrelated class is fit 3 (E2010). After an interface: any class. An interface after `as`; after `is` it is fit 3 - dcc 37 rejects `X is IFoo` whatever X is (E2015). A class-reference value (`Sender is AClass`, a function returning one - Self's `ClassType` too; dcc 37 takes it) leads, below the types (0.84.19); no other value - a constant only of a class-reference type (0.84.19: a unit's string constant was listed), no routine, no type of another category - no helper either (dcc 37: E2015 for a class and a record helper alike), and an alias is judged by the type it names (`TCanvasDC = HDC` is none; 0.85.4, an IDE test listed both after `if Self is t\|`). With `Self` on the left and no descendant declared, every class listed is the class, an ancestor (both lead) or unrelated (fit 3). **`as` takes its target's type** (decided by Alex, 2026-11-09): where the whole `X as \|` is assigned (`Acc := AObj as \|`) or passed to a value parameter (`Foo(AObj as \|)`) of a class or an interface type, the cast must convert to it - the target itself fit 0, its descendants (for an interface target also the classes implementing it) fit 1, every other type fit 3, the target's ancestors included (dcc 37: E2010; an interface for a class target E2015). TObject or IInterface as the target narrows nothing (the root-target row); without an outer type, and in a grouping paren (`(AObj as \|).Foo`, `X := (AObj as \|` - a cast in parentheses is mostly read through, and the `)` is often not typed yet), the left operand ranks as above (0.85.11). A class-reference value takes Conv 1 against the types' 0 (0.85.11: `ClassParent`, `ClassType` sorted above the types of their fit in 22% of `is` requests) | 0.84.16 (`as` to an interface from a class implementing none - TObject - is E2015 too, not told apart; a left side the engine cannot type ranks nothing) |
| an exception handler | `on E: \|`, `on \|` | Exception's descendants, the nearer first (Conv: Exception itself, then its children - 0.85.0); another class is fit 3; no value, no type of another category | 0.84.16 (Exception is the class of that name the caret's unit can see - without SysUtils nothing is ranked) |
| a heritage list | `class(\|)`, `class(TBase, \|)`, `interface(\|)` | the first entry of `class(` a class, fit 1 (an interface there is E2021, fit 3); after a comma and in `interface(` an interface, fit 1 (a class after the comma is E2205, fit 3). No helper (E2021), no type of another category - an alias judged by the type it names, a qualified one too (TBytes, PByte, `TLocaleID = LCID` were listed - 0.85.10), never the type declared; a unit name leads | 0.85.10 |
| `implements` | `property P: IFoo read FFoo implements \|`, `implements IA, \|` | interfaces alone (dcc 37: a class there is E2205, also for a class-typed property). Those the class's own heritage list names and the property's own type are fit 0; any other interface fit 1, though dcc rejects one the heritage list does not name (E2265 - an ancestor's list does not count) and, for an interface-typed property, one its type does not descend from (E2010). No value, no other type | 0.84.17 (an interface declared since the last analysis cannot be compared: fit 1) |
| a helper's type | `class helper for \|`, `record helper for \|`, `class helper(THlp) for \|` | a class helper: classes (E2021 otherwise). A record helper: a record or a simple type - an ordinal, a subrange, a float, a string, a set, a pointer, a dynamic array, a Variant; dcc 37 rejects a static array, a procedural type, an interface, a class and a class reference (E2474), which are not listed. Every type listed is fit 1; no value, no routine, no keyword, no helper (E2021 / E2474), never the helper itself; an alias is judged by the type it names, a qualified one too (`EListError = System.SysUtils.EListError` was fit 1 for a record helper - 0.85.10) | 0.84.17 |
| a type declaration's right side | `type T = \|`, `T = type \|` | types and the words that start a type (`class`, `record`, `interface`, `array`, `set`, `procedure`, `function`, `reference`, `packed`, `type`, ...) fit 1; a true constant or an enumeration value - the low bound of a subrange, `T = Low..High` - after them: fit 2 when ordinal, fit 3 otherwise (a string constant). No variable, typed constant (E2026) or routine. After `= type` a type identifier alone: no constant, no keyword (`type 1..5`, `type array of` are E2029). A helper is listed (`T = THelper`, `T = type THelper` compile); the type declared is not (`T = T` is E2086 - a type names itself through `^` and `class of` only, 0.85.10) | 0.84.17 |
| a generic constraint | `<T: \|>`, `<T: class, \|>` | the keywords `class`, `record`, `constructor` first (fit 0), then classes and interfaces (fit 1); no type of another category - an alias judged by the type it names, the edited unit's own too (a `TArray<>` alias was listed - 0.85.10) - no helper, no value. `<A, \|>` names a parameter and is no constraint | 0.84.16 |
| an attribute | `[\|]`, `[A, \|]` before a declaration, a member or a parameter | TCustomAttribute's descendants; another class is fit 3; no value, no type of another category. Listed under the declared name only (`TableAttribute`): dcc takes `[Table]` too, but the filter's start-of-name tier already finds `TableAttribute` for `Tab`, and one row per class keeps its hint and navigation. An argument (`[Foo(\|)]`) is a constant expression (a variable is E2026; 0.85.8), a set constructor and an index keep their contexts | 0.84.16 (TCustomAttribute is the class of that name the caret's unit can see - System's in a real project) |

A type NAME fits as a value where its type would (`X := TFoo(Y)`,
`X := TFoo.Create`): the cast and the constructor both produce one.

Keywords by position (0.85.6, each checked against dcc 37; an IDE test
listed `interface` after `arr: array of int|`). `string` and `nil` come as
the builtin type and constant of that name.

| Position | Keywords listed | Not listed, and why |
|---|---|---|
| `T = \|` | `array` `set` `file` `record` `class` `interface` `dispinterface` `object` `procedure` `function` `packed` `string` `reference` `type` - before the types of their fit (Conv 0 against Conv 1, 0.85.8: over a thousand type names are fit 1 too, and a type constructor is what is written there most) | `of` (never starts a type) |
| a variable's, a field's, a typed constant's type; `array of \|` there | `array` `set` `file` `record` `packed` `string` `procedure` `function` | `class` `interface` `object` (E2058 outside a type declaration), `reference` (E2003, also after `array of` in a type declaration), `of` |
| a parameter's type | `array` `string` `file` | the rest: a type identifier stands there |
| an open array parameter's element (`A: array of \|`) | `const` `string` | |
| a result's, a property's type | `string` | `array` (E2029), `file` (E2024) |
| `^\|` | `string` | |
| a generic argument | `string` | |
| `set of \|`, `class of \|`, `file of \|`, a heritage list | none | |
| `X is \|` | `not` | |
| an operand's start (`:=`, `(`, an operator before) | `nil` `not` `inherited` `function` `procedure` (anonymous methods) `if` (an if-expression) | the binary operators |
| ... in a constant expression (a `case` label, a default, a constant, a bound, an attribute's argument, a property's `default` / `index`) | `nil` `not` | `inherited`, the anonymous methods, `if` (E2026, dcc 37) - 0.85.8 |
| ... a `var` / `out` argument | none: a variable stands there | every operand word - 0.85.8 |
| ... after a directive word: `raise X at \|`, `default \|`, `index \|`, `message \|`, `dispid \|` | as an operand's start (the word is no operand) | the binary operators - 0.85.8 |
| right after an operand | `and` `or` `xor` `div` `mod` `shl` `shr` `is` `as` `in` `not` | `nil`, `inherited`, the anonymous methods |
| a statement's start | `begin` `end` `if` `else` `case` `while` `repeat` `until` `for` `with` `try` `finally` `except` `raise` `goto` `asm` `inherited` `var` `const` | `then` `do` `to` `downto` (they follow a part of a statement) |

- **Filter** - the letters already typed of the identifier at the caret.
- **Fit** (per item, decided by PasTree's `MatchOf`, sent as `data.match`:
  0 and 1 are fit 1 - the same type, an assignable one - 2 is fit 2, 3 or
  absent fit 3; split since 0.84.0):

| Fit | What it is |
|---|---|
| 1 - fits | the same type, or assignable with evidence: a descendant class or interface, an integer for an integer or float, a Char for a string, `True`/`False` for a Boolean, `nil` for a reference or a dynamic array (and for a generic parameter constrained to a class or an interface, 0.85.11), a dynamic array whose element fits (the start of `A[I]`) |
| 2 - leads to it | may reach the value through `.` `[` `(`: an untyped Pointer where a class, an interface, a class reference, a procedural value or a dynamic array is expected (dcc converts it, nobody writes it; since 0.84.7); a value of a class, an interface, a class reference, a procedural value (never walked - their members are the whole library); a record, an array or a typed pointer one of whose members or elements does; a string where a Char is expected (`S[I]`, 0.85.11); a type (`TFoo.Create`, `TPath.Combine`, a cast) judged as its value; a unit name, a function whose result the engine cannot type (`GetValue<T>`, `Ord`, `Copy`); everything where a Boolean is expected, since a comparison makes one of any value |
| 3 - does not fit | proven wrong: a number, a string, a Char, an enumeration or a set of no fit; since 0.84.7 also a record, an array or a typed pointer whose members and elements are each proven wrong, four levels deep (`StringToGUID`'s TGUID where an enumeration is expected: integers, an array of Byte, itself), and a type name the same way (`string` there). A scalar's helper (`S := I.ToString`) is the one way out this ignores. (A procedure is not listed at all - the context's "Never listed".) |

- **Proximity** - where the name is declared, nearest first: locals and
  parameters, members of the class the caret is in, this unit, used units,
  System. The server already sends it as the second key of `sortText`.
- **Conv** (since 0.85.0) - inside a fit, how near the value is to what
  the position wants, 0 nearest (PasTree's `TPasComplItem.Conv`, the
  `sortText` digit after the match). For a value that converts it is read
  off the tables overload resolution ranks by (`XConvDistX`): each
  argument kind's row ranks its own type highest and every target below
  it, so the distance is that row's top less its entry at the target,
  halved (a step of one is no reason to bury a nearer-declared name) - for
  a `TDateTime` (a Double) a Double and a Single 0, an Integer 2, a Byte
  4; for an Int64 an Integer 0, a Word 1, a Byte 2; a Variant last (9); a
  value of no conversion kind where the target has one (an enumeration
  value where an index takes any ordinal) 8; a true constant of the
  target's own category (`N = 5` for an Int64) 0, as it takes the type it
  meets - an integer one for a float stays an integer (`NOERROR` after
  `Norm` for a `TDateTime`). A class is
  graded by its hops to Exception in an exception handler and after
  `raise` (Exception itself first) and nowhere else: measured, the object
  assigned, compared or tested with `is` / `as` is as often a deep class
  as a near one (`Sender = actSave`, `Sender as TStringGrid` from a
  TObject), and nearer-first buried those. Context rules use it too: a
  Boolean's `True` / `False` first outside a condition; a comparison's
  constant first, though not over the routine's own locals and
  parameters; a `case` selector's string after the other values that
  lead.

### The rules

| # | Context | Filter | What is listed | Order |
|---|---|---|---|---|
| A | no | no | everything reachable from the position | proximity, name |
| B | yes | no | everything reachable, less what the context never lists | fit, conv, proximity, name - fit 3 last |
| C | any | yes | every name the filter matches (tiers 1 to 4 below; tier 1 and 2 alone when the IDE's "contain filter" option is off), less what the context never lists | fit 3 last (with a context); above it and inside it: match tier, then fit, conv, proximity, name |

The match tiers of rule C (the tiers VS Code and Roslyn rank a filtered list by):

| Tier | The filter is | Example |
|---|---|---|
| 1 | the whole name | `str` - `Str` |
| 2 | the start of the name | `str` - `StrAlloc` |
| 3 | the start of a word inside it, or the starts of its words in order | `str` - `pkStripe`; `gs` - `GetSelection`; `fpf` - `CC_FPFASTCALL` |
| 4 | anywhere else in it | `fas` - `CC_FPFASTCALL` |

A word starts at a capital after a small letter or a digit, at the last
capital of a run followed by a small letter (`TIEFast`: T, I, Fast), after an
underscore, and at a digit after a non-digit. Without the IDE's "starts with
first" option tiers 1 to 4 are one run.

Selected row: the first. Under the IDE's "Select shortest matching symbol",
the shortest name of the first row's tier and fit.

### Measured (local/cc-sim, 2026-11-05)

317 real `:=`/`=`/`<>` sites of this repository and PasTree, each replayed as
if the right side were being typed. "top 5" is the share where the name the
author wrote is among the first five rows.

| Typed | Order | Head of the right side: top 5 / median row | Member after a dot: top 5 / median row |
|---|---|---|---|
| nothing | name only (before 0.84) | 0% / 1322 | 25% / 14 |
| nothing | fit, name (0.84) | 12% / 207 | 46% / 11 |
| nothing | fit, proximity, name (rule B order) | 20% / 125 | 46% / 11 |
| 1 letter | fit first, then filter match (0.84 before rule C) | 38% / 12 | 61% / 2 |
| 1 letter | start or contained first, then fit, proximity | 41% / 8 | 87% / 2 |
| 1 letter | the four match tiers, then fit, proximity (rule C) | 41% / 8 | 87% / 2 |
| 2 letters | fit first, then filter match (0.84 before rule C) | 68% / 2 | 88% / 1 |
| 2 letters | start or contained first, then fit, proximity | 72% / 2 | 95% / 1 |
| 2 letters | the four match tiers, then fit, proximity (rule C) | 73% / 2 | 95% / 1 |
| 3 letters | fit first, then filter match (0.84 before rule C) | 87% / 1 | 92% / 1 |
| 3 letters | start or contained first, then fit, proximity | 89% / 1 | 100% / 1 |
| 3 letters | the four match tiers, then fit, proximity (rule C) | 89% / 1 | 100% / 1 |

The selected row (the head of the right side) is the author's name at 45% of
the sites with 2 letters typed under the tiers, 42% without them; 63% with 3
letters, 66% without: a whole-name match comes first even where it does not
fit - `nil` for `NIL_NODE`, `Low` for `LowerCase` - as in Roslyn.

A match at a word start inside the name (`pkStripe` for `str`) counted as a
start-of-name match was also measured and is worse than both (1 letter, after
a dot: 64%): every capital is a word start, so one letter matches nearly
everything.

### Measured (all contexts, 2026-11-08)

local/cc-sim `sim2.js` replays every context above on two corpora - this
repository's server and PasTree units ("own", 7 files) and a large
project's 51 units ("large", Win32) - at most 60 sites per context each,
the head of the identifier with 0 and 2 letters typed, ordered exactly as
the plugin orders (rule B, rule C). Cells: top 1 / top 5, 0.84.23 -> 0.85.0
(the conversion grade and the context rules of 0.85.0). A blank: fewer than
5 sites.

| Context | own, nothing typed | own, 2 letters | large, nothing typed | large, 2 letters |
|---|---|---|---|---|
| assignment | 7% / 13% -> 12% / 22% | 50% / 75% -> 57% / 78% | 12% / 33% -> 12% / 35% | 48% / 67% -> 50% / 68% |
| comparison | 2% / 17% -> 3% / 22% | 25% / 75% -> 25% / 75% | 12% / 35% -> 13% / 48% | 55% / 67% -> 60% / 70% |
| call argument | 12% / 45% -> 12% / 45% | 59% / 88% -> 59% / 88% | 17% / 38% -> 18% / 43% | 52% / 73% -> 57% / 77% |
| `var` argument | 5% / 45% -> 5% / 45% | 78% / 97% -> 78% / 97% | 9% / 30% -> 9% / 30% | 64% / 92% -> 64% / 92% |
| value typecast | 20% / 32% -> 20% / 32% | 56% / 76% -> 56% / 76% | 38% / 57% -> 38% / 57% | 63% / 78% -> 63% / 78% |
| `Exit(` | 2% / 7% -> 13% / 42% | 27% / 62% -> 60% / 85% |  |  |
| condition | 0% / 0% -> 0% / 0% | 63% / 90% -> 63% / 90% | 3% / 7% -> 3% / 7% | 42% / 67% -> 42% / 67% |
| `and` / `or` operand | 5% / 13% -> 5% / 13% | 60% / 91% -> 60% / 91% | 2% / 8% -> 2% / 8% | 45% / 68% -> 45% / 68% |
| `not` operand | 25% / 47% -> 25% / 47% | 62% / 87% -> 62% / 87% | 3% / 11% -> 3% / 11% | 53% / 75% -> 53% / 75% |
| `case` selector | 5% / 13% -> 5% / 13% | 62% / 81% -> 64% / 83% | 5% / 37% -> 5% / 37% | 53% / 63% -> 53% / 63% |
| `case` label | 7% / 15% -> 7% / 15% | 7% / 15% -> 7% / 15% | 20% / 92% -> 20% / 92% | 20% / 92% -> 20% / 92% |
| `for` bounds | 7% / 10% -> 7% / 10% | 20% / 83% -> 20% / 85% | 0% / 8% -> 0% / 8% | 20% / 50% -> 23% / 60% |
| `for ... in` | 33% / 60% -> 33% / 60% | 78% / 97% -> 78% / 97% | 50% / 75% -> 50% / 75% | 85% / 95% -> 85% / 95% |
| index | 13% / 52% -> 13% / 52% | 75% / 90% -> 75% / 90% | 48% / 67% -> 48% / 67% | 66% / 82% -> 66% / 82% |
| set element | 12% / 33% -> 12% / 33% | 50% / 74% -> 50% / 74% | 7% / 50% -> 7% / 52% | 28% / 72% -> 28% / 72% |
| operator operand | 20% / 43% -> 20% / 43% | 75% / 93% -> 75% / 93% | 3% / 22% -> 3% / 22% | 45% / 77% -> 45% / 77% |
| `raise` | 14% / 14% -> 14% / 29% | 43% / 43% -> 43% / 43% | 0% / 0% -> 0% / 75% | 75% / 75% -> 75% / 100% |
| `is` / `as` |  |  | 0% / 8% -> 0% / 8% | 10% / 25% -> 10% / 25% |
| exception handler | 0% / 0% -> 89% / 89% | 89% / 100% -> 89% / 100% |  |  |
| `inherited` | 100% / 100% -> 100% / 100% | 100% / 100% -> 100% / 100% | 67% / 67% -> 78% / 78% | 79% / 79% -> 79% / 79% |
| typed constant | 38% / 74% -> 71% / 76% | 91% / 97% -> 91% / 97% | 0% / 9% -> 0% / 9% | 36% / 50% -> 36% / 50% |
| default parameter | 50% / 90% -> 70% / 90% | 90% / 100% -> 90% / 100% | 3% / 38% -> 28% / 60% | 90% / 93% -> 90% / 93% |
| array bound | 0% / 0% -> 19% / 25% | 25% / 31% -> 25% / 38% | 20% / 30% -> 30% / 30% | 80% / 80% -> 80% / 80% |
| attribute |  |  | 0% / 0% -> 0% / 0% | 100% / 100% -> 100% / 100% |
| `type T =` | 0% / 0% -> 0% / 0% | 0% / 100% -> 0% / 100% | 3% / 8% -> 3% / 8% | 27% / 43% -> 27% / 43% |
| property accessor |  |  | 52% / 87% -> 52% / 87% | 82% / 98% -> 82% / 98% |
| declaration type | 0% / 0% -> 0% / 0% | 22% / 25% -> 22% / 25% | 2% / 2% -> 2% / 2% | 17% / 28% -> 17% / 28% |
| generic argument | 0% / 0% -> 0% / 0% | 17% / 27% -> 17% / 27% | 0% / 6% -> 0% / 6% | 22% / 61% -> 22% / 61% |
| heritage list | 0% / 0% -> 0% / 0% | 60% / 100% -> 60% / 100% | 3% / 12% -> 3% / 12% | 15% / 42% -> 15% / 42% |

Where nothing ranks (a declaration's type, a generic argument without a
constraint, a heritage list) the name decides alone. Left as measured: after
`is` / `as` from a TObject every class fits and the one meant is anywhere
in the hierarchy; a `case` label, a set element or an enumeration compared
are values of one type ordered by name; in a condition every Boolean is
fit 0. None of these has a type rule to add. Two orders were tried and
dropped (0.85.0): a class graded by its distance outside a handler and
`raise` (`Sender = actSave`, a deep TAction for a TObject, fell from row
89 to 1519), and constants first in a comparison over the routine's own
parameters (`Status <> AStatus`).

### Open decisions

- **Rule C - DECIDED 2026-11-05: what is proven wrong (fit 3) last, then
  the match tier, then the fit.** Three steps: the tier outer for all, as
  VS Code and Roslyn do; then the fit outer, after a session in the IDE
  (Alex: a name that matches the letters well but does not fit is no help);
  then, with fit 2 and fit 3 told apart, only fit 3 below everything - a
  value that leads to the type (`LM.` for `LM`) is no worse a start than a
  fitting name that merely contains the letters. `PayKind = str` lists
  `pkStripe` above `StrAlloc` (a PChar, which leads to no enumeration) and
  the string functions.
  The replay prices it (run7, top 5, head of the right side / member after a
  dot): 2 letters 62% / 88% against 73% / 95% with the tier outer; 3 letters
  84% / 92% against 89% / 100%. Every loss is a name of the server's third
  group (`data.match` 2), which today holds both "leads to it" and "does not
  fit": `LM` for `LM.UsesList[LU].UnitId`, `Ord`, `FModel.Symbols` - each
  below every fitting name that merely contains the letters.
  With the third group split (0.84.0, run8): the author's name is never fit
  3, so "proven wrong" is sound. Top 5, head / member, by letters typed:

  | Order | 1 | 2 | 3 |
  |---|---|---|---|
  | tier, then fit (VS Code) | 43% / 90% | 74% / 93% | 90% / 100% |
  | fit (1, 2, 3), then tier | 42% / 83% | 63% / 90% | 87% / 97% |
  | fit 3 last; fit 1 and 2 by tier, then fit - rule C | 43% / 90% | 74% / 93% | 90% / 100% |

  The third also selects the author's name most often (2 letters 48%, 3
  letters 67%, against 37% and 60% with the fit outer).
  After two classification fixes (run9: a subrange bounded by an
  expression - TColor, TModalResult - was uncategorized, and every type name
  led somewhere) rule C reaches 51% / 76% / 92% at the head for 1 / 2 / 3
  letters. A fitting name matched at a word start ranked with the name
  starts (`pkStripe` above `StrToGUID` for `str`) was measured and drops
  it to 33% / 70% / 89%: one or two letters start a word in most names.
- **Rule B - DECIDED 2026-11-05: fit 3 goes last, it is not hidden.** Only
  the grammar hides (the "Never listed" column). Hiding by type would have
  lost the author's name at 15 of the 313 sites with a context (5%): 7 types
  (`TStringBuilder.Create`), 6 functions the engine cannot type
  (`GetValue<string>`, `Default`, `Ord`, `Copy`), 2 casts or untyped names.
  A scalar with a helper has members too (`S := I.ToString`), so "another
  scalar type" is not proof of a wrong name. The major engines agree: clangd,
  Roslyn, VS Code and IntelliJ's basic completion all demote on the expected
  type and hide only what the grammar forbids (VS: base lists, `catch`,
  `is`/`as`); IntelliJ hides by type only in its separate smart completion
  and warns that the list can come out empty when inference fails.
- **Rule A - DECIDED 2026-11-05: proximity, then name**, as VS Code orders
  by sortText; the native list sorts by name alone, but the measurement says
  proximity helps wherever there is no filter.
- **The match tiers - TAKEN 2026-11-05 from VS Code and Roslyn** (0.84.0),
  inside each fit group. Not measured: abbreviations (`gs`), which a replay of
  what was typed never produces.

## Server (phase A - done 2026-08-21, on the keyword provider)

1. **Advertise** `completionProvider: {"triggerCharacters": ["."]}` in the
   `initialize` response (`PasLsp.Server.pas:994`). No `resolveProvider` yet -
   nothing lazy to resolve until the provider has documentation to defer.
2. **`HandleCompletion`**, dispatched like the other `textDocument/*`
   requests, with one deliberate difference: **it must not call
   `WaitAnalyzed`** (`PasLsp.Server.pas:860`). That helper flushes the pending
   rebuild and blocks until the closure is analyzed - exactly right for a
   click on stable code, exactly wrong per keystroke (a full rebuild is ~15 s
   on the reference project). The completion rule is: answer from the snapshot
   that exists, now.
   - No snapshot, or a build in flight → empty `CompletionList` with
     `isIncomplete: true` (a legal "ask me again"), in microseconds.
   - Snapshot present → call the seam. The snapshot may trail the text; that
     staleness is acknowledged and lives on the PasTree side of the seam
     (its plan owns "stale model + fresh parse of the one edited file"). The
     server passes the live overlay text precisely so no server rework is
     needed when that lands.
   - Completion never schedules a rebuild either - `didChange` already did.
3. **Response**: `CompletionList` with `isIncomplete` and items carrying
   `label`, `kind`, `detail`, `sortText`, and a `textEdit` built from the
   provider's replace span. Always `textEdit`, never bare `insertText` - the
   span is authoritative and survives a cursor that moved while the answer was
   in flight.
4. **Cancellation**: nothing new - `$/cancelRequest` and the cancel-poll
   already cover it; the handler checks the cancel set before serializing.
5. **Log line**: `completion <file>:<line>:<col> in <N> ms -> <M> items
   (<provider>)` - same discipline as `analysis done`/navigation lines; the
   log is the diagnosis surface for "completion shows nothing".
6. **Harness** (`LspClientSmoke`, section 5b): the request answers; items are
   filtered by the typed prefix; every item's `textEdit` range is exactly the
   typed token; and the replace span survives the UTF-16 column conversion on
   the Cyrillic fixture line (`DemoUnicode.pas` - same line the decode split
   was pinned on). The checks pin the CONTRACT, not the vocabulary: when
   PasTree replaces the keyword provider, everything but the literal labels
   must keep passing unchanged.

## Plugin (phase B - done 2026-08-21: LspCompletion plus the gated manager)

1. **`PasTreeIdePlugin.LspSession`** (done): add `LspCompletion(AFileName, ARow,
   ACol, ATriggerChar, AOnDone)` on the existing `Ask` pattern - its own
   pending-id slot, supersede-cancels-the-previous, closure-per-call capture,
   `FDocs.Sync` before send (sync-on-request already guarantees the server
   sees the freshest text - the requirement above is satisfied by the
   existing design, nothing new to build). Parses the `CompletionList` into a
   plain record array (`TLspCompletionItem`: label, kind, detail, replace
   span) - no JSON escapes past the session boundary, same as `TLspHit`.
2. **`PasTreeIdePlugin.CodeInsight`** (built; live bring-up CONFIRMED
   2026-08-21 - viewer, prefix filtering and accept-replaces-prefix all
   behave. Two findings a future reader needs: the undocumented AsyncInvoke*
   position parameters do NOT point at the caret's text, so completion reads
   EditPosition instead; and the native row layout is reproduced by the STOCK
   renderer once the columns are fed natively - SymbolClassText carries the
   left-hand class word in DelphiLSP's own vocabulary ('keyword', 'function',
   'const', …), SymbolTypeText is the glued-after-the-name slot where real
   signatures will go verbatim. Custom drawing was tried and backed out: the
   stock look IS the native look. The native viewer's bottom key-legend panel
   is that window's own chrome - nothing in ToolsAPI reaches it, managers get
   the classic window): `TPasCodeInsightManager`
   implementing `IOTACodeInsightManager100` (registration takes the sync
   interface) and offering `IOTAAsyncCodeInsightManager`/`…290` via
   `Supports` - the async shape is the whole point. The method map:
   - `HandlesFile` → `IsPascalSourceFile` (already shared).
   - `AsyncInvokeCodeCompletion` → `LspCompletion`; on answer, fill a local
     `TPasSymbolList` (implements `IOTACodeInsightSymbolList`) and invoke the
     IDE's callback. `SetFilter`/`FindIdent` are then answered synchronously
     from that cached array - they are called per keystroke and may never
     round-trip (the constraint clients/rad-studio/SPEC.md documents).
   - `AsyncGotoDefinitionEx` → the existing definition path in
     `PasTreeIdePlugin.GotoDeclaration`'s resolve logic - but returning
     file/line/col to the IDE instead of navigating ourselves: under the
     manager, the IDE navigates and keeps history. This is the migration seam
     the decided endgame needs.
   - Everything the server cannot answer yet - parameter insight, hint text -
     declines honestly (`AllowCodeInsight` says no for those invocations), so
     the IDE shows nothing rather than something wrong.
3. **Registration** - always on (revised 2026-08-21 at the user's call; the
   plan originally gated it behind `PASTREE_CODEINSIGHT=1`, and the gate was
   judged more ceremony than safety for a dev-stage plugin whose recovery
   path is uninstalling it). The IDE's own selection step is the real gate:
   registration alone takes nothing over - the manager only answers once the
   user picks "PasTree" under Tools > Options > Editor > Source > Insight
   Provider, and the same combobox switches back.
4. **Teardown**, per the standing rule: `RemoveCodeInsightManager` before the
   BPL unloads, ordered with the other unregistrations in
   `TIDEWizard.Destroy`.

## Phase C - DONE 2026-08-22

The mouse-notifier Ctrl+Click override and the `cEdMenuCatIdentifier` menu
takeover are deleted (the stepping stone - the override standing down when
PasTree was the selected provider - proved the manager's browse path live
first). The manager is the one navigation path: the IDE draws the
Ctrl+hover underline from our resolver, navigates, and keeps history; the
native "Find Declaration" menu item is back in its native slot and routes
by provider selection like everything else; the one-way-door caveat retired
with the code that carried it. "Find Type Declaration" and "Find
References" are not Code Insight concepts, so they stay ours - now under
the plugin's OWN menu category, cleanly unregistered at unload. The
provider contract cuts both ways and is accepted: selecting DelphiLSP gives
native navigation everywhere, PasTree gives ours everywhere - one combobox,
the whole insight family.

## Deferred polish (TODO)

**Rich row coloring in the RAD viewer** - **delivered 2026-08-22**, one day
after being noted, because step 1 turned out to already exist: the item
carries no signature field, but the project answers a symbol's DECLARED TYPE
on demand (`SymDeclTypeX`/`SubstX`/`XTypeText` - the recipe PasTree's own
demo popup uses, ≤512-item guard included). The seam emits `': <type>'` in
`detail` plus the routine's head word (`ItemHeadWord`, PasTree 0.5.0) in the
item's `data`; the plugin feeds `detail` to `SymbolTypeText` (the glued slot
IS the native layout) and `DrawLine` takes over COLORS only: class word and
punctuation dimmed, type name in the theme-aware blue, the selected row left
in the viewer's own highlight for contrast - which is what the native window
does too.

**Full routine signatures - delivered 2026-08-22, same day:** the parameter
list turned out to need no new engine API either - the declaration's
`nkParams` span read verbatim from the source text (whitespace-collapsed,
capped) IS the signature, so a routine row now reads
`(const AName: string): string` like the native list. The same walk decides
`hasParams`, which rides the item's `data`.

**Tooltip Insight - delivered 2026-08-22** (was queued below): plugin-only,
as predicted - `LspHover` on the Ask pattern, the session strips the
server's markdown to tooltip plain text, `AsyncGetHintText` serves it and
key `#3` stopped declining. The hint position trusts the browse-confirmed
parameter convention; if a tooltip ever describes the neighbor token, that
conversion is the first suspect.

**Auto-parenthesis - delivered 2026-08-22** (was queued below): `Done`
inserts `()` and steps the caret inside when the accepted item's
`hasParams` says so - a parameterless routine stays bare. Two recorded
deviations from the original note: the IDE's own "Auto parenthesis" option
is NOT honored (nothing in ToolsAPI exposes its value - searched), and
parens apply only on keyboard accepts (Enter/Tab), so a future close-key
`(` accept cannot double the paren.

**Parameter insight - plumbing delivered 2026-08-22, real provider later
the same day.** The full chain ships: `textDocument/signatureHelp` on the
no-WaitAnalyzed rule (trigger chars `(` and `,`), the manager's
`AsyncInvokeParameterCodeInsight` + both `IOTACodeInsightParameterList`
views + key `#1` un-declined, and the active argument recounted server-side
per request (`ParamIndex` answers -1 = reinvoke, so it cannot drift). The
provider is PasTree's `CallAt` (0.6.0, its plan §8B): innermost enclosing
call with indexers/grouping parens/casts stepped over, designator resolved
through the overlay+bridge - member calls and freshly typed cross-unit
calls both answer, the two recorded gaps of the interim backward-walk
locator, which was deleted as promised the day `CallAt` landed. Nothing
above the seam moved in the swap.

(Tooltip Insight and auto-parenthesis were queued here and are delivered -
see above.)

**Colored tooltips (noted 2026-08-22, wanted but blocked in ToolsAPI):** the
manager's hint path (`GetHintText`/`AsyncGetHintText`) accepts a bare string
and no custom-draw hook exists for the editor's hint window - the colored
hover the native IDE shows is the new LSP window's private UI, same class as
its bottom key-legend panel. The only route is a hint window of OUR OWN
(mouse-hover via the editor notifier, anchored with `GetCharacterPosPx`,
painted by `DrawColoredSignature`) - roughly a day, and it owns its
positioning/dismissal/theming. Queued behind parameter insight if wanted.

**Intrinsics show no signatures (found live 2026-08-22) - FIXED the same
day.** Compiler-seeded routines (SetLength, Length, Inc, ...) have no
source declaration, so every declaration-span consumer here showed them
bare. PasTree 0.6.0 ships curated display signatures for all 97 seeded
intrinsics plus a takes-arguments flag (its plan §8C), and they flow
through `ItemParamsText`/`ItemHasParams`/`CallAt` - so completion Detail,
signatureHelp and auto-parenthesis all answer for `SetLength(` now, with
all-optional intrinsics (Exit, Halt, Writeln) correctly staying bare.

## Handed to the PasTree plan (deep-review outcome, 2026-08-22)

RESOLVED 2026-08-22: PasTree 0.6.0 shipped the whole ask - public
`ItemParamsText`/`ItemHasParams` (empty `()` answers False, the
auto-parenthesis semantics ours pioneered), `TPasTree.NodeSpanText`, and
`CallAt`. The seam's private copies (`RoutineNodeOf`, `ParamsNodeOf`,
`HasParamChild`, `NodeSpanText`) are deleted; `cMinPasTreeVersion` rose to
0.6.0. The seam keeps only display concerns: the 100-char Detail cap and
`SplitParamLabels` (params text → individual LSP parameter labels).

## Deliberately not in this plan

- **`completionItem/resolve`** - until the provider defers documentation
  loading there is nothing to resolve; advertising it buys latency for
  nothing. **Settled for good on 2026-08-23**, when documentation arrived
  (XMLDoc, PasTree 0.6.3's `ItemDocComment`): it ships with EVERY item
  instead, because the RAD viewer asks a row for its documentation through
  `IOTACodeInsightSymbolList80.GetSymbolDocumentation` - a synchronous
  UI-thread call that may never round-trip - so a resolve pass would serve
  the one client we do not have and leave ours blank. The per-row cost is
  a backward raw-token step that stops immediately for every undocumented
  declaration, i.e. nearly all of them.
- **A word-scan-the-buffer provider** - identifiers harvested textually would
  LOOK scope-aware while ignoring scope, which teaches distrust. The keyword
  provider skirts this by being visibly, unmistakably just the reserved
  words; anything smarter waits for PasTree.
- **`textDocument/signatureHelp`** - same seam, separate feature; it enters
  this plan only after completion itself is real.
- **Incremental reanalysis** - the freshness gap is owned by the PasTree plan;
  this side is already shaped so that neither outcome (fresh-file-parse or
  true incremental) changes the server or plugin code.
