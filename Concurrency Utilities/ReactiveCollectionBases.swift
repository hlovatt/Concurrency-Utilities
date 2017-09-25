//
//  ReactiveCollectionBases.swift
//  Concurrency Utilities
//
//  Created by Howard Lovatt on 5/9/17.
//  Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.
//

import Foundation

// MARK: Base `Publisher`s.

/// Base protocol for publishers that ensures there is only ever one subscription.
///
/// - warning:
///   - The *only* method/property intended for use by a client (the programmer using an instance of this class) is method `subscribe`; which is best called using operator `~~>` since that emphasizes that the other methods are not for client use.
///   - If multiple subscriptions are attempted; subsequent subscriptions are rejected with their `on(eror:)` method called with `PublisherErrors.subscriptionRejected(reason:)`, but the original subscription continues.
///   - This protocol is not thread safe (it makes no sense to share a producer since Reactive Streams are an alternative to dealing with threads directly!).
///
/// - note:
///   - This class does not provide buffering, but a derived class might.
public protocol PublisherBase: Publisher {
    /// Return the output subscription (there is only ever one at a time).
    var _outputSubscription: Subscription { get }
    
    /// Reset the subscription, called before subscription is granted to subscriber.
    func _resetOutputSubscription()
    
    /// Indicates if the given new subscription should be accepted or not.
    ///
    /// - parameter newSubscriber: The `Subscriber` that wishes to obtain a subscription, passed in so that a dummy failed subscription, e.g. `FailedSubscription.instance`, and errors can be sent to the subscription if it is rejected.
    ///
    /// - returns: `true` if the given `Subscriber` is accepted.
    func _isAccepted<S>(newSubscriber: S) -> Bool where S: Subscriber, S.InputT == OutputT
    
    /// The output subscriber, if any, held inside an atomic, so that it is thread safe.
    ///
    /// - warning: Derrived classes should only set the atomic's value to `nil`, no other value, see note below.
    ///
    /// - note: Derrived classes should set the atomic's value to `nil` when the subscriptions ends (for any reason - complete, error, or cancel).
    var _outputSubscriber: Atomic<AnySubscriber<OutputT>?> { get }
}

public extension PublisherBase {
    /// Default imlementation does nothing.
    func _resetOutputSubscription() {}
    
    /// Default imlementation accepts the subscription by returning `true`, but does nothing else.
    func _isAccepted<S>(newSubscriber _: S) -> Bool where S: Subscriber, S.InputT == OutputT {
        return true
    }
    
    /// Default imlementation should not be overridden.
    func subscribe<S>(_ newSubscriber: S) where S: Subscriber, S.InputT == OutputT {
        var isSubscriptionError = false
        _outputSubscriber.update { outputSubscriberOptional in
            guard outputSubscriberOptional == nil else {
                newSubscriber.on(subscribe: FailedSubscription.instance) // Reactive stream specification requires this to be called.
                newSubscriber.on(error: PublisherErrors.subscriptionRejected(reason: "Can only have one subscriber at a time."))
                isSubscriptionError = true
                return outputSubscriberOptional
            }
            guard _isAccepted(newSubscriber: newSubscriber) else {
                isSubscriptionError = true
                return nil
            }
            return AnySubscriber(newSubscriber)
        }
        guard !isSubscriptionError else {
            return
        }
        _resetOutputSubscription()
        newSubscriber.on(subscribe: _outputSubscription)
    }
}

/// Base protocol for publishers that are like an iterator; it has a `next` method (that must be provided) that produces items and signals last item with `nil`.
///
/// - warning:
///   - When a subscriber subscribes to a class implementing this protocol it is passed `self` (because this protocol is its own subscription).
///     Therefore each subscriber has to `nil` out its reference to the subscription when it receives either `on(error: Item)` or `onComplete()`, otherwise there will be a retain cycle memory leak.
///   - The *only* method/property intended for use by a client (the programmer using an instance of this protocol) is method `subscribe`; which is best called using operator `~~>` since that emphasizes that the other methods are not for client use.
///   - If either methods `cancel` or `request` (from `Subscription`) are called when there is no subscriber the result is a fatal error.
///   - If multiple subscriptions are attempted; subsequent subscriptions are rejected with their `on(eror:)` method called with `PublisherErrors.subscriptionRejected(reason:)`, but the original subscription continues.
///   - This class is not thread safe (it makes no sense to share a producer since Reactive Streams are an alternative to dealing with threads directly!).
///
/// - note:
///   - Each subscriber receives all of the items individually (provided that the iterator supports multiple traversal).
///   - This class does not provide buffering, but a derived class might.
///     However, the given `bufferSize` is used to control how responsive cancellation is because cancellation is checked at least each `bufferSize` items produced.
///
/// - parameters
///   - T: The type of the items produced.
public protocol IteratorPublisherBase: PublisherBase, Subscription {
    /// Produces next item or `nil` if no more items.
    ///
    /// - note:
    ///   - Unlike a normal iterator, `IteratorPublisherBase` guarantees that `next` is *not* called again once it has returned `nil` and before `reset` is called.
    ///     If iteration is non-repeating (i.e. `reset` does nothing) then `next` must return `nil` for all calls post the iteration completing.
    ///     This simplifies the implementation of this method.
    func _next() throws -> OutputT?
    
