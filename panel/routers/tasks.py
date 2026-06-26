import asyncio
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import StreamingResponse
from sqlalchemy.orm import Session
from datetime import datetime, timezone
from ..database import get_db
from ..models import User, VpsNode, RestreamTask
from ..schemas import TaskCreate, TaskOut
from .. import auth as auth_module
from .. import ssh_manager

router = APIRouter(prefix="/api/tasks", tags=["tasks"])


def _mask_key(key: str) -> str:
    if len(key) <= 8:
        return "****"
    return key[:4] + "****" + key[-4:]


def _task_out(task: RestreamTask) -> dict:
    vps_name = task.vps_node.name if task.vps_node else ""
    return {
        "id": task.id,
        "vps_node_id": task.vps_node_id,
        "vps_name": vps_name,
        "douyin_url": task.douyin_url,
        "youtube_key_masked": task.youtube_key_masked,
        "task_type": task.task_type,
        "backup_urls": task.backup_urls,
        "pid": task.pid,
        "status": task.status,
        "started_at": task.started_at,
        "stopped_at": task.stopped_at,
        "created_at": task.created_at,
    }


@router.get("")
def list_tasks(
    vps_node_id: int = None,
    status: str = None,
    user: User = Depends(auth_module.get_current_user),
    db: Session = Depends(get_db),
):
    q = db.query(RestreamTask).filter(RestreamTask.user_id == user.id)
    if vps_node_id:
        q = q.filter(RestreamTask.vps_node_id == vps_node_id)
    if status:
        q = q.filter(RestreamTask.status == status)
    tasks = q.order_by(RestreamTask.created_at.desc()).limit(50).all()
    return [_task_out(t) for t in tasks]


@router.get("/{task_id}")
def get_task(task_id: int, user: User = Depends(auth_module.get_current_user), db: Session = Depends(get_db)):
    task = db.query(RestreamTask).filter(
        RestreamTask.id == task_id, RestreamTask.user_id == user.id
    ).first()
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    return _task_out(task)


@router.post("")
async def create_task(
    payload: TaskCreate,
    user: User = Depends(auth_module.get_current_user),
    db: Session = Depends(get_db),
):
    node = db.query(VpsNode).filter(
        VpsNode.id == payload.vps_node_id, VpsNode.user_id == user.id
    ).first()
    if not node:
        raise HTTPException(status_code=404, detail="VPS node not found")

    task = RestreamTask(
        vps_node_id=node.id,
        user_id=user.id,
        douyin_url=payload.douyin_url,
        youtube_key_masked=_mask_key(payload.youtube_key),
        youtube_key_enc=auth_module.encrypt_sensitive(payload.youtube_key),
        task_type=payload.task_type,
        backup_urls=payload.backup_urls,
        status="running",
        started_at=datetime.now(timezone.utc),
    )
    db.add(task)
    db.commit()
    db.refresh(task)

    script_dir = node.script_path

    if payload.task_type == "record":
        cmd = (
            f"cd {script_dir} && "
            f"bash record.sh '{payload.douyin_url}' '{task.id}' '{payload.backup_urls or ''}'"
        )
    else:
        cmd = (
            f"cd {script_dir} && "
            f"bash start.sh '{payload.douyin_url}' '{auth_module.decrypt_sensitive(task.youtube_key_enc)}' "
            f"'{task.id}' '{payload.backup_urls or ''}'"
        )

    try:
        exit_code, stdout, stderr = await ssh_manager.run_command(node, cmd, timeout=30)
        if exit_code == 0:
            task.pid = 0  # actual pid on vps side is managed by start.sh
            task.status = "running"
            db.commit()
            return _task_out(task)
        else:
            task.status = "error"
            task.stopped_at = datetime.now(timezone.utc)
            db.commit()
            raise HTTPException(status_code=400, detail=f"Start failed: {stderr or stdout}")
    except HTTPException:
        raise
    except Exception as e:
        task.status = "error"
        task.stopped_at = datetime.now(timezone.utc)
        db.commit()
        raise HTTPException(status_code=400, detail=f"SSH error: {str(e)}")


@router.delete("/{task_id}")
async def stop_task(
    task_id: int,
    user: User = Depends(auth_module.get_current_user),
    db: Session = Depends(get_db),
):
    task = db.query(RestreamTask).filter(
        RestreamTask.id == task_id, RestreamTask.user_id == user.id
    ).first()
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")
    if task.status != "running":
        raise HTTPException(status_code=400, detail="Task is not running")

    node = task.vps_node
    script_dir = node.script_path
    cmd = f"cd {script_dir} && bash stop.sh 'task{task.id}'"

    try:
        await ssh_manager.run_command(node, cmd, timeout=15)
    except Exception:
        pass

    task.status = "stopped"
    task.stopped_at = datetime.now(timezone.utc)
    db.commit()
    return _task_out(task)


@router.get("/{task_id}/logs")
async def task_logs(
    task_id: int,
    user: User = Depends(auth_module.get_current_user),
    db: Session = Depends(get_db),
):
    task = db.query(RestreamTask).filter(
        RestreamTask.id == task_id, RestreamTask.user_id == user.id
    ).first()
    if not task:
        raise HTTPException(status_code=404, detail="Task not found")

    node = task.vps_node
    if task.task_type == "record":
        log_path = f"{node.script_path}/logs/recording_{task.id}.log"
    else:
        log_path = f"{node.script_path}/logs/restream_task{task.id}.log"

    async def event_stream():
        yield f"data: [系统] 正在连接 VPS 获取日志...\n\n"
        try:
            async for line in ssh_manager.run_command_stream(node, f"tail -f -n 100 {log_path}"):
                safe_line = line.replace("\n", " ").replace("\r", "")
                yield f"data: {safe_line}\n\n"
        except Exception as e:
            yield f"data: [错误] {str(e)}\n\n"
        yield f"data: [系统] 日志流结束\n\n"

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )
