//
//  ReactiveStream.swift
//  Concurrency Utilities
//
//  Created by Howard Lovatt on 5/9/17.
//  Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.
//

import Foundation

/// Base class for publishers that is like an iterator; it has a `next` method (that must be overridden) that produces items and signals last item with `nil`.
/// - warning:
///   - Method `next` must be overridden and method `reset` is usually overridden.
///   - This class is not thread safe (it makes no sense to share a producer!).
///   - When a subscriber subscribes to this class it is passed `self` (because this class is its own subscription).
///     Therefore each subscriber has to `nil` out its reference to the subscription when it receives either `on(error: Item)` or `onComplete()`, otherwise there will be a retain cycle memory leak.
/// - note:
///   - Each subscriber receives all of the items individually (provided that the iterator supports multiple traversal).
///   - This class does not provide buffering, but a derived class might.
///     However, the given `bufferSize` is used to control how responsive cancellation is because cancellation is checked at least each `bufferSize` items produced.
/// - parameter T: The type of the items produced.
open class IteratingPublisher<T>: Publisher, Subscription {
    // MARK: Methods of concern when overriding.
    
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

/// A `Subscriber` that is also a `Future` that takes items from its subscription and passes them to its `accumulatee` method which processes each item and when completed the result is obtained from property `accumulator` and returned via `get` and/or `status`.
/// - warning: Both `accumulatee` and `accumulator` must be overriden (the default implementations throw a fatal error).
/// - note:
///   - `Subscriber`s are not thread safe, since they are an alternative to dealing with thread safety directly and therefore it makes no sense to share them between threads.
///   - As all `Subscriber`s that also `Future`s this subscriber can have only one subscription in its liefetime since a future can only complete once.
///   - Since the subscriber is also a future it can be cancelled or timeout, both of which in turn cancells its subscription.
///   - Completion occurs when the subscription signals completion (it calls `onComplete()`) and the subscription should not call any methods after that, but this is not enforced (see next point for why).
///   - The contract for `on(next: Item)` requires that this method continues to allow calls after cancellation etc. so that 'in-transit' items do not cause thread locks and therefore this method is not locked out and therefore neither are the other 'on' methods (though they do nothing).
/// - parameters:
///   - T: The type of the elements subscribed to.
///   - R: The result type of the accumulation.
open class AccumulatingSubscriber<T, R>: Future<R>, Subscriber {
    
    // MARK: Future properties and methods
    
    private let _status = Atomic(FutureStatus<R>.running) // Set in background, read in foreground.
    
    private let timeoutTime: Date
    
    override var status: FutureStatus<R> {
        return _status.value
    }
    
    override public var get: R? {
        while true { // Keep looping until completed, cancelled, timed out, or throws.
            switch _status.value {
            case .running:
                let sleepInterval = min(timeoutTime.timeIntervalSinceNow, Futures.defaultMaximumSleepTime)
                if sleepInterval > Futures.defaultMinimumSleepTime {
                    Thread.sleep(forTimeInterval: sleepInterval)
                    break // Loop and check status again.
                }
                _status.update {
                    switch $0 {
                    case .running:
                        subscription?.cancel() // Cancel the subscription, if there is one.
                        subscription = nil // Free subscription's resources.
                        return .threw(error: TerminateFuture.timedOut) // Timeout if still running.
                    default:
                        return $0 // Stay in present state if not running. Can't think how to test this line!
                    }
            } // Exit outer loop by checking status again.
            case .completed(let result):
                return result
            case .threw(_):
                return nil
            }
        }
    }
    
    override public func cancel() {
        _status.update {
            switch $0 {
            case .running:
                subscription?.cancel() // Cancel the subscription, if there is one.
                subscription = nil // Free subscription's resources.
                return .threw(error: TerminateFuture.cancelled)
            default:
                return $0 // Do nothing - already finished.
            }
        }
    }
    
    // MARK: Subscriber properties and methods
    
    public typealias SubscriberT = T
    
    private var subscription: Subscription?
    
    private let bufferSize: Int
    
    private var countToRefill = 0
    
    public func on(subscribe: Subscription) {
        _status.update {
            switch $0 {
            case .running: // Only allow subscriptions if running.
                guard subscription == nil else { // Only allow one subscription.
                    subscription?.cancel() // Cancel the current subscription because of double subscription error.
                    return .threw(error: SubscriberErrors.tooManySubscriptions(number: 2))
                }
                countToRefill = bufferSize
                subscribe.request(bufferSize) // Start subscription
                subscribe.request(bufferSize) // Ensure that two lots of items are always in flight.
                self.subscription = subscribe
                return $0 // Still running.
            default:
                return $0 // Do nothing - already finished. Can't think how to test this!
            }
        }
    }
    