    /// Holds the subscriber, if there is one (inside an `Atomic` because thread safety is needed).
    var _outputSubscriber: Atomic<AnySubscriber<OutputT>?> { get }
    
    /// This is a standard property of Reactive Streams; in this case the property doesn't define the buffer size but rather the number of items produced before testing for subscription cancellation.
    var _outputBufferSize: Int { get }
    
    /// The queue used to sequence item production.
    var _outputDispatchQueue: DispatchQueue { get }
    
    /// The `producing` tasks are `Future`s, to allow cancellation, and inside a dictionary indexed with a unique number, producer number, to allow them to be both indivdually and *en masse* cancelled and deleted.
    var _outputProducers: [Int : Future<Void>] { get set }
    
    /// Unique number for each producer generated as a result of a `request`.
    var producerNumber: Int { get set }
    
    /// Called to request `n` more items to be produced.
    /// Schedules the production of items in blocks of upto `bufferSize` units.
    ///
    /// - parameter n: The number of additional items requested.
    func request(_ n: Int)
    
    /// Cancel the subscription and cancel any outstanding item production on a best efforts basis, i.e. additional items may be produced before the cancellation takes effect.
    /// Items are produced in upto `bufferSized` blocks and the current block will keep producing items after cancelleation, but a scheduled but unstarted block will be cancelled.
    func cancel()
}

public extension IteratorPublisherBase {
    /// This protocol is its own subscription therefore the default implementation of this property returns `self`.
    var _outputSubscription: Subscription {
        return self
    }

    /// Called to request `n` more items to be produced.
    /// Schedules the production of items in blocks of upto `bufferSize` units.
    ///
    /// - parameter n: The number of additional items requested.
    func request(_ n: Int) {
        guard n != 0 else { // n == 0 is same as cancel.
            cancel()
            return
        }
        _outputSubscriber.update { outputSubscriberOptional in
            guard let outputSubscriber = outputSubscriberOptional else { // Guard against already finished.
                fatalError("`request` called without a subscriber.") // Can't test fatal errors!
            }
            guard n > 0 else { // Guard against -ve n.
                outputSubscriber.on(error: PublisherErrors.cannotProduceRequestedNumberOfItems(numberRequested: n, reason: "Negative number of items not allowed."))
                return nil  // Completed.
            }
            let thisProducersNumber = producerNumber
            let producer = AsynchronousFuture(queue: self._outputDispatchQueue) { isTerminated throws -> Void in
                var count = n
                while count > 0 {
                    try isTerminated()
                    let innerLimit = min(self._outputBufferSize, count)
                    var innerCount = innerLimit
                    do {
                        while innerCount > 0, let item = try self._next() {
                            outputSubscriber.on(next: item)
                            innerCount -= 1
                        }
                    } catch {
                        outputSubscriber.on(error: error) // Report an error from next method.
                        self._outputProducers.removeValue(forKey: thisProducersNumber) // This producer has finished.
                        self.cancel() // Cancel remaining queued production and mark this subscription as complete.
                        return
                    }
                    count = innerCount > 0 ? -1 : count - innerLimit
                }
                self._outputProducers.removeValue(forKey: thisProducersNumber) // This producer has finished.
                if count < 0 { // Complete?
                    outputSubscriber.onComplete() // Tell subscriber that subscription is completed.
                    self.cancel() // Cancel remaining queued production and mark this subscription as complete.
                }
            }
            _outputProducers[thisProducersNumber] = producer
            producerNumber += 1
            return outputSubscriberOptional
        }
    }
    
