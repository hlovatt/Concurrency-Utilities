//
//  ReactiveCollectionBases.swift
//  Concurrency Utilities
//
//  Created by Howard Lovatt on 5/9/17.
//  Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.
//

import Foundation

// MARK: Base `Publisher`s.

/// Base protocol for publishers that ensures there is only ever one output subscription.
///
/// - warning:
///   - The *only* method/property intended for use by a client (the programmer using an instance of this class) is method `subscribe`; which is best called using operator `~~>` since that emphasizes that the other methods are not for client use.
///   - If multiple subscriptions are attempted; subsequent subscriptions are rejected with their `on(eror:)` method called with `PublisherErrors.subscriptionRejected(reason:)`, but the original subscription continues.
///   - This protocol is not thread safe (it makes no sense to share a producer since Reactive Streams are an alternative to dealing with threads directly!).
protocol PublisherBase: Publisher {
    /// Return the output subscription (there is only ever one at a time).
    var _outputSubscription: Subscription { get }
    
    /// Reset the subscription, called before subscription is granted to subscriber.
    func _resetOutputSubscription()
    
    /// Indicates if the given new output subscription should be accepted or not.
    ///
    /// - returns: An empty string if the given `Subscriber` is accepted, otherwise an error message to pass onto the subscriber whose subscription request was rejected.
    var _isNewOutputSubscriberAccepted: String { get }
    
    /// The output subscriber, if any, held inside an atomic, so that it is thread safe.
    ///
    /// - warning: Derrived classes should only set the atomic's value to `nil`; no other value, see note below.
    ///
    /// - note: Derrived classes should set the atomic's value to `nil` when the subscription ends (for any reason - complete, error, or cancel).
    var _outputSubscriber: Atomic<AnySubscriber<OutputT>?> { get }
}

extension PublisherBase {
    /// Default implementation does nothing.
    func _resetOutputSubscription() {} // Can't be bothered to test.

    /// Default imlementation accepts the subscription by returning an empty string, but does nothing else.
    var _isNewOutputSubscriberAccepted: String {
        return ""
    }
    
    /// Default imlementation checks for multiple subscription attempt, checks if subscription accepted, calls `_resetOutputSubscription`, and calls `newOutputSubscriber.on(subscribe: _outputSubscription)`.
    func subscribe<S>(_ newOutputSubscriber: S) where S: Subscriber, S.InputT == OutputT {
        var isSubscriptionError = false
        _outputSubscriber.update { outputSubscriberOptional in
            guard outputSubscriberOptional == nil else {
                newOutputSubscriber.on(subscribe: FailedSubscription.instance) // Reactive stream specification requires this to be called.
                newOutputSubscriber.on(error: PublisherErrors.subscriptionRejected(reason: "Can only have one subscriber at a time."))
                isSubscriptionError = true
                return outputSubscriberOptional
            }
            let errorMessage = _isNewOutputSubscriberAccepted
            guard errorMessage.isEmpty else {
                newOutputSubscriber.on(subscribe: FailedSubscription.instance) // Reactive stream specification requires this to be called.
                newOutputSubscriber.on(error: PublisherErrors.subscriptionRejected(reason: errorMessage))
                isSubscriptionError = true
                return nil
            }
            return AnySubscriber(newOutputSubscriber)
        }
        guard !isSubscriptionError else {
            return
        }
        _resetOutputSubscription()
        newOutputSubscriber.on(subscribe: _outputSubscription)
    }
}

/// Base protocol for publishers that are like an iterator; it has a `next` method (that must be provided) that produces items and signals last item with `nil`.
///
/// - warning:
///   - When a subscriber subscribes successfully to a class implementing this protocol it is passed `self` (because this protocol is its own subscription).
///     Therefore each subscriber has to `nil` out its reference to the subscription when it receives either `on(error: Item)` or `onComplete()`, otherwise there will be a retain cycle memory leak.
///   - The *only* method/property intended for use by a client (the programmer using an instance of this protocol) is method `subscribe`; which is best called using operator `~~>` since that emphasizes that the other methods are not for client use.
///   - If either methods `cancel` or `request` (from `Subscription`) are called when there is no subscriber the result is a fatal error.
///   - If multiple subscriptions are attempted; subsequent subscriptions are rejected with their `on(eror:)` method called with `PublisherErrors.subscriptionRejected(reason:)`, but the original subscription continues.
///   - This class is not thread safe (it makes no sense to share a producer since Reactive Streams are an alternative to dealing with threads directly!).
///
/// - note:
///   - Each subscriber receives all of the items individually (provided that the `next` method supports multiple traversal).
protocol IteratorPublisherBase: PublisherBase, Subscription {
    /// Produces next item or `nil` if no more items.
    ///
    /// - note:
    ///   - Unlike a normal iterator, `IteratorPublisherBase` guarantees that `_next` is *not* called again once it has returned `nil` and before `_resetOutputSubscription` is called.
    ///     *However,* if the iteration is non-repeating (i.e. `_resetOutputSubscription` does nothing) then `_next` must return `nil` for all calls post the iteration completing (`_resetOutputSubscription` will be called but since it does nothing `_next` must continue to return `nil`).
    ///     This rul of calling `_resetOutputSubscription` after `_next` has returned `nil` simplifies the implementation of the `_next` method.
    func _next() throws -> OutputT?
    
