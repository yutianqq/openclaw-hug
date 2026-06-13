import os
import sys
import json
import tarfile
import re
from huggingface_hub import HfApi, hf_hub_download

api = HfApi()
repo_id = os.getenv("HF_DATASET")
token = os.getenv("HF_TOKEN")
FILENAME = "latest_backup.tar.gz"

OPENCLAW_DIR = "/root/.openclaw"

def get_workspace_path():
    config_path = os.path.join(OPENCLAW_DIR, "openclaw.json")
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            config = json.load(f)
        workspace = config.get("agents", {}).get("defaults", {}).get("workspace", "")
        if workspace and os.path.exists(workspace):
            return workspace
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    
    default_workspace = os.path.join(OPENCLAW_DIR, "workspace")
    if os.path.exists(default_workspace):
        return default_workspace
    
    return None

def restore():
    try:
        if not repo_id or not token:
            print("Skip Restore: HF_DATASET or HF_TOKEN not set")
            return
        
        print(f"Downloading {FILENAME} from {repo_id}...")
        path = hf_hub_download(repo_id=repo_id, filename=FILENAME, repo_type="dataset", token=token)
        
        with tarfile.open(path, "r:gz") as tar:
            for member in tar.getmembers():
                if member.name == "openclaw.json" or member.name.endswith("/openclaw.json"):
                    continue
                tar.extract(member, path=OPENCLAW_DIR)
        
        print(f"Success: Restored from {FILENAME}")
        return True
    except Exception as e:
        print(f"Restore Note: No existing backup found or error: {e}")

def backup():
    try:
        if not repo_id or not token:
            print("Skip Backup: HF_DATASET or HF_TOKEN not set")
            return

        workspace = get_workspace_path()

        paths_to_backup = [
            ("credentials", os.path.join(OPENCLAW_DIR, "credentials")),
            ("cron", os.path.join(OPENCLAW_DIR, "cron")),
            ("agents/main/agent", os.path.join(OPENCLAW_DIR, "agents", "main", "agent")),
            ("skills", os.path.join(OPENCLAW_DIR, "skills")),
        ]

        if workspace:
            persona_files = ["SOUL.md", "AGENTS.md", "IDENTITY.md", "USER.md", "TOOLS.md", "MEMORY.md", "HEARTBEAT.md"]
            for fname in persona_files:
                fpath = os.path.join(workspace, fname)
                if os.path.exists(fpath):
                    paths_to_backup.append((f"workspace/{fname}", fpath))
            
            workspace_skills = os.path.join(workspace, "skills")
            if os.path.exists(workspace_skills):
                paths_to_backup.append(("workspace/skills", workspace_skills))

        with tarfile.open(FILENAME, "w:gz") as tar:
            for arcname, p in paths_to_backup:
                if os.path.exists(p):
                    tar.add(p, arcname=arcname)

        api.upload_file(
            path_or_fileobj=FILENAME,
            path_in_repo=FILENAME,
            repo_id=repo_id,
            repo_type="dataset",
            token=token
        )
        os.remove(FILENAME)
        print(f"Backup {FILENAME} Success (Overwritten).")
    except Exception as e:
        print(f"Backup Error: {e}")

