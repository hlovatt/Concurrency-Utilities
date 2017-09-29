//
//  ReactiveCollectionTests.swift
//  Concurrency UtilitiesTests
//
//  Created by Howard Lovatt on 4/9/17.
//  Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.
//

import XCTest
@testable import Concurrency_Utilities


class ReactiveCollectionTests: XCTestCase {
    
    // MARK: Examples
    
    func testHelloWorld() {
        let test = "Hello, world!"
        let helloWorldPublisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let helloWorldSubscriber = ReduceFutureSubscriber(into: "") { (result: inout String, nextChar: Character) in
            result.append(nextChar) // Copy the string a character at a time.
        }
        var helloWorldResult = "Failed!"
        helloWorldPublisher ~~> helloWorldSubscriber ~~>? helloWorldResult
        XCTAssertEqual(test, helloWorldResult)
    }
    
    func testEstimatePi() {
        let maxRandom = Double(UInt32.max)
        let randomCoordinatePublisher = IteratorSeededPublisher(initialSeed: ()) { _ in
            return (Double(arc4random()) / maxRandom, Double(arc4random()) / maxRandom)
        }
        let piEstimatorProcesssor = MapSeededProcessor(initialSeed: (0, 0)) { (seed: inout (Int, Int), coordinate: (Double, Double)) -> Double in
            var (total, inside) = seed
            total += 1
            let (x, y) = coordinate
            if x * x + y * y <= 1.0 {
                inside += 1
            }
            guard total < 14_000 && inside < 11_000 else {
                throw SubscriberSignal.cancelInputSubscriptionAndComplete
            }
            seed = (total, inside)
            return 4.0 * Double(inside) / Double(total)
        }
        let lastValueSubscriber = ReduceFutureSubscriber(into: 0.0) { (old: inout Double, new: Double) in
            old = new
        }
        var estimatedPi = Double.nan
        randomCoordinatePublisher ~~> piEstimatorProcesssor ~~> lastValueSubscriber ~~>? estimatedPi
        XCTAssertEqual(Double.pi, estimatedPi, accuracy: 0.1)
    }
    
    func testFlatMap() {
        let publisher = IteratorSeededPublisher(initialSeed: 0) { (seed: inout Int) -> Int? in
            seed += 1
            return seed < 5 ? seed : nil
        }
        let processor = FlatMapSeededProcessor(initialSeed: ()) { (_: inout Void, next: Int) in
            next % 2 == 0 ? next : nil
        }
        let subscriber = ReduceFutureSubscriber(into: 2) { (result: inout Int, next: Int) in
            result += next
        }
        var result = -1
        publisher ~~> processor ~~> subscriber ~~>? result
        XCTAssertEqual(8, result)
    }
    
    
    func testFilter() {
        let publisher = IteratorSeededPublisher(initialSeed: 0) { (seed: inout Int) -> Int? in
            seed += 1
            return seed < 7 ? seed : nil
        }
        let processor = FilterSeededProcessor(initialSeed: 0) { (count: inout Int, _: Int) in
            count += 1
            return count % 3 == 0
        }
        let subscriber = ReduceFutureSubscriber(into: 2) { (result: inout Int, next: Int) in
            result += next
        }
        var result = -1
        publisher ~~> processor ~~> subscriber ~~>? result
        XCTAssertEqual(11, result)
    }
    
    
    // MARK: Coverage tests
    
    func testUsefulForDebugging() {
        let publisher = IteratorSeededPublisher(initialSeed: 0) { (seed: inout Int) -> Int? in
            seed += 1
            return seed == 1 ? 1 : nil
        }
        let subscriber = ReduceFutureSubscriber(into: 2) { (result: inout Int, next: Int) in
            result += next
        }
        var result = -1
        publisher ~~> subscriber ~~>? result
        XCTAssertEqual(3, result)
    }
    
