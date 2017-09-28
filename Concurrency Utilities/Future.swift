//
//  Future.swift
//  Concurrency Utilities
//
//  Created by Howard Lovatt on 5/9/17.
//  Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.
//

import Foundation

// Useful utility for UI programming.
extension Thread {
    /// Run the given closure on the main thread (thread hops to main) and *wait* for it to complete before returning its value; useful for updating and reading UI components.
    /// Checks to see if already executing on the main thread and if so does not change to main thread before executing closure, since changing to main when already on main would cause a deadlock.
    ///
    /// - note: Not unique to `Future`, hence an extension on `Thread`.
    public static func executeOnMain<T>(closure: @escaping () -> T) -> T {
        var result: T?
        if Thread.isMainThread {
            result = closure()
        } else {
            DispatchQueue.main.sync {
                result = closure() // Can't think how to test this.
            }
        }
        return result!
    }
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

/// Useful constants for use with futures (inside an enum to give them their own namespace - note cannot go in `Future` with Swift 4 because `Future` is generic).
public enum Futures {
    /// Suggested default timeout.
    ///
    /// - note: The current implementation is 1 second.
    public static let defaultTimeout = DispatchTimeInterval.seconds(1)
    
    /// Suggested maximum sleep time whilst waiting for a timeout before checking for termination.
    ///
    /// - note: The current implementation is 1/4 second.
    public static let defaultMaximumSleepTime = 0.25
    
    /// Suggested minimum sleep time whilst waiting for a timeout that it is worth actually sleeping for (the implication of which is that a timeout could be short by this amount).
    ///
    /// - note: The current implementation is 10 milli-seconds.
    public static let defaultMinimumSleepTime = 0.01
}

/// All possible states for a `Future`; a future is in exactly one of these.
///
/// - note:
///   - The `Future` transitions from running and then to either completed or threw, for non-resettable (most) futures once transitioned to completed or threw it cannot change state again.
///   - Most futures start in running but they can start in completed or threw if desired.
///
/// - parameters
///   - T: The type of the future's value.
public enum FutureStatus<T> {
    /// Currently running or waiting to run; has not completed, was not cancelled, has not timed out, and has not thrown.
    case running
    
    /// Ran to completion; was not cancelled, did not timeout, and did not throw, no longer running.
    case completed(result: T)
    
    /// Was cancelled, timed out, or calculation threw an exception; no longer running.
    case threw(error: Error)
}

/// An error that signals the future was terminated.
public enum TerminateFuture: Error {
    /// Thrown by the calculation a `Future` is running when the `Future`'s `cancel` is called.
    case cancelled
    
    /// Thrown by the calculation a `Future` is running when the `Future`'s `get` times out.
    case timedOut
}

/// Base class for futures; acts like a future that was cancelled, i.e. no result and threw `CancelFuture.cancelled`.
///
/// - note:
///   - You would normally program to `Future`, *not* one of its derived classes, i.e. arguments, return types, properties, etc. typed as `Future`.
///   - This class is useful in its own right; not just a base class, but as a future that is known to be cancelled.
///   - In the case of this, cancelled, base class:
///     - `status` is `.threw(error: CancelFuture.cancelled)`.
///     - `get` returns `nil`.
///     - `cancel` does nothing.
///
/// - parameters
///   - T: The type of the future's value.
open class Future<T> {
    /// The current state of execution of the future.
    ///
    /// - note:
    ///   - The status is updated when the future's calculation finishes; therefore there will be a lag between a cancellation or a timeout and status reflecting this.
    ///   - This status lag is due to the underlying thread system provided by the operating system that typically does not allow a running thread to be terminated.
    ///   - Because status can lag cancel and timeout; prefer get over status, for obtaining the result of a future and if detailed reasons for a failure are not required.
    ///   - Status however offers detailed information if a thread terminates by throwing (including cancellation and timeout) and is therefore very useful for debugging.
    open var status: FutureStatus<T> {
        return .threw(error: TerminateFuture.cancelled)
    }
    
    /// Wait until the value of the future is calculated and return it; if future timed out, if future was cancelled, or if calculation threw, then return nil.
    /// The intended use of this property is to chain with the nil coalescing operator, `??`, to provide a default, a retry, or an error message in the case of failure.
    ///
    /// - note:
    ///   - Timeout is only checked when `get` is called.
    ///   - If a future is cancelled or times out then get will subsequently return nil; however it might take some time before status reflects this calculation because status is only updated when the calculation stops.
    open var get: T? {
        return nil
    }
    
