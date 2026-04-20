from flask import Blueprint, render_template
from app.auth import login_required, group_required

main_bp = Blueprint("main", __name__)


@main_bp.route("/")
def index():
    return render_template("index.html")


@main_bp.route("/public")
@group_required("admins", "developers", "viewers")
def public():
    return render_template("public.html")


@main_bp.route("/dashboard")
@group_required("admins", "developers")
def dashboard():
    return render_template("dashboard.html")


@main_bp.route("/admin")
@group_required("admins")
def admin():
    return render_template("admin.html")


@main_bp.route("/profile")
@login_required
def profile():
    return render_template("profile.html")


@main_bp.route("/unauthorized")
def unauthorized():
    return render_template("unauthorized.html"), 403