def generate_config():
    """从环境变量读取配置，生成 /root/.openclaw/openclaw.json"""
    def parse_list(s):
        return [x.strip() for x in (s or "").split(",") if x.strip()]

    def clean_base(url):
        if not url:
            return ""
        u = url.strip()
        u = re.sub(r"/chat/completions/?$", "", u)
        u = re.sub(r"/v1/?$", "/v1", u)
        return u

    def provider_slugs():
        raw = os.environ.get("PROVIDERS", "").strip()
        if raw:
            return [s.strip().lower() for s in raw.split(",") if s.strip()]
        if os.environ.get("OPENAI_API_BASE") or os.environ.get("MODELS") or os.environ.get("OPENAI_API_KEY"):
            return [os.environ.get("PROVIDER_NAME", "default").strip().lower() or "default"]
        return []

    def load_provider(slug):
        key = slug.upper()
        base = clean_base(os.environ.get(f"{key}_OPENAI_API_BASE", ""))
        models = parse_list(os.environ.get(f"{key}_MODELS", ""))
        api_key = os.environ.get(f"{key}_API_KEY", "")
        if slug == os.environ.get("PROVIDER_NAME", "default").strip().lower():
            base = base or clean_base(os.environ.get("OPENAI_API_BASE", ""))
            models = models or parse_list(os.environ.get("MODELS", ""))
            api_key = api_key or os.environ.get("OPENAI_API_KEY", "")
        return base, models, api_key

    enabled = os.environ.get("QQ_BOT_ENABLED_PY") == "True"
    app_id = os.environ.get("QQ_APP_ID", "")
    secret = os.environ.get("QQ_CLIENT_SECRET", "")
    model = os.environ.get("MODEL", "").strip()
    fallbacks_raw = os.environ.get("MODEL_FALLBACKS", "")
    port = int(os.environ.get("PORT", "7860"))
    gw_token = os.environ.get("OPENCLAW_GATEWAY_PASSWORD", "")

    id_to_slugs = {}
    providers = {}
    agent_models = {}
    failed_providers = []

    for slug in provider_slugs():
        base, model_ids, api_key = load_provider(slug)
        missing = []
        if not api_key:
            missing.append(f"{slug.upper()}_API_KEY")
        if not base:
            missing.append(f"{slug.upper()}_OPENAI_API_BASE")
        if not model_ids:
            missing.append(f"{slug.upper()}_MODELS")
        if missing:
            print(f"WARN: Provider '{slug}' SKIPPED — missing: {', '.join(missing)}")
            failed_providers.append(slug)
            continue

        providers[slug] = {
            "baseUrl": base,
            "apiKey": api_key,
            "api": "openai-completions",
            "models": [{"id": mid, "name": mid} for mid in model_ids],
        }
        for mid in model_ids:
            ref = f"{slug}/{mid}"
            agent_models[ref] = {"alias": mid}
            id_to_slugs.setdefault(mid, []).append(slug)

    def resolve_ref(item):
        item = item.strip()
        if not item:
            return item
        if "/" in item:
            return item
        slugs = id_to_slugs.get(item, [])
        if len(slugs) == 1:
            return f"{slugs[0]}/{item}"
        if len(slugs) > 1:
            print(f"WARN: model id '{item}' exists on multiple providers {slugs}; use provider/model_id")
        return item

    def resolve_primary():
        if model:
            return resolve_ref(model)
        for slug in provider_slugs():
            if slug in providers:
                mids = providers[slug]["models"]
                if mids:
                    return f"{slug}/{mids[0]['id']}"
        return None

    def resolve_fallbacks(primary):
        out = []
        for item in parse_list(fallbacks_raw):
            ref = resolve_ref(item)
            if ref and ref != primary and ref not in out:
                out.append(ref)
        return out

    primary = resolve_primary()
    fallbacks = resolve_fallbacks(primary) if primary else []

    agents_defaults = {}
    if agent_models:
        agents_defaults["models"] = agent_models
    if primary:
        agents_defaults["model"] = {"primary": primary, "fallbacks": fallbacks}

    cfg = {
        "update": {"checkOnStart": True, "auto": {"enabled": True}},
        "models": {"mode": "merge", "providers": providers},
        "agents": {"defaults": agents_defaults},
        "commands": {"restart": True},
        "plugins": {
            "allow": (["qqbot", "workboard"] if enabled else ["workboard"]),
            "entries": {
                "qqbot": {"enabled": enabled},
                "workboard": {"enabled": True},
            },
        },
        "gateway": {
            "mode": "local",
            "bind": "lan",
            "port": port,
            "trustedProxies": ["0.0.0.0/0"],
            "auth": {"mode": "token", "token": gw_token},
            "controlUi": {
                "enabled": True,
                "allowInsecureAuth": True,
                "dangerouslyDisableDeviceAuth": True,
                "dangerouslyAllowHostHeaderOriginFallback": True,
            },
        },
        "channels": {
            "qqbot": {
                "enabled": enabled,
                "appId": app_id,
                "clientSecret": secret,
                "dmPolicy": "open",
                "groupPolicy": "open",
                "requireMention": True,
                "markdownSupport": True,
                "c2cMarkdownDeliveryMode": "proactive-all",
            }
        },
    }

    config_path = "/root/.openclaw/openclaw.json"
    old_cfg = None
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            old_cfg = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        pass

    if old_cfg and "cron" in old_cfg:
        cfg["cron"] = old_cfg["cron"]
        print(f"Merged existing cron config from previous {config_path}")

    with open(config_path, "w", encoding="utf-8") as f:
        cfg.setdefault("session", {}).update({
            "dmScope": "per-channel-peer",
            "maintenance": {
                "mode": "enforce",
                "pruneAfter": "1d",
                "maxEntries": 200,
            },
        })
        json.dump(cfg, f, indent=2, ensure_ascii=False)

    total_models = sum(len(p["models"]) for p in providers.values())
    print(
        f"Wrote {config_path} (qqbot={enabled}, primary={primary or 'unset'}, "
        f"providers={','.join(providers.keys()) or 'none'}, models={total_models})"
    )
    if not providers:
        print("WARN: no provider configured — set PROVIDERS and per-provider Variables/Secrets")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "backup":
        backup()
    elif len(sys.argv) > 1 and sys.argv[1] == "generate_config":
        generate_config()
    else:
        restore()