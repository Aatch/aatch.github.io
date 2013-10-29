---
layout: post
title: "Down the rabbit hole: A trip through trans"
date: 2013-09-18 17:00
comments: false
published: false
categories: [rust, trans]
---

Inspired by a recent post from Corey Richarson
[here](http://cmr.github.io/blog/2013/06/30/structure-and-organisation-of-rustc/) I decided to
write about the general flow through the translation module in `rustc`, i.e. trans. This is a bit
of a wild ride, so follow me down the rabbit hole.

<!-- more -->

# Striding outwards

So our journey starts in `middle::trans::base`, specifically, the function `trans_crate`, this is
entry point for the module receiving information about the session, analysis passes and the AST
itself. The first major thing to do is create a `CrateContext` that will hold all the information
we need to track during code generation. Once we have this object, the real work can begin. A quick
jump into `trans_mod` to start working our way through the items using `trans_item`.

An item in rust is pretty much any top-level code in Rust. Functions, `impl`s, enums, statics,
structs traits and mods are all items. `trans_item` matches the item it is given and calls out to
other functions to do the actual work.

# Lazy Generics

So the first thing to mention is that generics in rust are initialized on use. This is the only way
to do it, so inside `trans_item` each item is checked to see if it has any type parameters (where
appropriate of course) and if so, is skipped. This means that `trans_item` only works on concrete
types.

# Enumeration Nation

Next stop is the translation of `enum`s. These are more complicated than you might first think as
Rust's enums are really *Algebraic Data Types* or ADTs. People coming from functional languages
like OCaml or Haskell will be familiar with ADTs, for those that aren't they are essentially
language-level tagged unions. This means that compiler can ensure that they are used properly.

However, since the representation of enum's is a deliberately undefined, the compiler is free to
perform optimisations on the representation (also, it means you shouldn't use the information that
follows in code, since it may change in the future). Thus, there are 4 different cases to handle.

## C Town

The simplest case is when none of the enum variants have any fields. These are known as C-like
enums and look something like this:

{% codeblock lang:rust %}
enum CLike {
    First,
    Second,
    First
}
{% endcodeblock %}

These are represented as a simple range of integers. In fact, in the generated code, you'll find
that they are just subtituted with integers. The variants are treated as constant values that
happen to have that particular type.

## Univariant Crossroads

A univariant enum is simply an enum with only one variant. Since there is no need to be able to
distinguish between variants, the representation is the same as a tuple or struct. In fact, structs
and tuples actually use the Univariant representation so we'll come back here later.

Observant readers may notice that there is a potential overlap between C-like enums and univariant
enums, since you can have a C-like enum with a single variant. Well, the test for a C-like enum
comes before a univariant enum, so the C-like enum property wins out here.

## Nullable Pointer Place

"Nullable Pointers" are an interesting optimisation. While the univariant one simple takes
advantage of the fact that you don't need a way to distinguish between only option, nullable
pointers take advantage of the fact that Rust's standard pointers can't be null.

Since owned, shared and borrowed pointers all have the property that they aren't null, this
actually allows the compiler to use the value of the pointer to distinguish between multiple
variants. This only applies in a fairly specific case of an enum with 2 variants, one of which is
zero-length and the the other contains a non-nullable pointer. It can however have other fields,
including more pointers.

The pointer in the other variant is then used as the discriminant, instead of having to add an
extra field. The most obvious case here is `Option<T>`. When `T` is a pointer type, `Option<T>`
becomes a nullable pointer that forces you to do null checks, but still only takes up the space of
a single pointer (normally one word).

## General City

This is the general, and most common, case. This is when you have many variants and those variants
have fields. Such an example is this:

{% codeblock lang:rust %}
enum MyEnum {
    Var1(int, int),
    Var2(~str),
    Var3(@MyEnum),
    Var4
}
{% endcodeblock %}

So in this case, we have 4 variants and so we need some way to distinguish between them.  Enter the
discriminant. The discriminant is just a value that allows you to *discriminate* between the
different variants at runtime. So we create a discriminant for each variant, which currently is
just a number starting at 0 and incrementing for each variant. Then, for each variant a struct
representation is created, including the discriminant. LLVM uses structural typing, so we can do
this without having to name the types. We also pick one to be the "generic" type, the type that
goes into all the function arguments and variables and the like. The generic type is the one with
the largest alignment, so it will always be able to contain all the variants.

For the example, the 4 types are, assuming a platform with a native int of 8 bytes:

{% codeblock lang:llvm %}
; Var1, this is also the "generic" type
{int, int, int}
; Var2 (%str is just the string representation, it's the pointer that matters here)
{int, %str*, [8 x i8] }
; Var3, again, it's just the fact that it's a pointer that matters
{int, %MyEnum*, [8 x i8] }
; Var4
{int, [16 x i8] }
{% endcodeblock %}

The `[n x i8]` field at the end of each representation is padding to make all of
the variants the same size. This is because in order to switch between the different cases we have
to use an LLVM instruction called `bitcast`. `bitcast` has the restriction that it only works
between types that have the same size.

Finally, for each tuple-like variant (`Var(int, int)` for example), a function is created that
returns the actual value. This is because constructing a tuple variant is, syntactically, the same
as calling a function.

# Structs ho!

Structs in rust come in two flavours. The regular "struct" flavor that everybody knows and loves
and tuple structs.

{% codeblock lang:rust %}
// A "regular" struct
struct MyStruct {
    f1: int,
    f2: (char, u8, u8)
}

// A tuple struct
struct MyTupleStruct(int, bool);
{% endcodeblock %}

When it comes to `trans` however, we treat the two types almost identically. LLVM structs, as shown
above, don't name their fields, so the code we generate doesn't need those names either. The only
different treatment they are given in `trans` is that a tuple struct, like a tuple-like variant,
has a constructor function made for it. The representation of the types in LLVM is basically just
a direct translation of the fields into LLVM structs however, re-using the univariant enum code to
generate the representation.

# Static Statue Garden

Static variables in rust are also quite simple, being translated directly to globals in LLVM IR.
The translation code is fairly simple, with much of the work being translating expressions into
constant values.
