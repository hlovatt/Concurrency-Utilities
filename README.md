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

See `AtomicTests.swift` for examples.

## Futures
A future allows control and monitoring of a background task that returns a value (though the value may be a `Void`, i.e. `()`). You obtain the value of a future using `get` (which will timeout), you cancel a future with `cancel`, and you can find out their status using `status` (which is primarily for debugging and is one of `.running`, `.completed(result: T)`, or `.thew(error: Error)`).

You typically type function arguments and returns as `Future`, so that any of the more specific types of future can be supplied. Most commonly you create an `AsynchronousFuture` which is a future that evaluates asynchronously on a specified queue (defaults to global default queue which is concurrent) and with a specified timeout (defaults to 1 second). An `AsynchronousFuture` is given a closure to execute in the background that accepts a termination test argument (`try testTermination()`), can throw, and returns the future's value. `testTermination()` is automattically tested before and after the closure is run, but it is up to the programmer to test whilst the closure is running.

The future's timeout limits how long `get` will wait (block) from when the future was created and therefore breaks and/or detects deadlocks. If the future timeouts, is cancelled, or throws then `get` will return `nil`, otherwise it will return the future's value. The future's `status` is only updated after the closure has run, however `get` reflects timout and cancel whether the closure is still running or not. `get` returning `nil` can be used to provide a default value using the  Nil-Coalescing Operator (`??`).

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

A future may be a continually running background task and therefore have no value; in which case `get` would not be called and hence timeout would be ignored, it can however still be cancelled. EG:

    let backgroundTask = AsynchronuousFuture { isTerminated -> Void in
        while true { // Runs until cancelled
            try isTerminated() // Test for cancellation
            ... // Background task
        }
    }
    ...
    backgroundTask.cancel() // Background task runs until it is cancelled.

*It is intended that stream-flow operators are available that match those that go with the Reactive Flow classes, below, however currently the Swift 4 compiler can't infer the type, see bug report [SR-5853](https://bugs.swift.org/browse/SR-5838), and therefore these operators are not usable.* An overload for operator `~>` is provided for futures; this is particularly handy when working with Reactive Streams, see below. `future ~> &result` is equivalent to `result = future.get`. Overloads for `~>!` and `~>?` exist and do as expected; throws on `nil` and does nothing on `nil` respectively.

Futures are classes and therefore instances would normally be declared using `let` (which might seem odd because they mutate) and they are also thread safe and therefore can be shared between threads.

See `FutureTests.swift` for examples.

## Reactive Streams
Reactive Steams are a standardised way to transfer items between asynchronous tasks; they are widley supported in many languages and frameworks and therefore both general and detailed descriptions are available:

  - [Manifesto](http://www.reactivemanifesto.org)
  - [Specification](https://github.com/reactive-streams/reactive-streams-jvm/blob/v1.0.1/README.md#specification)
  - [Wiki](https://en.wikipedia.org/wiki/Reactive_Streams)

Reactive Streams are dynamic (can be reconfigured on the fly), can signal errors, can be cancelled, and use pull requests to control the number of items transfered. The terminology used is:

  - *Back pressure:* A subscriber controls the flow of items from a producer by requesting a number of items from the producer, if it stops requesting items then the producer must stop producing items (this is termed back pressure).
  - *Item:* What is transfered from a producer, optionally via a processor, to a subscriber.
  - *`Processor`:* Represents a processing stage, which obtains items from an upstream producer, processes these items, and supplies the processed items to a downstream subscriber (i.e. a processor is both a producer, for downstream subscribers, and a subscriber to upstream producers).
  - *`Producer`:* Provider of a potentially unbounded number of sequenced items, producing them according to the demand received from its subscriber(s).
  - *`Subscriber`:* Subscribe to a processor and recieve from the processor a subscripion, using this subscription the subscriber controls the flow of items from the producer to the subscriber.
  - *`Subscription`:* 'Contract' between a producer and subscriber for the supply of items, in particular the subscription regulates the rate of flow of items and signals completion, errors, and cancellation.

The Reactive Stream standard defines just four protocols: `Processor`, `Producer`, `Subscriber`, and `Subscription`, their methods, and the function the methods take are described in the [Reactive Streams Specification](https://github.com/reactive-streams/reactive-streams-jvm/blob/v1.0.1/README.md#specification). The implimentation in Swift of these protocols in this library faithfully follows the specification, but with Swift naming and type conventions rather than Java naming and type convensions, e.g. in Java you have:

    interface Subscriber<T> {
        void onError(Throwable t);
        ...
    }
        
and in Swift this becomes:
        
    protocol Subscriber {
        associatedType SubscriberItem
        func on(error: Error)
        ...
    }

This is similar to how Objective-C and C APIs are 'translated' when imported into Swift.

On top of the specification's protocols the library provides implementations of processors, producers, and subscribers with their associated subscriptions. These implementations are styled after the standard Swift collection library, in particular `Sequence`, for example there is a `ForEachProducer` and a `ReduceSubscriber` and the arguments when creating these classes mimic the arguments to the methods from `Sequence`, e.g. `ReduceSubscriber` accepts a `into` argument into which the reduction happens and a reduction closure that reduces the stream of items to a single item.

Subscribers, as well as conforming to `Subscribe`, also extend `Future` and are therefore a type of future (see above). The `get`, `cancel`, and `status` methods from `Future` behave as expected. In particular `get` gives access to the value of the subscriber, if any, and waits for the subscriber to complete.

To simplify connecting producers, to processors, to subscribers the operator `~>` is defined, that is the Tilde (not Minus) followed by the Greater Than characters. This was chosen because the Tilde looks like an 's' on its side and the operator establishes a subscription, because the Tilde is wavey and therefore represnents who the flow of items adjusts dynamically, and the Greater Than indicates the direction of flow.

Hello World using this library is:

    let helloWorldPublisher = ForEachPublisher(sequence: "Hello, world!".characters)
    let helloWorldSubscriber = ReduceSubscriber(into: "") { (result: inout String, next: Character) in
        result.append(next) // Copy the string a character at a time.
    }
    helloWorldPublisher ~> helloWorldSubscriber
    let helloWorldResult = helloWorldSubscriber.get ?? "Failed!"

Note how the arguments to `ForEachProducer` and `ReduceSubscriber` mimic those to similarly named methods in Swifts `Sequence` protocol, how `~>` is evocative of the process that is occurring, and how future's `get` controls execution and error reporting.

See `ReativeStreamTests.swift` for examples.

## Copyright and License
Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.

The full licence is [here](LICENSE.md) and an easy to follow summary [here](https://creativecommons.org/licenses/by/4.0/).