    /// Cancel the subscription and cancel any outstanding item production on a best efforts basis, i.e. additional items may be produced before the cancellation takes effect.
    /// Items are produced in upto `bufferSized` blocks and the current block will keep producing items after cancelleation, but a scheduled but unstarted block will be cancelled.
    func cancel() {
        _outputSubscriber.update { outputSubscriberOptional in
            guard outputSubscriberOptional != nil else { // Guard against `cancel` called when no subscriber.
                fatalError("`cancel` or `request(0)` called without a subscriber.") // Can't test a fatal error.
            }
            for producer in self._outputProducers.values {
                producer.cancel() // Cancel item production from queued producer.
            }
            _outputProducers.removeAll()
            return nil // Mark subscription as completed.
        }
    }
}

/// A convenience class for implementing `IteratorPublisherBase`; it provides all the stored properties.
///
/// - warning: `next` must be overridden because the default implementation throws a fatal error.
///
/// - parameters
///   - O: The type of the output items produced.
open class IteratorPublisherClassBase<O>: IteratorPublisherBase {
    public typealias OutputT = O
    
    public let _outputSubscriber = Atomic<AnySubscriber<O>?>(nil)
    
    public let _outputBufferSize: Int
    
    private(set) public var _outputDispatchQueue: DispatchQueue
    
    public var _outputProducers = [Int : Future<Void>]()
    
    public var producerNumber = 0
    
    /// A convenience class for implementing `IteratorPublisherBase`; it provides all the stored properties.
    ///
    /// - parameters:
    ///   - qos: Quality of service for the dispatch queue used to sequence items and produce items in the background (default `DispatchQOS.default`).
    ///   - bufferSize: This is a standard argument to Reactive Stream types, in this case the argument doesn't define the buffer size but rather the number of items produced before testing for subscription cancellation (default `ReactiveStreams.defaultBufferSize`).
    public init(qos: DispatchQoS = .default, bufferSize: Int = ReactiveStreams.defaultBufferSize) {
        _outputBufferSize = bufferSize
        _outputDispatchQueue = DispatchQueue(label: "IteratorPublisherClassBase Serial Queue \(UniqueNumber.next)", qos: qos)
    }
    
    /// Default implementation throws a fatal error and *must* be overridden.
    open func _next() throws -> O? {
        fatalError("Must override method `next`")
    }
    
    /// Default implementation does nothing and therefore *might* require overridding.
    open func _resetOutputSubscription() {}
}

// MARK: Base `Subscriber`s.

/// A partial implementation of the `Subscriber` protocol (needs further implementation to do anything useful) that handles its one at a time subscription but otherwise does nothing (in particular it does not request items from its subscription).
/// Requesting items is one of the things a next level implementation would do (e.g. `RequestorSubscriberBase`).
///
/// - warning:
///   - `Subscriber`s are not thread safe, since they are an alternative to dealing with threads directly and therefore it makes no sense to share them between threads.
///   - There are *no* methods/properties intended for use by a client (the programmer using an instance of this class); the client *only* passes the instance to the `subscribe` method of a `Publisher`, which is best accomplished by `publisher ~~> subscriber`.
///
/// - note:
///   - A new successful subscription causes `handleNewSubscription` to be called; the default implementation of which does nothing other than return true to indicate that the new subscription should be accepted.
///   - Multiple subscriptions, errors from the subscription, and completed subscriptions all cause the current subscription to be cancelled and freed (set to `nil`) and call there relevent handlers (see point below); but take *no* further action.
///   - Override methods `handleMultipleSubscriptionError()`, `handleOn(error: Error)`, `handleOnComplete()` to control errors and completion actions, the defaults all throw fatal errors.
///   - Completion occurs when the subscription signals completion (it calls `onComplete()`) and the subscription should not call any methods after that, but this is not enforced (see next point for why).
///   - The contract for `on(next: Item)` requires that this method continues to allow calls after cancellation etc. so that 'in-transit' items do not cause thread locks and therefore this method is not locked out and therefore neither are the other 'on' methods (though they do nothing).
public protocol SubscriberBase: Subscriber {
    /// Takes the next item from the subscription and if necessary requests more items from the subscription.
    ///
    /// - parameter item: The next item.
    func _consumeAndRequest(item: InputT) throws
    