    /// Holds the subscriber, if there is one (inside an `Atomic` because thread safety is needed).
    var _outputSubscriber: Atomic<AnySubscriber<OutputT>?> { get }
    
    /// The queue used to sequence item production.
    var _outputDispatchQueue: DispatchQueue { get }
    
    /// Number of additional items requested but not yet in production.
    var _additionalRequestedItems: Atomic<UInt64> { get }
    
    /// If addition actions, other than nilling out the output subscriber and setting additional items to zero, are required then this method shoule be overriden (the daefault does nothing).
    func _handleOutputSubscriptionCancelled()
}

extension IteratorPublisherBase {
    /// This protocol is its own subscription therefore the default implementation of this property returns `self`.
    var _outputSubscription: Subscription {
        return self
    }
    
    /// Default implementation schedules requested items for production in the background on the given queue.
    func request(_ n: UInt64) {
        guard n != 0 else { // n == 0 is same as cancel.
            cancel()
            return
        }
        guard _outputSubscriber.value != nil else { // Cannot request without a subscriber.
            return // Can't think how to test!
        }
        _additionalRequestedItems.update { current in
            if current == 0 {
                _scheduleProduction()
            }
            let total = current &+ n
            guard total >= n else {
                _outputSubscriber.update { outputSubscriberOptional in
                    outputSubscriberOptional?.on(error: PublisherErrors.cannotProduceRequestedNumberOfItems(numberRequested: n, reason: "More than `UInt64.max` items requested or in production."))
                    return nil // Cancel the subscription. Can't call cancel because updating `_additionalRequestedItems`.
                }
                return 0
            }
            return total
        }
    }
    
    /// Default implementation returns a function that is suitable for asynchronous execution that produces the outstanding items by calling `_next()`, checking for termination (signals, errors, and completion).
    /// When finished without termination checks if more items are now required, post initial schedulling, and if so produces these extra and repeats this process until no more items are required.
    private func _scheduleProduction() {
        _outputDispatchQueue.async {
            var numberOfItems = self._additionalRequestedItems.value
            while true {
                var count = numberOfItems
                guard count != 0, let outputSubscriber = self._outputSubscriber.value else {
                    return // Finished producing.
                }
                do {
                    while count > 0, let item = try self._next() {
                        outputSubscriber.on(next: item)
                        count -= 1
                    }
                } catch {
                    outputSubscriber.on(error: error) // Report an error from next method.
                    self.cancel() // Cancel remaining queued production and mark this subscription as complete.
                    return
                }
                guard count == 0 else { // Complete because `_next` must have returned `nil` and hence `count > 0`?
                    outputSubscriber.onComplete() // Tell subscriber that subscription is completed.
                    self.cancel() // Cancel remaining production and mark this subscription as complete.
                    return
                }
                numberOfItems = self._additionalRequestedItems.update { current in
                    return current > numberOfItems ?
                        current - numberOfItems :
                        0 // Must have been cancelled whilst producing the items.
                }
            }
        }
    }
    
    // Default implementation does nothing.
    func _handleOutputSubscriptionCancelled() {}
    
    /// Default implementation sets `_additionalRequestedItems.value` to zero, `nil`s out `_additionalRequestedItems`, and calls `_handleOutputSubscriptionCancelled`.
    func cancel() {
        _outputSubscriber.update { _ in
            _additionalRequestedItems.value = 0
            return nil // Mark subscription as completed.
        }
        _handleOutputSubscriptionCancelled()
    }
}

/// A convenience class for implementing `IteratorPublisherBase`; it provides all the stored properties.
///
/// - warning: `_next` must be overridden because its default implementation throws a fatal error.
///
/// - parameters
///   - O: The type of the output items produced.
class IteratorPublisherClassBase<O>: IteratorPublisherBase {
    public typealias OutputT = O
    
    let _outputSubscriber = Atomic<AnySubscriber<O>?>(nil)
    
    private(set) var _outputDispatchQueue: DispatchQueue
    
    let _additionalRequestedItems = Atomic<UInt64>(0)
    
    /// A convenience class for implementing `IteratorPublisherBase`; it provides all the stored properties.
    ///
    /// - parameters:
    ///   - queue: Dispatch queue used to produce items in the background.
    init(queue: DispatchQueue) {
        _outputDispatchQueue = queue
    }
    
    /// Default implementation throws a fatal error and *must* be overridden.
    func _next() throws -> O? {
        fatalError("Must override method `_next`") // Can't test fatal errors.
    }
    
