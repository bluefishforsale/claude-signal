"""Imports Signal Desktop history from the Windows side of a WSL2 machine.

signal-mcp only reads the Signal Desktop install on the OS it runs on, so from
WSL it would look in ~/.config/Signal and find nothing. The Windows database is
reachable through /mnt/c, but its key is protected with DPAPI, which only
Windows can undo. So the one Windows-only step runs through powershell.exe and
the rest is upstream's own import, pointed at the Windows profile.

Run with signal-mcp's venv Python: wsl_history.py /mnt/c/Users/me/AppData/Roaming/Signal
"""

import base64
import json
import subprocess
import sys
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from signal_mcp import desktop

# Reads base64 on stdin so the protected key never appears on a command line.
_UNPROTECT = (
    "Add-Type -AssemblyName System.Security;"
    "$b=[Convert]::FromBase64String([Console]::In.ReadToEnd());"
    "[Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Unprotect($b,$null,'CurrentUser'))"
)


def dpapi_unprotect(blob: bytes) -> bytes:
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", _UNPROTECT],
        input=base64.b64encode(blob).decode(),
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise desktop.DesktopImportError(
            f"DPAPI unprotect via powershell.exe failed (run as the Windows user who uses Signal Desktop): {result.stderr.strip()}"
        )
    return base64.b64decode(result.stdout.strip())


def decrypt_db_key(encrypted_hex: str, local_state: dict, unprotect=dpapi_unprotect) -> str:
    """Return Signal Desktop's SQLCipher key (an ASCII hex string) from config.json's encryptedKey.

    Current Electron on Windows encrypts with AES-256-GCM ("v10" + 12-byte nonce
    + ciphertext and tag) under a key kept DPAPI-wrapped in Local State. Older
    builds DPAPI-protected the value directly, so that's the fallback.
    """
    raw = bytes.fromhex(encrypted_hex)
    wrapped_b64 = local_state.get("os_crypt", {}).get("encrypted_key")
    if raw[:3] in (b"v10", b"v11") and wrapped_b64:
        wrapped = base64.b64decode(wrapped_b64)
        if wrapped[:5] != b"DPAPI":
            raise desktop.DesktopImportError("Local State os_crypt.encrypted_key lacks the DPAPI prefix")
        aes_key = unprotect(wrapped[5:])
        plaintext = AESGCM(aes_key).decrypt(raw[3:15], raw[15:], None)
    else:
        plaintext = unprotect(raw[3:] if raw[:3] in (b"v10", b"v11") else raw)
    # NOTE: the key is stored as ASCII hex. Hex-encoding it again (as upstream's
    # Windows path does) yields a wrong key and an unreadable database.
    return plaintext.decode("ascii")


def main(signal_dir: Path) -> None:
    local_state_path = signal_dir / "Local State"
    local_state = json.loads(local_state_path.read_text()) if local_state_path.exists() else {}
    # NOTE: patches a private upstream function; signal-mcp is pinned, so
    # recheck this name against desktop.py whenever SIGNAL_MCP_VERSION changes.
    desktop._get_db_key_hex = lambda encrypted_hex: decrypt_db_key(encrypted_hex, local_state)
    try:
        result = desktop.import_from_desktop(progress_cb=lambda msg: print(f"  {msg}"), signal_dir=signal_dir)
    except desktop.DesktopImportError as e:
        sys.exit(f"error: {e}")
    print(f"Done: {result['imported']} imported, {result['skipped']} already stored ({result['total']} total)")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
