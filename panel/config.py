from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
DATABASE_URL = f"sqlite:///{BASE_DIR / 'panel.db'}"
SECRET_KEY = "change-me-in-production-use-random-string"
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 60 * 24 * 7  # 7 days
SSH_TIMEOUT = 15
ENCRYPTION_KEY = "change-me-encryption-key-32b"  # 敏感信息加密
