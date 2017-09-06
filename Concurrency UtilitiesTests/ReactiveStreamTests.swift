//
//  ReactiveStreamTests.swift
//  Concurrency UtilitiesTests
//
//  Created by Howard Lovatt on 4/9/17.
//  Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.
//

import XCTest
@testable import Concurrency_Utilities

/// Precedence group for stream operators.
precedencegroup StreamPrecedence {
    higherThan: AssignmentPrecedence
    associativity: left
}

/// Operator for stream like flow.
infix operator ~> : StreamPrecedence

class ReactiveStreamTests: XCTestCase {
    func testHelloWorld() {
        let test = "Hello, world!"
        let helloWorldPublisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let helloWorldSubscriber = ReduceSubscriber(into: "") { (result: inout String, character: Character) in
            result.append(character) // Copy the string a character at a time.
        }
        helloWorldPublisher ~> helloWorldSubscriber
        let helloWorldResult = helloWorldSubscriber.get ?? "Failed!"
        XCTAssertEqual(test, helloWorldResult)
    }
    
    func testReductionRefils() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceSubscriber(bufferSize: 1, into: "") { (result: inout String, next: Character) in
            result.append(next) // Copy the string a character at a time.
        }
        publisher ~> subscriber
        let result = subscriber.get ?? "Failed!"
        XCTAssertEqual(test, result)
    }
    
    func testReductionFails() {
        let test = "Hello, world!"
        let error = "Failed!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceSubscriber(into: "") { (_: inout String, _: Character) in
            throw SubscriberErrors.tooManySubscriptions(number: 0) // Fail by throwing (in example any old error!).
        }
        publisher ~> subscriber
        let result = subscriber.get ?? error
        XCTAssertEqual(error, result)
    }
    
    func testReductionCancel() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceSubscriber(into: "") { (_: inout String, _: Character) in
            Thread.sleep(forTimeInterval: 0.1) // Allow time for cancel.
        }
        publisher ~> subscriber
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
        publisher ~> subscriber
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
        publisher ~> subscriber
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
        publisher ~> subscriber
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
        let subscriber = ReduceSubscriber(timeout: .seconds(1), into: "") { (_: inout String, _: Character) in
            Thread.sleep(forTimeInterval: 0.1) // Cause a timeout.
        }
        publisher ~> subscriber
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
    
    // Have to test that this doesn't occure!
    func testReductionTimesOutNever() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceSubscriber(timeout: .never, into: "") { (result: inout String, next: Character) in
            result.append(next) // Copy the string a character at a time.
        }
        publisher ~> subscriber
        XCTAssertEqual(test, subscriber.get ?? "Failed!")
    }
    
    func testReductionRejectsMultipleSubscriptions() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceSubscriber(timeout: .milliseconds(100), into: "") { (_: inout String, _: Character) in
            Thread.sleep(forTimeInterval: 0.1) // Allow time for multiple subscriptions.
        }
        publisher ~> subscriber
        publisher ~> subscriber // Subscribe a 2nd time - which should cause an error.
        publisher ~> subscriber // Subscribe a 3rd time - which should do nothing.
        switch subscriber.status {
        case .threw(let error):
            switch error as! SubscriberErrors {
            case .tooManySubscriptions(let number):
                XCTAssertEqual(number, 2)
            default:
                XCTFail("Should be an error")
            }
        default:
            XCTFail("Should be an error")
        }
    }
    
    func testReductionCancelIgnoredAfterCompletion() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceSubscriber(into: "") { (result: inout String, next: Character) in
            result.append(next) // Copy string a character at a time.
        }
        publisher ~> subscriber
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
        publisher ~> subscriber
        let _ = subscriber.get
        switch subscriber.status {
        case .threw(let error):
            switch error as! SubscriberErrors {
            case .tooManySubscriptions(let number):
                XCTAssertEqual(number, 0)
            default:
                XCTFail("Should be an error")
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
        publisher ~> anySubscriber
        let result = subscriber.get ?? "Failed!"
        XCTAssertEqual(test, result)
    }
    
    func testRequest0Items() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        class N0Subscriber: Subscriber {
            typealias SubscriberItem = Character
            
            var isComplete  = false
            
            func onComplete() {
                isComplete = true
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
        publisher ~> subscriber
        XCTAssertTrue(subscriber.isComplete)
    }
    
    func testRequestNegativeItems() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        class NNegativeSubscriber: Subscriber {
            typealias SubscriberItem = Character
            
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
        publisher ~> subscriber
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
