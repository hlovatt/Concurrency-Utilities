//
//  ReactiveStreamTests.swift
//  Concurrency UtilitiesTests
//
//  Created by Howard Lovatt on 4/9/17.
//  Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.
//

import XCTest
@testable import Concurrency_Utilities


class ReactiveStreamTests: XCTestCase {
    
    // MARK: Examples
    
    func testHelloWorld() {
        let test = "Hello, world!"
        let helloWorldPublisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let helloWorldSubscriber = ReduceSubscriber(into: "") { (result: inout String, character: Character) in
            result.append(character) // Copy the string a character at a time.
        }
        var helloWorldResult = "Failed!"
        helloWorldPublisher ~~> helloWorldSubscriber ~~>? helloWorldResult
        XCTAssertEqual(test, helloWorldResult)
    }
    
    // MARK: Coverage tests
    
    func testIteratingPublisherRejecting2ndSubscription() {
        class Test: IteratingPublisher<Int> {
            var count = -1
            override func next() -> Int? {
                Thread.sleep(forTimeInterval: 0.001) // Allow time for 2nd subscription.
                count += 1
                return count < 8 ? count : nil
            }
        }
        let publisher = Test()
        let subscriber1 = ReduceSubscriber(timeout: .milliseconds(50), into: 0) { (result: inout Int, next: Int) in
            result += next
        }
        let subscriber2 = ReduceSubscriber(into: 0) { (_: inout Int, _: Int) in
            XCTFail("Should never become subscribed.")
        }
        publisher ~~> subscriber1
        publisher ~~> subscriber2 // Should fail.
        var result = 0
        subscriber1 ~~>! result
        XCTAssertEqual(28, result)
        switch subscriber2.status {
        case .threw(let error):
            switch error as! PublisherErrors {
            case .subscriptionRejected(_):
            break // Should be executed.
            default:
                XCTFail("Should be an error")
            }
        default:
            XCTFail("Should be an error")
        }
    }
    
    func testIteratingPublisherDefaultReset() {
        class Test: IteratingPublisher<Int> {
            var count = -1
            override func next() -> Int? {
                count += 1
                return count < 8 ? count : nil
            }
        }
        let publisher = Test()
        let subscriber = ReduceSubscriber(timeout: .milliseconds(50), into: 0) { (result: inout Int, next: Int) in
            result += next
        }
        var result = 0
        publisher ~~> subscriber ~~>! result
        XCTAssertEqual(28, result)
    }
    
    func testReductionDoubleSubscription() {
        let test = "Hello, world!"
        let publisher1 = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let publisher2 = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceSubscriber(bufferSize: 1, into: "") { (_: inout String, _: Character) in
            Thread.sleep(forTimeInterval: 0.01) // Allow time for 2nd subscription.
        }
        publisher1 ~~> subscriber // Should succeed.
        switch subscriber.status {
        case .running:
            break
        default:
            XCTFail("Should be running.")
        }
        publisher2 ~~> subscriber // Should fail.
        switch subscriber.status {
        case .threw(let error):
            switch error as! SubscriberErrors {
            case .tooManySubscriptions(let number):
                XCTAssertEqual(number, 2)
            }
        default:
            XCTFail("Should have thrown.")
        }
    }
    