    /// Default implementation does nothing.
    func _resetOutputSubscription() {}
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
///   - A new successful subscription causes `_handleAndRequestFrom(newInputSubscription:)` to be called; the default implementation of which does nothing.
///   - Multiple subscriptions, errors from the subscription, and completed subscriptions all cause the current subscription to be cancelled and freed (set to `nil`) and call there relevent handlers (see point below); but take *no* further action.
///   - Override methods `_handleMultipleInputSubscriptionError()`, `_handleInputSubscriptionOn(error: Error)`, `_handleInputSubscriptionOnComplete()` to control errors and completion actions, the defaults all throw fatal errors.
///   - Completion occurs when the subscription signals completion (it calls `onComplete()`) and the subscription should not call any methods after that, but this is not enforced (see next point for why).
///   - The contract for `on(next: Item)` requires that this method continues to allow calls after cancellation etc. so that 'in-transit' items do not cause thread locks and therefore this method is not locked out and therefore neither are the other 'on' methods (though they do nothing).
protocol SubscriberBase: Subscriber {
    /// Takes the next item from the subscription and if necessary requests more items from the subscription.
    ///
    /// - parameter item: The next item.
    func _handleInputAndRequest(item: InputT) throws
    
    /// Called when a new input subscription is requested and if necessary requests an initial production run of items from the subscription.
    ///
    /// - parameter newInputSubscription: The input subscription that might have an initial production run requested from it by this method.
    func _handleAndRequestFrom(newInputSubscription: Subscription)
    
    /// Called when there is an attempt to make multiple input subscriptions.
    func _handleMultipleInputSubscriptionError()
    
    /// Called by the input subscription when there is a production error that has terminated production and no more items will be produced - even if more are requested.
    func _handleInputSubscriptionOn(error: Error)
    
    /// Called by the input subscription when the publisher has finished producting items (production run is complete and no more items will be produced - even if more are requested).
    func _handleInputSubscriptionOnComplete()
    
    /// The input subscription, if any, held inside an atomic, so that it is thread safe.
    ///
    /// - warning: Implementing classes should only set this to `nil`, no other value, see note below.
    ///
    /// - note: Implementing classes should set this to `nil` when subscriptions ends (for any reason - complete, error, or cancel).
    var _inputSubscription: Atomic<Subscription?> { get }
}

extension SubscriberBase {
    /// Default implementation does nothing.
    func _handleAndRequestFrom(newInputSubscription _: Subscription) {}
    
    /// Default implimentation throws a fatal error.
    func _handleMultipleInputSubscriptionError() {
        fatalError("Can only have one subscription at a time.") // Cannot test a fatal error!
    }
    
    /// Default implimentation throws a fatal error.
    func _handleInputSubscriptionOn(error: Error) {
        fatalError("Subscription error: \(error).") // Cannot test a fatal error!
    }
    
    /// Default implimentation throws a fatal error.
    func _handleInputSubscriptionOnComplete() {
        fatalError("Subscription complete.") // Cannot test a fatal error!
    }
    
    /// Default implementation checks that it is not already subscribed to, if it is it cancels both the exsisting and new subscriptions, and if not then calls `handleAndRequestFrom`.
    public func on(subscribe: Subscription) {
        _inputSubscription.update { subscriptionOptional in
            guard subscriptionOptional == nil else { // Cannot have more than one subscription.
                subscriptionOptional!.cancel()
                subscribe.cancel()
                _handleMultipleInputSubscriptionError()
                return nil
            }
            _handleAndRequestFrom(newInputSubscription: subscribe)
            return subscribe
        }
    }
    
    /// Default implementation passes given item onto `_handleInputAndRequest`, catches and processes `SubscriberSignal`s,  catches and reports other errors using `on(error:)`, and `nil`s out `_inputSubscription` to free resources.
    public func on(next nextItem: InputT) {
        do {
            try _handleInputAndRequest(item: nextItem) // Process the next item.
        } catch SubscriberSignal.cancelInputSubscriptionAndComplete {
            _inputSubscription.update { inputSubscriptionOptional in
                guard let inputSubscription = inputSubscriptionOptional else {
                    return nil // Already finished. Can't think how to test this!
                }
                inputSubscription.cancel()
                _handleInputSubscriptionOnComplete()
                return nil // Free subscription's resources.
            }
        } catch {
            _inputSubscription.update { inputSubscriptionOptional in
                guard let inputSubscription = inputSubscriptionOptional else {
                    return nil // Already finished.
                }
                inputSubscription.cancel()
                _handleInputSubscriptionOn(error: error)
                return nil // Free subscription's resources.
            }
        }
    }
    
    /// Default implementation calls `_handleInputSubscriptionOn(error:)` and `nil`s out `_inputSubscription` to free resources.
    public func on(error: Error) {
        _inputSubscription.update { inputSubscriptionOptional in
            guard inputSubscriptionOptional != nil else {
                return nil // Already finished. Can't think how to test this!
            }
            _handleInputSubscriptionOn(error: error)
            return nil // Free subscription's resources.
        }
    }
    
