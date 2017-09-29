#  Concurrency Utilities

## Introduction
A set of types and protocols that build from atomicity (`Atomic`) to futures (`Future`) to Reactive Streams. Futures are built on to of `Atomic` and Reactives Streams on top of futures. All three are useful when writing concurrent programs and the art of sucessfully writing concurrent programs is choosing the most suitable abstraction for the problem. When writing a new concurrent program it is suggested that you start with Reactive Streams, since these are the easiest to use, and only if there are problems consider the other abstractions.

## Using in your project
The easiest way to use these types and protocols in your own code is to clone this project from GitHub inside Xcode 9 and then drag the relevant swift files into your project. The files are only small so having a copy shouldn't be an issue (however you will need to manually update). If you just want atomicity then you just need `Atomic.swift`, for futures `Future.swift` *and* `Atomic.swift`, and for reactive collections you need `ReactiveCollection.swift`, `ReactiveCollectionBaseClasses.swift`, `ReactiveStream.swift`, `Future.swift`, *and* `Atomic.swift`.

The file `ReactiveStream.swift` just contains the protocols etc. to define a Reactive Stream and can be used to build an implementation of Reactive Streams, one such implementation is `ReactiveCollection.swift`,

## Atomic
Provides atomic access to a value; you can `get`, `set` and `update` the value. To update a value you supply a closure to `update` that accepts the old value and returns the new value; the `update` method also returns the new value from the closure. Calls to `get`, `set` and `update` can occur is any order and from any thread and are guaranteed not to expose partially updated values. Calls to `get`, `set` and `update` block until they have completed.

`update` can be used as a lock as well as providing atomicity, e.g.:

    let lock = Atomic<Void>(()) // `()` is `Void` literal.
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

`get` and `set` can be used to ensure visibility accross threads (`volatile` keyword in other C like languages), e.g.:

    let volatile = Atomic<T>(initialValue)
    …
    // In thread 1
    volatile.value = … // Write to volatile.
    …
    // In thread 2
    let value = volatile.value // Read from volatile.

Thread 2 will see the changes made by thread 1.

`Atomic` is a class and therefore instances would normally be declared using `let` (which can seem odd since they obviously mutate!).

See `AtomicTests.swift` for examples.

## Future
A future allows control and monitoring of a background task that returns a value (though the value may be a `Void`, i.e. `()`). You obtain the value of a future using `get` (which will timeout), you cancel a future with `cancel`, and you can find out their status using `status` (which is primarily for debugging and is one of `.running`, `.completed(result: T)`, or `.thew(error: Error)`).

You typically type function arguments and returns as `Future`, so that any of the more specific types of future can be supplied. Most commonly you create an `AsynchronousFuture` which is a future that evaluates asynchronously on a specified queue (defaults to global default queue which is concurrent) and with a specified timeout (defaults to 1 second). An `AsynchronousFuture` is given a closure to execute in the background that accepts a termination test argument (`try testTermination()`), can throw, and returns the future's value. `testTermination()` is automattically tested before and after the closure is run, but it is up to the programmer to test whilst the closure is running.

The future's timeout limits how long `get` will wait (block) from when the future was created and therefore breaks and/or detects deadlocks. If the future timeouts, is cancelled, or throws then `get` will return `nil`, otherwise it will return the future's value. The future's `status` is only updated after the closure has run, however `get` reflects timout and cancel whether the closure is still running or not. `get` returning `nil` can be used to provide a default value using the  Nil-Coalescing Operator (`??`).

