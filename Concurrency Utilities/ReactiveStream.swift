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
/// - All (seven) methods are defined in void "one-way" message style.
/// - Communication relies on a simple form of flow control (method `Subscription.request(Int)`) that can be used to avoid resource management problems that may otherwise occur in "push" based systems.

/// A `Processor` represents a processing stage — which is both a `Subscriber` and a `Publisher` and obeys the contracts of both.
public protocol Processor: Subscriber, Publisher {}

/// `Publisher` errors that the publisher reports using `Subscriber.on(error: Error)`.
public enum PublisherErrors: Error {
    /// Subscription request failed.
    case subscriptionRejected(reason: String)
    
    /// Requested illegal number of items.
    case cannotProduceRequestedNumberOfItems(numberRequested: Int, reason: String)
    
    /// Existing subscription is terminated.
    case existingSubscriptionTerminated(reason: String)
}

/// A `Publisher` is a provider of a potentially unbounded number of sequenced items, publishing them according to the demand received from its `Subscriber`(s).
///
/// - note:
///   - A `Publisher` *can* serve multiple `Subscribers` subscribed by `subscribe(Subscriber)` dynamically at various points in time.
///   - However; *most* publishers can have only one subscriber at a time, but there are specialist publishers and processors (a type of publisher) that handle multiple subscribers simultaneously.
///   - A publisher is a class that implements this protocol; it is a class because method subscribe modifies *the* publisher, *not* a copy of the publisher.
///   - Publishers are typically not thread safe because it makes no sense to share them between threads (they are an alternative to using threads directly).
public protocol Publisher: AnyObject {
    
    /// The type of items this `Publisher` produces/outputs.
    associatedtype OutputT
    
    /// Request this `Publisher` starts streaming items to the given `Subscriber`.
    ///
    /// - note:
    ///   - This is a "factory method" and can be called multiple times, each time starting a new `Subscription`.
    ///     Most publishers can have only one subscriber at a time, but there are specialist publishers and processors (a type of publisher) that handle multiple subscribers simultaneously.
    ///   - Each `Subscription` will work for only a single `Subscriber`.
    ///   - A `Subscriber` should only subscribe once to a single `Publisher`.
    ///   - If the `Publisher` rejects the subscription attempt it will signal the error via `Subscriber.on(error: PublisherErrors.subscriptionRejected(reason: String))`.
    ///   Existing subscriptions would continue uninterrupted if an error occures when attempting subsequent subscriptions.
    ///
    /// - parameter subscriber: The `Subscriber` that will consume items from this `Publisher`.
    func subscribe<S>(_ subscriber: S) where S: Subscriber, S.InputT == OutputT
}

/// `Subscriber`s consume items from `Producers` once they have established a `Subscription` with the `Producer`.
///
/// They will receive a call to `on(subscribe: Subscription)` once after passing an instance of `self` to `Publisher.subscribe(Subscriber)` to supply the `Subscription`.
///
/// No (further) items will be received by this `Subscriber` from the subscribed to `Producer` until `Subscription.request(Int)` is called.
///
/// After signaling demand:
/// - Invocations of `on(next: T)` up to the maximum number requested by `Subscription.request(Int)` will be made by the subscribed to `Producer`.
/// - Single invocation of `on(error: Error)` or `onComplete()` which signals a terminal state after which no further items will be produced.
///
/// Demand can be signaled via `Subscription.request(Int)` whenever the `Subscriber` instance is capable of handling more items.
///
/// - note:
///   - A subscriber is a class that implements this protocol, it is a class because it passes itself to the publisher it is requesting a subscription from.
///   - Subscribers are typically not thread safe because it makes no sense to share them between threads (they are an alternative to using threads directly).
public protocol Subscriber: AnyObject {
    /// The type of the items consumed by this `Subscriber`.
    associatedtype InputT
    
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
    func on(next: InputT)
    
    /// Invoked by the subscribed to `Publisher`, after this `Subscriber` has called `Publisher.subscribe(self)`.
    ///
    /// No items will be produced until `Subscription.request(Int)` is invoked.
    /// It is the responsibility of this `Subscriber` to call `Subscription.request(Int)` whenever more data is wanted.
    /// The `Publisher` will produce items only in response to `Subscription.request(Int)`.
    ///
    /// - parameter subscribe: `Subscription` that allows requesting data via `Subscription.request(Int)`
    func on(subscribe: Subscription)
}

/// Operator for stream like flow.
///
/// - note:
//    - Double tilde used because `~>` already defined in the standard library, but without associativity and therefore can't be chained.
///   - The wavy line `~~` is reminiscent of both 'S' for subscription and the fact that flow goes up and down.
///   - The `>` is the direction of the flow.
infix operator ~~> : MultiplicationPrecedence

/// Operator for stream like flow that force unwraps an optional.
infix operator ~~>! : MultiplicationPrecedence

/// Operator for stream like flow that ignores a `nil` optional.
infix operator ~~>? : MultiplicationPrecedence

// Add flow syntax as an extension to `Subscriber` rather than `Publisher`, since the subscriber is returned and therefore the full type information, Self, is available for subsequent stages.
public extension Subscriber {
    /// Subscribe a subscriber to a publisher using stream flow syntax, `publisher ~~> subscriber1`.
    ///
    /// - warning: This operator should not be overridden since it only has one meaningful definition, however this cannot be prevented in Swift 4 because the operator is defined on a protocol.
    @discardableResult public static func ~~> <P>(left: P, right: Self) -> Self where P: Publisher, P.OutputT == InputT {
        left.subscribe(right)
        return right
    }
    
