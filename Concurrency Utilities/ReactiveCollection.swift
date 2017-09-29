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
///   - This class does not use buffering; the next item is calculated by given closure `nextItem`.
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
    ///   - dispatchQueue: Dispatch queue used to produce items in the background (default `DispatchQueue.global()`).
    ///   - initialSeed: The value of the seed at the start of each iteration cycle.
    ///   - nextItem: A closure that produces the next item, or `nil` to indicate termination, given the seed (which it can modify)
    ///   - seed: The seed passed to the `nextItem` closure as an `inout` parameter so that the closure can modify the seed.
    public init(dispatchQueue: DispatchQueue = DispatchQueue.global(), initialSeed: S, nextItem: @escaping (_ seed: inout S) throws -> O?) {
        self.initialSeed = initialSeed
        seed = initialSeed
        self.nextItem = nextItem
        super.init(dispatchQueue: dispatchQueue)
    }
    
    /// Calls `nextItem(&seed)`.
    public override func _next() throws  -> O? {
        return try nextItem(&seed)
    }
    
    /// Resets `seed` to `initialSeed`.
    public override func _resetOutputSubscription() {
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
    
    /// A publisher whose subscription produce the given sequences items in the order the sequence's iterator provides them (the subscription closes when the iterator runs out of items).
    ///
    /// - parameters:
    ///   - sequence: The sequence of items produced (one sequence per subscription assuming that the sequence can be traversed multiple times).
    ///   - dispatchQueue: Dispatch queue used to produce items in the background (default `DispatchQueue.global()`).
    public init<S>(sequence: S, dispatchQueue: DispatchQueue = DispatchQueue.global()) where S: Sequence, S.SubSequence: Sequence, S.Iterator.Element == O, S.SubSequence.SubSequence == S.SubSequence, S.SubSequence.Iterator.Element == O {
        self.sequence = AnySequence(sequence)
        super.init(dispatchQueue: dispatchQueue)
    }
    
    private var iterator: AnyIterator<O>!
    
    /// Calls `iterator.next()`.
    public override func _next() -> O? {
        return iterator.next()
    }
    
    /// `iterator = sequence.makeIterator()`.
    public override func _resetOutputSubscription() {
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

/// A `Subscriber` that is also a `Future` that takes items from its subscription and passes them to the given `updateAccumulatingResult` which combines them with the given `initialResult` and when finished returns via `get` the now modified `initialResult` (Reactive Stream version of `Sequence.reduce(into:_:)`).
///
/// - warning:
///   - `Subscriber`s are not thread safe, since they are an alternative to dealing with thread safety directly and therefore it makes no sense to share them between threads.
///   - There are *no* `Publisher` methods/properties intended for use by a client (the programmer using an instance of this class), the client *only* passes the instance to the `subscribe` method of a `Publisher`.
///   Passing the instance to the publisher is best accomplished using operator `~~>`, since this emphasizes that the other methods are not for client use.
///     The `Future` properties `get` and `status` and method `cancel` are the methods with which the client interacts.
///
/// - note:
///   - Since the subscriber is also a future it can be cancelled or timeout, both of which in turn cancells its subscription.
///   - Completion occurs when the subscription signals completion (it calls `onComplete()`) and the subscription should not call any methods after that, but this is not enforced (see next point for why).
///   - The contract for `on(next: Item)` requires that this method continues to allow calls after cancellation etc. so that 'in-transit' items do not cause thread locks and therefore this method is not locked out and therefore neither are the other 'on' methods (though they do nothing).
///
/// - parameters
///   - T: The type of the items subscribed to.
///   - R: The result type of the accumulation.
public final class ReduceFutureSubscriber<T, R>: FutureSubscriberClassBase<T, R> {
    private let initialResult: R
    
    /// A `Subscriber` that is also a future that takes items from its subscription and passes them to the given `updateAccumulatingResult` which combines them with the given `initialResult` and when finished returns via `get` the now modified `initialResult` (Reactive Stream version of `Sequence.reduce(into:_:)`).
    ///
    /// - parameters:
    ///   - timeout: The time that `get` will wait before returning `nil` and setting `status` to a timeout error (default `Futures.defaultTimeout`).
    ///   - bufferSize:
    ///     The buffer for this subscriber is the given `initialResult` (which is typically a single value).
    ///     Therefore this parameter is purely a tuning parameter to control the number of items requested at a time.
    ///     As is typical of subscribers, this subscriber always requests lots of `bufferSize` items and initially requests two lots of items so that there is always two lots of items in flight.
    ///     Tests for cancellation are only performed every `bufferSize` items, therefore there is a compromise between a large `bufferSize` to maximize throughput and a small `bufferSize` to maximise responsiveness.
    ///     The default `bufferSize` is `ReactiveStreams.defaultBufferSize`.
    ///   - into:
    ///     The running accumulator that the given `updateAccumulatingResult` closure accumulates into.
    ///     The given initial value is used to start the accumulation.
    ///     When accumulation is finished this value is returned via `get`.
    ///   - updateAccumulatingResult: A closure that accepts the given `into` as an `inout` parameter and an item from a subscription and combines them into `into`.
    ///   - accumulator: The running accumulator (this is the given `into` and is the value returned via `get`).
    ///   - next: The next item to be accumulated.
    public init(timeout: DispatchTimeInterval = Futures.defaultTimeout, bufferSize: UInt64 = ReactiveStreams.defaultBufferSize, into initialResult: R, updateAccumulatingResult: @escaping (_ accumulator: inout R, _ next: T) throws -> ()) {
        self.initialResult = initialResult
        result = initialResult
        self.updateAccumulatingResult = updateAccumulatingResult
        super.init(timeout: timeout, bufferSize: bufferSize)
    }
    
    private let updateAccumulatingResult: (_ accumulator: inout R, _ next: T) throws -> ()
    
    public override func _consume(item: T) throws {
        try updateAccumulatingResult(&result, item)
    }
    
    private var result: R
    
    public override var _result: R {
        return result
    }
    
    public override func _resetAccumulation() {
        result = initialResult
    }
}

// MARK: `Processors`s.

/// A `Processor` that takes input items from its input subscription and maps (a.k.a. processes, a.k.a. transforms) them into output items, using its seed (Reactive Stream version of `Sequence.map(_ transform:)`).
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
    
    /// A `Processor` that takes input items from its input subscription and maps (a.k.a. processes, a.k.a. transforms) them into output items, using its seed (Reactive Stream version of `Sequence.map(_ transform:)`).
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
    
    /// Calls the transform closure with the seed and the given input item and passes the resulting transformed item onto the output susbcription.
    ///
    /// - parameter inputItem: The input item to be transformed/mapped/processed.
    public override func _consumeAndRequest(item: I) throws {
        _outputSubscriber.value?.on(next: try transformClosure(&seed, item))
    }
    
    /// Resets the seed at the start of each new output subscription.
    public override func _resetOutputSubscription() {
        seed = initialSeed
    }
}

/// A `Processor` that takes input items from its input subscription and maps (a.k.a. processes, a.k.a. transforms) them into *non-`nil`* output items (Reactive Stream version of `Sequence.flatMap(_ transform:)`).
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
public final class FlatMapSeededProcessor<S, I, O>: ProcessorClassBase<I, O> {
    private let initialSeed: S
    
    private let transformClosure: (inout S, I) throws -> O?
    
    private var seed: S
    
    /// A `Processor` that takes input items from its input subscription and maps (a.k.a. processes, a.k.a. transforms) them into *non-`nil`* output items (Reactive Stream version of `Sequence.flatMap(_ transform:)`).
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
    
    /// Calls the `transform` closure with the seed and the given input item and passes the resulting transformed item onto the output susbcription assuming that it isn't `nil`, if it is `nil` it requests an extra input item.
    ///
    /// - parameter inputItem: The input item to be transformed/mapped/processed.
    public override func _consumeAndRequest(item: I) throws {
        let outputItemOptional = try transformClosure(&seed, item)
        guard let outputItem = outputItemOptional else {
            _inputSubscription.value?.request(1)
            return
        }
        _outputSubscriber.value?.on(next: outputItem)
    }
    
    /// Resets the seed at the start of each new output subscription.
    public override func _resetOutputSubscription() {
        seed = initialSeed
    }
}

/// A `Processor` that filters input items from its input subscription using the given `isIncluded` closure (Reactive Stream version of `Sequence.flatMap(_ transform:)`).
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
    
    /// A `Processor` that filters input items from its input subscription using the given `isIncluded` closure (Reactive Stream version of `Sequence.flatMap(_ transform:)`).
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
    
    /// Calls the `isIncluded` closure with the seed and the given input item and passes the input item to the output if the closure returns true.
    ///
    /// - parameter inputItem: The input item to be tested.
    public override func _consumeAndRequest(item: T) throws {
        if try isIncludedClosure(&seed, item) {
            _outputSubscriber.value?.on(next: item)
        } else {
            _inputSubscription.value?.request(1)
        }
    }
    
    /// Resets the seed at the start of each new output subscription.
    public override func _resetOutputSubscription() {
        seed = initialSeed
    }
}