    /// Cancel the calculation of the future; if it has not already completed.
    ///
    /// - note:
    ///   - Cancellation should cause `TerminateFuture.cancelled` to be thrown and hence the future's status changes to `threw` ('should' because the calculation can ignore its `isCancelled` argument or throw some other error and `Future` only checks for cancellation on entry and exit to its calculation).
    ///   - Cancellation is automatically checked on entry and exit to the calculation and therefore status will update before and after execution even if the calculation ignores its argument.
    ///   - Cancellation will not be instantaneous and therefore the future's status will not update immediately; it updates when the calculation terminates (either by returning a value or via a throw).
    ///   - If a future is cancelled subsequent calls to `get` will return nil; even if the calculation is still running and hence status has not updated.
    open func cancel() {}
    
    /// Operator to get the result from an asynchronous execution in a stream like syntax; `left ~> right` is equivalent to `right = left.get`.
    ///
    /// - note:
    ///   *The Swift 4 compiler has a bug, see [SR-5853](https://bugs.swift.org/browse/SR-5838), where it infers an `&` that it shouldn't, therefore use `future ~~> result` (the correct construct is `future ~~> &result` - note `&`).*
    public static func ~~> (left: Future<T>, right: inout T?) {
        right = left.get
    }
    
    /// Operator to get and force unwrap the result from an asynchronous execution in a stream like syntax; `left ~>! right` is equivalent to `right = left.get!`.
    ///
    /// - note:
    ///   *The Swift 4 compiler has a bug, see [SR-5853](https://bugs.swift.org/browse/SR-5838), where it infers an `&` that it shouldn't, therefore use `future ~~>! result` (the correct construct is `future ~~>! &result` - note `&`).*
    public static func ~~>! (left: Future<T>, right: inout T) {
        right = left.get!
    }
    
    /// Operator to get and ignore if `nil` the result from an asynchronous execution in a stream like syntax; `left ~>!? right` is equivalent to `right = left.get?`.
    ///
    /// - note:
    ///   *The Swift 4 compiler has a bug, see [SR-5853](https://bugs.swift.org/browse/SR-5838), where it infers an `&` that it shouldn't, therefore use `future ~~>? result` (the correct construct is `future ~~>? &result` - note `&`).*
    public static func ~~>? (left: Future<T>, right: inout T) {
        if let left = left.get {
            right = left
        }
    }
}

/// A future that calculates its value on the given queue asynchronously (i.e. its init method returns before the calculation is complete) and has the given timeout to bound the wait time when `get` is called.
///
/// - parameters
///   - T: The type of the future's value.
public final class AsynchronousFuture<T>: Future<T> {
    private let _status = Atomic(FutureStatus<T>.running) // Set in background, read in foreground.
    
    public override var status: FutureStatus<T> {
        return _status.value
    }
    
    private let group = DispatchGroup()
    
    private let timeoutTime: DispatchTime
    
    private var terminateFuture = Atomic<TerminateFuture?>(nil) // Set in foreground, read in background.
    
    private init(queue: DispatchQueue = .global(), timeout: DispatchTimeInterval = Futures.defaultTimeout, calculation: @escaping (_ terminateFuture: () throws -> Void) -> FutureStatus<T>) {
        self.timeoutTime = DispatchTime.now() + timeout
        super.init() // Have to complete initialization before result can be calculated.
        queue.async { // Deliberately holds a strong reference to self, so that a future can be side effecting.
            self.group.enter()
            defer {
                self.group.leave()
            }
            if let terminateFuture = self.terminateFuture.value { // Future was cancelled before execution began.
                self._status.value = .threw(error: terminateFuture)
                return
            }
            self._status.value = calculation { // Pass `terminateFuture` to `closure` (via a closure so that it isn't copied and therefore reflects its current value).
                if let terminateFuture = self.terminateFuture.value {
                    throw terminateFuture
                }
            }
            if let terminateFuture = self.terminateFuture.value { // Future was cancelled during execution.
                self._status.value = .threw(error: terminateFuture)
            }
        }
    }
    