    /// Default implementation calls `_handleInputSubscriptionOnComplete()` and `nil`s out `_inputSubscription` to free resources.
    public func onComplete() {
        _inputSubscription.update { inputSubscriptionOptional in
            guard inputSubscriptionOptional != nil else {
                return nil // Already finished.
            }
            _handleInputSubscriptionOnComplete()
            return nil // Free subscription's resources.
        }
    }
}

/// A partial implementation of `Subscriber` protocol (needs further implementation to do anything useful) that handles its one at a time subscription and instigates requests for `requestSize` items from its subscription.
/// Itially the class requests two lots of `requestSize` items and then subsequently one lot; this ensures that there are always two lots of items in flow (to maximize througput).
///
/// - warning:
///   - `Subscriber`s are not thread safe, since they are an alternative to dealing with threads directly and therefore it makes no sense to share them between threads.
///   - There are *no* methods/properties intended for use by a client (the programmer using an instance of this class), the client *only* passes the instance to the `subscribe` method of a `Publisher`, which is best accomplished using `publisher ~~> subscription`.
///
/// - note:
///   - A new successful subscription causes `_handleNewInputSubscription` to be called; the default implementation of which does nothing.
///   - Multiple subscriptions, errors from the subscription, and completed subscriptions all cause the current subscription to be cancelled and freed (set to `nil`) and call there relevent handlers (see point below); but take *no* further action.
///   - Override methods `_handleMultipleInputSubscriptionError()`, `_handleInputSubscriptionOn(error: Error)`, `_handleInputSubscriptionOnComplete()` to control errors and completion actions, the defaults all throw fatal errors.
///   - Completion occurs when the subscription signals completion (it calls `onComplete()`) and the subscription should not call any methods after that, but this is not enforced (see next point for why).
///   - The contract for `on(next: Item)` requires that this method continues to allow calls after cancellation etc. so that 'in-transit' items do not cause thread locks and therefore this method is not locked out and therefore neither are the other 'on' methods (though they do nothing).
protocol RequestorSubscriberBase: SubscriberBase {
    /// Consumes the next item from the subscription.
    ///
    /// - parameter item: The next item.
    func _handleInput(item: InputT) throws
    
    /// Called when a new input subscription is requested.
    func _handleNewInputSubscription()
    
    /// The number of items to request at a time.
    var _inputRequestSize: UInt64 { get set }
    
    /// The number of outstanding items in the current request (there is also an additional request of `requestSize` with producer, therefore producer is producing `_inputCountToRequest + requestSize` items).
    var _inputCountToRequest: Int64 { get set }
}

extension RequestorSubscriberBase {
    /// Default implementation does nothing.
    func _handleNewInputSubscription() {} // Can't be bothered to test.
    
    /// Default implementation requests `requestSize` items from subscription when current request is exhausted, calls the `_handleInput` method to process the next item, and throws any errors.
    func _handleInputAndRequest(item: InputT) throws {
        _inputCountToRequest -= 1
        guard _inputCountToRequest >= 0 else { // Cancelled producer is still producing!
            _inputCountToRequest = 0
            return
        }
        if _inputCountToRequest == 0 { // Request more items when `requestSize` items 'accumulated'.
            _inputCountToRequest = Int64(_inputRequestSize)
            _inputSubscription.value?.request(_inputRequestSize)
        }
        try _handleInput(item: item) // Process the next item.
    }
    
    /// Default implementation requests two lots of `bufSize` items from the subscription, so that one lot is always in-flight, if the subscription is accepted and returns the acceptance status from `_handleNewInputSubscription`.
    func _handleAndRequestFrom(newInputSubscription: Subscription) {
        _handleNewInputSubscription()
        _inputCountToRequest = Int64(_inputRequestSize)
        newInputSubscription.request(_inputRequestSize) // Start subscription
        newInputSubscription.request(_inputRequestSize) // Ensure that two lots of items are always in flight.
    }
}

/// Errors that a subscriber that is also a future can report.
/// A pure `Subscriber` has no means of reporting errors, all it can do is cancel its subscription without giving reason.
/// However, `Subscribers` that are also `Future`s can report their errors via `Future`'s `status`.
enum FutureSubscriberErrors: Error {
    /// Many `Subscribers` have a limit on the number of subscriptions they can have at one time, typically limited to one, and if this number is exceeded then the subscriper terminates and reports the error.
    case tooManySubscriptions(number: Int)
}

/// A base class (needs sub-classing to do anything useful) for a `Subscriber` that is also a `Future`.
/// It takes items from its subscription and passes them to its `next` method which processes each item and when completed the result is obtained from property `result` and returned via `get` and/or `status`.
///
/// - warning:
///   - Both `_handleInput` and `_result` must be overriden (the default implementations throw a fatal error).
///   The default `_resetAccumulation` method does nothing and therefore *might* also need overriding.
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
class FutureSubscriberClassBase<T, R>: Future<R>, RequestorSubscriberBase {
    var _inputRequestSize: UInt64
    
    var _inputCountToRequest: Int64 = 0
    
    let _inputSubscription = Atomic<Subscription?>(nil)
    
    // MARK: init
    
