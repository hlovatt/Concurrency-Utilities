//
//  ReactiveCollectionBaseClasses.swift
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
//open class IteratingPublisher<T>: Publisher, Subscription {
//    
//    // MARK: init.
//    
//    /// A publisher that publishes the items produced by its `next` method (that must be overridden).
//    /// - precondition: bufferSize > 0
//    /// - parameters:
//    ///   - qos: Quality of service for the dispatch queue used to sequence items and produce items in the background.
//    ///   - bufferSize: This is a standard argument to Reactive Stream types, in this case the argument doesn't define the buffer size but rather the maximum number of items produced before testing for subscription cancellation.
//    public init(qos: DispatchQoS = .default, bufferSize: Int = ReactiveStreams.defaultBufferSize) {
//        precondition(bufferSize > 0, "bufferSize > 0: \(bufferSize)") // Can't test precondition in Swift 4!
//        self.bufferSize = bufferSize
//        queue = DispatchQueue(label: "ForEachPublisher Serial Queue \(ObjectIdentifier(self))", qos: qos)
//    }
//    
//    // MARK: Methods of concern when overriding.
//    
//    /// Produces next item or `nil` if no more items.
//    /// - note:
//    ///   - This method must be overridden (as implemented in this base class it throws a fatal exception).
//    ///   - Unlike a normal iterator, `IteratingPublisher` guarantees that `next` is not called again once it has returned `nil` and before `reset` is called.
//    ///     If iteration is non-repeating (i.e. `reset` does nothing) then `next` must return `nil` for all calls post the iteration completing.
//    ///     This simplifies the implementation of this method.
//    open func next() -> T? {
//        fatalError("`IteratingPublisher.next()` must be overridden.") // Can't test fatalError in Swift 4!
//    }
//    
//    /// Reset the iteration back to start, called before 1st call to next each time a subscription is granted.
//    /// - note:
//    ///   - If the iteration is non repeating (i.e. this method does nothing) then no need to override this method, since the default implementation does nothing.
//    ///     However, `next` must continue to return `nil` for subsequent calls.
//    open func reset() {}
//    
//    /// MARK: Publisher
//    
//    /// The type of items produced.
//    public typealias PublisherT = T
//    
//    private let subscriberAtomic = Atomic<AnySubscriber<T>?>(nil) // Temporary retain cycle because the subscriber holds a reference to this instance, however the subscriber `nils` its reference when subscription is terminated.
//    
//    public final func subscribe<S>(_ subscriber: S) where S: Subscriber, S.SubscriberT == T {
//        var isSubscriptionError = false
//        subscriberAtomic.update { subscriberOptional in
//            guard subscriberOptional == nil else {
//                subscriber.on(error: PublisherErrors.subscriptionRejected(reason: "Can only have one subscriber at a time."))
//                isSubscriptionError = true
//                return subscriberOptional
//            }
//            return AnySubscriber(subscriber)
//        }
//        guard !isSubscriptionError else {
//            return
//        }
//        reset()
//        subscriber.on(subscribe: self)
//    }
//    
//    // Mark: Subscription
//    
//    /// The type of items produced.
//    public typealias SubscriptionItem = T
//    
//    /// This is a standard property of Reactive Streams; in this case the property doesn't define the buffer size but rather the number of items produced before testing for subscription cancellation.
//    private let bufferSize: Int
//    
//    private var queue: DispatchQueue! // The queue used to sequence item production (initialized using self, hence has to be an optional).
//    
//    private var producers = [Int : Future<Void>]() // Producers are `Future`s, to allow cancellation.
//    
//    private var producerNumber = 0 // The `index` for producers.
//    
//    public final func request(_ n: Int) {
//        guard n != 0 else { // n == 0 is same as cancel.
//            cancel()
//            return
//        }
//        subscriberAtomic.update { subscriberOptional -> AnySubscriber<T>? in
//            guard let subscriber = subscriberOptional else { // Guard against already finished.
//                return nil // Completed. Can't think how to test this!
//            }
//            guard n > 0 else { // Guard against -ve n.
//                subscriber.on(error: PublisherErrors.cannotProduceRequestedNumberOfItems(numberRequested: n, reason: "Negative number of items not allowed."))
//                return nil // Completed.
//            }
//            let thisProducersNumber = producerNumber
//            let producer = AsynchronousFuture(queue: self.queue) { isTerminated throws -> Void in
//                var count = n
//                while count > 0 {
//                    try isTerminated()
//                    let innerLimit = min(self.bufferSize, count)
//                    var innerCount = innerLimit
//                    while innerCount > 0, let item = self.next() {
//                        subscriber.on(next: item)
//                        innerCount -= 1
//                    }
//                    count = innerCount > 0 ? -1 : count - innerLimit
//                }
//                self.producers.removeValue(forKey: thisProducersNumber) // This producer has finished.
//                if count < 0 { // Complete?
//                    subscriber.onComplete() // Tell subscriber that subscription is completed.
//                    self.cancel() // Cancel remaining queued production and mark this subscription as complete.
//                }
//            }
//            producers[thisProducersNumber] = producer
//            producerNumber += 1
//            return subscriber // Still subscribed.
//        }
//    }
//    
//    public final func cancel() {
//        subscriberAtomic.update { _ -> AnySubscriber<T>? in
//            for producer in self.producers.values {
//                producer.cancel() // Cancel item production from queued producer.
//            }
//            producers.removeAll()
//            return nil // Mark subscription as completed.
//        }
//    }
//}

