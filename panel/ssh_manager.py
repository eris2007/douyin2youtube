"""asyncssh 封装：连接 VPS、执行命令、部署脚本"""

from __future__ import annotations

import asyncio
import asyncssh
from typing import AsyncIterator
from .config import SSH_TIMEOUT
from .models import VpsNode
from . import auth as auth_module


def _get_ssh_password(node: VpsNode) -> str:
    if node.ssh_auth_type == "password" and node.ssh_password_enc:
        return auth_module.decrypt_sensitive(node.ssh_password_enc)
    return ""


def _get_ssh_key(node: VpsNode) -> str:
    if node.ssh_auth_type == "key" and node.ssh_key_enc:
        return auth_module.decrypt_sensitive(node.ssh_key_enc)
    return ""


def _get_sk(node: VpsNode) -> asyncssh.SSHKey | None:
    if node.ssh_auth_type == "key":
        key_str = _get_ssh_key(node)
        if key_str:
            return asyncssh.import_private_key(key_str)
    return None


async def test_connection(node: VpsNode) -> tuple[bool, str]:
    """测试 SSH 连接"""
    try:
        conn_kwargs = dict(
            host=node.host,
            port=node.port,
            username=node.ssh_username,
            known_hosts=None,
            connect_timeout=SSH_TIMEOUT,
        )
        if node.ssh_auth_type == "key":
            conn_kwargs["client_keys"] = [_get_sk(node)]
        else:
            conn_kwargs["password"] = _get_ssh_password(node)

        async with asyncssh.connect(**conn_kwargs) as conn:
            result = await conn.run("whoami && uname -a", timeout=SSH_TIMEOUT)
            return True, result.stdout.strip()
    except Exception as e:
        return False, str(e)


async def run_command(
    node: VpsNode,
    command: str,
    timeout: int = SSH_TIMEOUT,
) -> tuple[int, str, str]:
    """在 VPS 上执行命令，返回 (exit_code, stdout, stderr)"""
    conn_kwargs = dict(
        host=node.host,
        port=node.port,
        username=node.ssh_username,
        known_hosts=None,
        connect_timeout=SSH_TIMEOUT,
    )
    if node.ssh_auth_type == "key":
        conn_kwargs["client_keys"] = [_get_sk(node)]
    else:
        conn_kwargs["password"] = _get_ssh_password(node)

    async with asyncssh.connect(**conn_kwargs) as conn:
        result = await conn.run(command, timeout=timeout)
        return result.exit_status, result.stdout.strip(), result.stderr.strip()


async def run_command_stream(
    node: VpsNode,
    command: str,
) -> AsyncIterator[str]:
    """在 VPS 上执行命令，流式返回 stdout 行"""
    conn_kwargs = dict(
        host=node.host,
        port=node.port,
        username=node.ssh_username,
        known_hosts=None,
        connect_timeout=SSH_TIMEOUT,
    )
    if node.ssh_auth_type == "key":
        conn_kwargs["client_keys"] = [_get_sk(node)]
    else:
        conn_kwargs["password"] = _get_ssh_password(node)

    async with asyncssh.connect(**conn_kwargs) as conn:
        async with conn.create_process(command) as process:
            async for line in process.stdout:
                yield line.rstrip("\n")
            async for line in process.stderr:
                yield line.rstrip("\n")


async def deploy_scripts(node: VpsNode) -> tuple[bool, str]:
    """部署脚本到 VPS：创建目录，git clone 或下载脚本"""
    ok, msg = await test_connection(node)
    if not ok:
        return False, f"SSH 连接失败: {msg}"

    script_path = node.script_path or "/root/douyin2youtube"
    lines = []

    async for line in run_command_stream(node, f"mkdir -p {script_path}"):
        lines.append(line)

    repo = node.github_repo or "https://github.com/yourname/douyin2youtube.git"

    if repo.endswith(".git") or "github.com" in repo:
        install_cmd = (
            f"cd {script_path} && "
            f"if [ -d .git ]; then git pull; else git clone {repo} . ; fi && "
            f"chmod +x *.sh && "
            f"which streamlink ffmpeg || (apt-get update && apt-get install -y streamlink ffmpeg)"
        )
    else:
        install_cmd = (
            f"cd {script_path} && "
            f"curl -sL {repo} -o restream.tar.gz && tar xzf restream.tar.gz && "
            f"chmod +x *.sh"
        )

    async for line in run_command_stream(node, install_cmd):
        lines.append(line)

    return True, "\n".join(lines)
