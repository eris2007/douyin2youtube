"""抖音 → YouTube 转推控制面板 - FastAPI 应用入口"""

from fastapi import FastAPI, Request, Depends
from fastapi.responses import RedirectResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles
from pathlib import Path
from jinja2 import Environment, FileSystemLoader
from sqlalchemy.orm import Session

from .database import init_db, get_db, SessionLocal
from .routers import auth as auth_router, nodes as nodes_router
from .routers import tasks as tasks_router, dashboard as dashboard_router
from . import auth as auth_module
from .models import User

app = FastAPI(title="Douyin2YouTube Panel", version="1.0")
init_db()

BASE_DIR = Path(__file__).resolve().parent
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")

jinja_env = Environment(loader=FileSystemLoader(str(BASE_DIR / "templates")), enable_async=True)

app.include_router(auth_router.router)
app.include_router(nodes_router.router)
app.include_router(tasks_router.router)
app.include_router(dashboard_router.router)


async def get_current_user_from_request(request: Request) -> User | None:
    """从请求中获取当前用户，不抛出异常"""
    db = SessionLocal()
    try:
        return auth_module.get_current_user(request, db)
    except Exception:
        return None
    finally:
        db.close()


def require_auth(request: Request):
    """在模板上下文中注入用户信息，未登录则重定向"""
    pass  # handled in each route


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    user = await get_current_user_from_request(request)
    if not user:
        return RedirectResponse(url="/login")
    return RedirectResponse(url="/dashboard")


@app.get("/login", response_class=HTMLResponse)
async def login_page(request: Request):
    user = await get_current_user_from_request(request)
    if user:
        return RedirectResponse(url="/dashboard")
    template = jinja_env.get_template("login.html")
    return HTMLResponse(await template.render_async(request=request))


@app.get("/register", response_class=HTMLResponse)
async def register_page(request: Request):
    user = await get_current_user_from_request(request)
    if user:
        return RedirectResponse(url="/dashboard")
    template = jinja_env.get_template("register.html")
    return HTMLResponse(await template.render_async(request=request))


@app.get("/dashboard", response_class=HTMLResponse)
async def dashboard_page(request: Request):
    user = await get_current_user_from_request(request)
    if not user:
        return RedirectResponse(url="/login")
    template = jinja_env.get_template("dashboard.html")
    return HTMLResponse(await template.render_async(request=request, username=user.username))


@app.get("/nodes", response_class=HTMLResponse)
async def nodes_page(request: Request):
    user = await get_current_user_from_request(request)
    if not user:
        return RedirectResponse(url="/login")
    template = jinja_env.get_template("nodes.html")
    return HTMLResponse(await template.render_async(request=request, username=user.username))


@app.get("/tasks", response_class=HTMLResponse)
async def tasks_page(request: Request):
    user = await get_current_user_from_request(request)
    if not user:
        return RedirectResponse(url="/login")
    template = jinja_env.get_template("tasks.html")
    return HTMLResponse(await template.render_async(request=request, username=user.username))


@app.get("/tasks/{task_id}", response_class=HTMLResponse)
async def task_detail_page(task_id: int, request: Request):
    user = await get_current_user_from_request(request)
    if not user:
        return RedirectResponse(url="/login")
    template = jinja_env.get_template("task_detail.html")
    return HTMLResponse(await template.render_async(request=request, username=user.username, task_id=task_id))


@app.get("/settings", response_class=HTMLResponse)
async def settings_page(request: Request):
    user = await get_current_user_from_request(request)
    if not user:
        return RedirectResponse(url="/login")
    template = jinja_env.get_template("settings.html")
    return HTMLResponse(await template.render_async(request=request, username=user.username))


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("panel.main:app", host="0.0.0.0", port=8000, reload=True)