    func testKeepProducingBufferSizeItemsAfterCancel() {
        let bufferSize: UInt64 = 2
        let publisher = IteratorSeededPublisher(initialSeed: 0) { (seed: inout Int) -> Int? in
            seed += 1
            return seed < 3 * bufferSize ? seed : nil
        }
        let subscriber = ReduceFutureSubscriber(bufferSize: bufferSize, into: 3) { (result: inout Int, next: Int) in
            Thread.sleep(forTimeInterval: 0.01) // Time delay to allow for cancel to happen.
            result += next
        }
        publisher ~~> subscriber // Start production.
        subscriber.cancel() // Cancel production.
        publisher ~~> subscriber // Start production again.
        var result = -1
        subscriber ~~>? result // Wait for 2nd production to finish.
        XCTAssertGreaterThan(result, 9) // Result is > 9 because 1 from first production gets through!
    }
    
    func testRecievingOnCompleteBeforeSendingRequest() {
        class SendOnComplete: PublisherBase {
            typealias OutputT = Int
            var _outputSubscription: Subscription {
                return FailedSubscription.instance
            }
            var _outputSubscriber = Atomic<AnySubscriber<Int>?>(nil)
            func subscribe<S>(_ newOutputSubscriber: S) where S: Subscriber, S.InputT == Int {
                newOutputSubscriber.on(subscribe: _outputSubscription)
                newOutputSubscriber.onComplete()
            }
        }
        let publisher = SendOnComplete()
        class DontRequest: SubscriberBase {
            typealias InputT = Int
            var isCompleted = false
            func _consumeAndRequest(item: Int) throws {
                XCTFail("No items should be produced.")
            }
            var _inputSubscription = Atomic<Subscription?>(nil)
            func _handleInputSubscriptionOnComplete() {
                isCompleted = true
            }
        }
        let subscriber = DontRequest()
        publisher ~~> subscriber
        XCTAssertTrue(subscriber.isCompleted)
        XCTAssertNil(publisher._outputSubscriber.value, "Should not be subscribed to.")
        XCTAssertNil(subscriber._inputSubscription.value, "Should not have a subscription.")
    }
    
    func testMapSubscribersError() {
        let publisher = IteratorSeededPublisher(initialSeed: ()) { _ -> Int in
            return 0
        }
        let processor = MapSeededProcessor(initialSeed: ()) { (_: inout Void, _: Int) -> Int in
            1
        }
        let testNumber = 2
        let subscriber = ReduceFutureSubscriber(into: 3) { (result: inout Int, _: Int) in
            throw FutureSubscriberErrors.tooManySubscriptions(number: testNumber) // Any old error!
        }
        publisher ~~> processor ~~> subscriber
        Thread.sleep(forTimeInterval: 0.01) // Allow time for error to propergate.
        XCTAssertNil(publisher._outputSubscriber.value, "Should not be subscribed to.")
        XCTAssertNil(processor._inputSubscription.value, "Should not have a subscription.")
        XCTAssertNil(processor._outputSubscriber.value, "Should not be subscribed to.")
        XCTAssertNil(subscriber._inputSubscription.value, "Should not have a subscription.")
        let test = 4
        var result = test
        subscriber ~~>? result
        XCTAssertEqual(test, result)
        switch subscriber.status {
        case .threw(let error):
            switch error as! FutureSubscriberErrors {
            case .tooManySubscriptions(let number):
                XCTAssertEqual(testNumber, number)
            }
        default:
            XCTFail("Should be `.threw`.")
        }
    }
    
    func testMapSubscriptionCancel() {
        let publisher = IteratorSeededPublisher(initialSeed: ()) { _ -> Int in
            Thread.sleep(forTimeInterval: 0.01) // Give time for cancel.
            return 0
        }
        let processor = MapSeededProcessor(initialSeed: ()) { (_: inout Void, _: Int) -> Int in
            1
        }
        let subscriber = ReduceFutureSubscriber(into: 2) { (result: inout Int, _: Int) in
            result = 3
        }
        publisher ~~> processor ~~> subscriber
        subscriber.cancel()
        XCTAssertNil(publisher._outputSubscriber.value, "Should not be subscribed to.")
        XCTAssertNil(processor._inputSubscription.value, "Should not have a subscription.")
        XCTAssertNil(processor._outputSubscriber.value, "Should not be subscribed to.")
        XCTAssertNil(subscriber._inputSubscription.value, "Should not have a subscription.")
        let test = 4
        var result = test
        subscriber ~~>? result
        XCTAssertEqual(test, result)
        switch subscriber.status {
        case .threw(let error):
            switch error as! TerminateFuture {
            case .cancelled:
                break
            default:
                XCTFail("Should be `.cancelled`.")
            }
        default:
            XCTFail("Should be `.threw`.")
        }
    }
    
