//
//  ReactiveStream.swift
//  Concurrency Utilities
//
//  Created by Howard Lovatt on 5/9/17.
//  Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.
//

import Foundation

/// Interrelated protocols for establishing flow-controlled components in which `Publishers` produce items consumed by one or more `Subscriber`s, each managed by a `Subscription`.
/// These interfaces correspond to the reactive-streams specification.
///
/// They apply in both concurrent and distributed asynchronous settings:
///
/// - All (seven) methods are defined in void "one-way" message style.
/// - Communication relies on a simple form of flow control (method `Subscription.request(Int)`) that can be used to avoid resource management problems that may otherwise occur in "push" based systems.

/// A `Processor` represents a processing stage — which is both a `Subscriber` and a `Publisher` and obeys the contracts of both.
public protocol Processor: Subscriber, Publisher {}

/// `Publisher` errors that the publisher reports using `Subscriber.on(error: Error)`, which is then typically reported via its status that is in turn typically from `Future`.
public enum PublisherErrors: Error {
    /// Subscription request failed.
    case subscriptionRejected(reason: String)
    
    /// Requested illegal number of items.
    case cannotProduceRequestedNumberOfItems(numberRequested: Int, reason: String)
    
    /// Publisher has been collected by ARC.
    case publisherNoLongerExists
}

/// A `Publisher` is a provider of a potentially unbounded number of sequenced items, publishing them according to the demand received from its `Subscriber`(s).
///
/// A `Publisher` can serve multiple `Subscribers` subscribed by `subscribe(Subscriber)` dynamically at various points in time.
public protocol Publisher {
    /// The type of items this `Publisher` produces.
    associatedtype PublisherT
    
    /// Request this `Publisher` starts streaming items to the given `Subscriber`.
    ///
    /// This is a "factory method" and can be called multiple times, each time starting a new `Subscription`.
    ///
    /// Each `Subscription` will work for only a single `Subscriber`.
    ///
    /// A `Subscriber` should only subscribe once to a single `Publisher`.
    ///
    /// If the `Publisher` rejects the subscription attempt or otherwise fails it will signal the error via `Subscriber.on(error: subscriptionRejected(reason: String))`.
    ///
    /// - parameter subscriber: The `Subscriber` that will consume items from this `Publisher`.
    func subscribe<S>(_ subscriber: S) where S: Subscriber, S.SubscriberT == PublisherT
}

/// `Subscriber` errors that the subscriber reports using its status (typically inherited from `Future`).
public enum SubscriberErrors: Error {
    /// Subscription request failed.
    case tooManySubscriptions(number: Int)
}

/// Will receive a call to `on(subscribe: Subscriber)` once after passing an instance of `self` to `Publisher.subscribe(Subscriber)` to supply the `Subscription`.
///
/// No further items will be received by this `Subscriber` from the subscribed to `Producer` until `Subscription.request(Int)` is called.
///
/// After signaling demand:
///
/// - Invocations of `on(next: T)` up to the maximum number requested by `Subscription.request(Int)` will be made by the subscribed to `Producer`.
/// - Single invocation of `on(error: Error)` or `onComplete()` which signals a terminal state after which no further items will be produced.
///
/// Demand can be signaled via `Subscription.request(Int)` whenever the `Subscriber` instance is capable of handling more items.
public protocol Subscriber {
    /// The type of the items consumed by this `Subscriber`.
    associatedtype SubscriberT
    
    /// Go into the successful terminal state (this method is called by the subscribed to `Producer` when it has no more items left to produce).
    ///
    /// No further items will be produced, even if `Subscription.request(Int)` is invoked again.
    func onComplete()
    
    /// Go into the failed terminal state (this method is called by the subscribed to `Producer` when it encounters an error).
    ///
    /// No further items will be produced, even if `Subscription.request(Int)` is invoked again.
    ///
    /// - parameter error: The error signalled by the `Producer` (which called this method).
    func on(error: Error)
    
