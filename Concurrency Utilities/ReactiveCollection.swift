//
//  ReactiveCollection.swift
//  Concurrency Utilities
//
//  Created by Howard Lovatt on 5/9/17.
//  Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.
//

import Foundation

// MARK: `Publisher`s.

/// Produces items by setting a seed to the given `initialSeed` and then calling the given `nextItem` closure repeatedly (giving the seed as its argument).
///
/// - warning:
///   - If either methods `cancel` or `request` (from `Subscription`) are called when there is no subscriber the result is a fatal error.
///   - When a subscriber subscribes to this class it is passed `self` (because this class is its own subscription).
///     Therefore each subscriber has to `nil` out its reference to the subscription when it receives either `on(error: Item)` or `onComplete()`, otherwise there will be a retain cycle memory leak.
///   - The *only* method/property intended for use by a client (the programmer using an instance of this class) is method `subscribe`; which is best called using operator `~~>` since that emphasizes that the other methods are not for client use.
///   - If multiple subscriptions are attempted; subsequent subscriptions are rejected with their `on(eror:)` method called with `PublisherErrors.subscriptionRejected(reason:)`, but the original subscription continues.
///   - This class is not thread safe (it makes no sense to share a publisher since Reactive Streams are an alternative to dealing with threads directly!).
///
/// - note:
///   - This producer terminates when `nextItem` returns `nil`.
///   - This producer is analogous to `IteratorProtocol`.
///   - Each subscriber receives all of the iterations individually, i.e. each subscriber receives the whole sequence because the seed is reset between subscriptions.
///
/// - parameters
///   - S: The type of the seed used by given closure `nextItem`.
///   - O: The type of the output items produced by given closure `nextItem`.
public final class IteratorSeededPublisher<S, O>: IteratorPublisherClassBase<O> {
    private let initialSeed: S
    
    private let nextItem: (inout S) throws -> O?
    
    private var seed: S

    /// Produces items by setting a seed to the given `initialSeed` and then calling the given `nextItem` closure repeatedly (giving the seed as its argument).
    ///
    /// - parameters:
    ///   - queue: Dispatch queue used to produce items in the background (default `DispatchQueue.global()`).
    ///   - initialSeed: The value of the seed at the start of each iteration cycle.
    ///   - nextItem: A closure that produces the next item, or `nil` to indicate termination, given the seed (which it can modify)
    ///   - seed: The seed passed to the `nextItem` closure as an `inout` parameter so that the closure can modify the seed.
    public init(queue: DispatchQueue = .global(), initialSeed: S, nextItem: @escaping (_ seed: inout S) throws -> O?) {
        self.initialSeed = initialSeed
        seed = initialSeed
        self.nextItem = nextItem
        super.init(queue: queue)
    }
    
    override func _next() throws  -> O? {
        return try nextItem(&seed)
    }
    
    override func _resetOutputSubscription() {
        seed = initialSeed
    }
}

/// Turns a `Sequence` into a `Publisher` by producing each item in the sequence in turn using the given sequences iterator; it is analogous to a `for` loop or the `forEach` method.
///
/// - warning:
///   - If either methods `cancel` or `request` (from `Subscription`) are called when there is no subscriber the result is a fatal error.
///   - When a subscriber subscribes to this class it is passed `self` (because this class is its own subscription).
///     Therefore each subscriber has to `nil` out its reference to the subscription when it receives either `on(error: Item)` or `onComplete()`, otherwise there will be a retain cycle memory leak.
///   - The *only* method/property intended for use by a client (the programmer using an instance of this class) is method `subscribe`; which is best called using operator `~~>` since that emphasizes that the other methods are not for client use.
///   - If multiple subscriptions are attempted; subsequent subscriptions are rejected with their `on(eror:)` method called with `PublisherErrors.subscriptionRejected(reason:)`, but the original subscription continues.
///   - This class is not thread safe (it makes no sense to share a publisher since Reactive Streams are an alternative to dealing with threads directly!).
///
/// - note:
///   - Each subscriber receives all of the sequence individually, i.e. each subscriber receives the whole sequence (provided that the given sequence supports multiple traversal).
///   - When created the given sequence is copied, therefore any changes to the sequence made after the publisher is created are *not* reflected in the items produced (the copy of the sequence is made at creation time not subscription time).
///
/// - parameters
///   - O: The type of the output items in the given sequence.
public final class ForEachPublisher<O>: IteratorPublisherClassBase<O> {
    private let sequence: AnySequence<O>
    
    private var iterator: AnyIterator<O>!