    func testCannotHaveAnOutputSubscriberWithoutAnInputSubscription() {
        let processor = MapSeededProcessor(initialSeed: ()) { (_: inout Void, _: Int) -> Int in
            0
        }
        let subscriber = ReduceFutureSubscriber(into: 1) { (result: inout Int, _: Int) in
            result = 2
        }
        let test = 3
        var result = test
        processor ~~> subscriber ~~>? result
        XCTAssertEqual(test, result)
        switch subscriber.status {
        case .threw(let error):
            switch error as! PublisherErrors {
            case .subscriptionRejected(let reason):
                XCTAssertEqual("Cannot have an output subscriber without an input subscription.", reason)
            default:
                XCTFail("Should be `.subscriptionRejected`.")
            }
        default:
            XCTFail("Should be `.threw`.")
        }
    }
    
    func testMapHandleInputSubscriptionOnError() {
        let publisher = IteratorSeededPublisher(initialSeed: ()) { _ -> Int in
            throw FutureSubscriberErrors.tooManySubscriptions(number: 0) // Any old error!
        }
        let processor = MapSeededProcessor(initialSeed: ()) { (_: inout Void, _: Int) -> Int in
            return 1
        }
        let subscriber = ReduceFutureSubscriber(into: 0) { (old: inout Int, new: Int) in
            old = new
        }
        var result = 0
        publisher ~~> processor ~~> subscriber ~~>? result
        XCTAssertEqual(0, result)
        switch subscriber.status {
        case .threw(let error):
            switch error as! FutureSubscriberErrors {
            case .tooManySubscriptions(let number):
                XCTAssertEqual(0, number)
            }
        default:
            XCTFail("Should have thrown.")
        }
    }
    
    func testMapMultipleInputSubscriptionsErrorsWithOutputConnectedForErrorReporting() {
        let publisher1 = ForEachPublisher(sequence: "Should fail!".characters)
        let publisher2 = ForEachPublisher(sequence: "Should fail also!".characters)
        let processor = MapSeededProcessor(initialSeed: ()) { (_: inout Void, next: Character) -> Character in
            Thread.sleep(forTimeInterval: 0.01) // Give time for 2nd input subscription to be tried.
            return next
        }
        let subscriber = ReduceFutureSubscriber(into: "") { (result: inout String, nextChar: Character) in
            result.append(nextChar) // Copy the string a character at a time.
        }
        publisher1 ~~> processor ~~> subscriber // First subscription and start processing.
        publisher2 ~~> processor // Should fail and terminate above line.
        XCTAssertNil(publisher1._outputSubscriber.value, "Should not be subscribed to.")
        XCTAssertNil(publisher2._outputSubscriber.value, "Should not be subscribed to.")
        XCTAssertNil(processor._inputSubscription.value, "Should not have a subscription.")
        XCTAssertNil(processor._outputSubscriber.value, "Should not be subscribed to.")
        XCTAssertNil(subscriber._inputSubscription.value, "Should not have a subscription.")
        let test = "Failed!"
        var result = test
        subscriber ~~>? result
        XCTAssertEqual(test, result)
    }
    
    func testMapMultipleInputSubscriptionsErrorsWithoutOutput() {
        let publisher1 = ForEachPublisher(sequence: "Should fail!".characters)
        let publisher2 = ForEachPublisher(sequence: "Should fail also!".characters)
        let processor = MapSeededProcessor(initialSeed: ()) { (_: inout Void, next: Character) -> Character in
            return next
        }
        [publisher1, publisher2] ~~> processor // First subscription OK, 2nd should fail and cancel 1st.
        XCTAssertNil(publisher1._outputSubscriber.value, "Should not be subscribed to.")
        XCTAssertNil(publisher2._outputSubscriber.value, "Should not be subscribed to.")
        XCTAssertNil(processor._inputSubscription.value, "Should not have a subscription.")
    }
    