    public func on(next: T) {
        countToRefill -= 1
        if countToRefill <= 0 { // Request more items when `bufferSize` items 'accumulated'.
            countToRefill = bufferSize
            subscription?.request(countToRefill)
        }
        do {
            try accumulatee(next: next) // The output buffer/accumulator is provided by `result`.
        } catch {
            subscription?.cancel()
            on(error: error)
        }
    }
    
    public func on(error: Error) {
        _status.update {
            switch $0 {
            case .running:
                subscription = nil // Free subscription's resources.
                return .threw(error: error)
            default:
                return $0 // Do nothing - already finished.
            }
        }
    }
    
    public func onComplete() {
        _status.update {
            switch $0 {
            case .running:
                subscription = nil // Free subscription's resources.
                return .completed(result: accumulator)
            default:
                return $0 // Do nothing - already finished.
            }
        }
    }
    
    // MARK: init
    
    /// A `Subscriber` that is also a `Future` that takes items from its subscription and passes them to its `accumulatee` method which processes each item and when completed the result is obtained from property `accumulator` and returned via `get` and/or `status`.
    /// - precondition: `bufferSize` must be > 0.
    /// - parameters:
    ///   - timeout: The time that `get` will wait before returning `nil` and setting `status` to a timeout error (default `Futures.defaultTimeout`).
    ///   - bufferSize:
    ///     The buffer for this subscriber is the given `initialResult` (which is typically a single value).
    ///     Therefore this parameter is purely a tuning parameter to control the number of items requested at a time.
    ///     As is typical of subscribers, this subscriber always requests lots of `bufferSize` items and initially requests two lots of items so that there is always two lots of items in flight.
    ///     Tests for cancellation are only performed every `bufferSize` items, therefore there is a compromise between a large `bufferSize` to maximize throughput and a small `bufferSize` to maximise responsiveness.
    ///     The default `bufferSize` is `ReactiveStreams.defaultBufferSize`.
    public init(timeout: DispatchTimeInterval = Futures.defaultTimeout, bufferSize: Int = ReactiveStreams.defaultBufferSize) {
        switch timeout {
        case .nanoseconds(let ns):
            timeoutTime = Date(timeIntervalSinceNow: Double(ns) / Double(1_000_000_000))
        case .microseconds(let us):
            timeoutTime = Date(timeIntervalSinceNow: Double(us) / Double(1_000_000))
        case .milliseconds(let ms):
            timeoutTime = Date(timeIntervalSinceNow: Double(ms) / Double(1_000))
        case .seconds(let s):
            timeoutTime = Date(timeIntervalSinceNow: Double(s))
        case .never:
            timeoutTime = Date.distantFuture
        }
        precondition(bufferSize > 0, "Buffer size must be > 0, is \(bufferSize)") // Can't test a precondition.
        self.bufferSize = bufferSize
    }
    
    // MARK: Methods that must be overridden
    
    /// Takes the next item from the subscription and accumulates it into the result (called each time `on(next: T)` is called).
    /// - parameter next: The item to accumulate.
    open func accumulatee(next: T) throws {
        fatalError("Method must be overridden.") // Can't test a fatal error.
    }
    
    /// Return the accumulation so far (called when the accumulation is complete and its value stored in status and returned by `get`).
    open var accumulator: R {
        fatalError("Getter must be overridden.") // Can't test a fatal error.
    }
}

/// A `Subscriber` that is also a `Future` that takes items from its subscription and passes them to the given `updateAccumulatingResult` which combines them with the given `initialResult` and when finished returns via `get` the now modified `initialResult` (Reactive Stream version of `Sequence.reduce(into:_:)`).
/// - warning: Do not manually call `accumulatee(next: T)`, it used by the superclass.
/// - note:
///   - `Subscriber`s are not thread safe, since they are an alternative to dealing with thread safety directly and therefore it makes no sense to share them between threads.
///   - As all `Subscriber`s that also `Future`s this subscriber can have only one subscription in its liefetime since a future can only complete once.
///   - Since the subscriber is also a future it can be cancelled or timeout, both of which in turn cancells its subscription.
///   - Completion occurs when the subscription signals completion (it calls `onComplete()`) and the subscription should not call any methods after that, but this is not enforced (see next point for why).
///   - The contract for `on(next: Item)` requires that this method continues to allow calls after cancellation etc. so that 'in-transit' items do not cause thread locks and therefore this method is not locked out and therefore neither are the other 'on' methods (though they do nothing).
/// - parameters:
///   - T: The type of the elements subscribed to.
///   - R: The result type of the accumulation.
public final class ReduceSubscriber<T, R>: AccumulatingSubscriber<T, R> {
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
}
