//
//  Concurrency_UtilitiesTests.swift
//  Concurrency UtilitiesTests
//
//  Created by Howard Lovatt on 4/9/17.
//  Copyright © 2017 Howard Lovatt. Creative Commons Attribution 4.0 International License.
//

import XCTest
@testable import Concurrency_Utilities

class Concurrency_UtilitiesTests: XCTestCase {
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
