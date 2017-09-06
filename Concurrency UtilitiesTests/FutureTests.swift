//
//  FutureTests.swift
//  Concurrency UtilitiesTests
//
//  Created by Howard Lovatt on 4/9/17.
//  Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.
//

import XCTest
@testable import Concurrency_Utilities

class FutureTests: XCTestCase {
    
    // MARK: Thread tests
    
    // Can't test queue hopping in test environment, need a Cocoa application!
    // Execution is already on main thread and hence queue and therefore `executeOnMain` does nothing!
    func testThreadExecuteOnMainAlreadyOnMain() {
        XCTAssertTrue(Thread.executeOnMain {
            true
        })
    }
    
    // MARK: Future tests

    private func sleepUpTo100ms() -> Future<Void> {
        return AsynchronousFuture(timeout: .milliseconds(100)) {
            while true {
                try $0() // Check for cancellation or timeout.
                Thread.sleep(forTimeInterval: 0.01) // Don't hog processor.
            }
        }
    }
    
    func testAsynchronuousFutureGet() {
        let completed = AsynchronousFuture { _ in
            true // completes straight away.
        }
        XCTAssertTrue(completed.get!)
    }
    
    func testAsynchronuousFutureThrew() {
        let threw = AsynchronousFuture { _ in
            throw TerminateFuture.cancelled // Throws straight away.
        }
        XCTAssertNil(threw.get)
    }
    
    func testAsynchronuousFutureCancelThenGet() {
        let cancelled = sleepUpTo100ms()
        cancelled.cancel()
        XCTAssertNil(cancelled.get)
    }
    
    func testAsynchronuousFutureTimeout() {
        let s100ms = sleepUpTo100ms()
        s100ms.get // Wait for timeout
        Thread.sleep(forTimeInterval: 0.05) // Wait for status to update.
        switch s100ms.status {
        case .threw(let error):
            guard let e = error as? TerminateFuture else {
                XCTFail("Should have timed out!")
                return
            }
            switch e {
            case .timedOut:
                return // Expected result.
            default:
                XCTFail("Should have timed out!")
            }
        default:
            XCTFail("Should have timed out!")
        }
    }
    
    func testAsynchronuousFutureCancel() {
        let s100ms = sleepUpTo100ms()
        s100ms.cancel() // Cancel the future.
        Thread.sleep(forTimeInterval: 0.05) // Wait for status to update.
        switch s100ms.status {
        case .threw(let error):
            guard let e = error as? TerminateFuture else {
                XCTFail("Should have cancelled!")
                return
            }
            switch e {
            case .cancelled:
                return // Expected result.
            default:
                XCTFail("Should have cancelled!")
            }
        default:
            XCTFail("Should have cancelled!")
        }
    }
    
    func testAsynchronuousFutureCancelThenCancelAgain() {
        let cancelled = sleepUpTo100ms()
        cancelled.cancel()
        Thread.sleep(forTimeInterval: 0.05) // Allow time for status to update.
        cancelled.cancel() // Tests a 2nd path in cancel logic.
        XCTAssertNil(cancelled.get)
    }
    
   func testAsynchronuousFutureCancelDetectedAfterExecutionFinished() {
        let s100ms = sleepUpTo100ms()
        Thread.sleep(forTimeInterval: 0.01)
        s100ms.cancel() // Cancel the future, whilst it is running.
        Thread.sleep(forTimeInterval: 0.1) // Wait for status to update.
        switch s100ms.status {
        case .threw(let error):
            guard let e = error as? TerminateFuture else {
                XCTFail("Should have cancelled!")
                return
            }
            switch e {
            case .cancelled:
                return // Expected result.
            default:
                XCTFail("Should have cancelled!")
            }
        default:
            XCTFail("Should have cancelled!")
        }
    }
    
    func testAsynchronuousFutureWrappingCompletionHandlerCompleted() {
        let completed = AsynchronousFuture { () -> (_: Void?, _: Error?) in
            ((), nil) // Completes straight away.
        }
        completed.get // Wait for completion.
        Thread.sleep(forTimeInterval: 0.01) // Wait for status to update.
        switch completed.status {
        case .completed(_):
        return // Expected result.
        default:
            XCTFail("Should have completed!")
        }
    }
    
    func testAsynchronuousFutureWrappingCompletionHandlerCancel() {
        let cancels = AsynchronousFuture { () -> (_: Void?, _: Error?) in
            (nil, TerminateFuture.cancelled) // Cancels straight away.
        }
        Thread.sleep(forTimeInterval: 0.01) // Wait for status to update.
        switch cancels.status {
        case .threw(let error):
            guard let e = error as? TerminateFuture else {
                XCTFail("Should have cancelled!")
                return
            }
            switch e {
            case .cancelled:
            return // Expected result.
            default:
                XCTFail("Should have cancelled!")
            }
        default:
            XCTFail("Should have cancelled!")
        }
    }
    
    func testFutureGet() {
        XCTAssertNil(Future<Void>().get)
    }
    
    func testFutureCancelAndStatus() {
        let f = Future<Void>()
        f.cancel()
        switch f.status {
        case .threw(let error):
            guard let e = error as? TerminateFuture else {
                XCTFail("Should have cancelled!")
                return
            }
            switch e {
            case .cancelled:
            return // Expected result.
            default:
                XCTFail("Should have cancelled!")
            }
        default:
            XCTFail("Should have cancelled!")
        }
    }
    
    func testThrownFutureGet() {
        XCTAssertNil(FailedFuture<Void>(TerminateFuture.cancelled).get)
    }
    
    func testThrownFutureCancelAndStatus() {
        let f = FailedFuture<Void>(TerminateFuture.cancelled)
        f.cancel()
        switch f.status {
        case .threw(let error):
            guard let e = error as? TerminateFuture else {
                XCTFail("Should have cancelled!")
                return
            }
            switch e {
            case .cancelled:
            return // Expected result.
            default:
                XCTFail("Should have cancelled!")
            }
        default:
            XCTFail("Should have cancelled!")
        }
    }
    
    func testKnownFutureGet() {
        XCTAssertTrue(KnownFuture(true).get!)
    }
    
    func testKnownFutureCancelAndStatus() {
        let f = KnownFuture(true)
        f.cancel()
        switch f.status {
        case .completed(let result):
            XCTAssertTrue(result)
        default:
            XCTFail("Should have completed!")
        }
    }
    
    // MARK: Templates (in case needed in future).
    
//    override func setUp() {
//        super.setUp()
//        // Put setup code here. This method is called before the invocation of each test method in the class.
//    }
//    
//    override func tearDown() {
//        // Put teardown code here. This method is called after the invocation of each test method in the class.
//        super.tearDown()
//    }
//    
//    func testPerformanceExample() {
//        // This is an example of a performance test case.
//        self.measure {
//            // Put the code you want to measure the time of here.
//        }
//    }
}
