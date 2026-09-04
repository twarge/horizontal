import CryptoKit
import Foundation

extension UUID {
    /// RFC 4122 name-based UUID (version 5): SHA-1 over the namespace's bytes
    /// followed by `name`, with the version and variant nibbles stamped in.
    /// Horizon derives deterministic ids this way (legacy unit alternate pin
    /// names, inner-layer padstack copies), so the same inputs must yield the
    /// same ids here or cross-references written by either program would miss.
    static func horizonUUID5(namespace: UUID, name: [UInt8]) -> UUID {
        var input = [UInt8]()
        input.reserveCapacity(16 + name.count)
        withUnsafeBytes(of: namespace.uuid) { input.append(contentsOf: $0) }
        input.append(contentsOf: name)

        var digest = Array(Insecure.SHA1.hash(data: input)).prefix(16).map { $0 }
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

    /// Horizon's `Pin::alternate_name_uuid_from_index`: the id of the `index`th
    /// entry of a legacy unit pin `names` array (two little-endian bytes under
    /// a fixed namespace). Lowercased, as every uuid in a pool file is.
    static func horizonAlternatePinNameID(index: Int) -> String {
        let namespace = UUID(uuidString: "3d1181ab-a2bf-4ddb-98ff-f91c3a817979")!
        let clamped = max(0, min(index, 65_535))
        return horizonUUID5(namespace: namespace, name: [UInt8(clamped & 0xFF), UInt8((clamped >> 8) & 0xFF)])
            .uuidString.lowercased()
    }
}