    func testPublisherBaseNextError() {
        let publisher = IteratorSeededPublisher(initialSeed: 0) { (_: inout Int) throws -> Character in
            throw FutureSubscriberErrors.tooManySubscriptions(number: 0) // Any old error!
        }
        let subscriber = ReduceFutureSubscriber(into: "") { (result: inout String, nextChar: Character) in
            result.append(nextChar) // Copy the string a character at a time.
        }
        var result = "Failed!"
        publisher ~~> subscriber ~~>? result
        XCTAssertEqual("Failed!", result)
        switch subscriber.status {
        case .threw(let error):
            XCTAssert(error is FutureSubscriberErrors, "The error should be `FutureSubscriberErrors`.")
        default:
            XCTFail("Should be `.threw`.")
        }
    }
    
    func testSubscriberBaseConsumerError() {
        let publisher = ForEachPublisher(sequence: "Hello, world!".characters) // String to be copied character wise.
        class FailedToConsume: FutureSubscriberClassBase<Character, String> {
            override func _consume(item: Character) throws {
                throw FutureSubscriberErrors.tooManySubscriptions(number: 0) // Any old error!
            }
        }
        let subscriber = FailedToConsume()
        var result = "Failed!"
        publisher ~~> subscriber ~~>? result
        XCTAssertEqual("Failed!", result)
        switch subscriber.status {
        case .threw(let error):
            XCTAssert(error is FutureSubscriberErrors, "The error should be `FutureSubscriberErrors`.")
        default:
            XCTFail("Should be `.threw`.")
        }
    }
    
    func testFailedSubscriptionInstance() {
        class FailedSubscriptionPublisher: PublisherBase {
            static let errorMessage = "Always fails!"
            typealias OutputT = Character
            let _outputSubscriber = Atomic<AnySubscriber<Character>?>(nil)
            var _outputSubscription: Subscription {
                XCTFail("Should never be called by `PublisherBase.subscribe`.")
                return FailedSubscription.instance
            }
            var _isNewOutputSubscriberAccepted: String {
                return FailedSubscriptionPublisher.errorMessage
            }
        }
        let failedPublisher = FailedSubscriptionPublisher()
        class FailedSubscriptionSubscriber: SubscriberBase {
            typealias InputT = Character
            let _inputSubscription = Atomic<Subscription?>(nil)
            func _consumeAndRequest(item _: Character) throws {
                XCTFail("Should never be called via `Subscription.on(next:)`.")
            }
            func _handleAndRequestFrom(newInputSubscription: Subscription) {
                newInputSubscription.request(10) // Check does nothing.
                newInputSubscription.cancel() // Check does nothing.
                XCTAssert(newInputSubscription === FailedSubscription.instance, "Should have returned `FailedSubscription.instance`")
            }
            func _handleInputSubscriptionOn(error: Error) {
                guard let error = error as? PublisherErrors else {
                    XCTFail("Should have sent a `PublisherErrors`.")
                    fatalError("Should have sent a `PublisherErrors`.")
                }
                switch error {
                case .subscriptionRejected(let reason):
                    XCTAssertEqual(FailedSubscriptionPublisher.errorMessage, reason)
                default:
                    XCTFail("Should be `.subscriptionRejected`.")
                }
            }
        }
        let failedSubscriber = FailedSubscriptionSubscriber()
        failedPublisher ~~> failedSubscriber
    }
    