    /// A base class (needs sub-classing to do anything useful) for a `Subscriber` that is also a `Future`.
    /// It takes items from its subscription and passes them to its `next` method which processes each item and when completed the result is obtained from property `result` and returned via `get` and/or `status`.
    ///
    /// - parameters:
    ///   - timeout: The time that `get` will wait before returning `nil` and setting `status` to a timeout error (default `Futures.defaultTimeout`).
    ///   - requestSize:
    ///     Tuning parameter to control the number of items requested at a time.
    ///     As is typical of subscribers, this subscriber always requests lots of `requestSize` items and initially requests two lots of items so that there is always two lots of items in flight.
    ///     Tests for cancellation are performed on average every `requestSize` items, therefore there is a compromise between a large `requestSize` to maximize throughput and a small `requestSize` to maximise responsiveness.
    ///     The default `requestSize` is `ReactiveStreams.defaultRequestSize`.
    init(timeout: DispatchTimeInterval = Futures.defaultTimeout, requestSize: UInt64 = ReactiveStreams.defaultRequestSize) {
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
        self._inputRequestSize = requestSize
    }
    
    func _handleInput(item: T) throws {
        fatalError("Method must be overridden") // Can't test a fatal error.
    }
    
    var _result: R {
        fatalError("Getter must be overridden.") // Can't test a fatal error.
    }
    
    /// Reset the accumulation for another evaluation (called each time there is a new input subscription).
    func _resetAccumulation() {} // Can't be bothered to test.
    
    // MARK: Future properties and methods
    