    /// Supply next item produced by the `Publisher` in response to requests to `Subscription.request(Int)` (this method is called by the subscribed to `Publisher` for each of the items requested).
    ///
    /// - parameter next: The next item produced by the subscribed to `Producer`.
    func on(next: SubscriberT)
    
    /// Invoked by the subscribed to `Publisher`, after this `Subscriber` has called `Publisher.subscribe(self)`.
    ///
    /// No items will be produced until `Subscription.request(Int)` is invoked.
    /// It is the responsibility of this `Subscriber` to call `Subscription.request(Int)` whenever more data is wanted.
    /// The `Publisher` will produce items only in response to `Subscription.request(Int)`.
    ///
    /// - parameter subscribe: `Subscription` that allows requesting data via `Subscription.request(Int)`
    func on(subscribe: Subscription)
}

// Add flow syntax as an extension to `Subsriber` rather than `Publisher`, since the subscriber is returned and therefore the full type information, Self, is available for subsequent stages.
public extension Subscriber {
    /// Subscribe to the publisher using stream flow syntax.
    /// - warning: This operator should not be overridden since it only has one meaningful definition, however this cannot be prevented in Swift 4 because the operator is defined on a protocol and worse the type checker seems to need it to be overridden (ensure body is `left.subscribe(right); return right`).
    @discardableResult public static func ~~> <P>(left: P, right: Self) -> Self where P: Publisher, P.PublisherT == SubscriberT {
        left.subscribe(right)
        return right
    }
}

/// Wrap any `Subscriber` in a standard class, useful where `Subscriber` is needed as a type (it is a protocol).
///
/// EG Implementations of `Subscription` typically contain a reference to the `Subscriber` they belong to and this reference is typed `AnySubscriber` because `Subscriber` cannot be used as a type because it has an associated type `SubscriberT`.
public class AnySubscriber<T>: Subscriber {
    public typealias SubscriberT = T
    
    private let complete: () -> Void
    
    private let error: (Error) -> Void
    
    private let next: (T) -> Void
    
    private let subscribe: (Subscription) -> Void
    
    /// Wrap the given subscriber, which can be any type of subscriber, so that the type becomes `AnySubscriber` regardless of the originating subscriber's specific type.
    /// - parameter subscriber: The subscriber to wrap.
    init<S>(_ subscriber: S) where S: Subscriber, S.SubscriberT == T {
        complete = {
            subscriber.onComplete()
        }
        error = {
            subscriber.on(error: $0)
        }
        next = {
            subscriber.on(next: $0)
        }
        subscribe = {
            subscriber.on(subscribe: $0)
        }
    }
    
    public func onComplete() {
        self.complete()
    }
    
    public func on(error: Error) {
        self.error(error)
    }
    
    public func on(next: T) {
        self.next(next)
    }
    
    public func on(subscribe: Subscription) {
        self.subscribe(subscribe)
    }
}

/// A `Subscription` represents a one-to-one lifecycle of a `Subscriber` subscribing to a `Publisher`.
///
/// It can only be used by a single `Subscriber` and only until `cancel` is called or `Producer` calls either `Subscriber.onComplete()` or `Subscriber.on(error: Error).
/// A `Subsctoptin` is supplied to a `Subscriber` by a `Publisher` by calling `Subscriber.on(subscription: Subscriber)`.
///
/// It is used to both signal desire for data and cancel demand (and allow resource cleanup).
public protocol Subscription {
    /// Request the `Publisher` to stop sending data and clean up resources (cancel the subscription).
    ///
    /// Data may still be sent to meet previously signalled demand after calling cancel.
    func cancel()
    
    /// No (further) items will produced by the subscribed `Publisher`, via `Subscriber.on(next: T)`, until demand is signaled via this method.
    ///
    /// This method can be called however often and whenever needed — but the outstanding cumulative demand must never exceed `Int.max`.
    /// An outstanding cumulative demand of `Int.max` may be treated by the `Publisher` as "effectively unbounded".
    ///
    /// Whatever has been requested can be sent by the `Publisher`, so only signal demand for what can be safely handled.
    ///
    /// A Publisher can send less than is requested if the stream ends or has an error, but then must emit either `Subscriber.on(error: Error)` or `Subscriber.onComplete()`.
    ///
    /// A request for zero items is the same as calling `cancel`.
    ///
    /// - parameter n: The strictly positive number of items to requests from the upstream `Publisher`.
    func request(_ n: Int)
}

