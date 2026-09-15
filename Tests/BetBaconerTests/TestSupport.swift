import Foundation
import Testing

func XCTAssertEqual<T: Equatable>(_ left: @autoclosure () -> T, _ right: @autoclosure () -> T) {
    #expect(left() == right())
}

func XCTAssertTrue(_ value: @autoclosure () -> Bool) {
    #expect(value())
}

func XCTAssertGreaterThan<T: Comparable>(_ left: @autoclosure () -> T, _ right: @autoclosure () -> T) {
    #expect(left() > right())
}

func XCTAssertLessThanOrEqual<T: Comparable>(_ left: @autoclosure () -> T, _ right: @autoclosure () -> T) {
    #expect(left() <= right())
}

func XCTUnwrap<T>(_ value: @autoclosure () -> T?) throws -> T {
    guard let value = value() else {
        #expect(Bool(false))
        throw TestSupportError.unwrapFailed
    }
    return value
}

func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) {
    do {
        _ = try expression()
        #expect(Bool(false))
    } catch {
        errorHandler(error)
    }
}

private enum TestSupportError: Error {
    case unwrapFailed
}