    /// A publisher whose subscription produce the given sequences items in the order the sequence's iterator provides them (the subscription closes when the iterator runs out of items).
    ///
    /// - parameters:
    ///   - sequence: The sequence of items produced (one sequence per subscription assuming that the sequence can be traversed multiple times).
    ///   - queue: Dispatch queue used to produce items in the background (default `DispatchQueue.global()`).
    public init<S>(sequence: S, queue: DispatchQueue = .global()) where S: Sequence, S.SubSequence: Sequence, S.Iterator.Element == O, S.SubSequence.SubSequence == S.SubSequence, S.SubSequence.Iterator.Element == O {
        self.sequence = AnySequence(sequence)
        super.init(queue: queue)
    }
    
    override func _next() -> O? {
        return iterator.next()
    }
    
    override func _resetOutputSubscription() {
        iterator = sequence.makeIterator()
    }
}

// MARK: `Subscriber`s.

/// Signals, as opossed to errors, that `Subscriber`s can send by throwing the signals as errors (they are intercepted and do not result in stream errors).
/// There is no standard way of a subscriber asking for actions, e.g. completion, in the Reactive Stream Specification and therefore throwing these signals must only be used within the Reactive Collection Library.
public enum SubscriberSignal: Error {
    /// Indicates that the subscribers input subscription should be cancelled and the subscriber's `onComplete` method should be called to mark the end of items from the subscription.
    /// This is useful when a subscriber, or a processor which is a subscriber, needs to signal successful completion, rather than signal an error.
    case cancelInputSubscriptionAndComplete
}

/// A `Subscriber` that is also a `Future` that takes items from its subscription and passes them to the given `updateAccumulatingResult` which combines them with the given `initialResult` and when finished returns via `get` the now modified `initialResult` (Reactive Collection version of `Sequence.reduce(into:_:)`).
///
/// - warning:
///   - `Subscriber`s are not thread safe, since they are an alternative to dealing with thread safety directly and therefore it makes no sense to share them between threads.
///   - There are *no* `Subscriber` methods/properties intended for use by a client (the programmer using an instance of this class), the client *only* passes the instance to the `subscribe` method of a `Publisher`.
///   Passing the instance to the publisher is best accomplished using operator `~~>`, since this emphasizes that the other methods are not for client use.
///     The `Future` properties `get` and `status` and method `cancel` are the methods with which the client interacts.
///
/// - note:
///   - Since the subscriber is also a future it can be cancelled or timeout, both of which in turn cancels its subscription.
///   - Completion occurs when the subscription signals completion (it calls `onComplete()`) and the subscription should not call any methods after that, but this is not enforced (see next point for why).
///   - The contract for `on(next: Item)` requires that this method continues to allow calls after cancellation etc. so that 'in-transit' items do not cause thread locks and therefore this method is not locked out and therefore neither are the other 'on' methods (though they do nothing).
///
/// - parameters
///   - T: The type of the items subscribed to.
///   - R: The result type of the accumulation.
public final class ReduceFutureSubscriber<T, R>: FutureSubscriberClassBase<T, R> {
    private let initialResult: R
    
    private var result: R
    
    private let updateAccumulatingResult: (_ accumulator: inout R, _ next: T) throws -> ()
    
    /// A `Subscriber` that is also a future that takes items from its subscription and passes them to the given `updateAccumulatingResult` which combines them with the given `initialResult` and when finished returns via `get` the now modified `initialResult` (Reactive Collection version of `Sequence.reduce(into:_:)`).
    ///
    /// - parameters:
    ///   - timeout: The time that `get` will wait before returning `nil` and setting `status` to a timeout error (default `Futures.defaultTimeout`).
    ///   - requestSize:
    ///     Tuning parameter to control the number of items requested at a time.
    ///     As is typical of subscribers, this subscriber always requests lots of `requestSize` items and initially requests two lots of items so that there is always two lots of items in flight.
    ///     Tests for cancellation are performed on average every `requestSize` items, therefore there is a compromise between a large `requerstSize` to maximize throughput and a small `requestSize` to maximise responsiveness.
    ///     The default `requestSize` is `ReactiveStreams.defaultRequestSize`.
    ///   - into:
    ///     The running accumulator that the given `updateAccumulatingResult` closure accumulates into.
    ///     The given initial value is used to start the accumulation.
    ///     When accumulation is finished this value is returned via `get`.
    ///   - updateAccumulatingResult: A closure that accepts the given `into` as an `inout` parameter and an item from a subscription and combines them into `into`.
    ///   - accumulator: The running accumulator (this is the given `into` and is the value returned via `get`).
    ///   - next: The next item to be accumulated.
    public init(timeout: DispatchTimeInterval = Futures.defaultTimeout, requestSize: UInt64 = ReactiveStreams.defaultRequestSize, into initialResult: R, updateAccumulatingResult: @escaping (_ accumulator: inout R, _ next: T) throws -> ()) {
        self.initialResult = initialResult
        result = initialResult
        self.updateAccumulatingResult = updateAccumulatingResult
        super.init(timeout: timeout, requestSize: requestSize)
    }
    