/// A `Subscriber` base class (needs sub-classing to do anything useful) that handles its one at a time subscription.
/// - warning:
///   - Method `next(item: T)` must be overriden (the default implementation throws a fatal error).
///   - `Subscriber`s are not thread safe, since they are an alternative to dealing with threads directly and therefore it makes no sense to share them between threads.
/// - note:
///   - A new successful subscription causes `handleNewSubscription` to be called; the default implementation of which does nothing.
///   - Multiple subscriptions, errors from the subscription, and completed subscriptions all cause the current subscription to be cancelled and freed (set to `nil`) and call there relevent handlers (see point below); but take *no* further action.
///   - Override methods `handleMultipleSubscriptionError()`, `handleOn(error: Error)`, `handleOnComplete()` to control errors and completion actions, the defaults all throw fatal errors.
///   - Completion occurs when the subscription signals completion (it calls `onComplete()`) and the subscription should not call any methods after that, but this is not enforced (see next point for why).
///   - The contract for `on(next: Item)` requires that this method continues to allow calls after cancellation etc. so that 'in-transit' items do not cause thread locks and therefore this method is not locked out and therefore neither are the other 'on' methods (though they do nothing).
///   - There is no concept of an abstract class in Swift, in other languages this would be an abstract class.
/// - parameters:
///   - T: The type of the elements subscribed to.
open class BaseSubscriber<T>: Subscriber {
    
    // MARK: init
    
    /// A `Subscriber` base class (needs sub-classing to do anything useful) that handles its one at a time subscription.
    /// - precondition: `bufferSize` must be > 0.
    /// - parameters:
    ///   - bufferSize:
    ///     The buffer for this subscriber, if any, is provided by its subclass.
    ///     This parameter is also a tuning parameter to control the number of items requested at a time.
    ///     As is typical of subscribers, this subscriber always requests lots of `bufferSize` items and initially requests two lots of items so that there is always two lots of items in flight.
    ///     Tests for cancellation are only performed every `bufferSize` items, therefore there is a compromise between a large `bufferSize` to maximize throughput and a small `bufferSize` to maximise responsiveness.
    ///     The default `bufferSize` is `ReactiveStreams.defaultBufferSize`.
    public init(bufferSize: Int = ReactiveStreams.defaultBufferSize) {
        precondition(bufferSize > 0, "Buffer size must be > 0, is \(bufferSize)") // Can't test a precondition.
        self.bufferSize = bufferSize
    }
    