    /// Called when a new subscription is accepted and signals by return boolean if the subscription is to be accepted and if necessary requests initial items from subscription.
    ///
    /// - parameter subscription: The subscription that is to be granted and requested from by this method.
    ///
    /// - returns: `true` if the subscription has been accepted, false otherwise.
    func _handleNewSubscriptionAndRequest(subscription: Subscription) -> Bool
    
    /// Called when there is an attempt to make multiple subscriptions.
    func _handleMultipleSubscriptionError()
    
    /// Called when there is a subscription error.
    func _handleOn(error: Error)
    
    /// Called when the subscription completes.
    func _handleOnComplete()
    
    /// The input subscription, if any, held inside an atomic, so that it is thread safe.
    ///
    /// - warning: Implementing classes should only set this to `nil`, no other value, see note below.
    ///
    /// - note: Implementing classes should set this to `nil` when subscriptions ends (for any reason - complete, error, or cancel).
    var _inputSubscription: Atomic<Subscription?> { get }
}

public extension SubscriberBase {
    /// Returns true, i.e. subscription always succeeds and given `Subscription` is unused.
    func _handleNewSubscriptionAndRequest(subscription _: Subscription) -> Bool {
        return true // Can't be bothered to test this!
    }
    
    /// Default implimentation throws a fatal error.
    func _handleMultipleSubscriptionError() {
        fatalError("Can only have one subscription at a time.") // Cannot test a fatal error!
    }
    
    /// Default implimentation throws a fatal error.
    func _handleOn(error: Error) {
        fatalError("Subscription error: \(error).") // Cannot test a fatal error!
    }
    
    /// Default implimentation throws a fatal error.
    func _handleOnComplete() {
        fatalError("Subscription complete.") // Cannot test a fatal error!
    }
    
    func on(subscribe: Subscription) {
        _inputSubscription.update { subscriptionOptional in
            guard subscriptionOptional == nil else { // Cannot have more than one subscription.
                subscriptionOptional!.cancel()
                _handleMultipleSubscriptionError()
                return nil
            }
            guard _handleNewSubscriptionAndRequest(subscription: subscribe) else { // Instigate new subscription and  check if successful.
                return nil
            }
            return subscribe
        }
    }
    
    func on(next nextItem: InputT) {
        do {
            try _consumeAndRequest(item: nextItem) // Process the next item.
        } catch {
            on(error: error)
        }
    }
    
    func on(error: Error) {
        _inputSubscription.update { subscription in
            _handleOn(error: error)
            return nil // Free subscription's resources.
        }
    }
    
    func onComplete() {
        _inputSubscription.update { subscription in
            _handleOnComplete()
            return nil // Free subscription's resources.
        }
    }
}

/// A partial implementation of `Subscriber` protocol (needs further implementation to do anything useful) that handles its one at a time subscription and instigates requests for `bufferSize` items from its subscription.
/// Itially the class requests two lots of `bufferSize` items and then subsequently one lot; this ensures that there are always two lots of items in flow (to maximize througput).
/// Because the class requests two lots of `bufferSize` items a buffering sub-class would normally use two buffers each of `bufferSize` to hold in-flight items; when one buffer is finished it can be cleared (and its capacity retained) in a single operation, which is highly efficient.
///
/// - warning:
///   - `Subscriber`s are not thread safe, since they are an alternative to dealing with threads directly and therefore it makes no sense to share them between threads.
///   - There are *no* methods/properties intended for use by a client (the programmer using an instance of this class), the client *only* passes the instance to the `subscribe` method of a `Publisher`, which is best accomplished using `publisher ~~> subscription`.
///
/// - note:
///   - A new successful subscription causes `handleNewSubscription` to be called; the default implementation of which does nothing other than return true to indicate that the new subscription should be accepted.
///   - Multiple subscriptions, errors from the subscription, and completed subscriptions all cause the current subscription to be cancelled and freed (set to `nil`) and call there relevent handlers (see point below); but take *no* further action.
///   - Override methods `handleMultipleSubscriptionError()`, `handleOn(error: Error)`, `handleOnComplete()` to control errors and completion actions, the defaults all throw fatal errors.
///   - Completion occurs when the subscription signals completion (it calls `onComplete()`) and the subscription should not call any methods after that, but this is not enforced (see next point for why).
///   - The contract for `on(next: Item)` requires that this method continues to allow calls after cancellation etc. so that 'in-transit' items do not cause thread locks and therefore this method is not locked out and therefore neither are the other 'on' methods (though they do nothing).
public protocol RequestorSubscriberBase: SubscriberBase {
    /// Consumes the next item from the subscription.
    ///
    /// - parameter item: The next item.
    func _consume(item: InputT) throws
    