    override func _handleInput(item: T) throws {
        try updateAccumulatingResult(&result, item)
    }
    
    override var _result: R {
        return result
    }
    
    override func _resetAccumulation() {
        result = initialResult
    }
}

// MARK: `Processors`s.

/// A `Processor` that takes input items from its input subscription and maps (a.k.a. processes, a.k.a. transforms) them into output items, using its seed (Reactive Collection version of `Sequence.map(_ transform:)`).
///
/// - warning:
///   - `processors`s are not thread safe, since they are an alternative to dealing with thread safety directly and therefore it makes no sense to share them between threads.
///   - There are *no* `Publisher` methods/properties intended for use by a client (the programmer using an instance of this class), the client *only* passes the instance to the `subscribe` method of a `Publisher`.
///   Passing the instance to the publisher is best accomplished using operator `~~>`, since this emphasizes that the other methods are not for client use.
///
/// - parameters
///   - S: The type of the seed accepted by the given transform closure.
///   - I: The type of the input items subscribed to.
///   - O: The output type after the mapping.
public final class MapSeededProcessor<S, I, O>: ProcessorClassBase<I, O> {
    private let initialSeed: S
    
    private let transformClosure: (inout S, I) throws -> O
    
    private var seed: S
    
    /// A `Processor` that takes input items from its input subscription and maps (a.k.a. processes, a.k.a. transforms) them into output items, using its seed (Reactive Collection version of `Sequence.map(_ transform:)`).
    ///
    /// - parameters:
    ///   - initialSeed: The initial value of the seed at the start of new input and output subscription.
    ///   - transform: The mapping/processing transform that converts an input item into an output item.
    ///   - seed: The running
    public init(initialSeed: S, transform: @escaping (_ seed: inout S, _ nextItem: I) throws -> O) {
        self.initialSeed = initialSeed
        seed = initialSeed
        transformClosure = transform
    }
    
    override func _handleInputAndRequest(item: I) throws {
        _outputSubscriber.value?.on(next: try transformClosure(&seed, item))
    }
    
    override func _resetOutputSubscription() {
        seed = initialSeed
    }
}

/// A `Processor` that takes input items from its input subscription and maps (a.k.a. processes, a.k.a. transforms) them into output items and if the output items are `nil` they are filtered from the output; the output is flattened if you consider an `Optional` to be a container of up to one item (Reactive Collection version of `Sequence.flatMap<O>(_ transform: (I) throws -> O?)`).
///
/// - warning:
///   - `processors`s are not thread safe, since they are an alternative to dealing with thread safety directly and therefore it makes no sense to share them between threads.
///   - There are *no* `Publisher` methods/properties intended for use by a client (the programmer using an instance of this class), the client *only* passes the instance to the `subscribe` method of a `Publisher`.
///   Passing the instance to the publisher is best accomplished using operator `~~>`, since this emphasizes that the other methods are not for client use.
///
/// - parameters
///   - S: The type of the seed accepted by the given transform closure.
///   - I: The type of the input items subscribed to.
///   - O: The output type after the mapping.
public final class FlatMapOptionalSeededProcessor<S, I, O>: ProcessorClassBase<I, O> {
    private let initialSeed: S
    
    private let transformClosure: (inout S, I) throws -> O?
    
    private var seed: S
    
    /// A `Processor` that takes input items from its input subscription and maps (a.k.a. processes, a.k.a. transforms) them into *non-`nil`* output items (Reactive Collectionm version of `Sequence.flatMap(_ transform:)`).
    ///
    /// - parameters:
    ///   - initialSeed: The initial value of the seed at the start of new input and output subscription.
    ///   - transform:
    ///     The mapping/processing transform that converts an input item into an *optional* output item.
    ///     If the transformed/mapped/processed item is `nil`, it is disguarded.
    ///   - seed: The seed passed to the `transform` closure as an `inout` parameter so that the closure can modify the seed.
    ///   - nextItem: The next item to be transformed/mapped/processed by the closure.
    public init(initialSeed: S, transform: @escaping (_ seed: inout S, _ nextItem: I) throws -> O?) {
        self.initialSeed = initialSeed
        seed = initialSeed
        transformClosure = transform
    }
    
