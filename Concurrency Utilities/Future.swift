//
//  Future.swift
//  Concurrency Utilities
//
//  Created by Howard Lovatt on 5/9/17.
//  Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.
//

import Foundation

// Useful utility for UI porogramming.
extension Thread {
    /// Run the given closure on the main thread (thread hops to main) and *wait* for it to complete before returning its value; useful for updating and reading UI components.
    /// Checks to see if already executing on the main thread and if so does not change to main thread before executing closure, since changing to main when already on main would cause a deadlock.
    /// - note: Not unique to `Future`, hence an extension on `Thread`.
    public static func executeOnMain<T>(closure: @escaping () -> T) -> T {
        var result: T?
        if Thread.isMainThread {
            result = closure()
        } else {
            DispatchQueue.main.sync {
                result = closure()
            }
        }
        return result!
    }
}

/// All possible states for a `Future`; a future is in exactly one of these.
/// - note:
///   - The `Future` transitions from running and then to either completed or threw, once transitioned to completed or threw it cannot change state again.
///   - Most futures start in running but they can start in completed ot threw if desired.
public enum FutureStatus<T> {
    /// Currently running or waiting to run; has not completed, was not cancelled, has not timed out, and has not thrown.
    case running
    
    /// Ran to completion; was not cancelled, did not timeout, and did not throw, no longer running.
    case completed(result: T)
    
    /// Was cancelled, timed out, or calculation threw an exception; no longer running.
    case threw(error: Error)
}

/// Operator for stream like flow.
/// - note: Double tilde used because `~>` already defined in the standard library, but without associativity and therefore can't be chained.
infix operator ~~> : MultiplicationPrecedence

/// Operator for stream like flow that force unwraps an optional.
infix operator ~~>! : MultiplicationPrecedence

/// Operator for streeam like flow that ignores a `nil` optional.
infix operator ~~>? : MultiplicationPrecedence

/// An error that signals the future was terminated.
public enum TerminateFuture: Error {
    /// Thrown by the calculation a `Future` is running when the `Future`'s `cancel` is called.
    case cancelled
    
    /// Thrown by the calculation a `Future` is running when the `Future`'s `get` times out.
    case timedOut
}

/// Base class for futures; acts like a future that was cancelled, i.e. no result and threw `CancelFuture.cancelled`.
/// - note:
///   - You would normally program to `Future`, not one of its derived classes, i.e. arguments, return types, properties, etc. typed as `Future`.
///   - This class is useful in its own right; not just a base class, but as a future that is known to be cancelled.
open class Future<T> {
    /// The current state of execution of the future.
    /// - note:
    ///   - The status is updated when the future's calculation finishes; therefore there will be a lag between a cancellation or a timeout and status reflecting this.
    ///   - This status lag is due to the underlying thread system provided by the operating system that typically does not allow a running thread to be terminated.
    ///   - Because status can lag cancel and timeout; prefer get over status, for obtaining the result of a future and if detailed reasons for a failure are not required.
    ///   - Status however offers detailed information if a thread terminates by throwing (including cancellation and timeout) and is therefore very useful for debugging.
    /// - note: In the case of this base class, always cancelled; returns `.threw(error: CancelFuture.cancelled)`.
    var status: FutureStatus<T> {
        return .threw(error: TerminateFuture.cancelled)
    }
    
    /// Wait until the value of the future is calculated and return it; if future timed out, if future was cancelled, or if calculation threw, then return nil.
    /// The intended use of this property is to chain with the nil coalescing operator, `??`, to provide a default, a retry, or an error message in the case of failure.
    /// - note:
    ///   - Timeout is only checked when `get` is called.
    ///   - If a future is cancelled or times out then get will subsequently return nil; however it might take some time before status reflects this calculation because status is only updated when the calculation stops.
    /// - note: In the case of this base class, always return nil.
    var get: T? {
        return nil
    }
    
    /// Cancel the calculation of the future; if it has not already completed.
    /// - note:
    ///   - Cancellation should cause `TerminateFuture.cancelled` to be thrown and hence the future's status changes to `threw` ('should' because the calculation can ignore its `isCancelled` argument or throw some other error and `Future` only checks for cancellation on entry and exit to its calculation).
    ///   - Cancellation is automatically checked on entry and exit to the calculation and therefore status will update before and after execution even if the calculation ignores its argument.
    ///   - Cancellation will not be instantaneous and therefore the future's status will not update immediately; it updates when the calculation terminates (either by returning a value or via a throw).
    ///   - If a future is cancelled subsequent calls to `get` will return nil; even if the calculation is still running and hence status has not updated.
    /// - note: In the case of this base class, cancel does nothing since this future is always cancelled.
    func cancel() {}
    
