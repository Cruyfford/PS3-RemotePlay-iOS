import Foundation

/// PREMO pad codes (see Core/premo.h): high byte = offset in the pad state, low byte = bit mask.
enum Pad {
    static let select: Int32 = 0x0501
    static let l3: Int32 = 0x0502
    static let r3: Int32 = 0x0504
    static let start: Int32 = 0x0508
    static let up: Int32 = 0x0510
    static let right: Int32 = 0x0520
    static let down: Int32 = 0x0540
    static let left: Int32 = 0x0580
    static let r2: Int32 = 0x0701
    static let l2: Int32 = 0x0702
    static let l1: Int32 = 0x0704
    static let r1: Int32 = 0x0708
    static let triangle: Int32 = 0x0710
    static let circle: Int32 = 0x0720
    static let cross: Int32 = 0x0740
    static let square: Int32 = 0x0780

    static let axisRX: Int32 = 0x08
    static let axisRY: Int32 = 0x0a
    static let axisLX: Int32 = 0x0c
    static let axisLY: Int32 = 0x0e

    static let stateStreaming: Int32 = 2
    static let stateEnded: Int32 = 3
    static let stateFailed: Int32 = 4
}