    // MARK: Method that must be overridden
    
    /// Takes the next item from the subscription.
    /// - parameter item: The next item.
    open func next(item: T) throws {
        fatalError("Method must be overridden.") // Can't test a fatal error.
    }
    
    // MARK: Methods that almost certainly will be overridden.
    
    /// Called when a new subscription is accepted.
    open func handleNewSubscription() {} // Can't be bothered to test this!
    
    /// Called when there is an attempt to make multiple subscriptions.
    open func handleMultipleSubscriptionError() {
        fatalError("Can only have one subscription at a time.") // Cannot test a fatal error!
    }
    
    /// Called when there is a subscription error.
    open func handleOn(error: Error) {
        fatalError("Subscription error: \(error).") // Cannot test a fatal error!
    }
    
    /// Called when the subscription completes.
    open func handleOnComplete() {
        fatalError("Subscription complete.") // Cannot test a fatal error!
    }
    
    // MARK: Subscriber properties and methods
    
    public typealias SubscriberT = T
    
    private var subscriptionAtomic = Atomic<Subscription?>(nil)
    
    private let bufferSize: Int
    
    private var countToRefill = 0
    
    public final func on(subscribe: Subscription) {
        subscriptionAtomic.update { subscriptionOptional in
            guard subscriptionOptional == nil else { // Cannot have more than one subscription.
                subscriptionOptional!.cancel()
                handleMultipleSubscriptionError()
                return nil
            }
            handleNewSubscription()
            countToRefill = bufferSize
            subscribe.request(bufferSize) // Start subscription
            subscribe.request(bufferSize) // Ensure that two lots of items are always in flight.
            return subscribe
        }
    }
    
    public final func on(next nextItem: T) {
        countToRefill -= 1
        if countToRefill <= 0 { // Request more items when `bufferSize` items 'accumulated'.
            countToRefill = bufferSize
            let subscription = subscriptionAtomic.value
            subscription?.request(countToRefill)
        }
        do {
            try next(item: nextItem) // Process the next item.
        } catch {
            on(error: error)
        }
    }
    
    public final func on(error: Error) {
        subscriptionAtomic.update { subscription in
            subscription?.cancel()
            handleOn(error: error)
            return nil // Free subscription's resources.
        }
    }
    
    public final func onComplete() {
        subscriptionAtomic.update { subscription in
            subscription?.cancel()
            handleOnComplete()
            return nil // Free subscription's resources.
        }
    }
}

/// A type erased version of `BaseSubscriber` that can used to enable multiple inheritance of `BaseSubscriber`; e.g.  `AccumulatingSubscriber` needs to inherite both `Future` and `BaseSubscriber`, this is achived by inheriting `Future` directly and `BaseSubscriber` via inheriting protocol `Subscriber` and using a delegate to an instance of this class to implement `Subscribers`'s methods.
/// - note:
///   - In Swift terminology `AnyBaseSubscriber` is said to type erase `BaseSubscriber`; meaning that it doesn't matter what type of `BaseSubscriber`'s closures are given to `AnyBaseSubscriber`'s `init` the result will always be the same type, `AnyBaseSubscriber`.
///   - For a Java, Scala, Haskell, etc. programmer this terminology is confusing because type erasure in these languages refers to erasing the generic type, in this case `T`, not the main type, in this case `AnyBaseSubscriber`.
///   - Further confusion for the Java, Scala, Haskell, etc. programmer is that `Subscriber` would be a type and not a generic constraint anyway, therefore `AnyBaseSubscriber` would be unnecessary in these languages.
public final class AnyBaseSubscriber<T>: BaseSubscriber<T> {
    private let handleNewSubscriptionClosure: () -> Void
    
    private let handleMultipleSubscriptionErrorClosure: () -> Void

    private let nextItemClosure: (T) throws -> Void
    
