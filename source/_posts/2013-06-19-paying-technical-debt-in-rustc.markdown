---
layout: post
title: "Paying technical debt in rustc"
date: 2013-06-19 14:00
comments: false
categories: [rust, refactor, debt]
---

With the 0.7 release of Rust almost upon us, it seems like a good time talk about some of the
technical debt that has accrued in the compiler, the issues in the codegen module and plan of
action to try and start paying off some of that debt.

<!-- more -->

The rust compiler has two kinds of technical debt. The first is the normal kind of technical debt
where you say "screw it, I'll do it properly later". This debt is common everywhere and generally
comes from a need to get it working quickly, or fixing a problem that is blocking the solution you
are actually working on. There isn't actually too much of this kind of debt in the rust code base.

The other kind of debt you find in the compiler is rather more unique. The Rust compiler is,
itself, written in Rust. This opens up whole new type of technical debt: not doing it properly
because it wasn't possible at the time. Whether this means having to work around a bug in order to
fix that bug, or having old patterns obsoleted by new features, this type of debt is much more
insidious. At the time of writing, the author of such code isn't aware of the debt he is creating.
He can't be. This means you end up with a proliferation of bad patterns and inconsistent code as
the langauge evolves and the codebase struggles to keep up.

## The debt in `trans`

For the uninitated, the codegen module in `librustc` lives in `middle::trans`, which I will refer
to as `trans` from here on in.

`trans` is where the compiler stops being a very specific static analyzer and starts being an
actual compiler. Turning abstract representation into LLVM IR. This means that it is one of the
most critical parts of the compiler from a performance standpoint. Some of the major issues with
Rust are related to the output from this stage. One major issue is that our final IR is
significantly larger than it should be. However, I'm not here to talk about what is wrong with the
functionality in `trans`.

Instead, I'm going to talk about how the accrued technical debt in `trans` stops, or at least
hinders, fixing those issues.

### Incomplete, bad and non-existant abstractions

An incredible number of functions in `trans` take a `TypeRef` or `ValueRef` directly. These are
LLVM objects and are completely opaque. Furthermore, we often end up needing information that
neither of these objects are capable of encoding, but don't have easily available. Often the code
uses suspicious work arounds or regenerates the required information. This is silly because we have
the full information from the type checker available to us.

Some abstractions do exist, like `Datum`, but the lack of full integration into the rest of the
module means that their use is limited. Even `Datum` is incomplete however, omitting useful
information that would allow us to make better decisions in code. This means the abstractions we do
have are bogged down trying to make sure they work with the rest of the code. It could be called
leaky, but this more like deliberately punching a hole in your roof so the birds can still get in.

Some of the biggest offenders are where we have only partial abstraction. Take for example
functions. We have a `fn_ctxt` object for "abstracting" functions, but you already need an LLVM
`ValueRef` for the function itself before you can create one. This means that _creating_
a function, first starts with _declaring_ it with a completely unrelated function, then you can
start building it's body. Oh, and by the way, declaring a function consists of calling one three
functions: `register_fn`, `register_fn_full` or `register_fn_fuller`. If you find yourself writing
a function with the word "fuller" at the end, I suggest you take a step back and think about the
life choices that led you here.

This often means that a simple operation will trace through dozens of functions in several files.
A simple wrong turn can lead you down a path that might not _ever_ be used any more, wasting time.

### Bad patterns

A common pattern in old Rust code is to do something like this:

{% codeblock lang:rust %}
struct Foo_ {
    num: int
}

pub type Foo = @mut Foo_;
{% endcodeblock %}

This code predates the powerful region system we have now, and (presumably) served to make life
easier, since you would otherwise need to pass around a `@mut Foo` explicitly. Times have changed
though, and this pattern only makes it harder to fix things. Patrick Walton recently informed me
that 7% of the time spent during compilation is on ref-count bumping. This is because a function
like this:

{% codeblock lang:rust %}
fn bar(a: Foo) -> int {
    a.num
}
{% endcodeblock %}

does a ref-count increase for `Foo` when entering the function, then later drops that count when
the function ends. In the simple example above, that might be optimized out, but more often than
not there is no way for the optimizer to know that it can do that, so the useless ref-count bumps
stay.

Unfortunately, these patterns lead to more bad patterns, and then more bad patterns. A good example
is a statistic that relies on scoped destruction to construct nested contexts that get popped off
as the context ends. The current context is stored in a structure that gets passed around to most
functions, and the object that does the "popping" on destruction maintains a reference to that
context. This means that the object needs a mutable reference to that structure that lasts for the
entire function. This conflicts with the borrowing rules that prevent you from having multiple,
mutable borrows (or even a mutable and an immutable one at the same time). Thus the solution is
that you still need the `@mut` everywhere, even though that feature is literally the only thing
that needs it.

Similarly, there are plenty of other cases that only work because they rely on the nature of `@` or
`@mut` that could easily work another way with modern Rust.

### Poor naming and documentation

Some things in `trans` are just badly named. Either they are misleading or opaque. This is because
of the "I know what they mean" effect. Some are somewhat benign, with the proliferation of `T_*`
functions being a little opaque, but are easy to figure out (LLVM TypeRef construction). Others are
maddening, like the `get_landing_pad` function in `base` that actually constructs the landing pad.
Other cases where there are dead arguments, or redundant arguments, or arguments are exist to
service one very specific case that infect every call to that function (or produce the crazy
`register_fn*` chain).

The poor documentation is more to do with the poor abstractions and naming than an absence of
comments. Often you'll need to trace the life of a particular piece of data, but be unable to find
where it comes into being. This is because some poorly-named function constructs it as a side
effect and it is later pulled out of some cryptic map by a line of code that _just knows_ that
it'll be there. Unfortunately, more often than not, the reason you are trying to trace this
particular object is because some other line of code that _just knows_ about the existence of that
object, is wrong.

### Death by a thousand paper cuts

There are too many minor issues with the code to list them all. Individually they aren't
a significant problem, but they conspire to make it just a little _too_ difficult to fix something.
Especially when that's not why you were there. Many of these issues could be fixed at the same time
as others, but the hassle it causes makes contributors (who often are volunteers working for
_free_) avoid it because they are trying to fix something else.

## How to fix it

This is the sticking point, high-level ideas are nice, but I'm not well-versed enough the code to
know exactly what we need in terms of new abstractions and refactorings. It's obvious that we need
to unify the function handling code, but what a function abstraction needs to look like is beyond
me.

I do know that something needs to be done, and I've tried, but I've hit the limit of my
understanding of the existing code and basic refactorings aren't going to help much anymore. In an
ideal world, we would just throw out `trans` and start again. Maybe salvaging what's there in order
to save time. Unfortunately, this is the real world and we can't stop all work on the compiler
while a module is being re-written. So the existing code needs to be moved, re-written, refactored
and improved, piece by piece until we get something that we don't have to ward newbies away from in
case they pick up bad habits.
