from pydantic import BaseModel, Field
from typing import Optional
from datetime import datetime


class UserRegister(BaseModel):
    username: str = Field(..., min_length=2, max_length=64)
    password: str = Field(..., min_length=6, max_length=128)


class UserLogin(BaseModel):
    username: str
    password: str


class VpsNodeCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=128)
    host: str = Field(..., min_length=1, max_length=256)
    port: int = Field(22, ge=1, le=65535)
    ssh_username: str = Field("root", max_length=64)
    ssh_auth_type: str = Field("password", pattern="^(password|key)$")
    ssh_password: Optional[str] = Field(None, max_length=256)
    ssh_key: Optional[str] = None
    script_path: str = Field("/root/douyin2youtube", max_length=512)
    github_repo: str = Field("https://github.com/yourname/douyin2youtube.git", max_length=512)


class VpsNodeUpdate(BaseModel):
    name: Optional[str] = None
    host: Optional[str] = None
    port: Optional[int] = None
    ssh_username: Optional[str] = None
    ssh_auth_type: Optional[str] = None
    ssh_password: Optional[str] = None
    ssh_key: Optional[str] = None
    script_path: Optional[str] = None
    github_repo: Optional[str] = None


class VpsNodeOut(BaseModel):
    id: int
    name: str
    host: str
    port: int
    ssh_username: str
    ssh_auth_type: str
    script_path: str
    github_repo: str
    status: str
    last_seen: Optional[datetime]
    created_at: datetime

    class Config:
        from_attributes = True


class TaskCreate(BaseModel):
    vps_node_id: int
    douyin_url: str = Field(..., min_length=5, max_length=1024)
    youtube_key: str = Field(..., min_length=4, max_length=256)
    task_type: str = Field("restream", pattern="^(restream|record)$")
    backup_urls: Optional[str] = None


class TaskOut(BaseModel):
    id: int
    vps_node_id: int
    vps_name: str = ""
    douyin_url: str
    youtube_key_masked: str
    task_type: str
    backup_urls: Optional[str]
    pid: Optional[int]
    status: str
    started_at: Optional[datetime]
    stopped_at: Optional[datetime]
    created_at: datetime

    class Config:
        from_attributes = True


class DashboardOut(BaseModel):
    total_nodes: int
    online_nodes: int
    running_tasks: int
    stopped_tasks: int
    recent_tasks: list[TaskOut]
