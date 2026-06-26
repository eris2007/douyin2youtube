from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session
from ..database import get_db
from ..models import User, VpsNode, RestreamTask
from .. import auth as auth_module

router = APIRouter(prefix="/api/dashboard", tags=["dashboard"])


@router.get("")
def dashboard(user: User = Depends(auth_module.get_current_user), db: Session = Depends(get_db)):
    total_nodes = db.query(VpsNode).filter(VpsNode.user_id == user.id).count()
    online_nodes = db.query(VpsNode).filter(
        VpsNode.user_id == user.id, VpsNode.status == "online"
    ).count()
    running_tasks = db.query(RestreamTask).filter(
        RestreamTask.user_id == user.id, RestreamTask.status == "running"
    ).count()
    stopped_tasks = db.query(RestreamTask).filter(
        RestreamTask.user_id == user.id, RestreamTask.status == "stopped"
    ).count()

    recent = (
        db.query(RestreamTask)
        .filter(RestreamTask.user_id == user.id)
        .order_by(RestreamTask.created_at.desc())
        .limit(10)
        .all()
    )

    task_outs = []
    for t in recent:
        vps_name = t.vps_node.name if t.vps_node else ""
        task_outs.append({
            "id": t.id,
            "vps_node_id": t.vps_node_id,
            "vps_name": vps_name,
            "douyin_url": t.douyin_url,
            "youtube_key_masked": t.youtube_key_masked,
            "task_type": t.task_type,
            "backup_urls": t.backup_urls,
            "pid": t.pid,
            "status": t.status,
            "started_at": t.started_at,
            "stopped_at": t.stopped_at,
            "created_at": t.created_at,
        })

    return {
        "total_nodes": total_nodes,
        "online_nodes": online_nodes,
        "running_tasks": running_tasks,
        "stopped_tasks": stopped_tasks,
        "recent_tasks": task_outs,
    }
