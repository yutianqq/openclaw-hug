import os
import sys
import json
import tarfile
import re
import argparse
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

    # Preserve runtime-only providers (not from env vars) across restarts
    env_slugs = set(provider_slugs())
    if old_cfg and "models" in old_cfg and "providers" in old_cfg["models"]:
        for slug, p in old_cfg["models"]["providers"].items():
            if slug not in providers and slug not in env_slugs:
                providers[slug] = p
                for mid_obj in p.get("models", []):
                    mid = mid_obj["id"]
                    ref = f"{slug}/{mid}"
                    agent_models[ref] = {"alias": mid}
                    id_to_slugs.setdefault(mid, []).append(slug)
                print(f"Preserved runtime provider: {slug}")

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


def _load_config():
    config_path = os.path.join(OPENCLAW_DIR, "openclaw.json")
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"Error reading config: {e}")
        return None

def _save_config(cfg):
    config_path = os.path.join(OPENCLAW_DIR, "openclaw.json")
    with open(config_path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)

def _mask_key(key):
    if not key or len(key) < 12:
        return "***"
    return f"{key[:4]}...{key[-4:]}"

def list_providers():
    cfg = _load_config()
    if not cfg:
        return
    providers = cfg.get("models", {}).get("providers", {})
    if not providers:
        print("No providers configured.")
        return
    model_cfg = cfg.get("agents", {}).get("defaults", {}).get("model", {})
    primary = (model_cfg.get("primary") or "") if isinstance(model_cfg, dict) else ""
    fallbacks = (model_cfg.get("fallbacks") or []) if isinstance(model_cfg, dict) else []
    print(f"{'Slug':<16} {'Base URL':<45} {'Models':<30} {'API Key'}")
    print("-" * 110)
    for slug, p in providers.items():
        marker = " [PRIMARY]" if primary.startswith(f"{slug}/") else ""
        for fb in fallbacks:
            if fb.startswith(f"{slug}/"):
                marker += " [FALLBACK]"
        models_str = ", ".join(m["id"] for m in p.get("models", []))
        print(f"{slug:<16} {p.get('baseUrl', ''):<45} {models_str:<30} {_mask_key(p.get('apiKey', ''))}{marker}")
    print(f"\nPrimary: {primary or '<unset>'}")
    print(f"Fallbacks: {', '.join(fallbacks) if fallbacks else '<none>'}")

def update_provider(args):
    cfg = _load_config()
    if not cfg:
        return
    if "models" not in cfg:
        cfg["models"] = {}
    if "providers" not in cfg["models"]:
        cfg["models"]["providers"] = {}

    providers = cfg["models"]["providers"]
    action = args.action
    slug = args.slug.lower()

    if action == "add":
        if slug in providers:
            print(f"Error: Provider '{slug}' already exists. Use --action update to modify.")
            return
        if not args.base_url or not args.models or not args.api_key:
            print("Error: --base-url, --models, and --api-key are required for add.")
            return
        models_list = [{"id": m.strip(), "name": m.strip()} for m in args.models.split(",") if m.strip()]
        providers[slug] = {
            "baseUrl": args.base_url,
            "apiKey": args.api_key,
            "api": "openai-completions",
            "models": models_list,
        }
        _save_config(cfg)
        print(f"Provider '{slug}' added: base={args.base_url}, models={[m['id'] for m in models_list]}, key={_mask_key(args.api_key)}")
        print("Config saved. Changes take effect immediately (hot-reload).")

    elif action == "remove":
        if slug not in providers:
            print(f"Error: Provider '{slug}' not found.")
            return
        model_cfg = cfg.get("agents", {}).get("defaults", {}).get("model", {})
        primary = (model_cfg.get("primary") or "") if isinstance(model_cfg, dict) else ""
        fallbacks = (model_cfg.get("fallbacks") or []) if isinstance(model_cfg, dict) else []
        if primary.startswith(f"{slug}/"):
            print(f"Error: Provider '{slug}' is the current PRIMARY model ({primary}). Change primary first.")
            return
        any_fb = [fb for fb in fallbacks if fb.startswith(f"{slug}/")]
        if any_fb:
            print(f"Error: Provider '{slug}' has fallback refs: {any_fb}. Remove from fallbacks first.")
            return
        del providers[slug]
        _save_config(cfg)
        print(f"Provider '{slug}' removed.")
        print("Config saved. Changes take effect immediately (hot-reload).")

    elif action == "update":
        if slug not in providers:
            print(f"Error: Provider '{slug}' not found. Use --action add to create it.")
            return
        p = providers[slug]
        if args.base_url:
            p["baseUrl"] = args.base_url
        if args.models:
            p["models"] = [{"id": m.strip(), "name": m.strip()} for m in args.models.split(",") if m.strip()]
        if args.api_key:
            p["apiKey"] = args.api_key
        _save_config(cfg)
        print(f"Provider '{slug}' updated:")
        print(f"  baseUrl: {p.get('baseUrl', '<unchanged>')}")
        print(f"  models:   {[m['id'] for m in p.get('models', [])]}")
        print(f"  apiKey:  {_mask_key(p.get('apiKey', '<unchanged>'))}")
        print("Config saved. Changes take effect immediately (hot-reload).")

    elif action == "set-primary":
        if slug not in providers:
            print(f"Error: Provider '{slug}' not found.")
            return
        if not args.model:
            mids = providers[slug].get("models", [])
            if not mids:
                print(f"Error: Provider '{slug}' has no models. Cannot set as primary.")
                return
            ref = f"{slug}/{mids[0]['id']}"
            print(f"No --model specified, using first model: {ref}")
        else:
            ref = f"{slug}/{args.model}"
        if "agents" not in cfg:
            cfg["agents"] = {}
        if "defaults" not in cfg["agents"]:
            cfg["agents"]["defaults"] = {}
        if "model" not in cfg["agents"]["defaults"]:
            cfg["agents"]["defaults"]["model"] = {"primary": ref, "fallbacks": []}
        else:
            cfg["agents"]["defaults"]["model"]["primary"] = ref
        _save_config(cfg)
        print(f"Primary model set to: {ref}")
        print("Config saved. Changes take effect immediately (hot-reload).")

    else:
        print(f"Unknown action: {action}. Use: add | remove | update | set-primary")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "backup":
        backup()
    elif len(sys.argv) > 1 and sys.argv[1] == "generate_config":
        generate_config()
    elif len(sys.argv) > 1 and sys.argv[1] == "update_provider":
        parser = argparse.ArgumentParser(description="Runtime provider management")
        parser.add_argument("--action", required=True, choices=["add", "remove", "update", "set-primary"])
        parser.add_argument("--slug", required=True, help="Provider slug name")
        parser.add_argument("--base-url", default="", help="API base URL")
        parser.add_argument("--models", default="", help="Comma-separated model IDs")
        parser.add_argument("--api-key", default="", help="API key")
        parser.add_argument("--model", default="", help="Model ID (for set-primary)")
        args = parser.parse_args(sys.argv[2:])
        update_provider(args)
    elif len(sys.argv) > 1 and sys.argv[1] == "list_providers":
        list_providers()
    else:
        restore()