    override func _handleInputAndRequest(item: I) throws {
        let outputItemOptional = try transformClosure(&seed, item)
        guard let outputItem = outputItemOptional else {
            _inputSubscription.value?.request(1)
            return
        }
        _outputSubscriber.value?.on(next: outputItem)
    }
    
    override func _resetOutputSubscription() {
        seed = initialSeed
    }
}

/// A `Processor` that filters input items from its input subscription using the given `isIncluded` closure (Reactive Collection version of `Sequence.filter(_ isIncluded:)`).
///
/// - warning:
///   - `processors`s are not thread safe, since they are an alternative to dealing with thread safety directly and therefore it makes no sense to share them between threads.
///   - There are *no* `Publisher` methods/properties intended for use by a client (the programmer using an instance of this class), the client *only* passes the instance to the `subscribe` method of a `Publisher`.
///   Passing the instance to the publisher is best accomplished using operator `~~>`, since this emphasizes that the other methods are not for client use.
///
/// - parameters
///   - S: The type of the seed accepted by the given transform closure.
///   - T: The type of the input and output items.
public final class FilterSeededProcessor<S, T>: ProcessorClassBase<T, T> {
    private let initialSeed: S
    
    private let isIncludedClosure: (_ seed: inout S, _ nextItem: T) throws -> Bool
    
    private var seed: S
    
    /// A `Processor` that filters input items from its input subscription using the given `isIncluded` closure (Reactive Collection version of `Sequence.filter(_ isIncluded:)`).
    ///
    /// - parameters:
    ///   - initialSeed: The initial value of the seed at the start of new input and output subscription.
    ///   - isIncluded: Closure that returns true if the input item is to be passed to the output.
    ///   - seed: The seed passed to the `transform` closure as an `inout` parameter so that the closure can modify the seed.
    ///   - nextItem: The next item to be transformed/mapped/processed by the closure.
    public init(initialSeed: S, isIncluded: @escaping (_ seed: inout S, _ nextItem: T) throws -> Bool) {
        self.initialSeed = initialSeed
        seed = initialSeed
        isIncludedClosure = isIncluded
    }
    
    override func _handleInputAndRequest(item: T) throws {
        if try isIncludedClosure(&seed, item) {
            _outputSubscriber.value?.on(next: item)
        } else {
            _inputSubscription.value?.request(1)
        }
    }
    
    override func _resetOutputSubscription() {
        seed = initialSeed
    }
}

/// The timout error when the time between items is too long.
public enum TimeoutError: Error {
    
    /// The timout error when the time between items is too long.
    case timedOut
}

/// A `Processor` that generates an error if there is a more than the given time interval between consecutive input items.
/// This processor is a type of timer, like `SubscriptionTimeLimitProcessor` is.
/// The difference between the two is twofold:
///
///  1. This processor times between input items as opposed to the time subscribed to a publisher.
///  2. This processor signals an error if the timeout time is exceeded as opposed to completing.
///
/// - warning:
///   - `processors`s are not thread safe, since they are an alternative to dealing with thread safety directly and therefore it makes no sense to share them between threads.
///   - There are *no* `Publisher` methods/properties intended for use by a client (the programmer using an instance of this class), the client *only* passes the instance to the `subscribe` method of a `Publisher`.
///   Passing the instance to the publisher is best accomplished using operator `~~>`, since this emphasizes that the other methods are not for client use.
///
/// - parameters
///   - T: The type of the input and output items.
public final class ItemTimeoutProcessor<T>: ProcessorClassBase<T, T> {
    private let queue = DispatchQueue(label: "ItemTimeoutProcessor Serial Queue \(UniqueNumber.next)")
    
    private let timeout: DispatchTimeInterval
    
    private var timer = Atomic<DispatchWorkItem?>(nil) // Potentially written from three different queues: `queue`, `_handleInputAndRequest(item: T)`'s queue, and `_resetOutputSubscription()`'s queue and the last two queues also read.
    
    /// A `Processor` that generates an error if there is a more than the given time interval between consecutive input items.
    ///
    /// - parameters:
    ///   - timeout: The maximum allowable time between input items, otherwise `outputSubscriber.on(error: TimeoutError.timedOut)` (default `Futures.defaultTimeout`).
    public init(timeout: DispatchTimeInterval = Futures.defaultTimeout) {
        self.timeout = timeout
    }
    
