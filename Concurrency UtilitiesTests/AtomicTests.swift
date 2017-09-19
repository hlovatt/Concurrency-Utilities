//
//  AtomicTests.swift
//  Concurrency UtilitiesTests
//
//  Created by Howard Lovatt on 4/9/17.
//  Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.
//

import XCTest
@testable import Concurrency_Utilities

class AtomicTests: XCTestCase {
    func testAtomicGetSetUpdate() {
        let test = Atomic((0, 0)) // Test that two parts of tuple always have same value.
        let error = Atomic(false)
        let group = DispatchGroup()
        for i in 1 ... 10 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                test.value = (i, i)
            }
            group.enter()
            DispatchQueue.global().async {
                test.update {
                    defer { group.leave() }
                    return ($0.0 + 1, $0.1 + 1)
                }
            }
            group.enter()
            DispatchQueue.global().async {
                error.update {
                    defer { group.leave() }
                    guard !$0 else { return true } // Don't over-write an existing error.
                    let t = test.value
                    return t.0 != t.1 // Test two parts of tuple have same value.
                }
            }
        }
        group.wait()
        XCTAssertFalse(error.value)
    }
    
    // Test that task 2 sees change made by task 1.
    // It is likely, though not guaranteed, that the two tasks are on seperate cores since they have different QOS.
    func testAtomicAsVolatile() {
        let test = Atomic(0)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: DispatchQoS.QoSClass.background).async {
            defer { group.leave() }
            test.value = 1
        }
        group.wait()
        var error = false
        group.enter()
        DispatchQueue.global(qos: DispatchQoS.QoSClass.userInteractive).async {
            defer { group.leave() }
            error = test.value != 1
        }
        group.wait()
        XCTAssertFalse(error)
    }
    
    func testAtomicAsLock() {
        let lock = Atomic<Void>(()) // Test that multiple threads lock each other out.
        var shared = 0 // Not using `Atomic` as a volatile, but OK since only local cache neeed to be up to date.
        let group = DispatchGroup()
        for i in 1 ... 10 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                lock.update {
                    shared = i
                    XCTAssertEqual(i, shared)
                    return ()
                }
            }
        }
        group.wait()
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

