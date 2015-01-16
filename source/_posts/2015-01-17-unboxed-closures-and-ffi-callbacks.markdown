---
layout: post
title: "Unboxed Closures and FFI Callbacks"
date: 2015-01-17 11:24:36 +1300
comments: false
categories: rust
---

Rust is awesome, but sometimes you need to step out of the comforting embrace of a powerful type
system and watchful compiler and interact with other languages. Fortunately Rust handles this
quite well, with a robust and easy-to-use foreign function interface that requires little more
than writing out the signatures of the foreign functions.

However that is only half the battle when writing bindings. The next part is figuring out the best
way to present the (normally) C API to Rust users. Exploiting the type system and features of the
language as best you can. Sometimes this is easy, sometimes hard, but one thing that is always
tricky to manage are callbacks.

Rust has closures as first-class entities, so it's natural that a bindings author would want to use
them when exposing a callback API to users. But how do you map Rust's closures to C's idea of
functions? Well, that's what I'm going to show you.

<!--more-->

For the purposes of this demonstration, I'm going to assume that you have a C function that looks
a little like this:

```c
void do_thing(int (*cb)(void*, int, int), void* user_data);
```

Note that the presence of that `void*` in both the callback signature and the function itself. This
is fairly common, the pointer is passed to the callback untouched. It's also required for this
technique to work. I'll show everything, end explain it afterwards.

```rust
pub mod ffi {
  extern "C" {
    // Declare the prototype for the external function
    pub fn do_thing(cb: extern fn (*mut c_void, c_int, c_int) -> c_int,
	   	  	    user_data: *mut c_void);
  }
}

// Exposed function to the user of the bindings
pub fn do_thing<F>(f: F) where F: Fn(i32, i32) -> i32 {
  let user_data = &f as *const _ as *mut c_void;
  unsafe {
	ffi::do_thing(do_thing_wrapper::<F>, user_data);
  }

  // Shim interface function
  extern fn do_thing_wrapper<F>(closure: *mut c_void, a: c_int, b: c_int) -> c_int
      where F: Fn(i32, i32) -> i32 {
	let opt_closure = closure as *mut Option<F>;
	unsafe {
	  let res = (*opt_closure).take().unwrap()(a as i32, b as i32);
	  return res as c_int;
    }
  }
}
```

So, first we declare the prototype so we can call it from Rust code, fairly standard stuff here.
Next, we make the actual exposed function and take a closure of the appropriate type. I've opted
for the `Fn` unboxed closure kind, but you could take a `FnMut` or even a `FnOnce` if you know the
callback will only be called once.

Now, inside this function is the tricky part. `&f as *const _ as *mut c_void` takes a reference
to the closure, casts it to a raw pointer (the `_` means that you want the compiler to infer that
part of the type) and then casts again to get the `*mut c_void` we need to pass along as the user
data. The actual call to the FFI function contains this oddity: `do_thing_wrapper::<F>` this uses
the ability to explicitly provide the type parameters to functions to, well, explicitly provide the
correct type. This is needed because otherwise Rust can't figure out the correct type to fill in.

The `do_thing_wrapper` is a foreign-ABI Rust function. This means that it's a function, written in
Rust, that uses a non-Rust ABI. In this case, because we didn't provide one explicitly, it falls
defaults to "C". Other than the type parameter, it matches the signature of the callback for the
`ffi::do_thing` function.

Inside the wrapper, we cast the closure to a `*mut Option<F>`, then do
`(*opt_closure).take().unwrap()` on it, this returns the actual unboxed closure we started with.
Then we call the closure, converting the arguments to the correct type and return the result,
again converting to the appropriate type.

And that's it! Note that this will only work if you know that the closure will be called before the
end of `do_thing`. We take a pointer to the entire closure, which exists on the stack, so that
pointer will become invalid when `do_thing` returns.

## How it works

The way this works is actually remarkably simple. The key part is the `do_thing_wrapper::<F>`
expression. Rust uses a technique called "monomorphisation" to handle generic types, including
generic functions. Monomorphisation basically consists of subtituting the type parameters with
concrete types and compiling the resulting non-generic function. What happens when `do_thing` is
monomorphised is that `do_thing_wrapper::<F>` is also monomorphised, creating a unique function
that is of the correct type to pass to the callback. Since we used a type parameter in
`do_thing_wrapper`, we can cast from the passed opaque pointer to the actual closure and continue
as normal.