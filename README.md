#  Concurrency Utilities

## Including in your project
The easiest way is to clone this project from GitHub inside Xcode 9 and then drag the relevant swift files into your project. The files are only small so having a copy shouldn't be an issue. If you just want atomicity then you just need `Atomic.swift`, for futures `Future.swift` and `Atomic.swift`, and for reactive streams you need `ReactiveStream.swift`, `Future.swift`, and `Atomic.swift`.

## Atomic
Provides atomic access to a value; you can `get`, `set` and `update` the value. To update a value you supply a closure to `update` that accepts the old value and returns the new value; the `update` method also returns the new value from the closure. Calls to `get`, `set` and `update` can occur is any order and from any thread and are guaranteed not to overlap. Calls to `get`, `set` and `update` block until they have completed. Update can be used as a lock as well as providing atomicity, e.g.:

    let status = Atomic(“A”) // Atomic is a class and therefore can be a `let`; even thogh value updates.
    …
    // In thread 1
    status.update {
        if status == “A” { …; return “B” }
        if status == “B” { …; return “A” }
    }
    …
    // In thread 2
    status.update {
        if status == “A” { …; return “B” }
        if status == “B” { …; return “A” }
    }

The threads will block until the other has finished because they are sharing `status`.



## Copyright and License
Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.
