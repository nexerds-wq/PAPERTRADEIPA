import Foundation

// Three-value overload used by the professional risk sizing code.
func min(_ a: Double, _ b: Double, _ c: Double) -> Double {
    Swift.min(a, Swift.min(b, c))
}
