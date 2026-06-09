import os
import sys
import json
import tarfile
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

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "backup":
        backup()
    else:
        restore()