    /// Operator to get the result from an asynchronuous execution in a stream like syntax; `left ~> right` is equivalent to `right = left.get`.
    /// - note: Currently not working in Swift 4 because of type inference problems.
    static func ~~> (left: Future<T>, right: inout T?) {
        right = left.get
    }
    
    /// Operator to get and force unwrap the result from an asynchronuous execution in a stream like syntax; `left ~>! right` is equivalent to `right = left.get!`.
    /// - note: Currently not working in Swift 4 because of type inference problems.
    static func ~~>! (left: Future<T>, right: inout T) {
        right = left.get!
    }
    
    /// Operator to get and ignore if `nil` the result from an asynchronuous execution in a stream like syntax; `left ~>!? right` is equivalent to `right = left.get?`.
    /// - note: Currently not working in Swift 4 because of type inference problems.
    static func ~~>? (left: Future<T>, right: inout T) {
        if let left = left.get {
            right = left
        }
    }
}

/// A future that calculates its value on the given queue asynchronously (i.e. its init method returns before the calculation is complete) and has the given timeout to bound the wait time when `get` is called.
public final class AsynchronousFuture<T>: Future<T> {
    private let _status = Atomic(FutureStatus<T>.running) // Set in background, read in foreground.
    
    override var status: FutureStatus<T> {
        return _status.value
    }
    
    private let group = DispatchGroup()
    
    private let timeoutTime: DispatchTime
    
    private var terminateFuture = Atomic<TerminateFuture?>(nil) // Set in forground, read in background.
    
    /// - note: The default queue is the global queue with default quality of service.
    /// - note:
    ///   Regarding the `timeout` argument:
    ///   - Timeout starts from when the future is created, not when `get` is called.
    ///   - The time used for a timeout is processor time; i.e. it excludes time when the computer is in sleep mode.
    ///   - The default timeout is 1 second.
    ///   - The timeout is only checked when `get` is called; i.e. the calculation will continue for longer than timeout, potentially indefinitely, if `get` is not called.
    ///   - If the future's calculation respects its `terminateFuture` argument then a timeout will break a deadlock.
    ///   - Once a future has timed out that call and subsequent calls to get will return nil.
    ///   - Also see warning below.
    /// - warning:
    ///   Be **very** careful about setting long timeouts; if a deadlock occurs it is diagnosed/broken by a timeout occurring!
    ///   If the calculating method tries its `throwIfTerminated` argument a timeout will break a deadlock, otherwise it will only detect a deadlock.
    init(queue: DispatchQueue = .global(), timeout: DispatchTimeInterval = .seconds(1), calculation: @escaping (_ terminateFuture: () throws -> Void) -> FutureStatus<T>) {
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
            self._status.value = calculation { // Pass `terminateFuture` to `calculation` (via a closure so that it isn't copied and therefore reflects its current value).
                if let terminateFuture = self.terminateFuture.value {
                    throw terminateFuture
                }
            }
            if let terminateFuture = self.terminateFuture.value { // Future was cancelled during execution.
                self._status.value = .threw(error: terminateFuture)
            }
        }
    }
    
    /// See above `init` for description.
    /// This `init` accepts a closure that returns a `T`; the above `init`'s closure returns a `FutureStatus<T>`.
    /// This `init`'s closure is wrapped to return a `FutureStatus<T>` and this `init` calls the above `init`.
    convenience init(queue: DispatchQueue = .global(), timeout: DispatchTimeInterval = .seconds(1), calculation: @escaping (_ terminateFuture: () throws -> Void) throws -> T) {
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
    
    /// See `init` 2 above for description.
    /// This `init` accepts a closure that accepts no arguments, unlike the closures for the other `init`s that accept `terminateFuture`, and returns a `(T?, Error?)`; the `init`' 2 above's closure returns a `FutureStatus<T>`.
    /// This `init`'s closure is wrapped to return a `FutureStatus<T>` and this `init` calls the `init` 2 above.
    convenience init(queue: DispatchQueue = .global(), timeout: DispatchTimeInterval = .seconds(1), calculation: @escaping () -> (T?, Error?)) {
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
    
    override var get: T? {
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
    
    override func cancel() {
        switch _status.value {
        case .running:
            terminateFuture.value = .cancelled
        default:
            return // Cannot cancel a future that has timed out, been cancelled, or thrown.
        }
    }
}

/// A future that doesn't need calculating, because the result is already known.
public final class KnownFuture<T>: Future<T> {
    private let result: T
    
    override var status: FutureStatus<T> {
        return .completed(result: result)
    }
    
    init(_ result: T) {
        self.result = result
    }
    
    override var get: T? {
        return result
    }
}

/// A future that doesn't need calculating, because it is known to fail.
public final class FailedFuture<T>: Future<T> {
    private let _status: FutureStatus<T>
    
    override var status: FutureStatus<T> {
        return _status
    }
    
    init(_ error: Error) {
        _status = .threw(error: error)
    }
}
