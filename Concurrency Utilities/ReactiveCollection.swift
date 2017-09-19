//
//  ReactiveCollection.swift
//  Concurrency Utilities
//
//  Created by Howard Lovatt on 5/9/17.
//  Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.
//

import Foundation

/// Base class for publishers that is like an iterator; it has a `next` method (that must be overridden) that produces items and signals last item with `nil`.
/// - warning:
///   - Method `next` must be overridden and method `reset` is usually overridden.
///   - This class is not thread safe (it makes no sense to share a producer since Reactive Streams are an alternative to dealing with threads directly!).
///   - When a subscriber subscribes to this class it is passed `self` (because this class is its own subscription).
///     Therefore each subscriber has to `nil` out its reference to the subscription when it receives either `on(error: Item)` or `onComplete()`, otherwise there will be a retain cycle memory leak.
/// - note:
///   - Each subscriber receives all of the items individually (provided that the iterator supports multiple traversal).
///   - This class does not provide buffering, but a derived class might.
///     However, the given `bufferSize` is used to control how responsive cancellation is because cancellation is checked at least each `bufferSize` items produced.
///   - There is no concept of an abstract class in Swift, in other languages this would be an abstract class.
/// - parameter T: The type of the items produced.
open class IteratingPublisher<T>: Publisher, Subscription {
    
    // MARK: init.
    
    /// A publisher that publishes the items produced by its `next` method (that must be overridden).
    /// - precondition: bufferSize > 0
    /// - parameters:
    ///   - qos: Quality of service for the dispatch queue used to sequence items and produce items in the background.
    ///   - bufferSize: This is a standard argument to Reactive Stream types, in this case the argument doesn't define the buffer size but rather the maximum number of items produced before testing for subscription cancellation.
    public init(qos: DispatchQoS = .default, bufferSize: Int = ReactiveStreams.defaultBufferSize) {
        precondition(bufferSize > 0, "bufferSize > 0: \(bufferSize)") // Can't test precondition in Swift 4!
        self.bufferSize = bufferSize
        queue = DispatchQueue(label: "ForEachPublisher Serial Queue \(ObjectIdentifier(self))", qos: qos)
    }
    
    // MARK: Methods of concern when overriding.
    
    /// Produces next item or `nil` if no more items.
    /// - note:
    ///   - This method must be overridden (as implemented in this base class it throws a fatal exception).
    ///   - Unlike a normal iterator, `IteratingPublisher` guarantees that `next` is not called again once it has returned `nil` and before `reset` is called.
    ///     If iteration is non-repeating (i.e. `reset` does nothing) then `next` must return `nil` for all calls post the iteration completing.
    ///     This simplifies the implementation of this method.
    open func next() -> T? {
        fatalError("`IteratingPublisher.next()` must be overridden.") // Can't test fatalError in Swift 4!
    }
    
    /// Reset the iteration back to start, called before 1st call to next each time a subscription is granted.
    /// - note:
    ///   - If the iteration is non repeating (i.e. this method does nothing) then no need to override this method, since the default implementation does nothing.
    ///     However, `next` must continue to return `nil` for subsequent calls.
    open func reset() {}
    
    /// MARK: Publisher
    
    /// The type of items produced.
    public typealias PublisherT = T
    
    private let subscriberAtomic = Atomic<AnySubscriber<T>?>(nil) // Temporary retain cycle because the subscriber holds a reference to this instance, however the subscriber `nils` its reference when subscription is terminated.
    
    public final func subscribe<S>(_ subscriber: S) where S: Subscriber, S.SubscriberT == T {
        var isSubscriptionError = false
        subscriberAtomic.update { subscriberOptional in
            guard subscriberOptional == nil else {
                subscriber.on(error: PublisherErrors.subscriptionRejected(reason: "Can only have one subscriber at a time."))
                isSubscriptionError = true
                return subscriberOptional
            }
            return AnySubscriber(subscriber)
        }
        guard !isSubscriptionError else {
            return
        }
        reset()
        subscriber.on(subscribe: self)
    }
    
    // Mark: Subscription
    
    /// The type of items produced.
    public typealias SubscriptionItem = T
    
    /// This is a standard property of Reactive Streams; in this case the property doesn't define the buffer size but rather the number of items produced before testing for subscription cancellation.
    private let bufferSize: Int
    
    private var queue: DispatchQueue! // The queue used to sequence item production (initialized using self, hence has to be an optional).
    
    private var producers = [Int : Future<Void>]() // Producers are `Future`s, to allow cancellation.
    
    private var producerNumber = 0 // The `index` for producers.
    
    public final func request(_ n: Int) {
        guard n != 0 else { // n == 0 is same as cancel.
            cancel()
            return
        }
        subscriberAtomic.update { subscriberOptional -> AnySubscriber<T>? in
            guard let subscriber = subscriberOptional else { // Guard against already finished.
                return nil // Completed. Can't think how to test this!
            }
            guard n > 0 else { // Guard against -ve n.
                subscriber.on(error: PublisherErrors.cannotProduceRequestedNumberOfItems(numberRequested: n, reason: "Negative number of items not allowed."))
                return nil // Completed.
            }
            let thisProducersNumber = producerNumber
            let producer = AsynchronousFuture(queue: self.queue) { isTerminated throws -> Void in
                var count = n
                while count > 0 {
                    try isTerminated()
                    let innerLimit = min(self.bufferSize, count)
                    var innerCount = innerLimit
                    while innerCount > 0, let item = self.next() {
                        subscriber.on(next: item)
                        innerCount -= 1
                    }
                    count = innerCount > 0 ? -1 : count - innerLimit
                }
                self.producers.removeValue(forKey: thisProducersNumber) // This producer has finished.
                if count < 0 { // Complete?
                    subscriber.onComplete() // Tell subscriber that subscription is completed.
                    self.cancel() // Cancel remaining queued production and mark this subscription as complete.
                }
            }
            producers[thisProducersNumber] = producer
            producerNumber += 1
            return subscriber // Still subscribed.
        }
    }
    
