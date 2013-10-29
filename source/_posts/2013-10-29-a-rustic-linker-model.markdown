---
layout: post
title: "A Rustic Linker Model"
date: 2013-10-29 13:15
comments: false
categories: [rust, linking]
---

This is a kinda-sorta proposal for a linking model for the rust compiler to use, allowing us to
separate out from system-specific semantics and avoid being tied too closely to a system linker.
The goals are to maintain most compatibility with system tools (linkers in particular), allow
common cases to behave identically on all supported platforms and maintain an escape hatch to allow
complex and/or esoteric cases to still work without too much hackery or relying on undocumented
behaviour.

<!-- More -->

## What is linking?

If you are already familiar with the concept of linking, feel free to skip this section, otherwise
here is a quick rundown of what linking is.

If you come from a primarily dynamic-language background (Python, Ruby, etc) then the concept of
linking is likely unfamiliar to you. However, it is an important step in the process of turning
your code into a library that can be shared or an executable that actually does something. Briefly,
linking is the process of taking compiled code and "linking" it with other compiled code to allow
that code to call out to other libraries.

When you compile a Rust library, one step produces a temporary file called an *Object File*. This
is a file in a specific format depending on what platform you're on. On Linux, this file is in the
ELF format. Now, this file only contains your code, so if you called any functions or methods from
other places you have references to those in your code, they are called *Unresolved Symbols* and
until they are resolved your code won't work.

The process of linking mostly involves finding out where those unresolved symbols live and, well,
resolving them. The linker will look in the libraries it has been told to for those symbols and
makes a note of where it found the symbol. While the exact behaviour depends on what type of file
you want to make, the process of making that file is effectively the same for both executables and
libraries.

If an unresolved symbol is found in a static library, then the code associated with that library is
copied into the new file and the symbol is resolved to point there. If the symbol is found in
a dynamic library, then the name of that file is added to a special list in the new file. When the
file is loaded (either in order to run it, or because another file needs it), this list is used to
load any required files and dynamically resolve any symbols needed.

## Platform Compatibility

This, to me, is probably the most important point. While there is a difference between being
compatible and being user-friendly, being incompatible with platform tools could severely limit the
situations that Rust would otherwise work in. This means using platform-specific formats and making
sure that any Rust-specific functionality can be implemented across the majority of platforms.

Fortunately, this goal is actually easier to achieve than not acheive as we would otherwise have to
replicate a lot of functionality that already exists in system tools. Ultimately, we're better off
using the work already done than trying to create our own system that does the same thing.

The only exception to this goal is supporting LTO (Link Time Optimisation). However, it seems that
all other implementations of LTO share the same limitation, so it does not seem unreasonable to
share this limitation for Rust.

## Common Cases

The phrase "Common Case" has a lot of baggage, as everybody has a different idea of what a "common"
case is. However, for the purposes of this discussion, I shall define "common" to be compiling
either a host platform executable or a host platform library. This should be broad enough to cover
most cases without too much controversy.

With that in mind, there are 4 types of files I have identified as common-case outputs

* Executable
* Dynamic Library
* Static Library
* LTO Library

In order to make linking behaviour the same across platforms, we need to specify what behaviour we
want in order to see what we might need to augment on what platforms to allow for the behaviour we
want. The behaviour, apart from standard linking behaviour, is as follows:

* Linking to a library does not add any extra explicit dependencies to the initial project. This is
  the same for both dynamic and static libraries.
* The default priority for linking libraries is LTO libraries then static libraries followed
  finally by dynamic libraries. This can be controlled on an overall-level and a per-library level.
  It should be possible to force a dynamic link even if a LTO library is available and it should be
  possible to prioritise a dynamic library over a static one.
* The path searched for libraries should start with command-line passed search paths, followed by
  a rust-specific linker path environment variable (e.g. `RUST_LIBRARY_PATH`), finally followed by
  the system linker path.
* The default behaviour for linking to a static library should *not* cause the static library to
  become a dependency. This could be overridden in cases where you know that the dependencies will
  always be available. (For example, the core libraries)
* The same rules should apply when linking in a non-rust library.

Again, this should cover most common cases and is already similar to the existing model. The first
two points are related. The way libraries are chosen is based on the first match found by searching
the paths, meaning that a dynamic library that is on a path earlier than a static library will be
linked instead of the static library.

This behaviour is intended to be separate from any platform-specific behaviour, the intention being
to provide a consistent base that users can rely on. Ideally we should be able to "fill in the
gaps" where platform behaviour deviates from the described behaviour.

## Uncommon cases and People doing weird things

These are cases that should be kept in mind, even though they might be more off of the radar than
most people will encounter.

* Cross-Compilation. Not particular out-there, but uncommon nonetheless. Ultimately, this should
  just require an extra flag to the compiler to compile to a different target. There may be
  interaction with linking to incompatible libraries though, so that needs to be kept in mind.
* Non-standard linking process. This is doing stuff like using your own linker scripts to get finer
  control over the linker. The most obvious example here I can think of are kernels, where custom
  linker scripts are required to put symbols at known addresses.
* Linking from a non-Rust environment. This is linking to a library from another natively-compiled
  language, like C. While there are things to be aware of outside of just linking, we should try to
  avoid making the process too difficult.
* Linking in non-Rust object files. This is important for doing things like integrating assembly
  files into the object.

To some extent, merely providing tools to inspect rust crates and maintaining the existing
object-only output should help with most of these. Though handling many of them in the compiler
would be nice.

## Conclusion

Supporting the uncommon cases is what I am most interested in here. Currently, Rust can be quite
difficult to use outside of the standard environment. I am aware though that the uncommon cases are
uncommon for a reason, and therefore have prioritised what *I* think the common cases are. I am
also undecided on the priority for the different library types, what is important is that
a priority exists, not what the priority actually is.
