from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from ..database import get_db
from ..models import User, VpsNode
from ..schemas import VpsNodeCreate, VpsNodeUpdate, VpsNodeOut
from .. import auth as auth_module
from .. import ssh_manager

router = APIRouter(prefix="/api/nodes", tags=["nodes"])


def _node_out(node: VpsNode) -> dict:
    return {
        "id": node.id,
        "name": node.name,
        "host": node.host,
        "port": node.port,
        "ssh_username": node.ssh_username,
        "ssh_auth_type": node.ssh_auth_type,
        "script_path": node.script_path,
        "github_repo": node.github_repo,
        "status": node.status,
        "last_seen": node.last_seen,
        "created_at": node.created_at,
    }


@router.get("")
def list_nodes(user: User = Depends(auth_module.get_current_user), db: Session = Depends(get_db)):
    nodes = db.query(VpsNode).filter(VpsNode.user_id == user.id).order_by(VpsNode.created_at.desc()).all()
    return [_node_out(n) for n in nodes]


@router.post("")
def create_node(payload: VpsNodeCreate, user: User = Depends(auth_module.get_current_user), db: Session = Depends(get_db)):
    node = VpsNode(
        user_id=user.id,
        name=payload.name,
        host=payload.host,
        port=payload.port,
        ssh_username=payload.ssh_username,
        ssh_auth_type=payload.ssh_auth_type,
        script_path=payload.script_path,
        github_repo=payload.github_repo,
    )
    if payload.ssh_auth_type == "password" and payload.ssh_password:
        node.ssh_password_enc = auth_module.encrypt_sensitive(payload.ssh_password)
    elif payload.ssh_auth_type == "key" and payload.ssh_key:
        node.ssh_key_enc = auth_module.encrypt_sensitive(payload.ssh_key)
    db.add(node)
    db.commit()
    db.refresh(node)
    return _node_out(node)


@router.put("/{node_id}")
def update_node(node_id: int, payload: VpsNodeUpdate, user: User = Depends(auth_module.get_current_user), db: Session = Depends(get_db)):
    node = db.query(VpsNode).filter(VpsNode.id == node_id, VpsNode.user_id == user.id).first()
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")
    for field, value in payload.model_dump(exclude_unset=True).items():
        if field in ("ssh_password", "ssh_key"):
            continue
        setattr(node, field, value)
    if payload.ssh_password:
        node.ssh_password_enc = auth_module.encrypt_sensitive(payload.ssh_password)
    if payload.ssh_key:
        node.ssh_key_enc = auth_module.encrypt_sensitive(payload.ssh_key)
    db.commit()
    db.refresh(node)
    return _node_out(node)


@router.delete("/{node_id}")
def delete_node(node_id: int, user: User = Depends(auth_module.get_current_user), db: Session = Depends(get_db)):
    node = db.query(VpsNode).filter(VpsNode.id == node_id, VpsNode.user_id == user.id).first()
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")
    db.delete(node)
    db.commit()
    return {"ok": True}


@router.post("/{node_id}/test")
async def test_node(node_id: int, user: User = Depends(auth_module.get_current_user), db: Session = Depends(get_db)):
    node = db.query(VpsNode).filter(VpsNode.id == node_id, VpsNode.user_id == user.id).first()
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")
    ok, msg = await ssh_manager.test_connection(node)
    return {"ok": ok, "message": msg}


@router.post("/{node_id}/deploy")
async def deploy_node(node_id: int, user: User = Depends(auth_module.get_current_user), db: Session = Depends(get_db)):
    node = db.query(VpsNode).filter(VpsNode.id == node_id, VpsNode.user_id == user.id).first()
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")
    ok, msg = await ssh_manager.deploy_scripts(node)
    return {"ok": ok, "message": msg}


@router.get("/{node_id}/status")
async def node_status(node_id: int, user: User = Depends(auth_module.get_current_user), db: Session = Depends(get_db)):
    node = db.query(VpsNode).filter(VpsNode.id == node_id, VpsNode.user_id == user.id).first()
    if not node:
        raise HTTPException(status_code=404, detail="Node not found")
    ok, msg = await ssh_manager.test_connection(node)
    return {"ok": ok, "message": msg}