The futures frameworks also includes an extension on `Thread` to allow easy running on the main thread for UI updates. EG:

    func getFromWeb(url: URL) throws -> Future<String> { ... }
    func updateUI(_ s1: String, _ s2: String) { ... }
    ...
    let cancellableUIAction = AsynchronousFuture { isTerminated -> Void in
        let future1 = getFromWeb(url: address1) // These two lines run in parallel (if > 1 core).
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

An existing API that uses a completion handler (common in Cocoa) can easitly be converted into using a `Future`. Suppose in the above example `getFromWeb` was written using a completion handler:

    func getFromWeb(url: URL, completion: (_ result: String?, _ error: Error?) -> Void) { ... }

Then this can easily be converted into a `Future`:

    func getFromWeb(url: URL) -> Future<String> {
        return AsynchronousFuture { () -> (String?, Error?) in
            var resultError: (String?, Error?)
            getFromWeb(url: url) { // Call the original completion handler version.
                resultError = ($0, $1) // Store its result.
            }
            return resultError
        }
    }

A further feature of `Future`s is that they only timeout when get is called. A design pattern used with futures is the completable future, this is accomplished using `Future` via a zero timeout. A completable future lets you override the result if the future hasn't completed regardless of how long it has had to complete. A typical use case might be:

    let f = AsyncronousFuture(timeout: .seconds(0)) { isTerminated -> String in // Note zero timeout.
        // Get or calculate text.
    }
    // Stuff that would take some time goes here.
    let s = f.get ?? defaultText // Because timeout is zero `get` never waits.

The above is a completable future because `get` returns instantly with either `nil` if the future hasn't completed or if the future threw or with the value if the future completed, therefore without waiting you recieve either the completed value or the default (i.e. a completable future).

A future may be a continually running background task and therefore have no value; in which case `get` would not be called and hence timeout would be ignored, it can however still be cancelled. EG:

    let backgroundTask = AsynchronuousFuture { isTerminated -> Void in
        while true { // Runs until cancelled
            try isTerminated() // Test for cancellation
            ... // Background task
        }
    }
    ...
    backgroundTask.cancel() // Background task runs until it is cancelled.

An custom operator `~~>` is provided for futures; this is particularly handy when working with Reactive Streams, see below. `future ~~> result` is equivalent to `result = future.get`. Additionally `~~>!` and `~~>?` exist and do as expected; throws on `nil` and does nothing on `nil` respectively. *The Swift 4 compiler has a bug, see [SR-5853](https://bugs.swift.org/browse/SR-5838), where it infers an `&` that it shouldn't (the correct construct is `future ~~> &result` - note `&`).*

Futures are classes and therefore instances would normally be declared using `let` (which might seem odd because they mutate) and they are also thread safe and therefore can be shared between threads.

See `FutureTests.swift` for examples.

## Reactive Stream
Reactive Steams are a standardised, Actor like, way to transfer items between asynchronous tasks; they are widely supported in many languages and frameworks and therefore both general and detailed descriptions are available:

  - [Manifesto](http://www.reactivemanifesto.org)
  - [Specification](https://github.com/reactive-streams/reactive-streams-jvm/blob/v1.0.1/README.md#specification)
  - [Wiki](https://en.wikipedia.org/wiki/Reactive_Streams)

Reactive Streams are dynamic (can be reconfigured on the fly), can signal errors, can be cancelled, and use pull requests to control the number of items transferred. The terminology used is:

  - *Back pressure:* A subscriber controls the flow of items from a producer by requesting a number of items from the producer, if it stops requesting items then the producer must stop producing items (this is termed back pressure).
  - *Item:* What is transferred from a producer, optionally via a processor, to a subscriber.
  - *`Processor`:* Represents a processing stage, which obtains items from an upstream producer, processes these items, and supplies the processed items to a downstream subscriber (i.e. a processor is both a producer, for downstream subscribers, and a subscriber to upstream producers).
  - *`Producer`:* Provider of a potentially unbounded number of sequenced items, producing them according to the demand received from its subscriber(s).
  - *`Subscriber`:* Subscribe to a processor and receive from the processor a subscription, using this subscription the subscriber controls the flow of items from the producer to the subscriber.
  - *`Subscription`:* 'Contract' between a producer and subscriber for the supply of items, in particular the subscription regulates the rate of flow of items and signals completion, errors, and cancellation.

The Reactive Stream standard defines just four protocols: `Processor`, `Producer`, `Subscriber`, and `Subscription`, which in turn define just seven methods. The methods are described in the [Reactive Streams Specification](https://github.com/reactive-streams/reactive-streams-jvm/blob/v1.0.1/README.md#specification). A summary of how the protocols and methods interact and in what sequence is shown diagramatically:

  [Overview Diagram](ReactiveStreamTimeSequence.pdf)

In practice Reactive Streams are easy to use because their action is largely automated; the programmer declare instances of producers, processors, and subscribers and then arranges for the processors to subscribe to the producers and the subscribers to subscribe to the processors. Using the Reactive Collection Library, described below, the overview diagram referenced above is:

    producer ~~> processor ~~> subscriber

The interactions shown in the diagram occur automatically once subscriptions are established, via the `~~>` operator.

The implementation in Swift of these protocols faithfully follows the Java specification, but with Swift naming and type conventions, e.g. in Java the standard specifies:

    interface Subscriber<T> {
        void onError(Throwable t);
        ...
    }
        
and in Swift this becomes:
        
    protocol Subscriber {
        associatedType InputT
        func on(error: Error)
        ...
    }

This is similar to how Objective-C and C APIs are 'translated' when imported into Swift.

## Reactive Collection
### Introduction
On top of the specification's protocols the library provides implementations of processors, producers, and subscribers with their associated subscriptions. The reactive collections run asynchronously and provide locking and background threads without the need for the user of the library to deal with threads/locking manually; but they are not themselves thread safe since it makes no snese to share them between threads, you use them instead of threads! These implementations are styled after the standard Swift Collection Library, in particular `Sequence`, for example there is a `ForEachProducer` and a `ReduceFutureSubscriber`:

  - The arguments when creating these classes mimic the arguments to the methods from `Sequence`, e.g. `ReduceFutureSubscriber` accepts a `into` argument into which the reduction happens and a reduction closure that reduces the stream of items to a single item.
  - Like the Swift Collection Library the action of these classes is specified using a trailing closure, e.g. `ReduceFutureSubscriber`'s trailing closure accumulates the results.
  - There is a logical naming convention going from most important to least important part of the name left to right of `[<SwiftCollectionName> | <Other>][Future]?[Seeded]?[Producer | Processor | Subscriber | ForkProcessor | JoinProcessor]`, where:
  
    - `<SwiftCollectionName> | <Other>`: The method/ptotocol name of the nearest equivalent in the Swift Collection Library (e.g. `forEach` from `Sequence` for `ForEachProducer`) or another name if nothing is suitable (e.g. `ClockedForkProcessor`). The `Other` part-name ends in `ForkProcessor` for processors that fork a single flow into multiple and in `JoinProcessor` for the reverse of joing multiple flows into one.
    - `Future`: *If* the class is also a `Future`; e.g. `ReduceFutureSubscriber` which gives access to the result of the reduction using  future's interface, in particular `get` or `~~>?`.
    - `Seeded`: Is appended to the name *if* the constructor has an `initialSeed` argument that is not present in the equivalent Swift Collection method. The seed is used as working storage for the trailing closure and is passed in as an `inout` parameter. EG `IteratorProducerSeeded` passes its seed to its `nextItem` closure, the equivalent in Swift's Collection Library is `IteratorProtocol` which would be implemented in a `struct`/`class` and the implementation would provide the storage instead of seed. 'Seeded' is styled after the Swift Collection `reduce(into: initialResult) { ... }` method, where the `into` argument is in this case both the seed and the final rersult.
    - `Producer | Processor | Subscriber | ForkProcessor | JoinProcessor`: Describe the role of the class. Producers are at the start of a flow, processors in the middle, and subscribers at the end. Typical usage is `producer ~~> processor ~~> subscriber`. `ForkProcessor` are processors that fork a single stream into multiple and  `JoinProcessor` are the reverse of joing multiple streams into one (`Fork`s and `Join`s are always `Processors` because they have, by definition, an input and an output).

Reactive Collections are easy to use, since the client programmer makes instances of the Reactive Collection classes and then joins these instances together using the `subscribe` method or `~~>` operator (see below). The other methods defined by the Reactive Stream API are not used by the client programmer; but by the library *automatically*. Some `Subscriber`s also extend `Future` and the  `get`, `cancel`, and `status` methods from `Future` provide client interaction. In particular `get` gives access to the value of the subscriber, if any, and waits for the subscriber to complete.

To simplify connecting producers, to processors, to subscribers the operator `~~>` is defined; that is two tildes (not minus) followed by  greater-than. This was chosen because the tilde looks like an 's' on its side and the operator establishes a subscription, because the tilde is wavy and therefore represents dynamic flow, and because the greater-than indicates the direction of flow. The operator `~~>` is prefered over method `subscribe` because it habituates the programmer away from method calls which as stated above are mainly not for programmer use. For the same reason, it is recommended that `~~>?` etc. are used with `Subscriber`s that are `Future`s also.

### Hello World (Publishers and Subscribers)
Hello World using this library is:

    let helloWorldPublisher = ForEachPublisher(sequence: "Hello, world!".characters)
    let helloWorldSubscriber = ReduceFutureSubscriber(into: "") { (result: inout String, next: Character) in
        result.append(next)
    }
    var helloWorldResult = "Failed!"
    helloWorldPublisher ~~> helloWorldSubscriber ~~>? helloWorldResult

Note how the arguments to `ForEachProducer` and `ReduceFutureSubscriber` mimic those to similarly named methods in Swifts `Sequence` protocol, how `Subscriber`'s `~~>` is evocative of the process that is occurring, and how `Future`'s `~~>?` looks natural and controls execution and error reporting.

`helloWorldPublisher ~~> helloWorldSubscriber` runs asynchronously and `~~>? helloWorldResult` waits for the result (`helloWorldResult` is both a `Future` and a `Subscriber`). `Publisher`s produce items in the background via Grand Central Dispartch (GCD) queues and the items are passed to and processed by subsequent stages in the thread processing the queued production task. The production of items per task is specified by the *subscribers* `bufferSize` argument, since it is the subscriber that requests items to be produced. The queue that a producer is to use can be specified when constructing the producer.

### Processors
Typically you would have intermediate stages in a calculation, `Processor`s that take an input and produce an output (these are similar to `Sequence`'s `map` and `filter` methods). The Monte Carlo method of approximating Pi estimates the ratio of the area of a square to the area of an arc. Consider a square piece of paper 1 by 1, i.e. both x and y ordinates run from 0 to 1,  with an arc drawn with centre at (0, 0) from (0, 1) to (1, 0), i.e. it has a radius of 1. If darts are randomly thrown at the paper then approximately the ratio of arc area / square area is the number of darts inside arc / total number of darts. From which Pi can be approximated as 4 times the area ratio. Using the Reactive Collection Library this is:

    let maxRandom = Double(UInt32.max)
    let randomCoordinatePublisher = IteratorSeededPublisher(initialSeed: ()) { _ in
        return (Double(arc4random()) / maxRandom, Double(arc4random()) / maxRandom)
    }
    let piEstimatorProcesssor = MapSeededProcessor(initialSeed: (0, 0)) { (seed: inout (Int, Int), coordinate: (Double, Double)) -> Double in
        var (total, inside) = seed
        total += 1
        let (x, y) = coordinate
        if x * x + y * y <= 1.0 {
            inside += 1
        }
        guard total < 14_000 && inside < 11_000 else {
            throw SubscriberSignal.cancelInputSubscriptionAndComplete
        }
        seed = (total, inside)
        return 4.0 * Double(inside) / Double(total)
    }
    let lastValueSubscriber = ReduceFutureSubscriber(into: 0.0) { (old: inout Double, new: Double) in
        old = new
    }
    var estimatedPi = Double.nan
    randomCoordinatePublisher ~~> piEstimatorProcesssor ~~> lastValueSubscriber ~~>? estimatedPi

Note how the processor, `piEstimatorProcesssor` sits between the publisher, `randomCoordinatePublisher`, and the subsciber, `lastValueSubscriber`. The publisher generates an *infinite* stream of random coordinates. The subscriber memorizes the last value, *ad-infinitum*. The intersting code is in the processor which:

  - Estimates Pi as described above.
  - Is a `map` much like `Sequences`'s `map`, however it is also seeded which allows it to keep track of the total number of coordinates and the number inside the arc between each call to its mapping closure.
  - Terminates the estimation when sufficient number of total points and points inside the arc have occurred (both the publisher and the subscriber run *indefinitely*).
  
Termination can be achieved by a subscriber or as in this case a processor by throwing `SubscriberSignal.cancelInputSubscriptionAndComplete`, which as the name suggests terminates the input stream by cancellation and the output stream by completion. Publishers, like `helloWorldPublisher` from the 1st example, terminate streams by calling the `onComplete` method of their subscriber (which for `ForEachPublisher` occues when the sequence's iterator's next method returns `nil`). (The Reactive Stream specification *only* allows input subscriptions to cancelled and output subscribers to be notified of completion, this throwing of `SubscriberSignal.cancelInputSubscriptionAndComplete` to allow subscribers and hence processors to signal completion is an extension provided by the Reactive Collection Library.) 

### Examples
See `ReativeCollectionTests.swift` for examples.

## Reactive Collection Bases
Typically you use the sequence like classes, `IteratorSeededPublisher`, `ForEachPublisher`, `ReduceFutureSubscriber`, etc., from the Reactive Collection Library. However an alternative to these are the base protocols/classes provided by the Reactive Collection Bases Library. These protocols/classes:

  - Simplify writing your own Reactive Stream implementations.
  - Can be used as an alternative to the sequence like classes by inheriting/subclassing.
  - These classes are the base protocol/classes for the classes provided by the Reactive Collection Library described above.
  - Are abstract protocols/classes and require implementing/sub-classing, see description of protocols/classes to see which methods require implementing/overridding. Swift 4 does not have the concept of an abstract class and therefore default implementations for classes throw a fatal error. Also there is no concept in Swift 4 of protected access therefore the methods to overrride in classes have `open` access. When using a sub-class of these base clases it is safer to use the operator `~~>` and not call the methods directly since this will prevent the error of calling a method that ideally would be protected accidently.
  - There is a logical naming convention going from most important to least important part of the name left to right, similar to that of the Reactive Collection Library described above, of `[<SwiftCollectionName>]?[Producer | Processor | Subscriber | ForkProcessor | JoinProcessor][Future]?[Class]?[Base]` where:
  
    - `<SwiftCollectionName>`: The method/protocol name of the nearest equivalent in the Swift Collection Library (e.g. `Iterator` from `IteratorProtocol` for `IteratorProducerBase`), or nothing if the class is not specialised in and way (e.g. `SubscriberBase`).
    - `Producer | Processor | Subscriber | ForkProcessor | JoinProcessor`: Describe the role of the class. Producers are at the start of a flow, processors in the middle, and subscribers at the end. Typical usage is `producer ~~> processor ~~> subscriber`. `ForkProcessor` are processors that fork a single stream into multiple and `JoinProcessor` are the reverse of joing multiple streams into one (`Fork`s and `Join`s are always `Processors` because they have, by definition, an input and an output).
    - `Future`: *If* the class is also a `Future`; e.g. `FutureSubscriberBase` which gives access to the result of the subscription using  future's interface, in particular `get` or `~~>?`.
    - `Class`: *If* the base is a class rather than a protocol then the name has `Class` as its 2nd last element, e.g. `IteratorProducerClassBase`. (These would be abstract classes in other languages, but Swift doesn't have abstract classes. Similarly default implementations of methods that must be overridden throw a fatal exception because there are no abstract methods in Swift.)
    - `Base`: All the names end in `Base` to indicate that the protocol/class is 'abstract' and requires implementing/sub-classing.
    
    Where these protocols/classes introduce new methods and properties their names begin with `_`; treat these as protected methods, i.e. do not call them - they are part of the library. (Swift doesn't have the concept of a protected method. Similarly if the method is in a protocol there is no way to mark it as final, therefore read the documentation carefully to decide if it is suitable for overridding. Conversely if the method is defined in a class there is no way to mark it as abstract and so methods that would be abstract throw a fatal error.)

## Issues
  1. If a subscriber cancels its subscription, the producer keeps producing, and the subscriber subscribes to another producer whilst the 1st is still producing, then it will recieve items from both producers! (The Reactive Stream Specification allows producers to keep producing post cancellation.) Whilst it would be possible to fix this, it would be a noticable performance overhead and therefore this option of items from multiple subscriptions is chosen as the 'lesser of the evils'! See `testKeepProducingBufferSizeItemsAfterCancel` in `ReactiveCollectionTests.swift` for an example.

## Roadmap
  4. Add `clone`.
  5. Latest value after timeout instead of timeout error, `TimeoutFutureSubscriber` - name? How does it fit with naming convention.
  6. Add `Fork` and `Join` `Processors` to enable:
  
          randomCoordinate ~~> fork ~~> [
              countTotal,
              filterInside ~~> countInside
          ] ~~> join ~~> piEstimator ~~> rememberLast ~~>? result
          
  7. Bidirectional streams/flows, e.g. simulating international, credit card transactions at Point Of Sale (POS) terminals:
  
          let kyd = Currency(oneUSDIs: 0.82)
          let pab = Currency(oneUSDIs: 1.00)
          let chf = Currency(oneUSDIs: 0.97)
          let currencies = [kyd, pab, chf]
          let masterCard = CardAssociation(currencies)
          let visaCard = CardAssociation(currencies)
          let caymanBank = Bank(currency: kyd, association: masterCard)
          let panamaBank = Bank(currency: pab, association: visaCard)
          let swissBank = Bank(currency: chf, association: masterCard)
          let donaldsCard = Card(limit: 1_000_000, bank: caymanBank)
          let sarahsCard = Card(limit: 1_000, bank: panamaBank)
          let vladimirsCard = Card(limit: 1_000_000_000, bank: swissBank)
          let cards = [donaldsCard, sarahsCard, vladimirsCard]
          let posTerminals = (0 ..< 2 * currencies.count).map { _ in
              PosTerminal(cards)
          }
          
          [posTerminals[0], posTerminals[1]] <~~> caymanBank.posTerminals
          [posTerminals[2], posTerminals[3]] <~~> panamaBank.posTerminals
          [posTerminals[4], posTerminals[5]] <~~> swissBank.posTerminals
          caymanBank.cardAssociations <~~> [masterCard, visaCard]
          panamaBank.cardAssociations <~~> [masterCard, visaCard]
          swissBank.cardAssociations <~~> [masterCard, visaCard]
          caymanBank.otherIssuers <~~> [panamaBank.transactionValidation, swissBank.transactionValidation]
          panamaBank.otherIssuers <~~> [caymanBank.transactionValidation, swissBank.transactionValidation]
          swissBank.otherIssuers <~~> [caymanBank.transactionValidation, panamaBank.transactionValidation]
          
          for posTerminal in posTerminals {
              posTerminal.get // Wait for each POS terminal simulation to finish.
          }
  
  8. See if `DispatchWorkItem` would be a better implementation for `Future`.

## Copyright and License
Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.

The full licence is [here](LICENSE.md) and an easy to follow summary [here](https://creativecommons.org/licenses/by/4.0/).
