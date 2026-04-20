from functools import wraps
from flask import Blueprint, session, redirect, url_for
from app import config

auth_bp = Blueprint("auth", __name__)


def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if "user" not in session:
            return redirect(url_for("auth.login"))
        return f(*args, **kwargs)
    return decorated


def group_required(*group_names):
    def decorator(f):
        @wraps(f)
        def decorated(*args, **kwargs):
            if "user" not in session:
                return redirect(url_for("auth.login"))
            user_groups = session.get("user_groups", [])
            if not any(g in user_groups for g in group_names):
                return redirect(url_for("main.unauthorized"))
            return f(*args, **kwargs)
        return decorated
    return decorator


@auth_bp.route("/login")
def login():
    from app import oauth
    redirect_uri = f"{config.APP_URL}/callback"
    return oauth.keycloak.authorize_redirect(redirect_uri)


@auth_bp.route("/callback")
def callback():
    from app import oauth
    token = oauth.keycloak.authorize_access_token()
    userinfo = token.get("userinfo")

    if userinfo is None:
        resp = oauth.keycloak.get(
            f"{config.KEYCLOAK_URL}/realms/{config.KEYCLOAK_REALM}/protocol/openid-connect/userinfo"
        )
        userinfo = resp.json()

    groups = userinfo.get("groups", [])
    groups = [g.strip("/") for g in groups]

    session["user"] = userinfo
    session["token"] = token
    session["user_groups"] = groups

    return redirect(url_for("main.index"))


@auth_bp.route("/logout")
def logout():
    token = session.get("token", {})
    id_token = token.get("id_token", "")
    session.clear()

    logout_url = (
        f"http://localhost:8080/realms/{config.KEYCLOAK_REALM}/protocol/openid-connect/logout?"
        f"post_logout_redirect_uri={config.APP_URL}&"
        f"client_id={config.KEYCLOAK_CLIENT_ID}&"
        f"id_token_hint={id_token}"
    )
    return redirect(logout_url)
