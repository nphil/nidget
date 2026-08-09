import Foundation
import CryptoKit

// MARK: - Errors

/// Failures raised by `E2EKey`. Messages never include key material or payload contents.
enum E2ECryptoError: Error, LocalizedError {
    case emptyPassword
    case emptySalt
    /// The IV is not the required 12 bytes.
    case invalidNonceLength(Int)
    /// The GCM auth tag is not the required 16 bytes.
    case invalidTagLength(Int)
    /// GCM open failed — wrong password/key, or tampered/corrupted data.
    case decryptionFailed
    case encryptionFailed

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "The encryption password is empty."
        case .emptySalt:
            return "The encryption key salt is missing."
        case .invalidNonceLength(let n):
            return "Encrypted payload has an invalid IV length (\(n) bytes; expected 12)."
        case .invalidTagLength(let n):
            return "Encrypted payload has an invalid auth tag length (\(n) bytes; expected 16)."
        case .decryptionFailed:
            return "Decryption failed — wrong end-to-end password, or the data is corrupted."
        case .encryptionFailed:
            return "Encryption failed."
        }
    }
}

// MARK: - E2EKey

/// Actual's end-to-end encryption key (docs/PROTOCOL.md §7).
///
/// Key derivation — PBKDF2-HMAC-SHA512, 10,000 iterations, 32-byte (256-bit) key:
/// - password input = UTF-8 bytes of the user's password string;
/// - salt input = **UTF-8 bytes of the base64 TEXT** exactly as stored server-side
///   (`encryptSalt`, fetched via `POST /sync/user-get-key`) — NOT the base64-decoded raw bytes.
///   Actual generates `salt = randomBytes(32).toString('base64')` and feeds that string straight
///   into PBKDF2, so the stored salt is treated as an opaque string (PROTOCOL §10 trap 8).
///
/// Payload format — AES-256-GCM, no AAD:
/// - `iv`: 12 random bytes, fresh per encryption;
/// - `authTag`: 16-byte GCM tag, carried SEPARATELY from the ciphertext on the wire
///   (`EncryptedData.authTag` vs `.data` — PROTOCOL §10 trap 7);
/// - `data`: ciphertext only.
///
/// CryptoKit has no PBKDF2, so it is implemented here on top of `HMAC<SHA512>` (RFC 8018 §5.2:
/// per block, U1 = HMAC(salt ‖ INT_32_BE(i)), then XOR-fold successive HMACs).
struct E2EKey: Sendable {
    /// The server-side key id (`keyId` / `encryptKeyId`) this key was derived for — sent as
    /// `SyncRequest.keyId` and used to pick the right key for incoming payloads (PROTOCOL §7.4).
    let keyID: String

    private let key: SymmetricKey

    /// Derive the AES-256 key from the user's E2E password and the file's stored salt.
    init(password: String, saltBase64: String, keyID: String) throws {
        guard !password.isEmpty else { throw E2ECryptoError.emptyPassword }
        guard !saltBase64.isEmpty else { throw E2ECryptoError.emptySalt }
        let derived = Self.pbkdf2SHA512(password: Data(password.utf8),
                                        salt: Data(saltBase64.utf8),
                                        iterations: 10_000,
                                        keyLength: 32)
        self.key = SymmetricKey(data: derived)
        self.keyID = keyID
    }

    /// Decrypt one AES-256-GCM payload (a sync `EncryptedData`'s parts, or a whole downloaded
    /// budget file with its `X-ACTUAL-ENCRYPT-META` / `encryptMeta` iv+authTag).
    func decrypt(iv: Data, authTag: Data, data: Data) throws -> Data {
        guard iv.count == 12 else { throw E2ECryptoError.invalidNonceLength(iv.count) }
        guard authTag.count == 16 else { throw E2ECryptoError.invalidTagLength(authTag.count) }
        do {
            let nonce = try AES.GCM.Nonce(data: iv)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: data, tag: authTag)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw E2ECryptoError.decryptionFailed
        }
    }

    /// Encrypt `plaintext` with a fresh random 12-byte nonce. Returns the three wire parts,
    /// tag kept separate from ciphertext, ready for `EncryptedData`.
    func encrypt(_ plaintext: Data) throws -> (iv: Data, authTag: Data, data: Data) {
        do {
            let nonce = AES.GCM.Nonce()  // 12 random bytes
            let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
            return (iv: Data(sealed.nonce), authTag: sealed.tag, data: sealed.ciphertext)
        } catch {
            throw E2ECryptoError.encryptionFailed
        }
    }

    // MARK: PBKDF2

    /// PBKDF2 (RFC 8018) with HMAC-SHA512 as the PRF, built on CryptoKit.
    private static func pbkdf2SHA512(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        let prfKey = SymmetricKey(data: password)
        var derived = Data()
        var blockIndex: UInt32 = 1
        while derived.count < keyLength {
            // U1 = PRF(password, salt || INT_32_BE(blockIndex))
            var message = salt
            withUnsafeBytes(of: blockIndex.bigEndian) { message.append(contentsOf: $0) }
            var u = [UInt8](Data(HMAC<SHA512>.authenticationCode(for: message, using: prfKey)))
            var block = u
            // U2...Uc: iterate the PRF, XOR-folding into the block.
            for _ in 1..<max(iterations, 1) {
                u = [UInt8](Data(HMAC<SHA512>.authenticationCode(for: Data(u), using: prfKey)))
                for i in 0..<block.count {
                    block[i] ^= u[i]
                }
            }
            derived.append(contentsOf: block)
            blockIndex &+= 1
        }
        return derived.prefix(keyLength)
    }
}