    func testReductionRefills() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceSubscriber(bufferSize: 1, into: "") { (result: inout String, next: Character) in
            result.append(next) // Copy the string a character at a time.
        }
        var result = "Failed!"
        publisher ~~> subscriber ~~>? result
        XCTAssertEqual(test, result)
    }
    
    func testOneIterationSequenceWithRefillAndFinishAtBufferBoundary() {
        struct Test: Sequence, IteratorProtocol {
            var count = 0
            mutating func next() -> Int? {
                defer { count += 1 }
                if count < 8 { return count }
                if count == 8 { return nil }
                fatalError("Can only iterate once.")  // Error if `next` called 9th time!
            }
        }
        let publisher = ForEachPublisher(sequence: Test())
        let subscriber = ReduceSubscriber(bufferSize: 4, into: "") { (result: inout String, next: Int) in
            result.append(next.description)
        }
        var result = "Failed!"
        publisher ~~> subscriber ~~>? result
        XCTAssertEqual("01234567", result)
    }
    
    func testOneIterationSequenceWithFinishAtRefill() {
        struct Test: Sequence, IteratorProtocol {
            var count = 0
            mutating func next() -> Int? {
                defer { count += 1 }
                if count < 8 { return count }
                if count == 8 { return nil }
                fatalError("Can only iterate once.")  // Error if `next` called 9th time!
            }
        }
        let publisher = ForEachPublisher(sequence: Test())
        let subscriber = ReduceSubscriber(bufferSize: 9, into: "") { (result: inout String, next: Int) in
            result.append(next.description)
        }
        var result = "Failed!"
        publisher ~~> subscriber ~~>? result
        XCTAssertEqual("01234567", result)
    }
    
    func testReductionFails() {
        let test = "Hello, world!"
        let error = "Failed!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceSubscriber(into: "") { (_: inout String, _: Character) in
            throw SubscriberErrors.tooManySubscriptions(number: 0) // Fail by throwing (in example any old error!).
        }
        publisher ~~> subscriber
        let result = subscriber.get ?? error
        XCTAssertEqual(error, result)
    }
    
    func testReductionCancel() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceSubscriber(into: "") { (_: inout String, _: Character) in
            Thread.sleep(forTimeInterval: 0.1) // Allow time for cancel.
        }
        publisher ~~> subscriber
        subscriber.cancel()
        switch subscriber.status {
        case .threw(let error):
            switch error as! TerminateFuture {
            case .cancelled:
            break // Should be executed.
            default:
                XCTFail("Should be an error")
            }
        default:
            XCTFail("Should be an error")
        }
    }
    
    func testReductionTimesOutNs() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceSubscriber(timeout: .nanoseconds(100), into: "") { (_: inout String, _: Character) in
            Thread.sleep(forTimeInterval: 0.1) // Cause a timeout.
        }
        publisher ~~> subscriber
        let _ = subscriber.get
        switch subscriber.status {
        case .threw(let error):
            switch error as! TerminateFuture {
            case .timedOut:
            break // Should be executed.
            default:
                XCTFail("Should be an error")
            }
        default:
            XCTFail("Should be an error")
        }
    }
    
    func testReductionTimesOutUs() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceSubscriber(timeout: .microseconds(100), into: "") { (_: inout String, _: Character) in
            Thread.sleep(forTimeInterval: 0.1) // Cause a timeout.
        }
        publisher ~~> subscriber
        let _ = subscriber.get
        switch subscriber.status {
        case .threw(let error):
            switch error as! TerminateFuture {
            case .timedOut:
            break // Should be executed.
            default:
                XCTFail("Should be an error")
            }
        default:
            XCTFail("Should be an error")
        }
    }
    
    func testReductionTimesOutMs() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceSubscriber(timeout: .milliseconds(100), into: "") { (_: inout String, _: Character) in
            Thread.sleep(forTimeInterval: 0.1) // Cause a timeout.
        }
        publisher ~~> subscriber
        let _ = subscriber.get
        switch subscriber.status {
        case .threw(let error):
            switch error as! TerminateFuture {
            case .timedOut:
            break // Should be executed.
            default:
                XCTFail("Should be an error")
            }
        default:
            XCTFail("Should be an error")
        }
    }
    
    func testReductionTimesOutS() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceSubscriber(timeout: .milliseconds(50), into: "") { (_: inout String, _: Character) in
            Thread.sleep(forTimeInterval: 0.1) // Cause a timeout.
        }
        publisher ~~> subscriber
        let _ = subscriber.get
        switch subscriber.status {
        case .threw(let error):
            switch error as! TerminateFuture {
            case .timedOut:
            break // Should be executed.
            default:
                XCTFail("Should be an error")
            }
        default:
            XCTFail("Should be an error")
        }
    }
    
    // Have to test that this doesn't occur!
    func testReductionTimesOutNever() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceSubscriber(timeout: .never, into: "") { (result: inout String, next: Character) in
            result.append(next) // Copy the string a character at a time.
        }
        publisher ~~> subscriber
        XCTAssertEqual(test, subscriber.get ?? "Failed!")
    }
    
    func testReductionCancelIgnoredAfterCompletion() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceSubscriber(into: "") { (result: inout String, next: Character) in
            result.append(next) // Copy string a character at a time.
        }
        publisher ~~> subscriber
        let _ = subscriber.get // Wait for completion.
        subscriber.cancel() // Should ignore cancel after completion.
        switch subscriber.status {
        case .completed(let result):
            XCTAssertEqual(test, result)
        default:
            XCTFail("Should have completed")
        }
    }
    
    func testReductionStatus() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceSubscriber(into: "") { (_: inout String, _: Character) in
            throw SubscriberErrors.tooManySubscriptions(number: 0) // Fail by throwing (in example any old error!).
        }
        publisher ~~> subscriber
        let _ = subscriber.get
        switch subscriber.status {
        case .threw(let error):
            switch error as! SubscriberErrors {
            case .tooManySubscriptions(let number):
                XCTAssertEqual(number, 0)
            }
        default:
            XCTFail("Should be an error")
        }
    }
    
    func testSubscribeInAnySubscriber() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceSubscriber(into: "") { (result: inout String, character: Character) in
            result.append(character) // Copy the string a character at a time.
        }
        let anySubscriber = AnySubscriber(subscriber) // Wrap in an AnySubscriber (to test AnySubscriber).
        publisher ~~> anySubscriber
        let result = subscriber.get ?? "Failed!"
        XCTAssertEqual(test, result)
    }
    
    func testRequest0Items() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        class N0Subscriber: Subscriber {
            func onComplete() {
                XCTFail("Should not be called")
            }
            
            func on(error: Error) {
                XCTFail("Should not be called")
            }
            
            func on(next: Character) {
                XCTFail("Should not be called")
            }
            
            func on(subscribe: Subscription) {
                subscribe.request(0) // Check that a request of zero causes cancellation.
            }
        }
        let subscriber = N0Subscriber()
        publisher ~~> subscriber
        publisher ~~> subscriber // Can subscribe 2nd time since 1st subscription cancelled
    }
    
    func testRequestNegativeItems() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        class NNegativeSubscriber: Subscriber {
            var isError  = false
            
            func onComplete() {
                XCTFail("Should not be called")
            }
            
            func on(error: Error) {
                isError = true
            }
            
            func on(next: Character) {
                XCTFail("Should not be called")
            }
            
            func on(subscribe: Subscription) {
                subscribe.request(-1) // Check that a request of -1 causes an error.
            }
        }
        let subscriber = NNegativeSubscriber()
        publisher ~~> subscriber
        XCTAssertTrue(subscriber.isError)
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
