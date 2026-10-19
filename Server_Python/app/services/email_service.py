from email.message import EmailMessage
import smtplib
import ssl
import logging

from app.core.config import settings
from app.core.exceptions import AppError


logger = logging.getLogger(__name__)


def _normalize_security_mode(raw_mode: str | None, port: int) -> str:
    mode = (raw_mode or "auto").strip().lower()
    if mode in {"ssl", "smtps"}:
        return "ssl"
    if mode in {"starttls", "tls"}:
        return "starttls"
    if mode in {"auto", ""}:
        return "ssl" if port == 465 else "starttls"
    raise AppError(
        "SMTP_INVALID_SECURITY_MODE",
        "SMTP_SECURITY must be one of: auto, ssl, starttls",
        status_code=500,
    )


def _send_with_ssl(
    *,
    smtp_host: str,
    smtp_port: int,
    smtp_user: str,
    smtp_pass: str,
    message: EmailMessage,
) -> None:
    context = ssl.create_default_context()
    with smtplib.SMTP_SSL(smtp_host, smtp_port, timeout=10, context=context) as server:
        server.login(smtp_user, smtp_pass)
        server.send_message(message)


def _send_with_starttls(
    *,
    smtp_host: str,
    smtp_port: int,
    smtp_user: str,
    smtp_pass: str,
    message: EmailMessage,
) -> None:
    context = ssl.create_default_context()
    with smtplib.SMTP(smtp_host, smtp_port, timeout=10) as server:
        server.ehlo()
        server.starttls(context=context)
        server.ehlo()
        server.login(smtp_user, smtp_pass)
        server.send_message(message)


def _send_email(*, target_email: str, subject: str, body: str) -> None:
    smtp_host = settings.smtp_host
    smtp_user = settings.smtp_user
    smtp_pass = settings.smtp_pass
    smtp_from = (settings.smtp_from or "").strip() or smtp_user
    smtp_port = settings.smtp_port if settings.smtp_port is not None else 465
    smtp_security = _normalize_security_mode(settings.smtp_security, smtp_port)

    if smtp_host is None or smtp_user is None or smtp_pass is None:
        raise AppError(
            "SMTP_NOT_CONFIGURED",
            "SMTP is not configured; cannot send onboarding email",
            status_code=502,
        )

    message = EmailMessage()
    message["Subject"] = subject
    message["From"] = smtp_from
    message["To"] = target_email
    message.set_content(body)

    try:
        if smtp_security == "ssl":
            _send_with_ssl(
                smtp_host=smtp_host,
                smtp_port=smtp_port,
                smtp_user=smtp_user,
                smtp_pass=smtp_pass,
                message=message,
            )
        else:
            _send_with_starttls(
                smtp_host=smtp_host,
                smtp_port=smtp_port,
                smtp_user=smtp_user,
                smtp_pass=smtp_pass,
                message=message,
            )
    except Exception as exc:
        logger.exception(
            "SMTP_EMAIL_DELIVERY_FAILED host=%s port=%s security=%s target_email=%s",
            smtp_host,
            smtp_port,
            smtp_security,
            target_email,
        )
        raise AppError(
            "EMAIL_DELIVERY_FAILED",
            "Could not send email",
            status_code=502,
            details={
                "reason": str(exc),
                "smtp_host": smtp_host,
                "smtp_port": smtp_port,
                "smtp_security": smtp_security,
            },
        ) from exc


def send_new_user_email(target_email: str, full_name: str, temporary_password: str) -> None:
    body = "\n".join(
        [
            f"Hi {full_name},",
            "",
            "Your Blockchain Inventory System account has been created.",
            f"Temporary password: {temporary_password}",
            "Please login and change your password immediately.",
            "Please do not reply to this email address.",
        ]
    )
    _send_email(target_email=target_email, subject="BIS account created", body=body)


def send_password_reset_otp_email(target_email: str, otp_code: str) -> None:
    body = "\n".join(
        [
            "Password reset OTP requested.",
            "",
            f"OTP code: {otp_code}",
            "This OTP is valid for 15 minutes.",
            "If you did not request it, contact your administrator immediately.",
            "Please do not reply to this email address.",
        ]
    )
    _send_email(target_email=target_email, subject="BIS password reset OTP", body=body)


def send_security_alert_email(target_email: str, *, title: str, details: dict) -> None:
    lines = [title, ""]
    for key, value in details.items():
        lines.append(f"{key}: {value}")
    _send_email(target_email=target_email, subject="BIS security alert", body="\n".join(lines))