    /// Create a future that executes the given `calculation` closure that can throw and returns the value of the future asynchronously with the given `timeout` and on the given `queue` (the execution is queued for execution as soon as the future is created).
    ///
    /// - note:
    ///   - The timeout is only checked when `get` is called; i.e. the calculation will continue for longer than timeout, potentially indefinitely, if `get` is not called.
    ///   - If the given `calculation` respects its `terminateFuture` argument then a timeout will break a deadlock.
    ///   - Once a future has timed out, that call to `get` and subsequent calls to `get` will return `nil`.
    ///   - The time used for a timeout is processor time; i.e. it excludes time when the computer is in sleep mode.
    ///   - Also see warning below.
    ///
    /// - warning:
    ///   Be **very** careful about setting long timeouts; if a deadlock occurs it is diagnosed/broken by a timeout occurring!
    ///   If the calculating method tries its `terminateFuture` argument a timeout will break a deadlock, otherwise it will only detect a deadlock.
    ///
    /// - parameters:
    ///   - queue: The queue to execute the given closure on (the default queue is the global queue with default quality of service).
    ///   - timeout:
    ///     - Timeout starts from when the future is created, not when `get` is called.
    ///     - The default timeout is `Futures.defaultTimeout`.
    ///   - calculation: The closure to execute that accepts a closure that throws when the future is to terminate and returns the future's value.
    ///   - terminateFuture:
    ///     A function that is supplied to the calculation that throws if the future is to terminate.
    ///     (It is supplied as a function so that it can check current status each time it is called, i.e. the termination check is in real time.)
    public convenience init(queue: DispatchQueue = .global(), timeout: DispatchTimeInterval = Futures.defaultTimeout, calculation: @escaping (_ terminateFuture: () throws -> Void) throws -> T) {
        self.init(queue: queue, timeout: timeout) { terminateFuture -> FutureStatus<T> in
            var resultOrError: FutureStatus<T>
            do {
                resultOrError = .completed(result: try calculation(terminateFuture))
            } catch {
                resultOrError = .threw(error: error)
            }
            return resultOrError
        }
    }
    
    /// Create a future that executes the given `calculation` closure that returns the value of the future and an error (both optionally) asynchronously with the given `timeout` and on the given `queue` (the execution is queued for execution as soon as the future is created).
    ///
    /// The purpose of this `init` is to wrap functions that use a 'continuation handler' style in a future and therefore simplify their use.
    /// Continuation handlers are common in Cocoa.
    ///
    /// - note:
    ///   - The timeout is only checked when `get` is called; i.e. the calculation will continue for longer than timeout, potentially indefinitely, if `get` is not called.
    ///   - Once a future has timed out, that call to `get` and subsequent calls to `get` will return `nil`.
    ///   - The time used for a timeout is processor time; i.e. it excludes time when the computer is in sleep mode.
    ///   - Also see warning below.
    ///
    /// - warning:
    ///   Be **very** careful about setting long timeouts; if a deadlock occurs it is diagnosed/broken by a timeout occurring!
    ///
    /// - parameters:
    ///   - queue: The queue to execute the given closure on (the default queue is the global queue with default quality of service).
    ///   - timeout:
    ///     - Timeout starts from when the future is created, not when `get` is called.
    ///     - The default timeout is `Futures.defaultTimeout`.
    ///   - calculation: The closure to execute that returns the future's or an error (both as optionals).
    public convenience init(queue: DispatchQueue = .global(), timeout: DispatchTimeInterval = Futures.defaultTimeout, calculation: @escaping () -> (T?, Error?)) {
        self.init(queue: queue, timeout: timeout) { _ -> FutureStatus<T> in
            var resultOrError: FutureStatus<T>
            let (result, error) = calculation()
            if error == nil {
                resultOrError = .completed(result: result!)
            } else {
                resultOrError = .threw(error: error!)
            }
            return resultOrError
        }
    }
    
    public override var get: T? {
        guard terminateFuture.value == nil else { // Catch waiting for a cancel/timeout to actually happen.
            return nil
        }
        while true { // Loop until not running, so that after a successful wait the result can be obtained.
            switch _status.value {
            case .running:
                switch group.wait(timeout: timeoutTime) { // Wait for calculation completion.
                case .success:
                    break // Loop round and test status again to extract result
                case .timedOut:
                    terminateFuture.value = .timedOut
                    return nil
                }
            case .completed(let result):
                return result
            case .threw(_):
                return nil
            }
        }
    }
    
    public override func cancel() {
        switch _status.value {
        case .running:
            terminateFuture.value = .cancelled
        default:
            return // Cannot cancel a future that has timed out, been cancelled, or thrown.
        }
    }
}

/// A future that doesn't need calculating, because the result is already known.
///
/// - parameters
///   - T: The type of the future's value.
public final class KnownFuture<T>: Future<T> {
    private let result: T
    
    public override var status: FutureStatus<T> {
        return .completed(result: result)
    }
    
    public init(_ result: T) {
        self.result = result
    }
    
    public override var get: T? {
        return result
    }
}

/// A future that doesn't need calculating, because it is known to fail.
///
/// - parameters
///   - T: The type of the future's value.
public final class FailedFuture<T>: Future<T> {
    private let _status: FutureStatus<T>
    
    public override var status: FutureStatus<T> {
        return _status
    }
    
    public init(_ error: Error) {
        _status = .threw(error: error)
    }
}
