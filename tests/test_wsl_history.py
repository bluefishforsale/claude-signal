import base64
import os
import sys
import unittest
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import wsl_history  # noqa: E402

DB_KEY = "3a0aaac0" * 8  # Signal Desktop's SQLCipher key: 64 ASCII hex chars


def identity(blob: bytes) -> bytes:
    return blob


class DecryptDbKey(unittest.TestCase):
    def test_gcm_key_comes_back_as_ascii_hex_not_double_hex_encoded(self):
        aes_key, nonce = os.urandom(32), os.urandom(12)
        encrypted = b"v10" + nonce + AESGCM(aes_key).encrypt(nonce, DB_KEY.encode(), None)
        local_state = {"os_crypt": {"encrypted_key": base64.b64encode(b"DPAPI" + aes_key).decode()}}
        self.assertEqual(wsl_history.decrypt_db_key(encrypted.hex(), local_state, identity), DB_KEY)

    def test_raw_dpapi_value_is_used_when_local_state_has_no_key(self):
        self.assertEqual(wsl_history.decrypt_db_key(DB_KEY.encode().hex(), {}, identity), DB_KEY)

    def test_local_state_key_without_dpapi_prefix_is_rejected(self):
        local_state = {"os_crypt": {"encrypted_key": base64.b64encode(b"XXXXX" + os.urandom(32)).decode()}}
        with self.assertRaises(wsl_history.desktop.DesktopImportError):
            wsl_history.decrypt_db_key((b"v10" + os.urandom(40)).hex(), local_state, identity)


if __name__ == "__main__":
    unittest.main()