    private let handleOnErrorClosure: (Error) -> Void
    
    private let handleOnCompleteClosure: () -> Void
    
    /// - parameters:
    ///   - bufferSize: See description for `BaseSubscriber`.
    ///   - handleNewSubscription: Closure that is called when a new subscription is successful.
    ///   - handleMultipleSubscriptionError: Closure that is called when an attempt is made to subscribe to multiple subscriptions.
    ///   - nextItem: Closure that is called each time the subscriber recieves a new item from its subscription.
    ///   - item: The next item from the subscription that is passed to the `nextItem` closure.
    ///   - handleOnError: Closure that is called when an error with the subscription occures.
    ///   - error: The error from the subscription that is passed to the `handleOnError` closure.
    ///   - handleOnComplete: Closure that is called when an error with the subscription occures.
    public init(bufferSize: Int = ReactiveStreams.defaultBufferSize, handleNewSubscription: @escaping () -> Void, handleMultipleSubscriptionError: @escaping () -> Void, nextItem: @escaping (_ item: T) throws -> Void, handleOnError: @escaping (_ error: Error) -> Void, handleOnComplete: @escaping () -> Void) {
        handleNewSubscriptionClosure = handleNewSubscription
        handleMultipleSubscriptionErrorClosure = handleMultipleSubscriptionError
        nextItemClosure = nextItem
        handleOnErrorClosure = handleOnError
        handleOnCompleteClosure = handleOnComplete
        super.init(bufferSize: bufferSize)
    }
    
    public override func handleNewSubscription() {
        handleNewSubscriptionClosure()
    }
    
    public override func handleMultipleSubscriptionError() {
        handleMultipleSubscriptionErrorClosure()
    }
    
    public override func next(item: T) throws {
        try nextItemClosure(item)
    }
    
    public override func handleOn(error: Error) {
        handleOnErrorClosure(error)
    }
    
    public override func handleOnComplete() {
        handleOnCompleteClosure()
    }
}

/// A base class (needs sub-classing to do anything useful) for a `Subscriber` that is also a `Future`.
/// It takes items from its subscription and passes them to its `accumulatee` method which processes each item and when completed the result is obtained from property `accumulator` and returned via `get` and/or `status`.
/// - warning:
///   - Both `accumulatee` and `accumulator` must be overriden (the default implementations throw a fatal error).
///   The default `reset` method does nothing and therefore might also need overriding.
///   - `Subscriber`s are not thread safe, since they are an alternative to dealing with thread safety directly and therefore it makes no sense to share them between threads.
/// - note:
///   - After one subscription has terminated (for any reason) a new subscription causes the future status to go back to running, i.e. the future is reset.
///   - Since the subscriber is also a future it can be cancelled or timeout, both of which in turn cancel its subscription.
///   - Completion occurs when the subscription signals completion (it calls `onComplete()`) and the subscription should not call any methods after that, but this is not enforced (see next point for why).
///   - The contract for `on(next: Item)` requires that this method continues to allow calls after cancellation etc. so that 'in-transit' items do not cause thread locks and therefore this method is not locked out and therefore neither are the other 'on' methods (though they do nothing).
///   - There is no concept of an abstract class in Swift, in other languages this would be an abstract class.
/// - parameters:
///   - T: The type of the elements subscribed to.
///   - R: The result type of the accumulation.
open class BaseFutureSubscriber<T, R>: Future<R>, Subscriber {
    
    // MARK: init
    