    /// Subscribe a subscriber to multiple publishers using stream flow syntax, `[publisher1, publisher2, ...] ~~> subscriber`.
    ///
    /// - warning: This operator should not be overridden since it only has one meaningful definition, however this cannot be prevented in Swift 4 because the operator is defined on a protocol.
    @discardableResult public static func ~~> <S, P>(left: S, right: Self) -> Self where S: Sequence, S.Iterator.Element == P, P: Publisher, P.OutputT == InputT {
        for publisher in left {
            publisher.subscribe(right)
        }
        return right
    }
}

// Add flow syntax as an extension to `Sequence` rather than `Publisher`, since the sequence is returned and therefore the full type information, Self, is available for subsequent stages.
public extension Sequence {
    /// Subscribe multiple subscribers to a single publisher using stream flow syntax, `publisher ~~> [subscriber1, subscriber2, ...]`.
    ///
    /// - warning: This operator should not be overridden since it only has one meaningful definition, however this cannot be prevented in Swift 4 because the operator is defined on a protocol.
    @discardableResult public static func ~~> <P, S>(left: P, right: Self) -> Self where Self.Iterator.Element == S,  S: Subscriber, P: Publisher, P.OutputT == S.InputT {
        for subscriber in right {
            left.subscribe(subscriber)
        }
        return right
    }
}

/// Wrap any `Subscriber` in a standard class, useful where `Subscriber` is needed as a type (it is a protocol with associated type and therefore not a type itself but rather a generic constraint).
///
/// EG Implementations of `Subscription` typically contain a reference to the `Subscriber` they belong to and this reference is typed `AnySubscriber` because `Subscriber` cannot be used as a type because it has an associated type `InputT`.
///
/// - note:
///   - In Swift terminology `AnySubscriber` is said to type erase `Subscriber`; meaning that it doesn't matter what type of subscriber is given to `AnySubscriber`'s `init` the result will always be the same type, `AnySubscriber`.
///   - For a Java, Scala, Haskell, etc. programmer this terminology is confusing because type erasure in these languages refers to erasing the generic type, in this case `T`, not the main type, in this case `AnySubscriber`.
///   - Further confusion for the Java, Scala, Haskell, etc. programmer is that `Subscriber` would be a type and not a generic constraint anyway, therefore `AnySubscriber` would be unnecessary in these languages.
///
/// - parameters
///   - I: The type of the items consumed (input) by the subscriber.
public final class AnySubscriber<I>: Subscriber {
    public typealias InputT = I
    
    private let complete: () -> Void
    
    private let error: (Error) -> Void
    
    private let next: (I) -> Void
    
    private let subscribe: (Subscription) -> Void
    
    /// Wrap the given subscriber, which can be any type of subscriber, so that the type becomes `AnySubscriber` regardless of the originating subscriber's specific type.
    ///
    /// - parameter subscriber: The subscriber to wrap.
    public init<S>(_ subscriber: S) where S: Subscriber, S.InputT == I {
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
    
    public func on(next: I) {
        self.next(next)
    }
    
    public func on(subscribe: Subscription) {
        self.subscribe(subscribe)
    }
}

/// A `Subscription` represents a one-to-one lifecycle of a `Subscriber` subscribing to a `Publisher`.
///
/// It can only be used by a single `Subscriber` and only until `cancel` is called or `Producer` calls either `Subscriber.onComplete()` or `Subscriber.on(error: Error).
/// A `Subscription` is supplied to a `Subscriber` by a `Publisher` by calling `Subscriber.on(subscription: Subscriber)`.
///
/// It is used to both signal desire for data and cancel demand (and allow resource cleanup).
///
/// - note:
///   - A subscription is a class that implements this protocol, it is a class because the subscription *itself* (not a copy) is passed from publisher to subscriber.
///   - Subscriptions are typically not thread safe because it makes no sense to share them between threads (they are an alternative to using threads directly).
public protocol Subscription: AnyObject {
    /// Request the `Publisher` to stop sending data and clean up resources (cancel the subscription).
    ///
    /// Data may still be sent to meet previously signalled demand after calling cancel.
    ///
    /// - note: Since it is the subscriber that initiates this cancellation the subscriber is not notified, i.e. neither `Subscriber.on(error: Error)` nor `Subscriber.onComplete()` called.
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

/// A failed subscription Singleton, used as the agrument for `Subscriber.on(subscribe:)` when a subscription attempt fails.
/// The Reactive Stream specification requires that a subscription is provided by `Subscriber.on(subscribe:)` before the error is signalled by `Subscriber.on(error:)`, hence this subscription is used as the argument.
/// The `cancel` and request` methods of this subscription both do nothing.
///
/// - note:
///   A publisher does not have to provide *this* `Subscription`, it can provide any `Subscription`, when a subscribe attempts fails, however it is convenient to do so.
public final class FailedSubscription: Subscription {
    
    /// The only instance of a `FailedSubscription`.
    public static let instance = FailedSubscription()
    
    private init() {}
    
    public func cancel() {}
    
    public func request(_ _: Int) {}
}

/// Functions and properties that are useful in conjunction with Reactive Streams (inside an enum to give them their own namespace).
public enum ReactiveStreams {
    /// Suggested default buffer size for `Publisher`s and `Subscriber`s.
    ///
    /// - note: The current implementation is 256.
    public static let defaultBufferSize = 256
}