/// Functions and properties that are useful in conjunction with Reactive Streams (inside an enum to give them their own namespace).
public enum ReactiveStreams {
    /// The suggested buffer size for `Publisher` or `Subscriber` buffering, that may be used in the absence of other constraints.
    ///
    /// - note: The current implementation has a default value is 256.
    public static let defaultBufferSize = 256
}

// MARK: Explination text loosly based upon: http://download.java.net/java/jdk9/docs/api/java/util/concurrent/Flow.html.

/// Turns a `Sequence` into a `Publisher` by producing each item in the sequence in turn using the given sequences iterator; it is analaguous to a `for` loop or the `forEach` method.
///
/// - note:
///   - Each subscriber recieves all of the sequence individually, i.e. each subscriber recieves the whole sequence (provided that the given sequence supports multiple traversal).
///   - It is not thread safe to pass the returned subscription to a different thread, therefore do not pass a single subscriber to different threads (though different subscribers may be on different threads).
///   - This class does not use buffering, unlike many implementations, because the buffer is the given sequence.
///   - When a `ForEachPubliser` is created the given sequence is copied, therefore any changes to the sequence made after the publisher is created are *not* reflected in the items produced (the copy of the sequence is made at creation time not subscription time).
///
/// - note:
///   - A `Publisher` usually defines its own `Subscription` implementation; constructing one in method `subscribe` and issuing it to the calling `Subscriber`.
///   - That way a publisher can trivially have multiple subscribers, since each subscriber has its own subscription.
///   - However; each subscriber has to nil out its reference to the subscription when it recieves either `on(error: Item)` or `onComplete()`, otherwise there will be a retain cycle memory leak.
///   - The publisher produces items in order and passes them to each subscriber asynchronously; normally this is achieved by each subscription having its own serial queue.
///
/// - parameter T: The type of the items produced.
public final class ForEachPublisher<T>: Publisher {
    /// The type of items produced.
    public typealias PublisherT = T
    
    /// The sequence of items produced (one sequence per subsription assuming that the sequence can be traversed multiple times).
    fileprivate let sequence: AnySequence<T>
    
    /// Quality of service for the dispatch queue used to sequence items and produce items in the background.
    fileprivate let qos: DispatchQoS
    
    /// This is a standard property of Reactive Stream types, in this case the property doesn't define the buffer size but rather the number of items produced before testing for subscription cancellation.
    fileprivate let bufferSize: Int
    
    public func subscribe<S>(_ subscriber: S) where S: Subscriber, S.SubscriberT == T {
        subscriber.on(subscribe: ForEachSubscription(self, AnySubscriber(subscriber)))
    }
    
    /// A publisher whose subscription produce the given sequences items in the order the sequence's iterator provides them (the subscription closes when the iterator runs out of items).
    /// - precondition: bufferSize > 0
    /// - parameters:
    ///   - sequence: The sequence of items produced (one sequence per subsription assuming that the sequence can be traversed multiple times).
    ///   - qos: Quality of service for the dispatch queue used to sequence items and produce items in the background.
    ///   - bufferSize: This is a standard argument to Reactive Stream types, in this case the argument doesn't define the buffer size but rather the number of items produced before testing for subscription cancellation.
    public init<S>(sequence: S, qos: DispatchQoS = .default, bufferSize: Int = ReactiveStreams.defaultBufferSize) where S: Sequence, S.SubSequence: Sequence, S.Iterator.Element == T, S.SubSequence.SubSequence == S.SubSequence, S.SubSequence.Iterator.Element == T {
        self.sequence = AnySequence(sequence)
        self.qos = qos
        precondition(bufferSize > 0, "bufferSize > 0: \(bufferSize)")
        self.bufferSize = bufferSize
    }
}

