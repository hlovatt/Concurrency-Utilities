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
    func testGetSetUpdate() {
        var test = Atomic((0, 0))
        var error = Atomic(false)
        for i in 0 ..< 10 {
            DispatchQueue.global().async {
                test.value = (i, i)
            }
            DispatchQueue.global().async {
                test.update {
                    ($0.0 + 1, $0.1 + 1)
                }
            }
            DispatchQueue.global().async {
                error.update {
                    guard !$0 else {
                        return true
                    }
                    let t = test.value
                    return t.0 != t.1
                }
            }
        }
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
