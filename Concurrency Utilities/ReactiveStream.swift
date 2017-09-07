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
enum PublisherErrors: Error {
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
    associatedtype PublisherItem
    
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
    func subscribe<S>(_ subscriber: S) where S: Subscriber, S.SubscriberItem == PublisherItem
    
    //    // Stream flow operator for subscriptions.
    //    static func ~> <S>(left: Self, right: S) -> S where S: Subscriber, S.SubscriberItem == PublisherItem
}

/// `Subscriber` errors that the subscriber reports using its status (typically inherited from `Future`).
enum SubscriberErrors: Error {
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
    associatedtype SubscriberItem
    
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
    func on(next: SubscriberItem)
    
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
    @discardableResult static func ~~> <P>(left: P, right: Self) -> Self where P: Publisher, P.PublisherItem == SubscriberItem {
        left.subscribe(right)
        return right
    }
}

/// Wrap any `Subscriber` in a `struct`, useful where `Subscriber` is needed as a type (it is a protocol).
///
/// EG Implementations of `Subscription` typically contain a reference to the `Subscriber` they belong to and this reference is typed `AnySubscriber` because `Subscriber` cannot be used as a type because it has an associated type `SubscriberItem`.
class AnySubscriber<T>: Subscriber {
    typealias SubscriberItem = T
    
    let complete: () -> Void
    
    let error: (Error) -> Void
    
    let next: (T) -> Void
    
    let subscribe: (Subscription) -> Void
    
