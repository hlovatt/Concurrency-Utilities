//
//  Atomic.swift
//  Concurrency Utilities
//
//  Created by Howard Lovatt on 4/9/17.
//  Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.
//

import Foundation

/// Gives atomic get/set/update to its value.
public final class Atomic<T> {
    private var queue: DispatchQueue!
    
    private var _value: T
    
    /// Create and initialize a new atomic.
    /// - parameter initialValue: The initial value of the variable.
    init(_ initialValue: T) {
        _value = initialValue
        queue = DispatchQueue(label: "Atomic Serial Queue \(ObjectIdentifier(self))", qos: DispatchQoS.userInitiated)
    }
    
    /// Atomically get and set the value.
    /// - note: See `update` for getting and then setting the value atomically.
    var value: T {
        get {
            var value: T?
            queue.sync {
                value = self._value
            }
            return value!
        }
        set {
            queue.sync {
                self._value = newValue
            }
        }
    }
    
    /// Atomically update the value (get then set value in one operation guaranteeing no `get`s, `set`s, or `update`s from other threads in between).
    /// - parameters:
    ///   - updater: A closure that accepts the current value and returns the new value.
    ///   - oldValue: The old value supplied to given updater.
    /// - returns: The updated value (which can be ignored).
    @discardableResult func update(updater: (_ oldValue: T) -> T) -> T {
        var result: T? = nil
        queue.sync {
            result = updater(self._value)
            self._value = result!
        }
        return result!
    }
}

