import Foundation

extension UserDefaults {
    /// Reads a String-backed RawRepresentable, falling back to `defaultValue`
    /// when the key is missing or holds an unknown raw value.
    func rawRepresentable<T: RawRepresentable>(forKey key: String, default defaultValue: T) -> T
    where T.RawValue == String {
        guard let raw = string(forKey: key), let value = T(rawValue: raw) else { return defaultValue }
        return value
    }
}