private final class ForEachSubscription<T>: Subscription {
    typealias SubscriptionItem = T
    
    private let subscriber: AnySubscriber<T> // Temporary retain cycle because the subscriber holds a reference to this instance, however the subscriber nils its reference when .
    
    private let iterator: AnyIterator<T>
    
    private let bufferSize: Int
    
    private var queue: DispatchQueue! = nil // Force unwrapped because `queue` can't be initialised otherwise because `self` is used to generate a unique number and this is only possible if `queue` has a value (`nil`).
    
    private var producers = [Int : Future<Void>]() // Production requests are within a `Future`, to allow cancellation.
    
    private var producerNumber = 0 // The `index` for producers.
    
    private let isCompleted = Atomic(false) // Used to ensure thread safety (its the lock) and to mark when the `Publisher` has finished.
    
    init(_ publisher: ForEachPublisher<T>, _ subscriber: AnySubscriber<T>) {
        self.subscriber = subscriber
        iterator = publisher.sequence.makeIterator()
        bufferSize = publisher.bufferSize
        queue = DispatchQueue(label: "ForEachPublisher Serial Queue \(ObjectIdentifier(self))", qos: publisher.qos)
    }
    
    public func request(_ n: Int) {
        isCompleted.update { completed -> Bool in
            guard n != 0, !completed else { // Guard against do nothing and already finished.
                if !completed {
                    self.subscriber.onComplete()
                }
                return true // Completed.
            }
            guard n > 0 else { // Guard against -ve n.
                self.subscriber.on(error: PublisherErrors.cannotProduceRequestedNumberOfItems(numberRequested: n, reason: "Negative number of items not allowed."))
                return true // Mark subscription as completed.
            }
            let thisProducersNumber = producerNumber
            let producer = AsynchronousFuture(queue: self.queue) { isTerminated throws -> Void in
                var count = n
                while count > 0 {
                    try isTerminated()
                    let innerLimit = min(self.bufferSize, count)
                    var innerCount = innerLimit
                    while innerCount > 0, let item = self.iterator.next() {
                        self.subscriber.on(next: item)
                        innerCount -= 1
                    }
                    count = innerCount > 0 ? -1 : count - innerLimit
                }
                self.producers.removeValue(forKey: thisProducersNumber) // This producer has finished.
                if count < 0 { // Complete?
                    self.subscriber.onComplete() // Tell subscriber that subscription is completed.
                    self.cancel() // Cancel remaining queued production and mark this subscription as complete.
                }
            }
            producers[thisProducersNumber] = producer
            producerNumber += 1
            return false // Still going.
        }
    }
    
    public func cancel() {
        isCompleted.update { completed -> Bool in
            for producer in self.producers.values {
                producer.cancel() // Cancel item production from queued producer.
            }
            producers.removeAll()
            return true // Mark subscription as completed.
        }
    }
}

