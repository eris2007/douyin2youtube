from datetime import datetime, timezone
from sqlalchemy import Column, Integer, String, Text, DateTime, ForeignKey
from sqlalchemy.orm import relationship
from .database import Base


def now():
    return datetime.now(timezone.utc)


class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True, autoincrement=True)
    username = Column(String(64), unique=True, nullable=False, index=True)
    password_hash = Column(String(256), nullable=False)
    created_at = Column(DateTime, default=now)
    vps_nodes = relationship("VpsNode", back_populates="owner", cascade="all, delete-orphan")
    tasks = relationship("RestreamTask", back_populates="owner", cascade="all, delete-orphan")


class VpsNode(Base):
    __tablename__ = "vps_nodes"
    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    name = Column(String(128), nullable=False)
    host = Column(String(256), nullable=False)
    port = Column(Integer, default=22)
    ssh_username = Column(String(64), default="root")
    ssh_auth_type = Column(String(16), default="password")  # "password" | "key"
    ssh_password_enc = Column(String(512))
    ssh_key_enc = Column(Text)
    script_path = Column(String(512), default="/root/douyin2youtube")
    github_repo = Column(String(512), default="")
    status = Column(String(16), default="pending")  # "online" / "offline" / "pending"
    last_seen = Column(DateTime)
    created_at = Column(DateTime, default=now)
    owner = relationship("User", back_populates="vps_nodes")
    tasks = relationship("RestreamTask", back_populates="vps_node", cascade="all, delete-orphan")


class RestreamTask(Base):
    __tablename__ = "restream_tasks"
    id = Column(Integer, primary_key=True, autoincrement=True)
    vps_node_id = Column(Integer, ForeignKey("vps_nodes.id"), nullable=False)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False)
    douyin_url = Column(String(1024), nullable=False)
    youtube_key_masked = Column(String(64), default="****")
    youtube_key_enc = Column(String(512))
    task_type = Column(String(16), default="restream")  # "restream" | "record"
    backup_urls = Column(Text)
    pid = Column(Integer)
    status = Column(String(16), default="stopped")  # "running" / "stopped" / "error"
    started_at = Column(DateTime)
    stopped_at = Column(DateTime)
    created_at = Column(DateTime, default=now)
    vps_node = relationship("VpsNode", back_populates="tasks")
    owner = relationship("User", back_populates="tasks")