    /// Called when a new subscription is accepted and signals by return boolean if the subscription is to be accepted and if necessary requests initial items from subscription.
    ///
    /// - returns: `true` if the subscription has been accepted, false otherwise.
    func _handleNewSubscription() -> Bool
    
    var _inputBufferSize: Int { get }
    
    var _inputCountToRefill: Int { get set }
}

public extension RequestorSubscriberBase {
    /// Default implementation return true, indicating that new subscription should be accepted.
    func _handleNewSubscription() -> Bool {
        return true // Can't be bothered to test this!
    }
    
    /// Default implementation requests `bufferSize` items from subscription when current request is exhausted, calls the `next` mthod to process the next item, and reports any errors.
    func _consumeAndRequest(item: InputT) throws {
        _inputCountToRefill -= 1
        if _inputCountToRefill <= 0 { // Request more items when `bufferSize` items 'accumulated'.
            _inputCountToRefill = _inputBufferSize
            _inputSubscription.value?.request(_inputBufferSize)
        }
        try _consume(item: item) // Process the next item.
    }
    
    /// Default implementation requests two lots of `bufSize` items from the subscriber, so that one lot is always in-flight, and returns the acceptance status from `handleNewSubscription`.
    func _handleNewSubscriptionAndRequest(subscription: Subscription) -> Bool {
        guard _handleNewSubscription() else {
            return false
        }
        _inputCountToRefill = _inputBufferSize
        subscription.request(_inputBufferSize) // Start subscription
        subscription.request(_inputBufferSize) // Ensure that two lots of items are always in flight.
        return true
    }
}

/// Errors that a subscriber can report.
/// A pure `Subscriber` has no means of reporting errors, all it can do is cancel its subscription without giving reason.
/// However, `Subscribers` that are also `Future`s can report their errors via `Future`'s `status`.
enum SubscriberErrors: Error {
    
    /// Many `Subscribers` have a limit on the number of subscriptions they can have at one time, typically limited to one, and if this number is exceeded then the subscriper terminates and reports the error.
    case tooManySubscriptions(number: Int)
}

/// A base class (needs sub-classing to do anything useful) for a `Subscriber` that is also a `Future`.
/// It takes items from its subscription and passes them to its `next` method which processes each item and when completed the result is obtained from property `result` and returned via `get` and/or `status`.
///
/// - warning:
///   - Both `next` and `result` must be overriden (the default implementations throw a fatal error).
///   The default `reset` method does nothing and therefore *might* also need overriding.
///   - `Subscriber`s are not thread safe, since they are an alternative to dealing with thread safety directly and therefore it makes no sense to share them between threads.
///   - There are *no* `Publisher` methods/properties intended for use by a client (the programmer using an instance of this class), the client *only* passes the instance to the `subscribe` method of a `Publisher`.
///     The `Future` properties `get` and `status` and method `cancel` are the methods with which the client interacts.
///
/// - note:
///   - After one subscription has terminated (for any reason) a new subscription causes the future status to go back to running, i.e. the future is reset.
///   - Since the subscriber is also a future it can be cancelled or timeout, both of which in turn cancel its subscription.
///   - Completion occurs when the subscription signals completion (it calls `onComplete()`) and the subscription should not call any methods after that, but this is not enforced (see next point for why).
///   - The contract for `on(next: Item)` requires that this method continues to allow calls after cancellation etc. so that 'in-transit' items do not cause thread locks and therefore this method is not locked out and therefore neither are the other 'on' methods (though they do nothing).
///   - There is no concept of an abstract class in Swift, in other languages this would be an abstract class.
///
/// - parameters
///   - T: The type of the elements subscribed to.
///   - R: The result type of the accumulation.
open class SubscriberFutureClassBase<T, R>: Future<R>, RequestorSubscriberBase {
    /// The number of items to request at a time.
    public let _inputBufferSize: Int
    
    /// The number of outstanding items in the current request (there is also an additional request of `bufferSize` with producer, therefore producer is producing `coutToRefill + bufferSize` items).
    public var _inputCountToRefill = 0
    
    /// The subscription, if there is one.
    public let _inputSubscription = Atomic<Subscription?>(nil)
    
    
    // MARK: init
    
