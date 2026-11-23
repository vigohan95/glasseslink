// OwnerExport.kt — patch to add to your own Visor build (app module).
//
// Why you need this: if Visor created the owner key inside the Android Keystore
// (KeyGenParameterSpec, hardware-backed), the private key can never leave the phone.
// Building Visor yourself lets you generate a *software* P-256 key instead, export it,
// then throw the Android phone away — the glasses only ever verify a signature.
//
// Where to hook: Visor's owner-key construction site, core/identity (OwnerKeyStore /
// identity module). Search for `KeyGenParameterSpec`, `AndroidKeyStore`, `ECGenParameterSpec`.
// Replace the key generation with softwareOwnerKey() and add exportOwner() to whatever
// screen has a "developer" section (or call it from onCreate once, behind a flag).

package dev.local.visorexport

import android.util.Base64
import java.io.File
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.ECGenParameterSpec

object OwnerExport {

    private const val FILE = "owner-export.json"

    /** Software P-256 key. Deliberately NOT in the Android Keystore so it can be exported. */
    fun softwareOwnerKey(): java.security.KeyPair {
        val g = KeyPairGenerator.getInstance("EC")
        g.initialize(ECGenParameterSpec("secp256r1"))
        return g.generateKeyPair()
    }

    /** Raw r||s (64B) ECDSA over an already-computed 32B digest — matches NONEwithECDSA. */
    fun signRaw(kp: java.security.KeyPair, digest: ByteArray): ByteArray {
        val sig = Signature.getInstance("NONEwithECDSA")
        sig.initSign(kp.private)
        sig.update(digest)
        val der = sig.sign()
        return derToRaw(der)
    }

    private fun derToRaw(der: ByteArray): ByteArray {
        // SEQUENCE { INTEGER r, INTEGER s } -> 0x00-padded 32B each
        var i = 0
        require(der[i] == 0x30.toByte()); i++
        if (der[i].toInt() and 0x80 != 0) i += (der[i].toInt() and 0x7f) + 1
        fun readInt(): ByteArray {
            require(der[i] == 0x02.toByte()); i++
            val len = der[i].toInt(); i++
            val v = der.copyOfRange(i, i + len); i += len
            val trimmed = if (v.size > 32) v.copyOfRange(v.size - 32, v.size) else v
            return ByteArray(32 - trimmed.size) + trimmed
        }
        val r = readInt()
        val s = readInt()
        return r + s
    }

    /**
     * @param receipt the ownership receipt bytes Visor got from Meta at pairing time
     *                (grep the identity module for `receipt` / `ownership`).
     * @param pubXy   64-byte public key, x||y, no 0x04 — same layout the glasses use on the wire.
     */
    fun exportOwner(ctx: android.content.Context, kp: java.security.KeyPair,
                    receipt: ByteArray, pubXy: ByteArray) {
        val priv = kp.private.encoded // PKCS#8 DER
        val json = """
        {
          "version": 1,
          "curve": "secp256r1",
          "publicKeyXy": "${b64(pubXy)}",
          "privateKeyPkcs8": "${b64(priv)}",
          "receipt": "${b64(receipt)}",
          "note": "import into the iOS client once, then the Android device is disposable"
        }
        """.trimIndent()
        val out = File(ctx.getExternalFilesDir(null), FILE)
        out.writeText(json)
        // Pull it with:  adb pull /sdcard/Android/data/<pkg>/files/owner-export.json
    }

    private fun b64(b: ByteArray): String = Base64.encodeToString(b, Base64.NO_WRAP)
}

/*
Also flip this in the connection layer while you are at it (debug builds only):
  wire.log  ->  already written by the debug variant of Visor; keep it enabled.
You will need one session's worth of svc36 traffic to confirm the trust message
layout on iOS (see PROTOCOL-NOTES.md, section 6).
*/
