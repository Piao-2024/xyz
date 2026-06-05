#!/usr/bin/env python3
"""
通过 QQ SMTP 发送通知邮件。
配置文件：同目录下的 .email_config（不被 Git 跟踪）
"""

import os
import smtplib
import sys
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from datetime import datetime


def load_config():
    """从外部文件加载邮箱配置，避免凭证提交到 Git。"""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    config_path = os.path.join(script_dir, ".email_config")

    if not os.path.exists(config_path):
        print("ERROR: 配置文件不存在，请创建 scripts/.email_config", file=sys.stderr)
        return None

    config = {}
    with open(config_path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, value = line.partition("=")
                config[key.strip()] = value.strip().strip('"')
    return config

SMTP_HOST = "smtp.qq.com"
SMTP_PORT = 587


def format_duration(seconds: int) -> str:
    """将秒数转为可读时长"""
    if not seconds:
        return "未知"
    m = seconds // 60
    s = seconds % 60
    return f"{m}分{s}秒"


def build_email(subject: str, new_eps_raw: str) -> str:
    """
    构建 HTML 邮件内容。
    new_eps_raw: 每行格式为 "标题|发布日期|时长"
    """
    lines = new_eps_raw.strip().split("\n")

    rows_html = ""
    for line in lines:
        parts = line.split("|")
        if len(parts) >= 3:
            title = parts[0]
            pub_date = parts[1]
            duration = format_duration(int(parts[2]) if parts[2].isdigit() else 0)
            rows_html += f"""
            <tr>
                <td style="padding:10px 12px;border-bottom:1px solid #eee">
                    <strong>{title}</strong><br>
                    <small style="color:#999">发布时间: {pub_date} | 时长: {duration}</small>
                </td>
            </tr>"""

    return f"""<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#f5f5f5;padding:20px">
<div style="max-width:560px;margin:0 auto;background:#fff;border-radius:8px;overflow:hidden">
    <div style="background:#07c160;color:#fff;padding:20px;text-align:center">
        <h2 style="margin:0">🎙️ 哎哟嚯Radio 更新提醒</h2>
    </div>
    <div style="padding:16px 20px">
        <p style="color:#333">你订阅的 <b>哎哟嚯Radio</b> 有新单集发布：</p>
        <table style="width:100%;border-collapse:collapse">
            {rows_html}
        </table>
        <p style="margin-top:16px;color:#999;font-size:13px">
            发送时间: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
        </p>
    </div>
</div>
</body>
</html>"""


def send_email(subject: str, new_eps_raw: str) -> bool:
    config = load_config()
    if not config:
        return False

    qq_email = config.get("QQ_EMAIL", "")
    smtp_password = config.get("QQ_SMTP_PASSWORD", "")
    to_email = config.get("TO_EMAIL", qq_email)

    if not qq_email or not smtp_password:
        print("ERROR: .email_config 中缺少 QQ_EMAIL 或 QQ_SMTP_PASSWORD", file=sys.stderr)
        return False

    msg = MIMEMultipart("alternative")
    msg["Subject"] = subject
    msg["From"] = qq_email
    msg["To"] = to_email

    html_content = build_email(subject, new_eps_raw)
    msg.attach(MIMEText(html_content, "html", "utf-8"))

    try:
        server = smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=15)
        server.starttls()
        server.login(qq_email, smtp_password)
        server.sendmail(qq_email, [to_email], msg.as_string())
        server.quit()
        print("邮件发送成功")
        return True
    except smtplib.SMTPAuthenticationError as e:
        print(f"SMTP 认证失败，请检查邮箱地址和授权码: {e}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"邮件发送失败: {e}", file=sys.stderr)
        return False


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("用法: send_qq_email.py <邮件主题> <单集数据>")
        print("单集数据格式: 每行 '标题|发布日期|时长'")
        sys.exit(1)

    subject = sys.argv[1]
    eps_data = sys.argv[2]
    success = send_email(subject, eps_data)
    sys.exit(0 if success else 1)