    /// A base class (needs sub-classing to do anything useful) for a `Subscriber` that is also a `Future`.
    /// It takes items from its subscription and passes them to its `next` method which processes each item and when completed the result is obtained from property `result` and returned via `get` and/or `status`.
    ///
    /// - precondition: `bufferSize` must be > 0.
    ///
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
            _timeoutTime = Date(timeIntervalSinceNow: Double(ns) / Double(1_000_000_000))
        case .microseconds(let us):
            _timeoutTime = Date(timeIntervalSinceNow: Double(us) / Double(1_000_000))
        case .milliseconds(let ms):
            _timeoutTime = Date(timeIntervalSinceNow: Double(ms) / Double(1_000))
        case .seconds(let s):
            _timeoutTime = Date(timeIntervalSinceNow: Double(s))
        case .never:
            _timeoutTime = Date.distantFuture
        }
        precondition(bufferSize > 0, "Buffer size must be > 0, is \(bufferSize)") // Can't test a precondition.
        self._inputBufferSize = bufferSize
    }
    
    // MARK: Methods that must be overridden
    
    /// Default implementation throws a fatal error, *must* be overridden.
    open func _consume(item: T) throws {
        fatalError("Method must be overridden")
    }
    
    /// Return the result so far (called when the accumulation is complete and its value stored in status and returned by `get`).
    open var _result: R {
        fatalError("Getter must be overridden.") // Can't test a fatal error.
    }
    
    /// Reset the accumulation for another evaluation.
    open func _resetAccumulation() {} // Can't be bothered to test.
    
    // MARK: Future properties and methods
    
    private let _status = Atomic(FutureStatus<R>.running) // Set in background, read in foreground.
    
    private let _timeoutTime: Date
    
    public final override var status: FutureStatus<R> {
        return _status.value
    }
    
    public final override var get: R? {
        while true { // Keep looping until completed, cancelled, timed out, or throws.
            switch _status.value {
            case .running:
                let sleepInterval = min(_timeoutTime.timeIntervalSinceNow, Futures.defaultMaximumSleepTime)
                guard sleepInterval < Futures.defaultMinimumSleepTime else { // Check worth sleeping.
                    Thread.sleep(forTimeInterval: sleepInterval)
                    break // Loop and check status again.
                }
                switch _status.value {
                case .running:
                    on(error: TerminateFuture.timedOut) // Timeout if still running.
                default:
                    break // Stay in present state if not running. Can't think how to test this line!
                }
            case .completed(let result):
                return result
            case .threw(_):
                return nil
            }
        }
    }
    
    public final override func cancel() {
        switch _status.value {
        case .running:
            on(error: TerminateFuture.cancelled)
        default:
            break // Do nothing - already finished.
        }
    }
    
    // MARK: Subscriber properties and methods
    
    public typealias InputT = T
    
    /// Sets the status to running, restes the acuumulation, and returns `true` to indicate acceptance of the subscription.
    public final func _handleNewSubscription() -> Bool {
        _status.value = .running
        _resetAccumulation()
        return true
    }
    
    /// Sets `status` to `.threw(error: SubscriberErrors.tooManySubscriptions(number: 2))`.
    public final func _handleMultipleSubscriptionError() {
        self._status.update {
            switch $0 {
            case .running:
                return .threw(error: SubscriberErrors.tooManySubscriptions(number: 2))
            default:
                fatalError("Should be `.running` for a multiple subscription error.") // Can't test a fatal error!
            }
        }
    }
    
    /// Sets `status` to `.threw(error: error)`.
    public final func _handleOn(error: Error) {
        _status.update {
            switch $0 {
            case .running:
                return .threw(error: error)
            default:
                return $0 // Ignore if already terminated.
            }
        }
    }
    
    /// Sets `status` to `.completed(result: accumulator)`.
    public final func _handleOnComplete() {
        _status.update {
            switch $0 {
            case .running:
                return .completed(result: _result)
            default:
                return $0 // Ignore if already terminated.
            }
        }
    }
}

// MARK: Base `Processor`s.

