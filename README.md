#  Concurrency Utilities

## Introduction
A set of types and protocols that build from atomicity (`Atomic`) to futures (`Future`) to Reactive Streams. Futures are built on to of `Atomic` and Reactives Streams on top of futures. All three are useful when writing concurrent programs and the art of sucessfully writing concurrent programs is choosing the most suitable abstraction for the problem. When writing a new concurrent program it is suggested that you start with Reactive Streams, since these are the easiest to use, and only if there are problems consider the other abstractions.

## Using in your project
The easiest way to use these types and protocols in your own code is to clone this project from GitHub inside Xcode 9 and then drag the relevant swift files into your project. The files are only small so having a copy shouldn't be an issue (however you will need to manually update). If you just want atomicity then you just need `Atomic.swift`, for futures `Future.swift` *and* `Atomic.swift`, and for reactive streams you need `ReactiveStream.swift`, `Future.swift`, *and* `Atomic.swift`.

## Atomic
Provides atomic access to a value; you can `get`, `set` and `update` the value. To update a value you supply a closure to `update` that accepts the old value and returns the new value; the `update` method also returns the new value from the closure. Calls to `get`, `set` and `update` can occur is any order and from any thread and are guaranteed not to expose partially updated values. Calls to `get`, `set` and `update` block until they have completed. Update can be used as a lock as well as providing atomicity, e.g.:

    let lock = Atomic<Void>()
    …
    // In thread 1
    lock.update {
        …
        return ()
    }
    …
    // In thread 2
    lock.update {
        …
        return ()
    }

The threads will block until the other has finished because they are sharing `lock`.

`Atomic` is a class and therefore instances would normally be declared using `let` (which can seem odd since they obviously mutate!).

See `Concurreny_UtilitiesTests.swift` for examples.

## Futures
A future allows control and monitoring of a background task that returns a value (though the value may be a `Void`, i.e. `()`). You obtain the value of a future using `get` (which will timeout), you cancel a future with `cancel`, and you can find out their status using `status` (which is primarily for debugging and is one of `.running`, `.completed(result: T)`, or `.thew(error: Error)`).

You typically type futures as `Future` so that any type of furure can be supplied. Most commonly you create an `AsynchronousFuture` which is a future that evaluates asynchronously on a specified queue (defaults to global default queue which is concurrent) and with a specified timeout (defaults to 1 second). An `AsynchronousFuture` is given a closure to execute in the background that accepts a termination test argument (`try testTermination()`), can throw, and returns the future's value. `testTermination()` is automattically tested before and after the closure is run, but it is up to the programmer to test whilst the closure is running.

The future's timeout limits how long `get` will wait (block) and therefore breaks and/or detects deadlocks. If the future timeouts, is cancelled, or throws then `get` will return `nil`, otherwise it will return the future's value. The future's `status` is only updated after the closure has run, however `get` reflects timout and cancel whether the closure is still running or not. `get` returning `nil` can be used to provide a default value.

The futures frameworks also includes an extension on `Thread` to allow easy running on the main thread for UI updates. EG:

    func getFromWeb(url: URL) throws -> Future<String> { ... }
    func updateUI(_ s1: String, _ s2: String) { ... }
    ...
    let cancellableUIAction = AsynchronousFuture { isTerminated -> Void in
        let future1 = getFromWeb(url: address1) // These two lines run concurrently.
        let future2 = getFromWeb(url: address2)
        let s1 = future1.get ?? defaultS1 // `get` returns `nil` on error/timeout/cancel, hence default.
        let s2 = future2.get ?? defaultS2
        try isTerminated() // If cancelled there is no update to do.
        Thread.executeOnMain {
            updateUI(s1, s2) // Does not block main thread because all waiting in background.
        }
    }
    ...
    cancellableUIAction.cancel() // Wired to cancel button on UI.

A future may repressent a continually running background task and therefore have no value; in which case `get` would not be called and hence timeout would be ignored, it can however still be cancelled. EG:

    let backgroundTask = AsynchronuousFuture { isTerminated -> Void in
        while true { // Runs until cancelled
            try isTerminated() // Test for cancellation
            ... // Background task
        }
    }
    ...
    backgroundTask.cancel() // Background task runs until it is cancelled.

*It is intended that stream-flow operators are available that match those that go with the Reactive Flow classes, however currently the Swift 4 compiler can't infer the type, see bug report [SR-5853](https://bugs.swift.org/browse/SR-5838), and therefore these operators are not usable.* An overload for operator `~>` is provided for futures; this is particularly handy when working with Reactive Streams, see below. `future ~> &result` is equivalent to `result = future.get`. Overloads for `~>!` and `~>?` exist and do as expected; throws on `nil` and does nothing on `nil` respectively.

Futures are classes and therefore instances would normally be declared using `let` (which might seem odd because they mutate) and they are also thread safe and therefore can be shared between threads.

See `Concurreny_UtilitiesTests.swift` for examples.

## Copyright and License
Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.

The full licence is [here](LICENSE.md) and an easy to follow summary [here](https://creativecommons.org/licenses/by/4.0/).