    /// A base class (needs sub-classing to do anything useful) for a `Subscriber` that is also a `Future`.
    /// It takes items from its subscription and passes them to its `accumulatee` method which processes each item and when completed the result is obtained from property `accumulator` and returned via `get` and/or `status`.
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
        super.init() // Need to manually call super `init` to allow subscriber initialization that references `self`.
        subscriber = AnyBaseSubscriber(
            bufferSize: bufferSize,
            handleNewSubscription: {
                self._status.value = .running
                self.reset()
            },
            handleMultipleSubscriptionError: {
                self._status.update {
                    switch $0 {
                    case .running:
                        return .threw(error: SubscriberErrors.tooManySubscriptions(number: 2))
                    default:
                        fatalError("Should be running for a multiple subscription error.") // Can't think how to test this!
                    }
                }
            },
            nextItem: accumulatee(next:),
            handleOnError: { error in
                self._status.update {
                    switch $0 {
                    case .running:
                        return .threw(error: error)
                    default:
                        return $0 // Ignore if already terminated.
                    }
                }
            },
            handleOnComplete: {
                self._status.update {
                    switch $0 {
                    case .running:
                        return .completed(result: self.accumulator)
                    default:
                        return $0 // Ignore if already terminated.
                    }
                }
            }
        )
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
    
    /// Reset the accumulation for another evaluation.
    open func reset() {} // Can't be bothered to test.
    
    // MARK: Future properties and methods
    
    fileprivate let _status = Atomic(FutureStatus<R>.running) // Set in background, read in foreground.
    
    private let timeoutTime: Date
    
    public final override var status: FutureStatus<R> {
        return _status.value
    }
    
    public final override var get: R? {
        while true { // Keep looping until completed, cancelled, timed out, or throws.
            switch _status.value {
            case .running:
                let sleepInterval = min(timeoutTime.timeIntervalSinceNow, Futures.defaultMaximumSleepTime)
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
    
    public typealias SubscriberT = T
    
    private var subscriber: AnyBaseSubscriber<T>! = nil // Needs to be a force unwrapped optional to allow initialization in `init` that references self.
    
    public final func on(subscribe: Subscription) {
        subscriber.on(subscribe: subscribe)
    }
    
    public final func on(next: T) {
        subscriber.on(next: next)
    }
    
    public final func on(error: Error) {
        subscriber.on(error: error)
    }
    
    public final func onComplete() {
        subscriber.onComplete()
    }
}


/// - warning:
///   - Do not call methods `next` or `reset` manually, they are called by the superclass.
/// - note:
///   - There is no concept of an abstract class in Swift, in other languages this would be an abstract class.
//open class BaseInlineProcessor<I, O>: IteratingPublisher<O>, Processor {
//
//    // MARK: `init` part.
//
//    public override init(qos: DispatchQoS = .default, bufferSize: Int = ReactiveStreams.defaultBufferSize) {
//        super.init(qos: qos, bufferSize: bufferSize)
//        subscriber = AnyBaseSubscriber(
//            bufferSize: bufferSize,
//            handleNewSubscription: <#T##() -> Void#>,
//            handleMultipleSubscriptionError: <#T##() -> Void#>,
//            nextItem: { item in
//                self.nextInput = item
//                self.next()
//            },
//            handleOnError: <#T##(Error) -> Void#>,
//            handleOnComplete: <#T##() -> Void#>
//        )
//    }
//
//    // MARK: Method to override.
//
//    open func process(_ item: I) throws -> O {
//        fatalError("Method must be overridden.") // Can't test fatalError in Swift 4!
//    }
//
//    // MARK: Subscriber part.
//
//    public typealias SubscriberT = I
//
//    private var subscriber: AnyBaseSubscriber<I>! = nil
//
//    public final func on(subscribe: Subscription) {
//        subscriber.on(subscribe: subscribe)
//    }
//
//    public final func on(next: I) {
//        subscriber.on(next: next)
//    }
//
//    public final func onComplete() {
//        subscriber.onComplete()
//    }
//
//    public final func on(error: Error) {
//        subscriber.on(error: error)
//    }
//
//    // MARK: Publisher part.
//
//    public typealias PublisherT = O
//
//    private var nextInput: I! = nil
//
//    public final override func next() -> O? {
//        do {
//            return try process(nextInput)
//        } catch {
//            on(error: error)
//            return nil
//        }
//    }
//
//    public final override func reset() {}
//}
