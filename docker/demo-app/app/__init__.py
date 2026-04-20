from flask import Flask, session
from authlib.integrations.flask_client import OAuth
from app import config
from app.auth import auth_bp
from app.routes import main_bp

oauth = OAuth()


def create_app():
    app = Flask(__name__)
    app.secret_key = config.SESSION_SECRET

    oauth.init_app(app)

    # CRITICAL: authorize_url uses localhost (browser-facing)
    # access_token_url uses docker service name (container-to-container)
    oauth.register(
        name="keycloak",
        client_id=config.KEYCLOAK_CLIENT_ID,
        client_secret=config.KEYCLOAK_CLIENT_SECRET,
        authorize_url=f"http://localhost:8080/realms/{config.KEYCLOAK_REALM}/protocol/openid-connect/auth",
        access_token_url=f"{config.KEYCLOAK_URL}/realms/{config.KEYCLOAK_REALM}/protocol/openid-connect/token",
        jwks_uri=f"{config.KEYCLOAK_URL}/realms/{config.KEYCLOAK_REALM}/protocol/openid-connect/certs",
        client_kwargs={
            "scope": "openid email profile",
            "verify": False,
        },
    )

    app.register_blueprint(auth_bp)
    app.register_blueprint(main_bp)

    @app.context_processor
    def inject_globals():
        user = session.get("user", {})
        groups = session.get("user_groups", [])
        return {
            "user": user,
            "user_name": user.get("name") or user.get("preferred_username", "User"),
            "groups": groups,
            "is_admin": "admins" in groups,
            "is_developer": "developers" in groups,
            "is_viewer": "viewers" in groups or "admins" in groups or "developers" in groups,
        }

    return app
