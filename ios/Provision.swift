// Provision.swift — make the iPhone itself the owner of the glasses, with no
// Android and no PC in the loop.
//
// Two halves, both straight ports of what Visor does on Android (and of
// pi/meta_identity.py here, which is the same code in Python):
//
//   1. Meta identity: OIDC authorize (in-app browser) -> code -> AR token,
//      then FRLA session cookies. The AR token is what authorises pair_request.
//   2. svc36 change-of-owner: identity() gives cert+serial, skip_challenge() gives
//      the 16-byte device nonce, Meta's /pair_request signs our public key, the
//      glasses counter-sign, Meta's /pair mints the final receipt, the glasses
//      accept it and we store the key bundle locally.
//
// After one successful run the glasses trust THIS device's key: the app no longer
// needs Meta, no longer needs a laptop, and no longer needs the Android phone.

import Foundation
import UIKit

// MARK: - gzip (Meta's pair endpoints want a gzipped body)

enum Gzip {
    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0 ..< 256 {
            var c = UInt32(i)
            for _ in 0 ..< 8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    /// Foundation gives us raw DEFLATE (`.zlib` is actually raw here on Apple
    /// platforms); wrap it in the 10-byte gzip header and the 8-byte trailer.
    static func encode(_ data: Data) -> Data? {
        guard let deflated = try? (data as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out.append(deflated)
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }
}

// MARK: - Meta endpoints (values pulled from Visor's core/identity sources)

enum Meta {
    static let appID = "934401142814369"
    static let redirectURI = "https://accounts.meta.com/native/oidc/redirect/metaai"
    static let authorizeURL = "https://accounts.meta.com/oidc/"
    static let exchangeURL = "https://api.accounts.meta.com/native/oidc/token-exchange/"
    static let arHost = "https://ar.graph.meta.com"
    static let hwGraph = "https://graph.facebook-hardware.com"
    static let pairProtocolVersion = "4"

    /// Client tokens shipped inside the official Meta AI app. Override with your own
    /// if Meta rotates them.
    static var arAppToken: String { UserDefaults.standard.string(forKey: "arToken") ?? "AR|306760944872162" }
    static var hwAppToken: String { UserDefaults.standard.string(forKey: "hwToken") ?? "HW|1312539125771114" }

    static let userAgent = "Dalvik/2.1.0 (Linux; U; Android 15) [FBAN/Stella;FBAV/289.0.0.25.162;FBSN/Android;FBSV/15;FBLC/en_US]"

    static func authorize(state: String) -> URL {
        var c = URLComponents(string: authorizeURL)!
        c.queryItems = [.init(name: "app_id", value: appID),
                        .init(name: "scope", value: "openid"),
                        .init(name: "response_type", value: "code"),
                        .init(name: "redirect_uri", value: redirectURI),
                        .init(name: "state", value: state)]
        return c.url!
    }

    /// The redirect carries ?code=… (or #code=…); pull it out of whatever the
    /// in-app browser hands back.
    static func code(from url: URL) -> String? {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let q = comps?.queryItems, let c = q.first(where: { $0.name == "code" })?.value { return c }
        if let frag = comps?.fragment, let c = URLComponents(string: "?\(frag)")?
            .queryItems?.first(where: { $0.name == "code" })?.value { return c }
        return nil
    }
}

// MARK: - HTTP

struct MetaClient {
    var log: (String) -> Void = { _ in }

    private func post(_ url: String, fields: [String: String],
                      gzipped: Bool = false, bearer: String? = nil) async throws -> (Int, Data) {
        var body = fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&")
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(Meta.userAgent, forHTTPHeaderField: "User-Agent")
        if let b = bearer { req.setValue("OAuth \(b)", forHTTPHeaderField: "Authorization") }
        var payload = Data(body.utf8)
        if gzipped, let gz = Gzip.encode(payload) {
            payload = gz
            req.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }
        req.httpBody = payload
        log("POST \(url)\(gzipped ? " [gzip]" : "")")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        body.removeAll()
        return (code, data)
    }

    /// code -> { access_token, … } for the Meta AI app identity.
    func exchangeCode(_ code: String) async throws -> String {
        let (status, data) = try await post(Meta.exchangeURL,
            fields: ["mt_app_id": Meta.appID, "oidc_auth_code": code, "redirect_uri": Meta.redirectURI])
        guard status / 100 == 2,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["access_token"] as? String else {
            throw LinkError.unexpected("token exchange \(status): \(String(decoding: data, as: UTF8.self).prefix(300))")
        }
        return token
    }

    /// FRLA: exchange the app token + user token for AR-graph session cookies and
    /// the AR-scoped access token that pair_request wants.
    func exchangeFRLA(userToken: String) async throws -> String {
        let (status, data) = try await post("\(Meta.arHost)/login", fields: [
            "access_token": Meta.arAppToken,
            "frl_access_token": userToken,
            "logging_session_id": UUID().uuidString,
            "device_id": UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString,
            "format": "json",
            "generate_session_cookies": "1",
            "generate_analytics_claim": "1",
        ])
        guard status / 100 == 2,
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ar = obj["access_token"] as? String else {
            throw LinkError.unexpected("frla \(status): \(String(decoding: data, as: UTF8.self).prefix(300))")
        }
        return ar
    }

    struct ReceiptPair { let signature: Data; let body: Data }

    /// /pair_request: we hand Meta our device cert, serial, nonce and public key.
    /// It answers with a receipt whose signature the glasses will check.
    func pairRequest(arToken: String, identity: Session.Identity,
                     deviceNonce: Data, appPubkey: Data,
                     secondaryCert: Data = Data()) async throws -> ReceiptPair {
        let additional: [String: Any] = [
            "device_nonce": deviceNonce.base64EncodedString(),
            "app_pubkey": appPubkey.base64EncodedString(),
            "secondary_cert": secondaryCert.base64EncodedString(),
        ]
        let additionalJSON = String(decoding: try JSONSerialization.data(withJSONObject: additional), as: UTF8.self)
        let (status, data) = try await post("\(Meta.hwGraph)/pair_request", fields: [
            "access_token": Meta.hwAppToken,
            "user_access_token": arToken,
            "user_token_universe": "ar",
            "pair_protocol_version": Meta.pairProtocolVersion,
            "device_cert": identity.cert.base64EncodedString(),
            "serial_number": identity.serial,
            "additional_data": additionalJSON,
        ], gzipped: true, bearer: arToken)
        guard status / 100 == 2 else {
            throw LinkError.unexpected("pair_request \(status): \(String(decoding: data, as: UTF8.self).prefix(400))")
        }
        return try Self.receipt(from: data, label: "pair_request")
    }

    /// /pair: replay with the glasses' counter-receipt; Meta returns the final one.
    func pair(arToken: String, identity: Session.Identity, devicePending: ReceiptPair) async throws -> ReceiptPair {
        var fields: [String: String] = [
            "access_token": Meta.hwAppToken,
            "user_access_token": arToken,
            "user_token_universe": "ar",
            "pair_protocol_version": Meta.pairProtocolVersion,
            "device_cert": identity.cert.base64EncodedString(),
            "serial_number": identity.serial,
            "device_pending_ownership_receipt": devicePending.body.base64EncodedString(),
            "device_pending_ownership_receipt_signature": devicePending.signature.base64EncodedString(),
        ]
        var req = URLRequest(url: URL(string: "\(Meta.hwGraph)/pair")!)
        req.httpMethod = "POST"
        let body = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&")
        fields.removeAll()
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(Meta.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("OAuth \(arToken)", forHTTPHeaderField: "Authorization")
        var payload = Data(body.utf8)
        if let gz = Gzip.encode(payload) {
            payload = gz
            req.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        }
        req.httpBody = payload
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status / 100 == 2 else {
            throw LinkError.unexpected("pair \(status): \(String(decoding: data, as: UTF8.self).prefix(400))")
        }
        return try Self.receipt(from: data, label: "pair")
    }

    /// Receipts arrive either as JSON (base64 fields) or as the raw protobuf shape
    /// {1: signature, 2: body}. Accept both.
    static func receipt(from data: Data, label: String) throws -> ReceiptPair {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let sigKey = ["pending_ownership_receipt_signature", "ownership_receipt_signature", "signature"]
            let bodyKey = ["pending_ownership_receipt", "final_ownership_receipt", "ownership_receipt", "receipt"]
            if let s = sigKey.compactMap({ obj[$0] as? String }).first,
               let b = bodyKey.compactMap({ obj[$0] as? String }).first,
               let sig = Data(base64Encoded: s), let body = Data(base64Encoded: b) {
                return ReceiptPair(signature: sig, body: body)
            }
        }
        if let f = try? PB.parse(data), let sig = f[1]?.first as? Data, let body = f[2]?.first as? Data {
            return ReceiptPair(signature: sig, body: body)
        }
        throw LinkError.unexpected("\(label): cannot read receipt from \(String(decoding: data, as: UTF8.self).prefix(300))")
    }
}

// MARK: - the whole provisioning run

enum Provisioner {
    /// Requires a live session whose handshake ran with `trust: false`.
    static func becomeOwner(session: Session, owner: OwnerMaterial,
                            userToken: String, log: @escaping (String) -> Void) async throws -> OwnerMaterial.Bundle {
        let meta = MetaClient(log: log)

        log("① identity()")
        let identity = try session.identity()
        log("   serial=\(identity.serial) cert=\(identity.cert.count)B")

        log("② skip_challenge()")
        let nonce = try session.skipChallenge()
        log("   nonce=\(nonce.hexShort)")

        log("③ Meta /pair_request")
        let arToken = try await meta.exchangeFRLA(userToken: userToken)
        let pending = try await meta.pairRequest(arToken: arToken, identity: identity,
                                                 deviceNonce: nonce, appPubkey: owner.publicKey65)
        log("   pending receipt \(pending.signature.count)B sig / \(pending.body.count)B body")

        log("④ svc36 START_CHANGE_OWNER — 若 4 秒没反应，按一下眼镜的拍摄键")
        let devicePending = try session.startChangeOwner(pending: encodeReceipt(pending),
                                                         onWait: { log("   ⚠️ 请按一下眼镜上的拍摄键") })
        let parsed = try decodeReceipt(devicePending)
        log("   device receipt \(parsed.signature.count)B sig")

        log("⑤ Meta /pair")
        let final = try await meta.pair(arToken: arToken, identity: identity, devicePending: parsed)

        log("⑥ svc36 FINISH_CHANGE_OWNER")
        try session.finishChangeOwner(final: encodeReceipt(final))
        log("   完成：这副眼镜现在认这台 iPhone 的 key")

        let bundle = OwnerMaterial.Bundle(
            serial: identity.serial,
            publicKeyXy: owner.publicKeyXy.base64EncodedString(),
            privateKeyPkcs8: pkcs8(from: owner).base64EncodedString(),
            receipt: .init(signature: final.signature.base64EncodedString(),
                           body: final.body.base64EncodedString()))
        try owner.save(bundle: bundle)
        return bundle
    }

    /// Receipt wire shape: {1: signature, 2: json body}
    static func encodeReceipt(_ r: MetaClient.ReceiptPair) -> Data {
        PB.bytes(1, r.signature) + PB.bytes(2, r.body)
    }

    static func decodeReceipt(_ data: Data) throws -> MetaClient.ReceiptPair {
        let f = try PB.parse(data)
        guard let sig = f[1]?.first as? Data else { throw LinkError.unexpected("no receipt signature") }
        return MetaClient.ReceiptPair(signature: sig, body: (f[2]?.first as? Data) ?? Data())
    }

    /// Wrap a raw scalar into PKCS#8 so the exported bundle matches what
    /// pi/provision.py and the Android exporter write.
    static func pkcs8(from owner: OwnerMaterial) -> Data {
        // ECPrivateKey ::= SEQUENCE { 1, OCTET STRING(32), [0] OID, [1] BIT STRING }
        let oidP256: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
        var inner = Data([0x02, 0x01, 0x01])                     // version 1
        inner += Data([0x04, 0x20]) + owner.scalar               // privateKey
        inner += Data([0xA0]) + tlvLen(oidP256.count) + Data(oidP256)
        let pub = owner.publicKey65
        let bitString = Data([0x00]) + pub                        // unused-bits byte + key
        inner += Data([0xA1]) + tlvLen(bitString.count + 2) + Data([0x03]) + tlvLen(bitString.count) + bitString
        let innerSeq = Data([0x30]) + tlvLen(inner.count) + inner
        let algId = Data([0x30, 0x13]) + Data(oidP256) + Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        let outer = Data([0x02, 0x01, 0x00]) + algId + Data([0x04]) + tlvLen(innerSeq.count) + innerSeq
        return Data([0x30]) + tlvLen(outer.count) + outer
    }

    static func tlvLen(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        if n <= 0xFF { return Data([0x81, UInt8(n)]) }
        return Data([0x82, UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
    }
}