    override func _handleInputAndRequest(item: T) throws {
        timer.update { timerOptional in
            timerOptional?.cancel()
            let t = DispatchWorkItem {
                self._outputSubscriber.update { outputSubscriberOptional in
                    outputSubscriberOptional?.on(error: TimeoutError.timedOut)
                    return nil
                }
                self._inputSubscription.update { inputSubscriptionOptional in
                    inputSubscriptionOptional?.cancel()
                    return nil
                }
                self.timer.value = nil
            }
            queue.asyncAfter(deadline: DispatchTime.now() + timeout, execute: t)
            return t
        }
        _outputSubscriber.value?.on(next: item)
    }
    
    override func _resetOutputSubscription() {
        timer.update { timerOptional in
            timerOptional?.cancel()
            return nil
        }
    }
}

/// A `Processor` that completes once it has had an output subscription for the given time limit.
/// This processor is a type of timer, like `ItemTimeoutProcessor` is.
/// The difference between the two is twofold:
///
///  1. This processor times between from start of output subscription as opposed to the time between input items.
///  2. This processor completes if the time limit is exceeded as opposed to signalling an error.
///
/// - warning:
///   - `processors`s are not thread safe, since they are an alternative to dealing with thread safety directly and therefore it makes no sense to share them between threads.
///   - There are *no* `Publisher` methods/properties intended for use by a client (the programmer using an instance of this class), the client *only* passes the instance to the `subscribe` method of a `Publisher`.
///   Passing the instance to the publisher is best accomplished using operator `~~>`, since this emphasizes that the other methods are not for client use.
///
/// - parameters
///   - T: The type of the input and output items.
public final class SubscriptionTimeLimitProcessor<T>: ProcessorClassBase<T, T> {
    private let queue = DispatchQueue(label: "SubscriptionTimeLimitProcessor Serial Queue \(UniqueNumber.next)")
    
    private let timeLimit: DispatchTimeInterval
    
    private var timer = Atomic<DispatchWorkItem?>(nil) // Potentially written from two different queues: `queue` and `_resetOutputSubscription()`'s queue and the last queue also reads.
    
    /// A `Processor` that completes once it has had an output subscription for the given time limit.
    ///
    /// - parameters:
    ///   - timeLimit: The maximum allowable time from output subscription to termination (default `Futures.defaultTimeout`).
    public init(timeLimit: DispatchTimeInterval = Futures.defaultTimeout) {
        self.timeLimit = timeLimit
    }
    
    override func _handleInputAndRequest(item: T) throws {
        _outputSubscriber.value?.on(next: item)
    }
    
    override func _resetOutputSubscription() {
        timer.update { timerOptional in
            timerOptional?.cancel()
            let t = DispatchWorkItem {
                self._outputSubscriber.update { outputSubscriberOptional in
                    outputSubscriberOptional?.onComplete()
                    return nil
                }
                self._inputSubscription.update { inputSubscriptionOptional in
                    inputSubscriptionOptional?.cancel()
                    return nil
                }
                self.timer.value = nil
            }
            queue.asyncAfter(deadline: DispatchTime.now() + timeLimit, execute: t)
            return t
        }
    }
}

/// Processors that forks (a.k.a. fans-out/duplicates) its input flow stream by passing all input item onto all its output forks (a.k.a. output flows/streams/subscriptions).
/// The input items are bufferd into the input buffer and each output stream has its own task supplying items from the ouput buffer, that way output streams operate concurrently (in parallel on multi-core machines) and thereby account for different processing and consumption rates of the different forks.
/// When the output buffer is output to all forks and the input buffer is full the two buffers are swapped over.
/// When the input subscription and output subscriptions are established the `fork` method is called to start production, no change in either input or output is then allowed until production has finished.
/// Once any the output forks cancel the input subscription is cancelled and the other output subscriptions are notified by an error of the cancellation.
/// An `on(error: Item)` or `onComplete()` from the input is passed to all output subscribers.
///
/// - warning:
///   - The *only* method/property intended for use by a client (the programmer using an instance of this class) is method `subscribe`; however an instance of this class may be passed to the `subscribe` method of another `Publisher`.
///   Passing the instance to the publisher and subscribing to its output is best accomplished using operator `~~>`, since this emphasizes that the other methods are not for client use.
///   - `Processor`s are not thread safe, since they are an alternative to dealing with thread safety directly and therefore it makes no sense to share them between threads.
///
/// - parameters
///   - T: The type of the input and output items.
public final class AllItemsForker<T>: ForkerClassBase<T> {
    /// Processor that forks (a.k.a. fans-out/duplicates) its input flow stream by passing all input item onto all its output forks (a.k.a. output flows/streams/subscriptions).
    ///
    /// - parameters:
    ///   - queue: Dispatch queue used to feed input items to output forks in the background (default `DispatchQueue.global()`).
    public override init(queue: DispatchQueue = .global()) {
        super.init(queue: queue)
    }
}
