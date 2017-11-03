//
//  Atomic.swift
//  Concurrency Utilities
//
//  Created by Howard Lovatt on 4/9/17.
//  Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.
//

import Foundation

/// Gives a unique number.
///
/// - note:
///   - An `enum` is used as a namespace since that is the nearest available in Swift.
///   - Useful for inique identifiers.
///   - Is thread safe.
public enum UniqueNumber {
    private static var queue = DispatchQueue(label: "UniqueNumber Serial Queue", qos: DispatchQoS.userInitiated)
    
    private static var uniqueNumber: UInt = 0
    
    /// The next unique number.
    public static var next: UInt {
        var result: UInt = 0
        queue.sync {
            uniqueNumber += 1
            result = uniqueNumber
        }
        return result
    }
}

/// Gives atomic get/set/update/mutate to its value.
///
/// - parameters
///   - T: The type of the value.
public final class Atomic<T> {
    private var queue: DispatchQueue
    
    private var _value: T
    
    /// Create and initialize a new atomic.
    ///
    /// - parameters:
    ///   - initialValue: The initial value of the variable.
    public init(_ initialValue: T) {
        _value = initialValue
        queue = DispatchQueue(label: "Atomic Serial Queue \(UniqueNumber.next)", qos: DispatchQoS.userInitiated)
    }
    
    /// Atomically get and set the value.
    ///
    /// - note: See `update` for getting and then setting the value atomically.
    public var value: T {
        get {
            var result: T? = nil
            queue.sync {
                result = self._value
            }
            return result!
        }
        set {
            queue.sync {
                self._value = newValue
            }
        }
    }
    
    /// Atomically update (recieve current value and supply new value) the value (get then set value in one operation guaranteeing no `get`s, `set`s, `update`s, or `mutate`s from other threads inbetween).
    /// Also see `mutate` which is potentially faster, particularly for arrays and alike, but you can make the mistake of forgetting to actually update the value when using `mutate` and it doesn't return the new value.
    ///
    /// - parameters:
    ///   - updater: A closure that accepts the current value and returns the new value.
    ///   - oldValue: The old value supplied to given updater.
    ///
    /// - returns: The updated value (which can be ignored).
    @discardableResult public func update(updater: (_ oldValue: T) -> T) -> T {
        var result: T? = nil
        queue.sync {
            result = updater(self._value)
            self._value = result!
        }
        return result!
    }
    
    /// Atomically mutate (in place) the value (get then set value in one operation guaranteeing no `get`s, `set`s, `update`s, or `mutate`s from other threads inbetween).
    /// Also see `update` which is easier to use because you can't forget to actually do the update and it returns the new value; but is potentially slower, particularly for arrays and alike.
    ///
    /// - parameters:
    ///   - mutater: A closure that accepts the value as an inout parameter.
    ///   - value: The value to be mutated (inout parameter).
    public func mutate(mutater: (_ value: inout T) -> Void) {
        queue.sync {
            mutater(&self._value)
        }
    }
}