/// - note:
///   - A `Subscriber` arranges that items be produced and processes the items it is supplied.
///   - Items (invocations on `Subscriber.on(next: T)`) are not produced unless requested, but multiple items are typically requested (`Subscription.request(Int)`).
///   - Many `Subscriber` implementations can arrange this in the style of the following example, where a buffer is used to allow for more efficient overlapped processing with less communication than if individual items are processed.
///   - Instead of subscripers supporting multiple subscriptions; it is easier to instead define multiple `Subscriber`s each with its own `Subscription`.
///   - Care needs to be taken, in a thread safe way (e.g. use `Future`'s status atomically), to ensure that there is only ever one subscription at a time.
///   - Typically `Subscribers` are also `Futures`, so that they can be cancelled and so that they can timeout.
///   - As with all `Future`s, timeout is only invoked when `get` is called (which will block until completeion, cancellation, timeout, or throws occurs) and if `get` is not called then the subscriber continures until it is cancelled or completed (i.e. no timeout).
///   - As with `AsynchronousFuture` the `init` of the subscriber returns without blocking and the future is in the running state and the timeout time has started.
///   - Completion occurs when the subscription signals completion (it calls `onComplete()`) and the subscription should not call any methods after that, but this is not enforced (see next point for why).
///   - The contract for `on(next: Item)` requires that this method continues to allow calls after cancellation etc. so that 'in-transit' items do not cause thread locks and therefore this method is not locked out and therefore neither are the other 'on' methods (though they do nothing).
///   - `Subscriber`s themselves are normally thread safe however their substriptions are nearly always not thread safe, therefore treat subscribers as not thread safe and do not pass between threads.
public final class ReduceSubscriber<T, R>: Future<R>, Subscriber {
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
                let sleepInterval = min(timeoutTime.timeIntervalSinceNow, 0.25) // Limit sleep to 250 ms to remain responsive.
                if sleepInterval > 0.01 { // Minimum time interval worth sleeping for is 10 ms.
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
    
    private var result: R
    
    private let accumulatee: (inout R, T) throws -> ()
    
    private var subscription: Subscription?
    
    private let bufferSize: Int
    
    private var countToRefill = 0
    
    public func on(subscribe: Subscription) {
        _status.update {
            switch $0 {
            case .running: // Only allow subscriptions if running.
                guard subscription == nil else { // Only allow one subscription.
                    subscription?.cancel() // Cancel the current subscription because of double subsciption error.
                    return .threw(error: SubscriberErrors.tooManySubscriptions(number: 2))
                }
                countToRefill = bufferSize
                subscribe.request(bufferSize) // Start subscription
                subscribe.request(bufferSize) // Ensure that two lots of items are always in flight.
                self.subscription = subscribe
                return $0 // Still running.
            default:
                return $0 // Do nothing - already finished.
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
            try accumulatee(&result, next) // The output buffer/accumulator is provided by `result`.
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
                return .completed(result: result)
            default:
                return $0 // Do nothing - already finished.
            }
        }
    }
    
    // MARK: init
    
    /// A subscriber that takes items from its subscription and passes them to the given `updateAccumulatingResult` which combines them with the given `initialResult` and when finished returns via `get` the now modified `initialResult` (Reactive Stream version of `Sequence.reduce(into:_:)`).
    /// - note: As is typical of subscribers this subscriber can have only one subscription at a time and it is not thread safe.
    /// - precondition: `bufferSize` must be > 0.
    /// - parameters:
    ///   - timeout: The time that `get` will wait before returning `nil` and seeting `status` to a timeout error (default 1 second).
    ///   - bufferSize:
    ///     The buffer for this subscriber is the given `initialResult` (which is typically a single value).
    ///     Therefore this parameter is purely a tunning parameter to control the number of items requested at a time.
    ///     As is typical of subscribers, this subscriber always requests lots of `bufferSize` items and initially requests two lots of items so that there is always two lots of items in flight.
    ///     Tests for cancellation are only performed every `bufferSize` items, therefore there is a compromise between a large `bufferSize` to maximize throuput and a small `bufferSize` to maximise responsiveness.
    ///     The default `bufferSize` is `ReactiveStreams.defaultBufferSize`.
    ///   - into:
    ///     The running accumulator that the given `updateAccumulatingResult` closure accumulates into.
    ///     The given initial value is used to start the accumulation.
    ///     When accumulation is finisged this value is returned via `get`.
    ///   - updateAccumulatingResult: A closure that accepts the given `into` as an `inout` parameter and an item from a subscription and combines them into `into`.
    ///   - accumulator: The rumming accumulator (this is the given `into` and is the value returned via `get`).
    ///   - next: The next item to be accumulated.
    public init(timeout: DispatchTimeInterval = .seconds(1), bufferSize: Int = ReactiveStreams.defaultBufferSize, into initialResult: R, updateAccumulatingResult: @escaping ( _ accumulator: inout R, _ next: T) throws -> ()) {
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
        result = initialResult
        accumulatee = updateAccumulatingResult
    }
}