    func testCopyingProducerFreesResources() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let processor = MapSeededProcessor(initialSeed: ()) { (_: inout Void, next: Character) in
            next
        }
        let subscriber = ReduceFutureSubscriber(into: "") { (result: inout String, nextChar: Character) in
            result.append(nextChar) // Copy the string a character at a time.
        }
        var result = "Failed!"
        publisher ~~> processor ~~> subscriber ~~>? result
        XCTAssertEqual(test, result)
        XCTAssertNil(publisher._outputSubscriber.value, "Publisher's output subscriber should have been freed.")
        XCTAssertNil(processor._outputSubscriber.value, "Processor's output subscriber should have been freed.")
        XCTAssertNil(processor._inputSubscription.value, "Processor's input subscription should have been freed.")
        XCTAssertNil(subscriber._inputSubscription.value, "Subscriber's input subscription should have been freed.")
    }
    
    func testSubscribeCompleteSubscribeAndCompleteAgain() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceFutureSubscriber(into: "") { (result: inout String, nextChar: Character) in
            result.append(nextChar) // Copy the string a character at a time.
        }
        var result = "Failed!"
        publisher ~~> subscriber ~~>? result
        XCTAssertEqual(test, result)
        result = "Failed!"
        publisher ~~> subscriber ~~>? result // Should work again once finished 1st time.
        XCTAssertEqual(test, result)
    }
    
    func testSubscribingToMultiplePublishersRejects1stAnd2ndSubscriptions() {
        class SlowCounter: IteratorPublisherClassBase<Int> {
            var count: Int
            init(_ initialCount: Int) {
                count = initialCount
            }
            override func _next() -> Int? {
                Thread.sleep(forTimeInterval: 0.005) // Allow time for 2nd subscription to happen.
                count += 1
                return count < 8 ? count : nil
            }
        }
        let publisher = SlowCounter(-1)
        let publisher2 = SlowCounter(9)
        let subscriber = ReduceFutureSubscriber(into: 0) { (result: inout Int, next: Int) in
            result += next
        }
        let test = -10
        var result = test
        publisher ~~> subscriber
        publisher2 ~~> subscriber // Should be rejected by subscriber and 1st subscription cancelled.
        subscriber ~~>? result // Should fail.
        XCTAssertEqual(test, result)
    }
    
    func testPublishers2ndSubscriptionAndCompleting1st() {
        class SlowCounter: IteratorPublisherClassBase<Int> {
            var count: Int
            init(_ initialCount: Int) {
                count = initialCount
            }
            override func _next() -> Int? {
                Thread.sleep(forTimeInterval: 0.005) // Allow time for 2nd subscription to happen.
                count += 1
                return count < 8 ? count : nil
            }
        }
        let publisher = SlowCounter(-1)
        let subscriberPlus = ReduceFutureSubscriber(into: 0) { (result: inout Int, next: Int) in
            result += next
        }
        let subscriberMinus = ReduceFutureSubscriber(into: 0) { (result: inout Int, next: Int) in
            result -= next
        }
        let testOK = 28
        let testFail = 100
        var result = testFail
        publisher ~~> subscriberPlus // Should continue to work.
        publisher ~~> subscriberMinus // Should be rejected.
        subscriberMinus ~~>? result // Should fail.
        XCTAssertEqual(testFail, result)
        subscriberPlus ~~>? result // Should be OK.
        XCTAssertEqual(testOK, result)
    }
    
    func testIteratorPublisherRejecting2ndSubscription() {
        class Test: IteratorPublisherClassBase<Int> {
            var count = -1
            override func _next() -> Int? {
                Thread.sleep(forTimeInterval: 0.001) // Allow time for 2nd subscription.
                count += 1
                return count < 8 ? count : nil
            }
        }
        let publisher = Test()
        let subscriber1 = ReduceFutureSubscriber(timeout: .milliseconds(50), into: 0) { (result: inout Int, next: Int) in
            result += next
        }
        let subscriber2 = ReduceFutureSubscriber(into: 0) { (_: inout Int, _: Int) in
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
    
    func testIteratorPublisherDefaultReset() {
        class Test: IteratorPublisherClassBase<Int> {
            var count = -1
            override func _next() -> Int? {
                count += 1
                return count < 8 ? count : nil
            }
        }
        let publisher = Test()
        let subscriber = ReduceFutureSubscriber(timeout: .milliseconds(50), into: 0) { (result: inout Int, next: Int) in
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
        let subscriber = ReduceFutureSubscriber(bufferSize: 1, into: "") { (_: inout String, _: Character) in
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
            switch error as! FutureSubscriberErrors {
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
        let subscriber = ReduceFutureSubscriber(bufferSize: 1, into: "") { (result: inout String, next: Character) in
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
        let subscriber = ReduceFutureSubscriber(bufferSize: 4, into: "") { (result: inout String, next: Int) in
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
        let subscriber = ReduceFutureSubscriber(bufferSize: 9, into: "") { (result: inout String, next: Int) in
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
        let subscriber = ReduceFutureSubscriber(into: "") { (_: inout String, _: Character) in
            throw FutureSubscriberErrors.tooManySubscriptions(number: 0) // Fail by throwing (in example any old error!).
        }
        publisher ~~> subscriber
        let result = subscriber.get ?? error
        XCTAssertEqual(error, result)
    }
    
    func testReductionCancel() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceFutureSubscriber(into: "") { (_: inout String, _: Character) in
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
                XCTFail("Should be `.cancelled`.")
            }
        default:
            XCTFail("Should be `.threw`.")
        }
    }
    
    func testReductionTimesOutNs() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceFutureSubscriber(timeout: .nanoseconds(100), into: "") { (_: inout String, _: Character) in
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
                XCTFail("Should be `.timedOut`.")
            }
        default:
            XCTFail("Should be `.threw`.")
        }
    }
    
    func testReductionTimesOutUs() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceFutureSubscriber(timeout: .microseconds(100), into: "") { (_: inout String, _: Character) in
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
                XCTFail("Should be `.timedOut`")
            }
        default:
            XCTFail("Should be `.threw`")
        }
    }
    
    func testReductionTimesOutMs() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceFutureSubscriber(timeout: .milliseconds(100), into: "") { (_: inout String, _: Character) in
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
                XCTFail("Should be `.timedOut`")
            }
        default:
            XCTFail("Should be `.threw`")
        }
    }
    
    func testReductionTimesOutS() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceFutureSubscriber(timeout: .milliseconds(50), into: "") { (_: inout String, _: Character) in
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
                XCTFail("Should be `.timedOut`")
            }
        default:
            XCTFail("Should be `.threw`")
        }
    }
    
    // Have to test that this doesn't occur!
    func testReductionTimesOutNever() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceFutureSubscriber(timeout: .never, into: "") { (result: inout String, next: Character) in
            result.append(next) // Copy the string a character at a time.
        }
        publisher ~~> subscriber
        XCTAssertEqual(test, subscriber.get ?? "Failed!")
    }
    
    func testReductionCancelIgnoredAfterCompletion() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceFutureSubscriber(into: "") { (result: inout String, next: Character) in
            result.append(next) // Copy string a character at a time.
        }
        publisher ~~> subscriber
        let _ = subscriber.get // Wait for completion.
        subscriber.cancel() // Should ignore cancel after completion.
        switch subscriber.status {
        case .completed(let result):
            XCTAssertEqual(test, result)
        default:
            XCTFail("Should have completed.")
        }
    }
    
    func testReductionStatus() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceFutureSubscriber(into: "") { (_: inout String, _: Character) in
            throw FutureSubscriberErrors.tooManySubscriptions(number: 0) // Fail by throwing (in example any old error!).
        }
        publisher ~~> subscriber
        let _ = subscriber.get
        switch subscriber.status {
        case .threw(let error):
            switch error as! FutureSubscriberErrors {
            case .tooManySubscriptions(let number):
                XCTAssertEqual(number, 0)
            }
        default:
            XCTFail("Should be `.threw`")
        }
    }
    
    func testSubscribeInAnySubscriber() {
        let test = "Hello, world!"
        let publisher = ForEachPublisher(sequence: test.characters) // String to be copied character wise.
        let subscriber = ReduceFutureSubscriber(into: "") { (result: inout String, character: Character) in
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