    public final func cancel() {
        subscriberAtomic.update { _ -> AnySubscriber<T>? in
            for producer in self.producers.values {
                producer.cancel() // Cancel item production from queued producer.
            }
            producers.removeAll()
            return nil // Mark subscription as completed.
        }
    }
}

/// Turns a `Sequence` into a `Publisher` by producing each item in the sequence in turn using the given sequences iterator; it is analogous to a `for` loop or the `forEach` method.
/// - warning:
///   - Methods `next` and `reset` are not to be called manually (the superclass uses these methods).
///   - This class is not thread safe (it makes no sense to share a producer!).
///   - When a subscriber subscribes to this class it is passed `self` (because this class is its own subscription).
///     Therefore each subscriber has to `nil` out its reference to the subscription when it receives either `on(error: Item)` or `onComplete()`, otherwise there will be a retain cycle memory leak.
/// - note:
///   - Each subscriber receives all of the sequence individually, i.e. each subscriber receives the whole sequence (provided that the given sequence supports multiple traversal).
///   - This class does not use buffering, because the buffer is the given sequence.
///   - When created the given sequence is copied, therefore any changes to the sequence made after the publisher is created are *not* reflected in the items produced (the copy of the sequence is made at creation time not subscription time).
/// - parameter T: The type of the items produced.
public final class ForEachPublisher<T>: IteratingPublisher<T> {
    private let sequence: AnySequence<T>
    
    /// A publisher whose subscription produce the given sequences items in the order the sequence's iterator provides them (the subscription closes when the iterator runs out of items).
    /// - precondition: bufferSize > 0
    /// - parameters:
    ///   - sequence: The sequence of items produced (one sequence per subscription assuming that the sequence can be traversed multiple times).
    ///   - qos: Quality of service for the dispatch queue used to sequence items and produce items in the background (default `DispatchQOS.default`).
    ///   - bufferSize: This is a standard argument to Reactive Stream types, in this case the argument doesn't define the buffer size but rather the number of items produced before testing for subscription cancellation (default `ReactiveStreams.defaultBufferSize`).
    public init<S>(sequence: S, qos: DispatchQoS = .default, bufferSize: Int = ReactiveStreams.defaultBufferSize) where S: Sequence, S.SubSequence: Sequence, S.Iterator.Element == T, S.SubSequence.SubSequence == S.SubSequence, S.SubSequence.Iterator.Element == T {
        self.sequence = AnySequence(sequence)
        super.init(qos: qos, bufferSize: bufferSize)
    }
    
    private var iterator: AnyIterator<T>?
    
    public override func next() -> T? {
        return iterator?.next()
    }
    
    public override func reset() {
        iterator = sequence.makeIterator()
    }
}

/// A `Subscriber` that is also a `Future` that takes items from its subscription and passes them to the given `updateAccumulatingResult` which combines them with the given `initialResult` and when finished returns via `get` the now modified `initialResult` (Reactive Stream version of `Sequence.reduce(into:_:)`).
/// - warning:
///   - Do not manually call `accumulatee(next: T)`, it used by the superclass.
///   - `Subscriber`s are not thread safe, since they are an alternative to dealing with thread safety directly and therefore it makes no sense to share them between threads.
/// - note:
///   - Since the subscriber is also a future it can be cancelled or timeout, both of which in turn cancells its subscription.
///   - Completion occurs when the subscription signals completion (it calls `onComplete()`) and the subscription should not call any methods after that, but this is not enforced (see next point for why).
///   - The contract for `on(next: Item)` requires that this method continues to allow calls after cancellation etc. so that 'in-transit' items do not cause thread locks and therefore this method is not locked out and therefore neither are the other 'on' methods (though they do nothing).
/// - parameters:
///   - T: The type of the elements subscribed to.
///   - R: The result type of the accumulation.
public final class ReduceSubscriber<T, R>: BaseFutureSubscriber<T, R> {
    private let initialResult: R
    
    /// A `Subscriber` that is also a future that takes items from its subscription and passes them to the given `updateAccumulatingResult` which combines them with the given `initialResult` and when finished returns via `get` the now modified `initialResult` (Reactive Stream version of `Sequence.reduce(into:_:)`).
    /// - precondition: `bufferSize` must be > 0.
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
    public init(timeout: DispatchTimeInterval = Futures.defaultTimeout, bufferSize: Int = ReactiveStreams.defaultBufferSize, into initialResult: R, updateAccumulatingResult: @escaping ( _ accumulator: inout R, _ next: T) throws -> ()) {
        self.initialResult = initialResult
        result = initialResult
        self.updateAccumulatingResult = updateAccumulatingResult
        super.init(timeout: timeout, bufferSize: bufferSize)
    }
    
    private let updateAccumulatingResult: ( _ accumulator: inout R, _ next: T) throws -> ()
    
    public override func accumulatee(next: T) throws {
        try updateAccumulatingResult(&result, next)
    }
    
    private var result: R
    
    public override var accumulator: R {
        return result
    }
    
    public override func reset() {
        result = initialResult
    }
}
