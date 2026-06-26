from fastapi import APIRouter, Depends, HTTPException, Response
from sqlalchemy.orm import Session
from ..database import get_db
from ..models import User
from ..schemas import UserRegister, UserLogin
from .. import auth as auth_module

router = APIRouter(prefix="/api/auth", tags=["auth"])


@router.post("/register")
def register(payload: UserRegister, db: Session = Depends(get_db)):
    existing = db.query(User).filter(User.username == payload.username).first()
    if existing:
        raise HTTPException(status_code=409, detail="Username already exists")
    user = User(
        username=payload.username,
        password_hash=auth_module.hash_password(payload.password),
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    token = auth_module.create_access_token({"sub": str(user.id)})
    return {"token": token, "username": user.username}


@router.post("/login")
def login(payload: UserLogin, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.username == payload.username).first()
    if not user or not auth_module.verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    token = auth_module.create_access_token({"sub": str(user.id)})
    return {"token": token, "username": user.username}


@router.get("/me")
def me(user: User = Depends(auth_module.get_current_user)):
    return {"id": user.id, "username": user.username, "created_at": user.created_at.isoformat()}