/// Base class for processors that take items from its input subscription, process them using the `process` method, and make the new items available via its output subscription.
///
/// - warning:
///   - Method `process` must be overridden (the default implementation throws a fatal error).
///   - When a subscriber subscribes to this class it is passed `self` (because this class is its own subscription).
///     Therefore each subscriber has to `nil` out its reference to the subscription when it receives either `on(error: Item)` or `onComplete()`, otherwise there will be a retain cycle memory leak.
///   - If either methods `cancel` or `request` (from `Subscription`) are called when there is no subscriber the result is a fatal error.
///   - The *only* method/property intended for use by a client (the programmer using an instance of this class) is method `subscribe`; however an instance of this class may be passed to the `subscribe` method of another `Publisher`.
///   Passing the instance to the publisher is best accomplished using operator `~~>`, since this emphasizes that the other methods are not for client use.
///   - If multiple subscriptions to this processor are attempted; subsequent subscriptions are rejected with their `on(eror:)` method called with `PublisherErrors.subscriptionRejected(reason:)`, but the original subscription continues.
///   - `Processor`s are not thread safe, since they are an alternative to dealing with thread safety directly and therefore it makes no sense to share them between threads.
///
/// - note:
///   - An output subscription is refused if there is no input subscription.
///   - When the output subscription requests items then this class requests the same number of items from its input subscription.
///   - If the output subscription is cancelled then this class cancels its input subscription.
///   - Multiple output subscription attempts to this processor cause the current subscription to be cancelled and freed (set to `nil`) and call there relevent handlers (see point below); but take *no* further action.
///   - If an attempt is made to subscribe this processor to multiple publishers then the existing input subscription is cancelled and if there is an output subscription it is terminated with `PublisherErrors.existingSubscriptionTerminated`.
///   - If the input subscription completes then this class completes its output subscription.
///   - If the input subscription signals an error then this class signals the error to its output subscription.
///   - If the `process` method throws then the error the error propagated to the output subscription and the input subscription is cancelled.
///   - There is no concept of an abstract class in Swift, in other languages this would be an abstract class.
///   - The associated types are:
///     - InputT: The type of the input items.
///     - OutputT: The type of the output items.
public protocol InlineProcessorBase: Processor, SubscriberBase, PublisherBase, Subscription {
    /// Takes given input item and processes it into an outut item.
    ///
    /// - parameter inputItem: The input item to be processed.
    ///
    /// - returns: The processed input item.
    func _process(_ inputItem: InputT) throws -> OutputT
}

extension InlineProcessorBase {
    /// Default implementation `process`es the input `item` from the input subscription and passes it onto the output subscription.
    func _consumeAndRequest(item: InputT) throws {
        _outputSubscriber.value?.on(next: try _process(item))
    }
    
    /// Default implementation terminates the existing input subscription, if there is one, with error `PublisherErrors.existingSubscriptionTerminated(reason: "...")`.
    func _handleMultipleSubscriptionError() {
        _outputSubscriber.update { outputSubscriberOptional in
            outputSubscriberOptional?.on(error: PublisherErrors.existingSubscriptionTerminated(reason: "Attempt to subscribe `Processor` to multiple publishers (in addition to this subscription)."))
            return nil
        }
    }
    
    /// Default implementation passes given error from the output subscription onto existing input subscription and terminates it, if there is one.
    func _handleOn(error: Error) {
        _outputSubscriber.update { outputSubscriberOptional in
            outputSubscriberOptional?.on(error: error)
            return nil
        }
    }
    
    /// Default implementation terminates the existing input subscription, if there is one, with `onComplete()`.
    func _handleOnComplete() {
        _outputSubscriber.update { outputSubscriberOptional in
            outputSubscriberOptional?.onComplete()
            return nil
        }
    }
    
    /// Default implementation returns `self` since an `InlineProcessorBase` is its own `Subscription`.
    var subscription: Subscription {
        return self
    }
    
    /// Default implementation only accepts an output subscription if the processor already has an input subscription.
    func _isAccepted<S>(newSubscriber _: S) -> Bool where S: Subscriber, S.InputT == OutputT {
        return _inputSubscription.value != nil
    }
    
    /// Default implementation cancels the input subscription, if there is one.
    func cancel() {
        _outputSubscriber.update { outputSubscriber in
            guard outputSubscriber != nil else {
                fatalError("`cancel` called without a subscriber to the output.") // Can't test a fatal error.
            }
            return nil
        }
        _inputSubscription.update { inputSubscription in
            inputSubscription?.cancel()
            return nil
        }
    }
    
    /// Default implementation passes the request for more items from the output subscription onto the input subscription.
    func request(_ n: Int) {
        guard _outputSubscriber.value != nil else {
            fatalError("`request` called without a subscriber to the output.") // Can't test a fatal error.
        }
        _inputSubscription.value!.request(n)
    }
}