    /// Return the result or `nil` on error, timeout, or cancel.
    final override var wait: R? {
        while true { // Keep looping until completed, cancelled, timed out, or throws.
            switch _status.value {
            case .running:
                let sleepInterval = min(_timeoutTime.timeIntervalSinceNow, Futures.defaultMaximumSleepTime)
                guard sleepInterval < Futures.defaultMinimumSleepTime else { // Check worth sleeping.
                    Thread.sleep(forTimeInterval: sleepInterval)
                    break // Loop and check status again.
                }
                switch _status.value {
                case .running: // Timeout if still running.
                    _inputSubscription.value?.cancel() // Cancel the input.
                    on(error: TerminateFuture.timedOut)
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
    
    let _status = Atomic(FutureStatus<R>.running) // Set in background, read in foreground.
    
    let _timeoutTime: Date
    
    final override var status: FutureStatus<R> {
        return _status.value
    }
    
    final override func cancel() {
        switch _status.value {
        case .running:
            _inputSubscription.value?.cancel() // Cancel the input.
            _inputCountToRequest = 0
            on(error: TerminateFuture.cancelled) // Set status to cancelled.
        default:
            break // Do nothing - already finished.
        }
    }
    
    // MARK: Subscriber properties and methods
    
    public typealias InputT = T
    
    /// Sets the status to running and restes the acuumulation.
    /// - note: The method is called after checking that there is not already a subscription, therefore method does not check for multiple subscriptions.
    final func _handleNewInputSubscription() {
        _status.value = .running
        _resetAccumulation()
    }
    
    /// Sets `status` to `.threw(error: FuturteSubscriberErrors.tooManySubscriptions(number: 2))`.
    final func _handleMultipleInputSubscriptionError() {
        self._status.update {
            switch $0 {
            case .running:
                _inputCountToRequest = 0
                return .threw(error: FutureSubscriberErrors.tooManySubscriptions(number: 2))
            default:
                fatalError("Should be `.running` for a multiple subscription error.") // Can't test a fatal error!
            }
        }
    }
    
    /// Sets `status` to `.threw(error: error)`.
    final func _handleInputSubscriptionOn(error: Error) {
        _status.update {
            switch $0 {
            case .running:
                _inputCountToRequest = 0
                return .threw(error: error)
            default:
                return $0 // Ignore if already terminated. Can't think how to test.
            }
        }
    }
    
    /// Sets `status` to `.completed(result: accumulator)`.
    final func _handleInputSubscriptionOnComplete() {
        _status.update {
            switch $0 {
            case .running:
                _inputCountToRequest = 0
                return .completed(result: _result)
            default:
                return $0 // Ignore if already terminated. Can't think how to test.
            }
        }
    }
}

// MARK: Base `Processor`s.

/// Base protocol for processors that take items from its input subscription, process them using the `_map` method, and make the new items available via its output subscription.
///
/// - warning:
///   - When a subscriber subscribes to this class it is passed `self` (because this class is its own subscription).
///     Therefore each subscriber has to `nil` out its reference to the subscription when it receives either `on(error: Item)` or `onComplete()`, otherwise there will be a retain cycle memory leak.
///   - If either methods `cancel` or `request` (from `Subscription`) are called when there is no subscriber the result is a fatal error.
///   - The *only* method/property intended for use by a client (the programmer using an instance of this class) is method `subscribe`; however an instance of this class may be passed to the `subscribe` method of another `Publisher`.
///   Passing the instance to the publisher or subscribing to its output is best accomplished using operator `~~>`, since this emphasizes that the other methods are not for client use.
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
///   - If the `_map` method throws then the error the error propagated to the output subscription and the input subscription is cancelled.
///   - A new successful input subscription causes `_handleNewInputSubscription` to be called; the default implementation of which does nothing.
///   - Multiple input subscriptions, errors from the input subscription, and a completed input subscriptions all cause the current input subscription to be cancelled and freed (set to `nil`) and call there relevent handlers (see point below); but take *no* further action.
///   - Override methods `_handleMultipleInputSubscriptionError()`, `_handleInputSubscriptionOn(error: Error)`, `_handleInputSubscriptionOnComplete()` to control errors and completion actions, the defaults all throw fatal errors.
///   - Completion occurs when the input subscription signals completion (it calls `onComplete()`) and the input subscription should not call any methods after that, but this is not enforced (see next point for why).
///   - The contract for `on(next: Item)` requires that this method continues to allow calls after cancellation etc. so that 'in-transit' items do not cause thread locks and therefore this method is not locked out and therefore neither are the other 'on' methods (though they do nothing).
///   - The associated types are:
///     - InputT: The type of the input items.
///     - OutputT: The type of the output items.
protocol ProcessorBase: Processor, SubscriberBase, PublisherBase, Subscription {}

extension ProcessorBase {
    /// Default returns self since `ProcessorBase` is its own `Subscription`.
    var _outputSubscription: Subscription {
        return self
    }
    
    /// Default implementation terminates the existing output subscription, if there is one, with error `PublisherErrors.existingSubscriptionTerminated(reason: "...")`.
    func _handleMultipleInputSubscriptionError() {
        _outputSubscriber.update { outputSubscriberOptional in
            outputSubscriberOptional?.on(error: PublisherErrors.existingSubscriptionTerminated(reason: "Attempt to subscribe `Processor` to multiple `Publisher`s (multiple input error)."))
            return nil
        }
    }
    
    /// Default implementation passes given error from the input subscription onto the output subscription, if there is one, and hence terminates it.
    func _handleInputSubscriptionOn(error: Error) {
        _outputSubscriber.update { outputSubscriberOptional in
            outputSubscriberOptional?.on(error: error)
            return nil
        }
    }
    
    /// Default implementation terminates the existing output subscription, if there is one, with `onComplete()`.
    func _handleInputSubscriptionOnComplete() {
        _outputSubscriber.update { outputSubscriberOptional in
            outputSubscriberOptional?.onComplete()
            return nil
        }
    }
    
    /// Default implementation only accepts an output subscriber if the processor already has an input subscription.
    var _isNewOutputSubscriberAccepted: String {
        return _inputSubscription.value == nil ?
            "Cannot have an output subscriber without an input subscription." :
            ""
    }
    
    /// Default implementation cancels the input subscription and `nil`s out the reference to it, if it has one, and if there is an output subscriber `nil`s it also and if there is no output subscriber throws a fatal error.
    func cancel() {
        _outputSubscriber.update { outputSubscriberOptional in
            guard outputSubscriberOptional != nil else {
                fatalError("`cancel` called without a subscriber to the output.") // Can't test a fatal error.
            }
            return nil
        }
        _inputSubscription.update { inputSubscriptionOptional in
            inputSubscriptionOptional?.cancel()
            return nil
        }
    }
    
    /// Default implementation passes the request for more items from the output subscription onto the input subscription and if there is no output subscriber throws a fatal error.
    func request(_ n: UInt64) {
        guard _outputSubscriber.value != nil else {
            fatalError("`request` called without a subscriber to the output.") // Can't test a fatal error.
        }
        _inputSubscription.value!.request(n)
    }
}

/// A convenience class for implementing `ProcessorBase`; it provides all the stored properties.
///
/// - warning: `_handleInputAndRequest(item:)` and `_resetOutputSubscription` must both be overridden because their default implementations throw a fatal error.
///
/// - parameters
///   - I: The type of the input items to be processed.
///   - O: The type of the output items produced.
class ProcessorClassBase<I, O>: ProcessorBase {
    public typealias InputT = I
    
    public typealias OutputT = O
    
    let _outputSubscriber = Atomic<AnySubscriber<O>?>(nil)
    
    let _inputSubscription = Atomic<Subscription?>(nil)
    
    func _handleInputAndRequest(item: I) throws {
        fatalError("Must be overridden.") // Can't test a fatal error!
    }
    
    func _resetOutputSubscription() {
        fatalError("Must override method `_resetOutputSubscription`") // Can't test fatal errors.
    }
}

/// Base class for  processors that forks (a.k.a. fans-out/duplicates) its input flow stream by passing all input item onto all its output forks (a.k.a. output flows/streams/subscriptions).
/// The input items are bufferd into the input buffer and each output stream has its own task supplying items from the ouput buffer, that way output streams operate concurrently (in parallel on multi-core machines) and thereby account for different processing and consumption rates of the different forks.
/// When the output buffer is output to all forks and the input buffer is full the two buffers are swapped over.
/// When the input subscription and output subscriptions are established the `fork` method is called to start production, no change in either input or output is then allowed until production has finished.
/// Once any the output forks cancel the input subscription is cancelled and the other output subscriptions are notified by an error of the cancellation.
/// An `on(error: Item)` or `onComplete()` from the input is passed to all output subscribers.
///
/// - warning:
///   - When a subscriber subscribes to this class it is passed a unique subscription.
///     Therefore each subscriber has to `nil` out its reference to the subscription when it receives either `on(error: Item)` or `onComplete()`, otherwise the subscription will be retained.
///   - The *only* method/property intended for use by a client (the programmer using an instance of this class) is method `subscribe`; however an instance of this class may be passed to the `subscribe` method of another `Publisher`.
///   Passing the instance to the publisher and subscribing to its output is best accomplished using operator `~~>`, since this emphasizes that the other methods are not for client use.
///   - `Processor`s are not thread safe, since they are an alternative to dealing with thread safety directly and therefore it makes no sense to share them between threads.
///
/// - note:
///   - An output subscription is refused if there is no input subscription.
///   - When an output subscription requests items then items from the input subscription are requested.
///     Typically output subscriptions request different numbers of items and at different rates; an internal buffer is used to allow the input stream to produce at the rate of the fastest output stream for a while and then wait whilst the slower output streams catch up.
///     The size of this internal buffer is adapive to the request size from the output streams (it is half the minimumum of the requested items from the input streams).
///   - If an attempt is made to subscribe this processor to multiple publishers then the existing input subscription is cancelled and if there are output subscriptions they is terminated with `PublisherErrors.existingSubscriptionTerminated`.
///   - If the input subscription completes then this class completes all its output subscriptions.
///   - If the input subscription signals an error then this class signals the error to all its output subscriptions.
///   - Multiple input subscriptions, errors from the input subscription, and a completed input subscription all cause the current input subscription to be cancelled and freed (set to `nil`).
///   - Completion occurs when the input subscription signals completion (it calls `onComplete()`) and the input subscription should not call any methods after that, but this is not enforced (see next point for why).
///   - The contract for `on(next: Item)` requires that this method continues to allow calls after cancellation etc. so that 'in-transit' items do not cause thread locks and therefore this method is not locked out and therefore neither are the other 'on' methods (though they do nothing).
///   - The generic types are:
///     - T: The type of the items (input and output are the same type).
class ForkerClassBase<T>: Processor {
    typealias InputT = T
    
    typealias OutputT = T
    
    var _inputSubscription: Subscription? = nil
    
    var _inputBuffer = [T]()
    
    var _inputCountRemaining: Int64 = 0
    
    var _outputSubscriptions = [ForkerClassBaseSubscription<T>]()
    
    var _outputBuffer = [T]()
    
    let _outputDispatchQueue: DispatchQueue
    
    var _isForked = false
    
    let _producersGroup = DispatchGroup()
    
    let _controlDispatchQueue = DispatchQueue(label: "ForkerClassBase Serial Queue \(UniqueNumber.next)")
    
    /// Base class for  processors that forks (a.k.a. fans-out/duplicates) its input flow stream by passing all input item onto all its output forks (a.k.a. output flows/streams/subscriptions).
    ///
    /// - parameters:
    ///   - queue: Dispatch queue used to feed input items to output forks in the background.
    init(queue: DispatchQueue) {
        _outputDispatchQueue = queue
    }
    
    /// Fork the input into the multiple outputs and request production from the input.
    ///
    /// - warning:
    ///   - Throws a fatal error if the method is called a second time without the previous production having first finished and new input and output subscriptions established.
    ///   - Throws a fatal error if there is no input subscription.
    ///   - Throws a fatal error if there are no output subscriptions.
    ///
    /// - note:
    ///   This method must be called for production to proceed.
    ///   The subscriptions do not start production, they just request a production quantity, until this method is called.
    ///   Production proceeds (when this method is called) with a production quantity of the minimum of half the requested production quantities from the output subscribers.
    ///   The reason that the production quantity is half is that subscribers typically ask for twice what they need to ensure that there are always production items 'in-flight'.
    public final func fork() {
        _controlDispatchQueue.sync {
            guard !self._isForked else {
                fatalError("Cannot fork twice.") // Can't test a fatal error.
            }
            guard self._inputSubscription != nil else {
                fatalError("Cannot fork without an input subscription.") // Can't test a fatal error.
            }
            guard !self._outputSubscriptions.isEmpty else {
                fatalError("Cannot fork without any output subscriptions.") // Can't test a fatal error.
            }
            self.requestInput()
            self._isForked = true
        }
    }
    
    private func requestInput() {
        var requestSize = UInt64.max
        for outputSubscription in _outputSubscriptions { // An output still running, therefore do nothing.
            let totalRequests = outputSubscription._outstandingOutputRequestsTotal
            guard totalRequests != 0 else {
                fatalError("A production request should have been made before fork was called.") // Can't test a fatal error.
            }
            requestSize = min(requestSize, totalRequests - totalRequests / 2) // Normally half of total, but cover total of 1.
        }
        _inputCountRemaining = Int64(requestSize)
        _inputBuffer.removeAll(keepingCapacity: true)
        _inputBuffer.reserveCapacity(Int(requestSize))
        _inputSubscription!.request(requestSize)
    }
    
    public final func subscribe<S>(_ subscriber: S) where S: Subscriber, T == S.InputT {
        _controlDispatchQueue.sync {
            guard !self._isForked else { // Once forked no more subscribers.
                for outputSubscription in self._outputSubscriptions {
                    outputSubscription._outputSubscriber.on(error: PublisherErrors.existingSubscriptionTerminated(reason: "Attempt to add another output subscriber once forked."))
                }
                self._cancelInputAndRemoveOutputs()
                return
            }
            self._outputSubscriptions.append(ForkerClassBaseSubscription(outputSubscriber: AnySubscriber(subscriber), cancel: self._cancel, request: self._request))
        }
    }
    
    public final func onComplete() {
        _producersGroup.notify(queue: _controlDispatchQueue) {
            for outputSubscription in self._outputSubscriptions {
                self._outputDispatchQueue.async(group: self._producersGroup) {
                    for item in self._inputBuffer {
                        outputSubscription._outputSubscriber.on(next: item)
                    }
                    outputSubscription._outputSubscriber.onComplete()
                }
            }
            self._producersGroup.wait()
            self._cancelInputAndRemoveOutputs()
        }
    }
    
    public final func on(error: Error) {
        _producersGroup.notify(queue: _controlDispatchQueue) {
            for outputSubscription in self._outputSubscriptions {
                outputSubscription._outputSubscriber.on(error: error)
            }
            self._cancelInputAndRemoveOutputs()
        }
    }
    
    public final func on(next: T) {
        _inputCountRemaining -= 1
        guard _inputCountRemaining >= 0 else { // Producer has continued to produce after cancellation.
            _inputCountRemaining = 0
            return
        }
        _inputBuffer.append(next)
        if _inputCountRemaining == 0 {
            _producersGroup.notify(queue: _controlDispatchQueue) {
                self._outputBuffer.removeAll(keepingCapacity: true)
                swap(&self._inputBuffer, &self._outputBuffer)
                for outputSubscription in self._outputSubscriptions {
                    self._outputDispatchQueue.async(group: self._producersGroup) {
                        for item in self._outputBuffer {
                            outputSubscription._outputSubscriber.on(next: item)
                        }
                        outputSubscription._outstandingOutputRequestsTotal -= UInt64(self._outputBuffer.count)
                    }
                }
                self.requestInput()
            }
        }
    }
    
    public final func on(subscribe inputSubscription: Subscription) {
        _controlDispatchQueue.async {
            guard self._inputSubscription == nil else { // Cannot have more than one subscription.
                inputSubscription.cancel()
                for outputSubscription in self._outputSubscriptions {
                    outputSubscription._outputSubscriber.on(error: PublisherErrors.existingSubscriptionTerminated(reason: "Attempt to subscribe `Processor` to multiple `Publisher`s (multiple input error)."))
                }
                self._cancelInputAndRemoveOutputs()
                return
            }
            self._inputSubscription = inputSubscription
        }
    }
    
    private func _cancelInputAndRemoveOutputs() {
        _outputSubscriptions.removeAll()
        _inputSubscription?.cancel()
        _inputSubscription = nil
        _inputBuffer.removeAll()
        _inputCountRemaining = 0
        _outputBuffer.removeAll()
        _isForked = false
    }
    
    private func _cancel(subscriptionThatCancelled: ForkerClassBaseSubscription<T>) {
        _controlDispatchQueue.async {
            for outputSubscription in self._outputSubscriptions {
                guard subscriptionThatCancelled !== outputSubscription else { // Don't send an error to the subscription that cancelled.
                    continue
                }
                outputSubscription._outputSubscriber.on(error: PublisherErrors.existingSubscriptionTerminated(reason: "Another output subscriber cancelled."))
            }
            self._cancelInputAndRemoveOutputs()
        }
    }

    private func _request(outputSubscription: ForkerClassBaseSubscription<T>, n: UInt64) {
        _controlDispatchQueue.async {
            outputSubscription._outstandingOutputRequestsTotal += n
        }
    }
    
    final class ForkerClassBaseSubscription<T>: Subscription {
        private let _cancel: (ForkerClassBaseSubscription<T>) -> Void
        
        private let _request: (ForkerClassBaseSubscription<T>, UInt64) -> Void
        
        var _outstandingOutputRequestsTotal: UInt64 = 0
        
        let _outputSubscriber: AnySubscriber<T>
        
        init(outputSubscriber: AnySubscriber<T>, cancel: @escaping (ForkerClassBaseSubscription<T>) -> Void, request: @escaping (ForkerClassBaseSubscription<T>, UInt64) -> Void) {
            _outputSubscriber = outputSubscriber
            _cancel = cancel
            _request = request
            outputSubscriber.on(subscribe: self)
        }
        
        public func cancel() {
            _cancel(self)
        }
        
        public func request(_ n: UInt64) {
            guard n != 0 else { // Requesting 0 items is the same as cancel.
                cancel()
                return
            }
            _request(self, n)
        }
    }
}