    init<S>(_ subscriber: S) where S: Subscriber, S.SubscriberItem == T {
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
    
    func onComplete() {
        self.complete()
    }
    
    func on(error: Error) {
        self.error(error)
    }
    
    func on(next: T) {
        self.next(next)
    }
    
    func on(subscribe: Subscription) {
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
enum ReactiveStreams {
    /// The suggested buffer size for `Publisher` or `Subscriber` buffering, that may be used in the absence of other constraints.
    ///
    /// - note: The current implementation has a default value is 256.
    static let defaultBufferSize = 256
}

// MARK: Explination text loosly based upon: http://download.java.net/java/jdk9/docs/api/java/util/concurrent/Flow.html.

/// A `Publisher` usually defines its own `Subscription` implementation; constructing one in method `subscribe` and issuing it to the calling `Subscriber`.
/// That way a publisher can trivially have multiple subscribers, since each subscriber has its own subscription.
/// However; each subscriber has to nil out its reference to the subscription when it recieves either `on(error: Item)` or `onComplete()`, otherwise there will be a retain cycle memory leak.
/// The publisher produces items in order and passes them to each subscriber asynchronously; normally this is achieved by each subscription having its own serial queue.
/// For example, here is a publisher that produces (when requested) items from the given `Sequence` to its subscribers.
/// Each subscriber recieves all of the sequence individually, i.e. each subscriber recieves the whole sequence (provided that the given sequence supports multiple traversal).
/// This class does not use buffering, unlike many implementations, because buffering is handelled by the given sequence.
/// The class ensures ordering of items produced using a serial queue inside its private subscription class.
/// When a `ForEachPubliser` is created the given sequence is copied, therefore any changes to the sequence made after the publisher is created are *not* reflected in the items produced (the copy of the sequence is made at creation time not subscription time).
public final class ForEachPublisher<T>: Publisher {
    public typealias PublisherItem = T
    
    private let sequence: AnySequence<T>
    
    private let qos: DispatchQoS
    
    public func subscribe<S>(_ subscriber: S) where S: Subscriber, S.SubscriberItem == T {
        subscriber.on(subscribe: ForEachSubscription(AnySubscriber(subscriber), sequence.makeIterator(), qos))
    }
    
    init<S>(sequence: S, qos: DispatchQoS = DispatchQoS.default) where S: Sequence, S.SubSequence: Sequence, S.Iterator.Element == T, S.SubSequence.SubSequence == S.SubSequence, S.SubSequence.Iterator.Element == T {
        self.sequence = AnySequence(sequence)
        self.qos = qos
    }
}

private final class ForEachSubscription<T>: Subscription {
    typealias SubscriptionItem = T
    
    private let subscriber: AnySubscriber<T> // Temporary retain cycle because the subscriber holds a reference to this instance, however the subscriber nils its reference when .
    
    private let iterator: AnyIterator<T>
    
    private var queue: DispatchQueue! = nil
    
    private var future: Future<Void>? = nil // Put the production within a `Future`, to allow cancellation.
    
    private let isCompleted = Atomic(false) // Used to ensure thread safety (its the lock) and to mark when the `Publisher` has finished.
    
    init(_ subscriber: AnySubscriber<T>, _ iterator: AnyIterator<T>, _ qos: DispatchQoS) {
        self.subscriber = subscriber
        self.iterator = iterator
        queue = DispatchQueue(label: "ForEachPublisher Serial Queue \(ObjectIdentifier(self))", qos: qos)
    }
    
    func request(_ n: Int) {
        isCompleted.update { [weak self] completed -> Bool in // Capture self weakly, incase no longer required.
            guard n != 0, !completed, let strongSelf = self else { // Guard against do nothing, already finished, and no self.
                if !completed {
                    self?.subscriber.onComplete()
                }
                return true // Completed.
            }
            if n < 0 {
                strongSelf.subscriber.on(error: PublisherErrors.cannotProduceRequestedNumberOfItems(numberRequested: n, reason: "Negative number of items not allowed."))
                return true // Mark subscription as completed.
            }
            future = AsynchronousFuture(queue: strongSelf.queue) { _ throws -> Void in
                var count = n
                while count > 0, let item = strongSelf.iterator.next() {
                    strongSelf.subscriber.on(next: item)
                    count -= 1
                }
                if count != 0 {
                    strongSelf.subscriber.onComplete() // Tell subscriber that subscription is completed.
                    strongSelf.isCompleted.value = true // Mark subscription as completed.
                }
            }
            return false // Still going.
        }
    }
    
    func cancel() {
        isCompleted.update { [weak self] completed -> Bool in // Capture self weakly, incase no longer required.
            self?.future?.cancel() // Cancel production of future items.
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
///   - `Subscriber`s are thread safe and can be shared between threads, like other `Future`s.
public final class ReduceSubscriber<T, R>: Future<R>, Subscriber {
    // MARK: Future properties and methods
    
    private let _status = Atomic(FutureStatus<R>.running) // Set in background, read in foreground.
    
    private let timeoutTime: Date
    
    override var status: FutureStatus<R> {
        return _status.value
    }
    
    override var get: R? {
        while true { // Keep looping until completed, cancelled, timed out, or throws.
            switch _status.value { // Potentially wait for timeout.
            case .running:
                let sleepInterval = min(timeoutTime.timeIntervalSinceNow, 0.25) // Limit sleep to 250 ms to remain responsive.
                if sleepInterval > 0.01 { // Minimum time interval worth sleeping for is 10 ms.
                    Thread.sleep(forTimeInterval: sleepInterval)
                } else {
                    _status.update {
                        switch $0 {
                        case .running:
                            return .threw(error: TerminateFuture.timedOut) // Timeout if still running.
                        default:
                            return $0 // Can't think how to test this!
                        }
                    }
            } // Loop and check status again.
            case .completed(let result):
                return result
            case .threw(_):
                return nil
            }
        }
    }
    
    override func cancel() {
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
    
    public typealias SubscriberItem = T
    
    private var result: R
    
    private let updateAccumulatingResult: (inout R, T) throws -> ()
    
    private var subscription: Subscription?
    
    private let bufferSize: Int
    
    private var countToRefill = 0 // The buffer is provided by the consumer, but the data transfer is still in chunks so that the system is responsive (in particular checks on cancellation, throws, and completion are made before and after a chunk of items are transfered).
    
    public func on(subscribe: Subscription) {
        _status.update {
            switch $0 {
            case .running: // Only allow subscriptions if running.
                guard subscription == nil else { // Only allow one subscription.
                    subscription?.cancel() // Cancel the current subscription because of the error.
                    return .threw(error: SubscriberErrors.tooManySubscriptions(number: 2)) // Error if already subscribed.
                }
                countToRefill = bufferSize - bufferSize / 2 // Re-request when half consumed (half rounded up so that a buffer of 1 is OK).
                subscribe.request(bufferSize) // Initially fill the buffer
                self.subscription = subscribe
                return $0 // Still running.
            default:
                return $0 // Do nothing - already finished.
            }
        }
    }
    
    public func on(next: T) {
        countToRefill -= 1
        if countToRefill <= 0 {
            countToRefill = bufferSize - bufferSize / 2 // Re-request when half consumed (half rounded up so that a buffer of 1 is OK).
            subscription?.request(countToRefill)
        }
        do {
            try updateAccumulatingResult(&result, next) // The output buffer/accumulator is provided by `result`.
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
    
    /// - note: The default `timeout` is 1 second and the default buffer size is `ReactiveStreams.defaultBufferSize`.
    /// - precondition: `bufferSize` must be > 0.
    init(timeout: DispatchTimeInterval = .seconds(1), bufferSize: Int = ReactiveStreams.defaultBufferSize, into initialResult: R, updateAccumulatingResult: @escaping (inout R, T) throws -> ()) {
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
        self.updateAccumulatingResult = updateAccumulatingResult
    }
}
