"""简单的 AES 加密工具，用于保护数据库中存储的 SSH 密码和密钥"""

import base64
import hashlib
import os
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes


def _derive_key(master: str) -> bytes:
    return hashlib.sha256(master.encode("utf-8")).digest()


def encrypt(plaintext: str, master_key: str) -> str:
    key = _derive_key(master_key)
    iv = os.urandom(16)
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv))
    encryptor = cipher.encryptor()
    padded = plaintext.encode("utf-8")
    pad_len = 16 - (len(padded) % 16)
    padded += bytes([pad_len]) * pad_len
    ciphertext = encryptor.update(padded) + encryptor.finalize()
    return base64.b64encode(iv + ciphertext).decode("ascii")


def decrypt(token: str, master_key: str) -> str:
    key = _derive_key(master_key)
    raw = base64.b64decode(token)
    iv, ciphertext = raw[:16], raw[16:]
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv))
    decryptor = cipher.decryptor()
    padded = decryptor.update(ciphertext) + decryptor.finalize()
    pad_len = padded[-1]
    return padded[:-pad_len].decode("utf-8")
