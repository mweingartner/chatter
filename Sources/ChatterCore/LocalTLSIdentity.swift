import Foundation
import Security
import CryptoKit

/// A locally generated ECDSA identity. Clients explicitly pin its SHA-256 fingerprint;
/// this certificate is never installed as a system trust anchor.
public struct LocalTLSIdentity {
    public let identity: SecIdentity
    public let certificate: Data
    public var fingerprint: String { SHA256.hash(data: certificate).map { String(format: "%02x", $0) }.joined() }

    public static func load(directory: URL, now: Date = .now) throws -> LocalTLSIdentity {
        try PrivateStorage.directory(directory)
        let keyURL = directory.appending(path: "identity-key.bin")
        let certURL = directory.appending(path: "identity.der")
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                                       kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits as String: 256]
        if FileManager.default.fileExists(atPath: keyURL.path) {
            try PrivateStorage.protectFile(keyURL)
            let bytes = try ChatterPaths.readRegularFile(at: keyURL, upTo: 4096)
            guard let key = SecKeyCreateWithData(bytes as CFData, attributes as CFDictionary, nil) else {
                throw ChatterError.invalid("The LAN identity key is damaged. Replace the LAN identity in Connections.")
            }
            let certificate = try ChatterPaths.readRegularFile(at: certURL, upTo: 16384)
            return try makeIdentity(key: key, certificate: certificate)
        }
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
              let publicKey = SecKeyCopyPublicKey(key),
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, nil),
              let privateBytes = SecKeyCopyExternalRepresentation(key, nil) else {
            throw ChatterError.unavailable("Cannot create LAN TLS identity.")
        }
        let certificate = try selfSigned(key: key, publicBytes: publicBytes as Data, now: now)
        let result = try makeIdentity(key: key, certificate: certificate)
        // Store the certificate first: a missing key can safely regenerate the pair after interruption.
        try PrivateStorage.write(certificate, to: certURL)
        try PrivateStorage.write(privateBytes as Data, to: keyURL)
        return result
    }

    private static func makeIdentity(key: SecKey, certificate: Data) throws -> LocalTLSIdentity {
        guard let cert = SecCertificateCreateWithData(nil, certificate as CFData),
              let identity = SecIdentityCreate(nil, cert, key) else { throw ChatterError.invalid("Invalid LAN TLS identity.") }
        return LocalTLSIdentity(identity: identity, certificate: certificate)
    }

    // A minimal X.509 v3 certificate; all cryptographic operations are performed by Security.framework.
    private static func selfSigned(key: SecKey, publicBytes: Data, now: Date) throws -> Data {
        let signatureAlgorithm = sequence(oid([0x2a,0x86,0x48,0xce,0x3d,0x04,0x03,0x02])) // ecdsa-with-SHA256
        let name = sequence(der(0x31, sequence(oid([0x55,0x04,0x03]) + der(0x0c, Data("Chatter LAN".utf8)))))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        let validity = sequence(der(0x18, Data(formatter.string(from: now.addingTimeInterval(-300)).utf8)) +
                                der(0x18, Data(formatter.string(from: now.addingTimeInterval(365 * 86400)).utf8)))
        let algorithm = sequence(oid([0x2a,0x86,0x48,0xce,0x3d,0x02,0x01]) + oid([0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07]))
        let subjectKey = sequence(algorithm + der(0x03, Data([0]) + publicBytes))
        let constraints = sequence(oid([0x55,0x1d,0x13]) + der(0x01, Data([0xff])) + der(0x04, sequence(Data())))
        let usage = sequence(oid([0x55,0x1d,0x0f]) + der(0x01, Data([0xff])) + der(0x04, der(0x03, Data([7,0x80]))))
        let extended = sequence(oid([0x55,0x1d,0x25]) + der(0x04, sequence(oid([0x2b,0x06,0x01,0x05,0x05,0x07,0x03,0x01]))))
        let names = sequence(der(0x82, Data("localhost".utf8)) + der(0x87, Data([127,0,0,1])))
        let altNames = sequence(oid([0x55,0x1d,0x11]) + der(0x04, names))
        var serial = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial) == errSecSuccess else { throw ChatterError.unavailable("Cannot generate TLS serial.") }
        serial[0] = (serial[0] & 0x7f) | 1
        let tbs = sequence(der(0xa0, der(0x02, Data([2]))) + der(0x02, Data(serial)) + signatureAlgorithm + name + validity + name + subjectKey + der(0xa3, sequence(constraints + usage + extended + altNames)))
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, nil) else {
            throw ChatterError.unavailable("Cannot sign LAN certificate.")
        }
        return sequence(tbs + signatureAlgorithm + der(0x03, Data([0]) + (signature as Data)))
    }
    private static func oid(_ bytes: [UInt8]) -> Data { der(0x06, Data(bytes)) }
    private static func sequence(_ data: Data) -> Data { der(0x30, data) }
    private static func der(_ tag: UInt8, _ data: Data) -> Data {
        var length = data.count; var bytes: [UInt8] = []
        repeat { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 } while length > 0
        return Data([tag]) + (data.count < 128 ? Data([UInt8(data.count)]) : Data([0x80 | UInt8(bytes.count)] + bytes)) + data
    }
}
